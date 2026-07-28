import Darwin
import Foundation
import Testing
@testable import CodexCapsLockIndicator

private final class ReceivedLifecycleRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LifecycleRecord?

    var value: LifecycleRecord? {
        lock.withLock { storage }
    }

    func set(_ record: LifecycleRecord?) {
        lock.withLock {
            storage = record
        }
    }
}

@Test("online hook transport uses the private daemon control socket")
func onlineLifecycleTransport() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = RuntimePaths(
        baseDirectory: directory,
        eventJournal: directory.appendingPathComponent("events.spool"),
        statusFile: directory.appendingPathComponent("status.json"),
        codexHome: directory.appendingPathComponent("codex"),
        sessionsDirectory: directory.appendingPathComponent("sessions"),
        logsDatabase: directory.appendingPathComponent("logs.sqlite")
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try paths.prepare()

    let received = ReceivedLifecycleRecord()
    let server = DaemonControlServer(socketURL: paths.controlSocket) { request in
        received.set(request.record)
        return DaemonControlResponse(
            requestID: request.requestID,
            succeeded: request.command == .ingestLifecycle,
            message: "ok"
        )
    }
    try server.start()
    defer { server.stop() }
    var initialSocketInformation = stat()
    #expect(lstat(paths.controlSocket.path, &initialSocketInformation) == 0)
    #expect(initialSocketInformation.st_mode & S_IFMT == S_IFSOCK)
    #expect(initialSocketInformation.st_uid == geteuid())
    #expect(initialSocketInformation.st_mode & 0o077 == 0)
    try HookJournalWriter(paths: paths).append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"online","turn_id":"turn"}"#.utf8)
    )

    #expect(received.value?.sessionID == "online")
    #expect(received.value?.kind == .promptSubmitted)
    #expect(!FileManager.default.fileExists(atPath: paths.eventSpool.path))
    var information = stat()
    #expect(lstat(paths.controlSocket.path, &information) == 0)
    #expect(information.st_mode & 0o777 == 0o600)
}

@Test("control server never replaces a non-socket runtime file")
func controlServerRejectsRegularFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = RuntimePaths(
        baseDirectory: directory,
        eventJournal: directory.appendingPathComponent("events.spool"),
        statusFile: directory.appendingPathComponent("status.json"),
        codexHome: directory.appendingPathComponent("codex"),
        sessionsDirectory: directory.appendingPathComponent("sessions"),
        logsDatabase: directory.appendingPathComponent("logs.sqlite")
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try paths.prepare()
    try Data("owned-data".utf8).write(to: paths.controlSocket)

    let server = DaemonControlServer(socketURL: paths.controlSocket) { request in
        DaemonControlResponse(
            requestID: request.requestID,
            succeeded: true,
            message: "unexpected"
        )
    }
    #expect(throws: HookJournalError.self) {
        try server.start()
    }
    #expect(
        try String(contentsOf: paths.controlSocket, encoding: .utf8)
            == "owned-data"
    )
}

@Test("control protocol carries an exact completion id")
func exactAcknowledgementTransport() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = RuntimePaths(
        baseDirectory: directory,
        eventJournal: directory.appendingPathComponent("events.spool"),
        statusFile: directory.appendingPathComponent("status.json"),
        codexHome: directory.appendingPathComponent("codex"),
        sessionsDirectory: directory.appendingPathComponent("sessions"),
        logsDatabase: directory.appendingPathComponent("logs.sqlite")
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try paths.prepare()
    let expected = UUID()
    let server = DaemonControlServer(socketURL: paths.controlSocket) { request in
        DaemonControlResponse(
            requestID: request.requestID,
            succeeded: request.command == .acknowledgeCompletion
                && request.completionID == expected,
            message: "checked"
        )
    }
    try server.start()
    defer { server.stop() }

    let response = DaemonControlClient(socketURL: paths.controlSocket)
        .sendAcknowledgement(completionID: expected)

    #expect(response?.succeeded == true)
}
