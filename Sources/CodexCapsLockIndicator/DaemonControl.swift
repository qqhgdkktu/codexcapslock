import Darwin
import Foundation

enum DaemonControlCommand: String, Codable, Sendable {
    case ingestLifecycle = "ingest-lifecycle"
    case acknowledgeNext = "ack-next"
    case acknowledgeCompletion = "ack-completion"
    case acknowledgeAll = "ack-all"
    case selfTest = "self-test"
    case demo
    case inspectLED = "inspect-led"
    case inspectMagSafe = "inspect-magsafe"
    case repairOutputs = "repair-outputs"
}

struct DaemonControlRequest: Codable, Sendable {
    let requestID: UUID
    let command: DaemonControlCommand
    let record: LifecycleRecord?
    let completionID: UUID?

    init(
        requestID: UUID,
        command: DaemonControlCommand,
        record: LifecycleRecord? = nil,
        completionID: UUID? = nil
    ) {
        self.requestID = requestID
        self.command = command
        self.record = record
        self.completionID = completionID
    }
}

struct DaemonControlResponse: Codable, Sendable {
    let requestID: UUID
    let succeeded: Bool
    let message: String
}

final class DaemonControlServer: @unchecked Sendable {
    private static let maximumMessageBytes = 4_096

    private let socketURL: URL
    private let handler: @Sendable (DaemonControlRequest) -> DaemonControlResponse
    private let queue = DispatchQueue(label: "com.mikita.codex-capslock-indicator.control")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(
        socketURL: URL,
        handler: @escaping @Sendable (DaemonControlRequest) -> DaemonControlResponse
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() throws {
        var existing = stat()
        if lstat(socketURL.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK,
                  existing.st_uid == geteuid() else {
                throw HookJournalError.unsafeFile
            }
            guard unlink(socketURL.path) == 0 else {
                throw HookJournalError.openFailed(errno)
            }
        } else if errno != ENOENT {
            throw HookJournalError.openFailed(errno)
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HookJournalError.openFailed(errno)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketURL.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    strlcpy($0, source, capacity)
                }
            }
        }
        guard copied < capacity else {
            stop()
            throw HookJournalError.unsafeFile
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0,
              chmod(socketURL.path, 0o600) == 0,
              listen(descriptor, 4) == 0 else {
            stop()
            throw HookJournalError.openFailed(errno)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            stop()
            throw HookJournalError.openFailed(errno)
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.acceptAvailableClients()
        }
        let listeningDescriptor = descriptor
        source.setCancelHandler {
            close(listeningDescriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        if let source {
            self.source = nil
            descriptor = -1
            source.cancel()
        } else if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(socketURL.path)
    }

    private func acceptAvailableClients() {
        while descriptor >= 0 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            return
        }
        _ = peerGID

        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                client,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                client,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        guard let data = readLine(from: client),
              let request = try? JSONDecoder().decode(
                  DaemonControlRequest.self,
                  from: data
              ) else {
            return
        }
        let response = handler(request)
        guard var encoded = try? JSONEncoder().encode(response),
              encoded.count <= Self.maximumMessageBytes else {
            return
        }
        encoded.append(0x0A)
        _ = writeAll(encoded, to: client)
    }

    private func readLine(from descriptor: Int32) -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= Self.maximumMessageBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return data
                }
                if byte == 0 {
                    return nil
                }
                data.append(byte)
            } else if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    let remaining = deadline
                        - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        return nil
                    }
                    var pollDescriptor = pollfd(
                        fd: descriptor,
                        events: Int16(POLLIN),
                        revents: 0
                    )
                    let milliseconds = Int32(
                        min(
                            max(remaining * 1_000, 1),
                            Double(Int32.max)
                        )
                    )
                    guard poll(
                        &pollDescriptor,
                        1,
                        milliseconds
                    ) == 1 else {
                        return nil
                    }
                    continue
                }
                return nil
            } else {
                return nil
            }
        }
        return nil
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return false
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        let remaining = deadline
                            - ProcessInfo.processInfo.systemUptime
                        guard remaining > 0 else {
                            return false
                        }
                        var pollDescriptor = pollfd(
                            fd: descriptor,
                            events: Int16(POLLOUT),
                            revents: 0
                        )
                        let milliseconds = Int32(
                            min(
                                max(remaining * 1_000, 1),
                                Double(Int32.max)
                            )
                        )
                        guard poll(
                            &pollDescriptor,
                            1,
                            milliseconds
                        ) == 1 else {
                            return false
                        }
                        continue
                    }
                    return false
                } else {
                    return false
                }
            }
            return true
        }
    }
}

struct DaemonControlClient {
    let socketURL: URL

    func send(
        _ command: DaemonControlCommand,
        timeout: TimeInterval = 15
    ) -> DaemonControlResponse? {
        send(
            DaemonControlRequest(requestID: UUID(), command: command),
            timeout: timeout
        )
    }

    func send(
        lifecycleRecord: LifecycleRecord,
        timeout: TimeInterval = 1
    ) -> DaemonControlResponse? {
        send(
            DaemonControlRequest(
                requestID: UUID(),
                command: .ingestLifecycle,
                record: lifecycleRecord
            ),
            timeout: timeout
        )
    }

    func sendAcknowledgement(
        completionID: UUID,
        timeout: TimeInterval = 15
    ) -> DaemonControlResponse? {
        send(
            DaemonControlRequest(
                requestID: UUID(),
                command: .acknowledgeCompletion,
                completionID: completionID
            ),
            timeout: timeout
        )
    }

    private func send(
        _ request: DaemonControlRequest,
        timeout: TimeInterval
    ) -> DaemonControlResponse? {
        func failed(_ stage: String) -> DaemonControlResponse? {
            if ProcessInfo.processInfo.environment[
                "CODEX_CAPS_INDICATOR_DEBUG_CONTROL"
            ] == "1" {
                FileHandle.standardError.write(
                    Data("control-client failure: \(stage) errno=\(errno)\n".utf8)
                )
            }
            return nil
        }
        var socketInformation = stat()
        guard lstat(socketURL.path, &socketInformation) == 0,
              (socketInformation.st_mode & S_IFMT) == S_IFSOCK,
              socketInformation.st_uid == geteuid(),
              socketInformation.st_mode & 0o077 == 0 else {
            return failed("socket-metadata")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return failed("socket")
        }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return failed("no-sigpipe")
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketURL.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    strlcpy($0, source, capacity)
                }
            }
        }
        guard copied < capacity else {
            return failed("socket-path")
        }

        var socketTimeout = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        _ = withUnsafePointer(to: &socketTimeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return failed("nonblocking")
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                return failed("connect")
            }
            let timeoutMilliseconds = Int32(
                min(max(timeout * 1_000, 1), Double(Int32.max))
            )
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            guard poll(&pollDescriptor, 1, timeoutMilliseconds) == 1 else {
                return failed("connect-timeout")
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &errorLength
            ) == 0, socketError == 0 else {
                return failed("connect-error")
            }
        }
        guard fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            return failed("blocking")
        }

        guard var data = try? JSONEncoder().encode(request) else {
            return failed("encode")
        }
        data.append(0x0A)
        guard writeAll(data, to: descriptor, timeout: timeout) else {
            return failed("write")
        }
        guard let responseData = readLine(
            from: descriptor,
            timeout: timeout
        ) else {
            return failed("read")
        }
        guard let response = try? JSONDecoder().decode(
            DaemonControlResponse.self,
            from: responseData
        ) else {
            return failed("decode")
        }
        guard response.requestID == request.requestID else {
            return failed("request-id")
        }
        return response
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return false
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        let remaining = deadline
                            - ProcessInfo.processInfo.systemUptime
                        guard remaining > 0 else {
                            return false
                        }
                        var pollDescriptor = pollfd(
                            fd: descriptor,
                            events: Int16(POLLOUT),
                            revents: 0
                        )
                        let milliseconds = Int32(
                            min(
                                max(remaining * 1_000, 1),
                                Double(Int32.max)
                            )
                        )
                        guard poll(
                            &pollDescriptor,
                            1,
                            milliseconds
                        ) == 1 else {
                            return false
                        }
                        continue
                    }
                    return false
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func readLine(
        from descriptor: Int32,
        timeout: TimeInterval
    ) -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= 4_096 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return data
                }
                if byte == 0 {
                    return nil
                }
                data.append(byte)
            } else if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    let remaining = deadline
                        - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        return nil
                    }
                    var pollDescriptor = pollfd(
                        fd: descriptor,
                        events: Int16(POLLIN),
                        revents: 0
                    )
                    let milliseconds = Int32(
                        min(
                            max(remaining * 1_000, 1),
                            Double(Int32.max)
                        )
                    )
                    guard poll(
                        &pollDescriptor,
                        1,
                        milliseconds
                    ) == 1 else {
                        return nil
                    }
                    continue
                }
                return nil
            } else {
                return nil
            }
        }
        return nil
    }
}
