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

    init(socketPath: String = MagSafeLEDController.socketPath) {
        self.socketPath = socketPath
    }

    func ping() -> Bool {
        guard let response = send("ping"), response.succeeded else {
            return false
        }
        return response.body == "pong"
    }

    func probe() -> Bool {
        guard let response = send("probe"), response.succeeded else {
            return false
        }
        return response.body == "supported"
    }

    @discardableResult
    func setMode(_ mode: MagSafeLEDMode) -> Bool {
        guard let response = send(mode.rawValue), response.succeeded else {
            return false
        }
        return response.body == "ok"
    }

    func currentValue() -> UInt8? {
        guard let response = send("status"), response.succeeded else {
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

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return nil
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
            return nil
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        let sendTimeoutConfigured = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let receiveTimeoutConfigured = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendTimeoutConfigured == 0, receiveTimeoutConfigured == 0 else {
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
            return nil
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            return nil
        }

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
