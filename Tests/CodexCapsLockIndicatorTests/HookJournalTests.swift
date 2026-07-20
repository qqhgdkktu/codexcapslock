import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("hook journal preserves only lifecycle metadata")
func hookJournalRoundTrip() throws {
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
    let input = Data("""
    {"session_id":"session","turn_id":"turn","transcript_path":"/tmp/rollout.jsonl","hook_event_name":"UserPromptSubmit","prompt":"secret prompt"}
    """.utf8)

    try HookJournalWriter(paths: paths).append(state: .working, inputData: input)
    let signals = HookJournalReader(url: paths.eventJournal).readNewSignals()

    #expect(signals.count == 1)
    #expect(signals[0].state == .working)
    #expect(signals[0].sessionID == "session")
    #expect(signals[0].turnID == "turn")

    let persisted = try String(contentsOf: paths.eventJournal, encoding: .utf8)
    #expect(!persisted.contains("secret prompt"))
    #expect(!persisted.contains("rollout.jsonl"))
}

@Test("acknowledgement is persisted as a metadata-only control signal")
func acknowledgementJournalRoundTrip() throws {
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

    try HookJournalWriter(paths: paths).appendAcknowledgement()
    let signals = HookJournalReader(url: paths.eventJournal).readNewSignals()

    #expect(signals.count == 1)
    #expect(signals[0].hookEventName == Constants.acknowledgementEventName)
    #expect(signals[0].state == .off)
}
