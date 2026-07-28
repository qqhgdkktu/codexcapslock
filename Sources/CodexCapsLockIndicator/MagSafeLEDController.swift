import Darwin
import Foundation

enum MagSafeLEDMode: String, Codable, CaseIterable, Sendable {
    case system
    case off
    case green
    case orange
    case flash
    case blinkSlow = "blink-slow"
    case blinkFast = "blink-fast"
    case blinkOff = "blink-off"

    var aclcValue: UInt8 {
        switch self {
        case .system: 0
        case .off: 1
        case .green: 3
        case .orange: 4
        case .flash: 5
        case .blinkSlow: 6
        case .blinkFast: 7
        case .blinkOff: 19
        }
    }

    init?(aclcValue: UInt8) {
        guard let mode = Self.allCases.first(where: { $0.aclcValue == aclcValue }) else {
            return nil
        }
        self = mode
    }
}

struct MagSafeHelperResponse: Equatable, Sendable {
    let status: Int
    let body: String

    var succeeded: Bool {
        status == 0
    }
}

final class MagSafeLEDController {
    static let socketPath = "/var/run/com.mikita.codex-capslock-indicator.magsafe.sock"
    private static let maximumResponseBytes = 4_096

    private let socketPath: String
    private let usesPersistentLease: Bool
    private let leaseLock = NSLock()
    private var leaseDescriptor: Int32 = -1

    init(
        socketPath: String = MagSafeLEDController.socketPath,
        usesPersistentLease: Bool? = nil
    ) {
        self.socketPath = socketPath
        self.usesPersistentLease = usesPersistentLease ?? (socketPath == Self.socketPath)
    }

    deinit {
        closeLease()
    }

    func ping() -> Bool {
        let response = usesPersistentLease ? sendLease("ping") : send("ping")
        guard let response, response.succeeded else {
            return false
        }
        return response.body == "pong"
    }

    func probe() -> Bool {
        let response = usesPersistentLease ? sendLease("probe") : send("probe")
        guard let response, response.succeeded else {
            return false
        }
        return response.body == "supported"
    }

    @discardableResult
    func setMode(_ mode: MagSafeLEDMode) -> Bool {
        let response = usesPersistentLease
            ? sendLease("set \(mode.rawValue)")
            : send(mode.rawValue)
        guard let response, response.succeeded else {
            return false
        }
        return response.body == "ok"
    }

    func currentValue() -> UInt8? {
        let response = usesPersistentLease ? sendLease("status") : send("status")
        guard let response, response.succeeded else {
            return nil
        }
        return UInt8(response.body)
    }

    func send(_ command: String) -> MagSafeHelperResponse? {
        guard !command.isEmpty,
              command.utf8.count <= 64,
              !command.utf8.contains(0),
              !command.contains("\r"),
              !command.contains("\n") else {
            return nil
        }

        guard let descriptor = connectedSocket() else { return nil }
        defer { close(descriptor) }

        let payload = Data((command + "\n").utf8)
        guard writeAll(payload, to: descriptor) else {
            return nil
        }
        _ = shutdown(descriptor, SHUT_WR)

        guard let line = readResponseLine(from: descriptor) else {
            return nil
        }

        let pieces = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let status = Int(pieces[0]) else {
            return nil
        }
        return MagSafeHelperResponse(status: status, body: String(pieces[1]))
    }

    func closeLease() {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        closeLeaseLocked()
    }

    private func sendLease(_ command: String) -> MagSafeHelperResponse? {
        guard !command.isEmpty,
              command.utf8.count <= 64,
              !command.utf8.contains(0),
              !command.contains("\r"),
              !command.contains("\n") else {
            return nil
        }

        leaseLock.lock()
        defer { leaseLock.unlock() }
        guard establishLeaseLocked() else {
            return nil
        }
        let payload = Data((command + "\n").utf8)
        guard writeAll(payload, to: leaseDescriptor),
              let response = readSingleResponse(from: leaseDescriptor) else {
            closeLeaseLocked()
            return nil
        }
        return response
    }

    private func establishLeaseLocked() -> Bool {
        if leaseDescriptor >= 0 {
            return true
        }
        guard let descriptor = connectedSocket() else {
            return false
        }
        leaseDescriptor = descriptor
        let hello = Data("hello 2\n".utf8)
        guard writeAll(hello, to: descriptor),
              let response = readSingleResponse(from: descriptor),
              response == MagSafeHelperResponse(status: 0, body: "ready") else {
            closeLeaseLocked()
            return false
        }
        return true
    }

    private func closeLeaseLocked() {
        guard leaseDescriptor >= 0 else {
            return
        }
        _ = shutdown(leaseDescriptor, SHUT_RDWR)
        close(leaseDescriptor)
        leaseDescriptor = -1
    }

    private func connectedSocket() -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return nil
        }

        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        withUnsafePointer(to: &timeout, {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }) == 0,
        withUnsafePointer(to: &timeout, {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }) == 0 else {
            close(descriptor)
            return nil
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: maximumLength) { pointer in
                    strlcpy(pointer, source, maximumLength)
                }
            }
        }
        guard copied < maximumLength else {
            close(descriptor)
            return nil
        }

        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(descriptor)
            return nil
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                close(descriptor)
                return nil
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollDescriptor, 1, 250) == 1 else {
                close(descriptor)
                return nil
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
                close(descriptor)
                return nil
            }
        }
        guard fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func readSingleResponse(from descriptor: Int32) -> MagSafeHelperResponse? {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 320)

        while response.firstIndex(of: 0x0A) == nil {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(Int(count)))
                guard response.count <= Self.maximumResponseBytes else {
                    return nil
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        guard let newline = response.firstIndex(of: 0x0A),
              response[response.index(after: newline)...].allSatisfy({
                  $0 == 0x0A || $0 == 0x0D
              }) else {
            return nil
        }
        var line = response[..<newline]
        if line.last == 0x0D {
            line = line.dropLast()
        }
        guard !line.isEmpty,
              !line.contains(0),
              let value = String(data: line, encoding: .utf8) else {
            return nil
        }
        let pieces = value.split(
            separator: "\t",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2, let status = Int(pieces[0]) else {
            return nil
        }
        return MagSafeHelperResponse(status: status, body: String(pieces[1]))
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }

            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func readResponseLine(from descriptor: Int32) -> String? {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 320)

        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(Int(count)))
                guard response.count <= Self.maximumResponseBytes else {
                    return nil
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        guard let newline = response.firstIndex(of: 0x0A) else {
            return nil
        }
        let trailing = response[response.index(after: newline)...]
        guard trailing.allSatisfy({ $0 == 0x0A || $0 == 0x0D }) else {
            return nil
        }

        var line = response[..<newline]
        if line.last == 0x0D {
            line = line.dropLast()
        }
        guard !line.isEmpty,
              !line.contains(0),
              let value = String(data: line, encoding: .utf8) else {
            return nil
        }
        return value
    }
}
