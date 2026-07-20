import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("the first completion wins across Codex and Claude Code sessions")
func multiAgentFirstCompletionLifecycle() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let paths = RuntimePaths(
        baseDirectory: temporary,
        eventJournal: temporary.appendingPathComponent("events.jsonl"),
        statusFile: temporary.appendingPathComponent("status.json"),
        codexHome: temporary.appendingPathComponent("codex"),
        sessionsDirectory: temporary.appendingPathComponent("sessions"),
        logsDatabase: temporary.appendingPathComponent("logs.sqlite")
    )
    let writer = HookJournalWriter(paths: paths)
    let reader = HookJournalReader(url: paths.eventJournal)
    var tracker = ActivityTracker()

    let claudeWorking = Data("""
    {"session_id":"shared-id","hook_event_name":"UserPromptSubmit","prompt":"private"}
    """.utf8)
    let codexWorking = Data("""
    {"session_id":"shared-id","turn_id":"codex-turn","hook_event_name":"UserPromptSubmit","prompt":"private"}
    """.utf8)
    let claudeDone = Data("""
    {"session_id":"shared-id","hook_event_name":"Stop","last_assistant_message":"private"}
    """.utf8)

    try writer.append(state: .working, source: .claude, inputData: claudeWorking)
    try writer.append(state: .working, source: .codex, inputData: codexWorking)
    try writer.append(state: .done, source: .claude, inputData: claudeDone)
    for signal in reader.readNewSignals() {
        tracker.apply(signal)
    }

    #expect(tracker.sessions.count == 2)
    #expect(tracker.sessions["shared-id"]?.mode == .working)
    #expect(tracker.sessions["claude:shared-id"]?.mode == .done)
    #expect(tracker.effectiveMode == .done)
    #expect(tracker.firstCompletedSource == .claude)

    try writer.appendAcknowledgement()
    for signal in reader.readNewSignals() {
        tracker.apply(signal)
    }

    #expect(tracker.sessions["claude:shared-id"] == nil)
    #expect(tracker.effectiveMode == .working)
}
