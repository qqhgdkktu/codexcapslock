import Darwin
import Foundation
import Testing
@testable import CodexCapsLockIndicator

private func temporaryPaths() -> RuntimePaths {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return RuntimePaths(
        baseDirectory: directory,
        eventJournal: directory.appendingPathComponent("events.spool"),
        statusFile: directory.appendingPathComponent("status.json"),
        codexHome: directory.appendingPathComponent("codex"),
        sessionsDirectory: directory.appendingPathComponent("sessions"),
        logsDatabase: directory.appendingPathComponent("logs.sqlite")
    )
}

@Test("hook spool preserves only bounded lifecycle metadata")
func hookJournalRoundTrip() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    let input = Data("""
    {"session_id":"session","turn_id":"turn","transcript_path":"/tmp/SECRET.jsonl","hook_event_name":"UserPromptSubmit","prompt":"SECRET_PROMPT"}
    """.utf8)

    try HookJournalWriter(paths: paths).append(
        action: .promptSubmitted,
        source: .codex,
        inputData: input
    )
    let batch = try #require(HookJournalReader(paths: paths).readBatch())

    #expect(batch.records.count == 1)
    #expect(batch.records[0].sessionID == "session")
    #expect(batch.records[0].turnID == "turn")
    #expect(batch.records[0].kind == .promptSubmitted)

    let persisted = try String(contentsOf: paths.eventSpool, encoding: .utf8)
    #expect(!persisted.contains("SECRET_PROMPT"))
    #expect(!persisted.contains("SECRET.jsonl"))
}

@Test("Claude hook schema is namespaced and remains privacy-limited")
func claudeHookJournalRoundTrip() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    let input = Data("""
    {"session_id":"same-id","transcript_path":"/tmp/claude.jsonl","cwd":"/private/project","hook_event_name":"Stop","last_assistant_message":"private answer"}
    """.utf8)

    try HookJournalWriter(paths: paths).append(
        action: .stopped,
        source: .claude,
        inputData: input
    )
    let records = try #require(HookJournalReader(paths: paths).readBatch()).records

    #expect(records.count == 1)
    #expect(records[0].sessionID == "claude:same-id")
    #expect(records[0].source == .claude)
    #expect(records[0].kind == .stopped(outcome: .completed))

    let persisted = try String(contentsOf: paths.eventSpool, encoding: .utf8)
    #expect(!persisted.contains("private answer"))
    #expect(!persisted.contains("claude.jsonl"))
    #expect(!persisted.contains("/private/project"))
}

@Test("missing or oversized identifiers are rejected instead of sharing unknown")
func invalidHookIdentifiersAreRejected() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    let writer = HookJournalWriter(paths: paths)

    #expect(throws: HookJournalError.self) {
        try writer.append(
            action: .promptSubmitted,
            source: .codex,
            inputData: Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8)
        )
    }
    let oversized = String(repeating: "x", count: Constants.maximumIdentifierBytes + 1)
    #expect(throws: HookJournalError.self) {
        try writer.append(
            action: .promptSubmitted,
            source: .codex,
            inputData: Data(#"{"session_id":"\#(oversized)"}"#.utf8)
        )
    }
    #expect(!FileManager.default.fileExists(atPath: paths.eventSpool.path))
}

@Test("acknowledgement is persisted as an exact metadata control event")
func acknowledgementJournalRoundTrip() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    let completionID = UUID()

    try HookJournalWriter(paths: paths).appendAcknowledgement(completionID: completionID)
    let records = try #require(HookJournalReader(paths: paths).readBatch()).records

    #expect(records.count == 1)
    #expect(records[0].kind == .acknowledged(completionID: completionID))
}

@Test("spool compaction preserves records appended after a read")
func spoolCompactionPreservesTail() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    let writer = HookJournalWriter(paths: paths)
    let reader = HookJournalReader(paths: paths)

    try writer.append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"first","turn_id":"1"}"#.utf8)
    )
    let firstBatch = try #require(reader.readBatch())
    try writer.append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"second","turn_id":"2"}"#.utf8)
    )
    try reader.commit(firstBatch)

    let remaining = try #require(reader.readBatch())
    #expect(remaining.records.map(\.sessionID) == ["second"])
}

@Test("malformed and oversized records do not block the next record")
func malformedSpoolRecordsAreSkipped() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    try paths.prepare()
    let malformed = Data("not-json\n".utf8)
    try malformed.write(to: paths.eventSpool)
    try HookJournalWriter(paths: paths).append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"valid","turn_id":"turn"}"#.utf8)
    )

    let batch = try #require(HookJournalReader(paths: paths).readBatch())
    #expect(batch.records.map(\.sessionID) == ["valid"])
}

@Test("writer removes a crash-truncated tail before appending a new event")
func crashTruncatedSpoolTailIsRepaired() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    try paths.prepare()
    try Data(#"{"schemaVersion":2"#.utf8).write(to: paths.eventSpool)

    try HookJournalWriter(paths: paths).append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"survives","turn_id":"turn"}"#.utf8)
    )

    let batch = try #require(HookJournalReader(paths: paths).readBatch())
    #expect(batch.records.map(\.sessionID) == ["survives"])
}

@Test("runtime directory and spool use private modes regardless of umask")
func runtimeFilesHavePrivateModes() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    let originalMask = umask(0)
    defer { _ = umask(originalMask) }

    try HookJournalWriter(paths: paths).append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"session"}"#.utf8)
    )

    var directoryInfo = stat()
    var spoolInfo = stat()
    #expect(lstat(paths.baseDirectory.path, &directoryInfo) == 0)
    #expect(lstat(paths.eventSpool.path, &spoolInfo) == 0)
    #expect(directoryInfo.st_mode & 0o777 == 0o700)
    #expect(spoolInfo.st_mode & 0o777 == 0o600)
}

@Test("state snapshot preserves reducer queue without private hook contents")
func stateStoreRoundTrip() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    var reducer = LifecycleReducer()
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    _ = reducer.apply(LifecycleRecord(
        source: .codex,
        sessionID: "session",
        turnID: "turn",
        emittedAtMillis: now,
        kind: .promptSubmitted
    ), nowMillis: now)
    _ = reducer.apply(LifecycleRecord(
        source: .codex,
        sessionID: "session",
        turnID: "turn",
        emittedAtMillis: now + 1,
        kind: .stopped(outcome: .completed)
    ), nowMillis: now + 1)

    let store = StateStore(paths: paths)
    try store.save(reducer)
    let restored = store.load()

    #expect(restored.completionQueue == reducer.completionQueue)
    let persisted = try String(contentsOf: paths.stateSnapshot, encoding: .utf8)
    #expect(!persisted.contains("prompt"))
    #expect(!persisted.contains("transcript"))
}

@Test("state store rejects a symlinked snapshot")
func stateStoreRejectsSymlinkedSnapshot() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.baseDirectory) }
    try paths.prepare()
    let outside = paths.baseDirectory.appendingPathComponent("outside.json")
    try Data(#"{"schemaVersion":2}"#.utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: paths.stateSnapshot,
        withDestinationURL: outside
    )

    let restored = StateStore(paths: paths).load()

    #expect(restored.effectiveMode == .off)
    #expect(restored.completionQueue.isEmpty)
}
