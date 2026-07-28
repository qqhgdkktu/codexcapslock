import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("the first completion wins across Codex and Claude Code sessions")
func multiAgentFirstCompletionLifecycle() throws {
    let paths = RuntimePaths(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true),
        eventJournal: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("unused"),
        statusFile: FileManager.default.temporaryDirectory.appendingPathComponent("unused-status"),
        codexHome: FileManager.default.temporaryDirectory.appendingPathComponent("unused-codex"),
        sessionsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-sessions"),
        logsDatabase: FileManager.default.temporaryDirectory.appendingPathComponent("unused.sqlite")
    )
    let actualPaths = RuntimePaths(
        baseDirectory: paths.baseDirectory,
        eventJournal: paths.baseDirectory.appendingPathComponent("events.spool"),
        statusFile: paths.baseDirectory.appendingPathComponent("status.json"),
        codexHome: paths.baseDirectory.appendingPathComponent("codex"),
        sessionsDirectory: paths.baseDirectory.appendingPathComponent("sessions"),
        logsDatabase: paths.baseDirectory.appendingPathComponent("logs.sqlite")
    )
    defer { try? FileManager.default.removeItem(at: actualPaths.baseDirectory) }
    let writer = HookJournalWriter(paths: actualPaths)
    let reader = HookJournalReader(paths: actualPaths)
    var reducer = LifecycleReducer()

    try writer.append(
        action: .promptSubmitted,
        source: .claude,
        inputData: Data(#"{"session_id":"shared-id","hook_event_name":"UserPromptSubmit","prompt":"private"}"#.utf8)
    )
    try writer.append(
        action: .promptSubmitted,
        source: .codex,
        inputData: Data(#"{"session_id":"shared-id","turn_id":"codex-turn","hook_event_name":"UserPromptSubmit","prompt":"private"}"#.utf8)
    )
    try writer.append(
        action: .stopped,
        source: .claude,
        inputData: Data(#"{"session_id":"shared-id","hook_event_name":"Stop","last_assistant_message":"private"}"#.utf8)
    )
    let batch = try #require(reader.readBatch())
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    for event in batch.records {
        _ = reducer.apply(event, nowMillis: now)
    }

    #expect(reducer.activeGenerations.count == 1)
    #expect(reducer.activeGenerations["shared-id"]?.phase == .working)
    #expect(reducer.completionQueue.first?.sessionID == "claude:shared-id")
    #expect(reducer.effectiveMode == .done)
    #expect(reducer.firstCompletedSource == .claude)

    let completionID = try #require(reducer.firstCompletionID)
    try writer.appendAcknowledgement(completionID: completionID)
    let secondBatch = try #require(reader.readBatch())
    for event in secondBatch.records {
        _ = reducer.apply(event, nowMillis: now)
    }

    #expect(reducer.completionQueue.isEmpty)
    #expect(reducer.effectiveMode == .working)
}
