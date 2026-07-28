// The fixed ACLC protocol is derived from MagSafe Dark by Mark Kats
// (MIT License). See THIRD_PARTY_NOTICES.md.

#include <MagSafeSMC.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define SOCKET_PATH "/var/run/com.mikita.codex-capslock-indicator.magsafe.sock"
#define MAX_COMMAND_LENGTH 64
#define CLIENT_TIMEOUT_SECONDS 1
#define LEASE_TIMEOUT_MILLISECONDS 3000
#define PROTOCOL_VERSION 2

static volatile sig_atomic_t stopping = 0;
static int server_socket = -1;
static int active_client = -1;

static void handle_signal(int signal_number) {
    (void)signal_number;
    stopping = 1;
    if (active_client >= 0) {
        (void)shutdown(active_client, SHUT_RDWR);
    }
    if (server_socket >= 0) {
        close(server_socket);
        server_socket = -1;
    }
}

static long long monotonic_milliseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0;
    }
    return (long long)value.tv_sec * 1000LL + value.tv_nsec / 1000000LL;
}

static int write_all(int descriptor, const char *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(descriptor, bytes + offset, length - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return 0;
        }
    }
    return 1;
}

static void send_response(int client, int status, const char *message) {
    char response[320];
    int length = snprintf(response, sizeof(response), "%d\t%s\n", status, message);
    if (length > 0 && (size_t)length < sizeof(response)) {
        (void)write_all(client, response, (size_t)length);
    }
}

static int configure_client_socket(int client) {
    struct timeval timeout = {
        .tv_sec = CLIENT_TIMEOUT_SECONDS,
        .tv_usec = 0,
    };
    int no_signal = 1;
    return setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0
        && setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0
        && setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal)) == 0;
}

static int read_command(int client, char command[MAX_COMMAND_LENGTH + 1]) {
    size_t length = 0;
    int terminated = 0;

    while (!terminated) {
        unsigned char buffer[32];
        ssize_t count = read(client, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return 0;
        }

        for (ssize_t index = 0; index < count; index += 1) {
            unsigned char byte = buffer[index];
            if (byte == '\0') {
                return 0;
            }
            if (byte == '\r' || byte == '\n') {
                terminated = 1;
                for (ssize_t trailing = index + 1; trailing < count; trailing += 1) {
                    if (buffer[trailing] != '\r' && buffer[trailing] != '\n') {
                        return 0;
                    }
                }
                break;
            }
            if (length >= MAX_COMMAND_LENGTH) {
                return 0;
            }
            command[length] = (char)byte;
            length += 1;
        }
    }

    if (length == 0 || !terminated) {
        return 0;
    }
    command[length] = '\0';
    return 1;
}

static int active_console_user(uid_t *uid) {
    struct stat information;
    if (stat("/dev/console", &information) != 0 || information.st_uid == 0) {
        return 0;
    }
    *uid = information.st_uid;
    return 1;
}

static int peer_is_authorized(int client, uid_t *console_uid) {
    uid_t peer_uid = 0;
    gid_t peer_gid = 0;
    if (getpeereid(client, &peer_uid, &peer_gid) != 0) {
        return 0;
    }
    (void)peer_gid;

    uid_t current_console_uid = 0;
    if (!active_console_user(&current_console_uid)) {
        return peer_uid == 0;
    }
    if (peer_uid != 0 && peer_uid != current_console_uid) {
        return 0;
    }
    *console_uid = current_console_uid;
    return 1;
}

static void refresh_socket_owner(void) {
    uid_t uid = 0;
    if (!active_console_user(&uid)) {
        uid = 0;
    }
    (void)chown(SOCKET_PATH, uid, 0);
    (void)chmod(SOCKET_PATH, 0600);
}

static int register_idle_events(int event_queue, int console_descriptor) {
    struct kevent changes[2];
    EV_SET(
        &changes[0],
        (uintptr_t)server_socket,
        EVFILT_READ,
        EV_ADD | EV_ENABLE,
        0,
        0,
        NULL
    );
    EV_SET(
        &changes[1],
        (uintptr_t)console_descriptor,
        EVFILT_VNODE,
        EV_ADD | EV_ENABLE | EV_CLEAR,
        NOTE_ATTRIB | NOTE_DELETE | NOTE_RENAME,
        0,
        NULL
    );
    return kevent(event_queue, changes, 2, NULL, 0, NULL) == 0;
}

static int restore_system(void) {
    if (codex_smc_set_aclc(0) != 0) {
        return 0;
    }
    uint8_t actual = 255;
    return codex_smc_get_aclc(&actual) == 0 && actual == 0;
}

static int mode_value(const char *mode, uint8_t *value) {
    if (strcmp(mode, "system") == 0) {
        *value = 0;
    } else if (strcmp(mode, "green") == 0) {
        *value = 3;
    } else if (strcmp(mode, "flash") == 0) {
        *value = 5;
    } else if (strcmp(mode, "blink-slow") == 0) {
        *value = 6;
    } else if (strcmp(mode, "blink-fast") == 0) {
        *value = 7;
    } else {
        return 0;
    }
    return 1;
}

static int send_status(int client) {
    uint8_t value = 0;
    int result = codex_smc_get_aclc(&value);
    if (result != 0) {
        char error[160];
        snprintf(error, sizeof(error), "Unable to read ACLC (error %d)", result);
        send_response(client, 69, error);
        return 0;
    }
    char current[16];
    snprintf(current, sizeof(current), "%u", value);
    send_response(client, 0, current);
    return 1;
}

static int set_mode(int client, const char *mode) {
    uint8_t value = 0;
    if (!mode_value(mode, &value)) {
        send_response(client, 64, "Unknown mode");
        return 0;
    }
    int result = codex_smc_set_aclc(value);
    if (result != 0) {
        char error[160];
        snprintf(error, sizeof(error), "Unable to write ACLC (error %d)", result);
        send_response(client, 69, error);
        return 0;
    }
    send_response(client, 0, "ok");
    return 1;
}

static int process_lease_command(int client, const char *command) {
    if (strcmp(command, "ping") == 0) {
        send_response(client, 0, "pong");
        return 1;
    }
    if (strcmp(command, "probe") == 0) {
        uint8_t value = 0;
        if (codex_smc_get_aclc(&value) != 0) {
            send_response(client, 69, "ACLC unavailable");
            return 0;
        }
        send_response(client, 0, "supported");
        return 1;
    }
    if (strcmp(command, "status") == 0) {
        return send_status(client);
    }
    if (strncmp(command, "set ", 4) == 0) {
        return set_mode(client, command + 4);
    }
    send_response(client, 64, "Unknown protocol command");
    return 0;
}

static void run_lease(int client, uid_t lease_console_uid) {
    long long last_activity = monotonic_milliseconds();

    while (!stopping) {
        uid_t current_console_uid = 0;
        if (!active_console_user(&current_console_uid)
            || current_console_uid != lease_console_uid) {
            break;
        }

        struct pollfd descriptor = {
            .fd = client,
            .events = POLLIN | POLLHUP | POLLERR,
            .revents = 0,
        };
        int ready = poll(&descriptor, 1, 1000);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        long long now = monotonic_milliseconds();
        if (ready == 0) {
            if (now - last_activity >= LEASE_TIMEOUT_MILLISECONDS) {
                break;
            }
            continue;
        }
        if ((descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
            break;
        }

        char command[MAX_COMMAND_LENGTH + 1];
        if (!read_command(client, command)) {
            break;
        }
        last_activity = now;
        if (!process_lease_command(client, command)) {
            break;
        }
    }

    (void)restore_system();
}

static void process_client(int client) {
    uid_t lease_console_uid = 0;
    if (!peer_is_authorized(client, &lease_console_uid)) {
        send_response(client, 77, "Client is not root or the active console user");
        return;
    }
    if (!configure_client_socket(client)) {
        send_response(client, 70, "Unable to configure client socket");
        return;
    }

    char command[MAX_COMMAND_LENGTH + 1];
    if (!read_command(client, command)) {
        send_response(client, 64, "Invalid command");
        return;
    }
    if (strcmp(command, "hello 2") == 0) {
        send_response(client, 0, "ready");
        run_lease(client, lease_console_uid);
        return;
    }

    // Compatibility diagnostics are one-shot. Any mode change is restored
    // before ownership of the client connection is released.
    if (strcmp(command, "ping") == 0) {
        send_response(client, 0, "pong");
    } else if (strcmp(command, "probe") == 0) {
        uint8_t value = 0;
        if (codex_smc_get_aclc(&value) == 0) {
            send_response(client, 0, "supported");
        } else {
            send_response(client, 69, "ACLC unavailable");
        }
    } else if (strcmp(command, "status") == 0) {
        (void)send_status(client);
    } else {
        (void)set_mode(client, command);
        (void)restore_system();
    }
}

static int configure_signals(void) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGINT, &action, NULL) == 0
        && sigaction(SIGTERM, &action, NULL) == 0
        && sigaction(SIGHUP, &action, NULL) == 0;
}

int main(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "codex-capslock-magsafe-helper must run as root\n");
        return 77;
    }
    if (!configure_signals()) {
        perror("sigaction");
        return 1;
    }
    if (!restore_system()) {
        fprintf(stderr, "unable to restore ACLC system mode at startup\n");
        return 69;
    }

    unlink(SOCKET_PATH);
    server_socket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_socket < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, SOCKET_PATH, sizeof(address.sun_path));

    if (bind(server_socket, (struct sockaddr *)&address, sizeof(address)) != 0
        || listen(server_socket, 4) != 0) {
        perror("bind/listen");
        close(server_socket);
        unlink(SOCKET_PATH);
        return 1;
    }
    refresh_socket_owner();

    int console_descriptor = open("/dev/console", O_EVTONLY | O_CLOEXEC);
    int event_queue = kqueue();
    if (console_descriptor < 0
        || event_queue < 0
        || !register_idle_events(event_queue, console_descriptor)) {
        perror("kqueue");
        if (console_descriptor >= 0) {
            close(console_descriptor);
        }
        if (event_queue >= 0) {
            close(event_queue);
        }
        close(server_socket);
        server_socket = -1;
        unlink(SOCKET_PATH);
        (void)restore_system();
        return 1;
    }

    while (!stopping) {
        struct kevent events[2];
        int ready = kevent(event_queue, NULL, 0, events, 2, NULL);
        if (ready < 0) {
            if (stopping || errno == EINTR || errno == EBADF) {
                continue;
            }
            perror("kevent");
            break;
        }
        int client_ready = 0;
        for (int index = 0; index < ready; index += 1) {
            if (events[index].filter == EVFILT_VNODE) {
                refresh_socket_owner();
            } else if (events[index].filter == EVFILT_READ
                       && (int)events[index].ident == server_socket) {
                client_ready = 1;
            }
        }
        if (!client_ready) {
            continue;
        }

        int client = accept(server_socket, NULL, NULL);
        if (client < 0) {
            if (stopping || errno == EINTR || errno == EBADF) {
                continue;
            }
            perror("accept");
            break;
        }
        active_client = client;
        process_client(client);
        close(client);
        active_client = -1;
    }

    (void)restore_system();
    close(console_descriptor);
    close(event_queue);
    if (active_client >= 0) {
        close(active_client);
    }
    if (server_socket >= 0) {
        close(server_socket);
    }
    unlink(SOCKET_PATH);
    return 0;
}
