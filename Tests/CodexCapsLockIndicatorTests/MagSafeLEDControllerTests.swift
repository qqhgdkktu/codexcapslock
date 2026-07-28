import Darwin
import Foundation
import Testing
@testable import CodexCapsLockIndicator

private enum MockSocketError: Error {
    case operation(String, Int32)
    case pathTooLong
}

private final class MockMagSafeServer: @unchecked Sendable {
    let socketPath: String

    private let server: Int32
    private let responseChunks: [Data]
    private let responseDelay: useconds_t
    private let finished = DispatchSemaphore(value: 0)

    init(responseChunks: [Data], responseDelay: useconds_t = 0) throws {
        socketPath = "/tmp/codex-magsafe-\(UUID().uuidString).sock"
        self.responseChunks = responseChunks
        self.responseDelay = responseDelay

        server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else {
            throw MockSocketError.operation("socket", errno)
        }

        unlink(socketPath)
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
            close(server)
            throw MockSocketError.pathTooLong
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    server,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(server)
            unlink(socketPath)
            throw MockSocketError.operation("bind", code)
        }
        guard listen(server, 1) == 0 else {
            let code = errno
            close(server)
            unlink(socketPath)
            throw MockSocketError.operation("listen", code)
        }
    }

    deinit {
        close(server)
        unlink(socketPath)
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )

            var request = [UInt8](repeating: 0, count: 128)
            _ = Darwin.read(client, &request, request.count)
            for chunk in responseChunks {
                if responseDelay > 0 {
                    usleep(responseDelay)
                }
                chunk.withUnsafeBytes { buffer in
                    _ = Darwin.write(client, buffer.baseAddress, buffer.count)
                }
            }
        }
    }

    func wait() {
        _ = finished.wait(timeout: .now() + 2)
    }
}

private final class MockLeaseServer: @unchecked Sendable {
    let socketPath: String

    private let server: Int32
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var commandStorage: [String] = []

    var commands: [String] {
        lock.withLock { commandStorage }
    }

    init() throws {
        socketPath = "/tmp/codex-magsafe-lease-\(UUID().uuidString).sock"
        server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else {
            throw MockSocketError.operation("socket", errno)
        }
        unlink(socketPath)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(
                    to: CChar.self,
                    capacity: maximumLength
                ) {
                    strlcpy($0, source, maximumLength)
                }
            }
        }
        guard copied < maximumLength else {
            close(server)
            throw MockSocketError.pathTooLong
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    server,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0, listen(server, 1) == 0 else {
            let code = errno
            close(server)
            unlink(socketPath)
            throw MockSocketError.operation("bind/listen", code)
        }
    }

    deinit {
        close(server)
        unlink(socketPath)
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            while let command = readLine(client) {
                lock.withLock {
                    commandStorage.append(command)
                }
                let response: String
                switch command {
                case "hello 2": response = "0\tready\n"
                case "set green": response = "0\tok\n"
                case "ping": response = "0\tpong\n"
                case "status": response = "0\t3\n"
                default: response = "64\tunknown\n"
                }
                _ = response.withCString { pointer in
                    Darwin.write(client, pointer, strlen(pointer))
                }
            }
        }
    }

    func wait() {
        _ = finished.wait(timeout: .now() + 2)
    }

    private func readLine(_ descriptor: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= 128 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return String(data: data, encoding: .utf8)
                }
                data.append(byte)
            } else {
                return nil
            }
        }
        return nil
    }
}

@Test("MagSafe helper response can arrive in multiple socket reads")
func fragmentedMagSafeHelperResponse() throws {
    let server = try MockMagSafeServer(
        responseChunks: [Data("0\t".utf8), Data("pong\n".utf8)],
        responseDelay: 20_000
    )
    server.start()

    let response = MagSafeLEDController(socketPath: server.socketPath).send("ping")

    #expect(response == MagSafeHelperResponse(status: 0, body: "pong"))
    server.wait()
}

@Test("MagSafe helper rejects more than one protocol response")
func duplicateMagSafeHelperResponseIsRejected() throws {
    let server = try MockMagSafeServer(
        responseChunks: [Data("0\tpong\n".utf8), Data("0\tok\n".utf8)],
        responseDelay: 20_000
    )
    server.start()

    let response = MagSafeLEDController(socketPath: server.socketPath).send("ping")

    #expect(response == nil)
    server.wait()
}

@Test("MagSafe helper timeout remains bounded")
func magSafeHelperTimeoutIsBounded() throws {
    let server = try MockMagSafeServer(
        responseChunks: [Data("0\tpong\n".utf8)],
        responseDelay: 400_000
    )
    server.start()

    let startedAt = Date()
    let response = MagSafeLEDController(socketPath: server.socketPath).send("ping")
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(response == nil)
    #expect(elapsed < 0.8)
    server.wait()
}

@Test("MagSafe helper response size is bounded")
func oversizedMagSafeHelperResponseIsRejected() throws {
    var payload = Data(repeating: 0x41, count: 4_097)
    payload.append(0x0A)
    let server = try MockMagSafeServer(responseChunks: [payload])
    server.start()

    let response = MagSafeLEDController(socketPath: server.socketPath).send("ping")

    #expect(response == nil)
    server.wait()
}

@Test("MagSafe helper ping requires the expected body")
func magSafeHelperPingValidatesBody() throws {
    let server = try MockMagSafeServer(responseChunks: [Data("0\tok\n".utf8)])
    server.start()

    let alive = MagSafeLEDController(socketPath: server.socketPath).ping()

    #expect(!alive)
    server.wait()
}

@Test("MagSafe writes require the helper acknowledgement body")
func magSafeHelperWriteValidatesBody() throws {
    let server = try MockMagSafeServer(responseChunks: [Data("0\tpong\n".utf8)])
    server.start()

    let applied = MagSafeLEDController(socketPath: server.socketPath).setMode(.green)

    #expect(!applied)
    server.wait()
}

@Test("persistent MagSafe control negotiates and maintains protocol v2 lease")
func magSafeLeaseProtocol() throws {
    let server = try MockLeaseServer()
    server.start()
    let controller = MagSafeLEDController(
        socketPath: server.socketPath,
        usesPersistentLease: true
    )

    #expect(controller.setMode(.green))
    #expect(controller.ping())
    #expect(controller.currentValue() == 3)
    controller.closeLease()
    server.wait()

    #expect(server.commands == ["hello 2", "set green", "ping", "status"])
}
