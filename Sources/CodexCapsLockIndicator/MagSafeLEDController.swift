import Darwin
import Foundation

enum MagSafeLEDMode: String, Codable, Sendable {
    case system
    case off
    case green
    case orange
    case flash
    case blinkSlow = "blink-slow"
    case blinkFast = "blink-fast"
    case blinkOff = "blink-off"
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

    private let socketPath: String

    init(socketPath: String = MagSafeLEDController.socketPath) {
        self.socketPath = socketPath
    }

    func probe() -> Bool {
        send("probe")?.succeeded == true
    }

    @discardableResult
    func setMode(_ mode: MagSafeLEDMode) -> Bool {
        send(mode.rawValue)?.succeeded == true
    }

    func currentValue() -> UInt8? {
        guard let response = send("status"), response.succeeded else {
            return nil
        }
        return UInt8(response.body)
    }

    func send(_ command: String) -> MagSafeHelperResponse? {
        guard !command.isEmpty, command.utf8.count <= 64 else {
            return nil
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
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
        let sent = payload.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard sent == payload.count else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 320)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0,
              let line = String(data: Data(buffer.prefix(Int(count))), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        let pieces = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let status = Int(pieces[0]) else {
            return nil
        }
        return MagSafeHelperResponse(status: status, body: String(pieces[1]))
    }
}
