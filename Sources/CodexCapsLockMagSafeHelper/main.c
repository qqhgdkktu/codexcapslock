// The command protocol and SMC LED values are derived from MagSafe Dark
// by Mark Kats (MIT License). See THIRD_PARTY_NOTICES.md.

#include <MagSafeSMC.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCKET_PATH "/var/run/com.mikita.codex-capslock-indicator.magsafe.sock"
#define MAX_COMMAND_LENGTH 64
#define CLIENT_TIMEOUT_SECONDS 1

static volatile sig_atomic_t stopping = 0;
static int server_socket = -1;

static void handle_signal(int signal_number) {
    (void)signal_number;
    stopping = 1;
    if (server_socket >= 0) {
        close(server_socket);
        server_socket = -1;
    }
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

    if (length == 0) {
        return 0;
    }
    command[length] = '\0';
    return 1;
}

static int active_console_user(uid_t *uid) {
    struct stat info;
    if (stat("/dev/console", &info) != 0 || info.st_uid == 0) {
        return 0;
    }
    *uid = info.st_uid;
    return 1;
}

static int peer_is_authorized(int client) {
    uid_t peer_uid = 0;
    gid_t peer_gid = 0;
    if (getpeereid(client, &peer_uid, &peer_gid) != 0) {
        return 0;
    }
    (void)peer_gid;
    if (peer_uid == 0) {
        return 1;
    }

    uid_t console_uid = 0;
    return active_console_user(&console_uid) && peer_uid == console_uid;
}

static int mode_value(const char *command, uint8_t *value) {
    if (strcmp(command, "system") == 0) {
        *value = 0;
    } else if (strcmp(command, "off") == 0) {
        *value = 1;
    } else if (strcmp(command, "green") == 0) {
        *value = 3;
    } else if (strcmp(command, "orange") == 0) {
        *value = 4;
    } else if (strcmp(command, "flash") == 0) {
        *value = 5;
    } else if (strcmp(command, "blink-slow") == 0) {
        *value = 6;
    } else if (strcmp(command, "blink-fast") == 0) {
        *value = 7;
    } else if (strcmp(command, "blink-off") == 0) {
        *value = 19;
    } else {
        return 0;
    }
    return 1;
}

static void process_command(int client, const char *command) {
    if (strcmp(command, "ping") == 0) {
        send_response(client, 0, "pong");
        return;
    }

    if (strcmp(command, "probe") == 0 || strcmp(command, "status") == 0) {
        uint8_t value = 0;
        int result = codex_smc_read_u8("ACLC", &value);
        if (result != 0) {
            char error[160];
            snprintf(error, sizeof(error), "Unable to read ACLC (IOKit error %d)", result);
            send_response(client, 69, error);
            return;
        }
        if (strcmp(command, "probe") == 0) {
            send_response(client, 0, "supported");
        } else {
            char current[16];
            snprintf(current, sizeof(current), "%u", value);
            send_response(client, 0, current);
        }
        return;
    }

    uint8_t value = 0;
    if (!mode_value(command, &value)) {
        send_response(client, 64, "Unknown command");
        return;
    }

    int result = codex_smc_write_u8("ACLC", value);
    if (result != 0) {
        char error[160];
        snprintf(error, sizeof(error), "Unable to write ACLC (IOKit error %d)", result);
        send_response(client, 69, error);
        return;
    }
    send_response(client, 0, "ok");
}

static int configure_signals(void) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGINT, &action, NULL) == 0
        && sigaction(SIGTERM, &action, NULL) == 0;
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

    if (bind(server_socket, (struct sockaddr *)&address, sizeof(address)) != 0) {
        perror("bind");
        close(server_socket);
        unlink(SOCKET_PATH);
        return 1;
    }
    if (chmod(SOCKET_PATH, 0666) != 0 || listen(server_socket, 8) != 0) {
        perror("listen");
        close(server_socket);
        unlink(SOCKET_PATH);
        return 1;
    }

    while (!stopping) {
        int client = accept(server_socket, NULL, NULL);
        if (client < 0) {
            if (stopping || errno == EINTR || errno == EBADF) {
                continue;
            }
            perror("accept");
            break;
        }

        if (!peer_is_authorized(client)) {
            send_response(client, 77, "Client is not the active console user");
            close(client);
            continue;
        }

        if (!configure_client_socket(client)) {
            send_response(client, 70, "Unable to configure client socket");
            close(client);
            continue;
        }

        char command[MAX_COMMAND_LENGTH + 1];
        if (!read_command(client, command)) {
            send_response(client, 64, "Invalid command");
            close(client);
            continue;
        }
        process_command(client, command);
        close(client);
    }

    (void)codex_smc_write_u8("ACLC", 0);
    if (server_socket >= 0) {
        close(server_socket);
    }
    unlink(SOCKET_PATH);
    return 0;
}
