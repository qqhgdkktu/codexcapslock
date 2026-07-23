import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("transcript monitor recognizes a complete interactive lifecycle")
func transcriptLifecycle() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-20T14:06:07Z"))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let day = root.appendingPathComponent("2026/07/20", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "019f7f34-62d0-7762-9c0a-7353efd96c4d"
    let file = day.appendingPathComponent("rollout-2026-07-20T14-06-07-\(sessionID).jsonl")
    let lines = [
        #"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn"}}"#,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

    let events = TranscriptMonitor(sessionsDirectory: root).poll(now: now)
    #expect(events == [
        .turnStarted(sessionID: sessionID, turnID: "turn"),
        .waitingForInput(sessionID: sessionID, callID: "call"),
        .activityResumed(sessionID: sessionID, callID: "call"),
        .turnCompleted(sessionID: sessionID, turnID: "turn"),
    ])
}

@Test("transcript monitor skips an oversized historical line and reads the recent lifecycle tail")
func transcriptTailIsBounded() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-20T14:06:07Z"))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let day = root.appendingPathComponent("2026/07/20", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "019f7f34-62d0-7762-9c0a-7353efd96c4d"
    let file = day.appendingPathComponent("rollout-2026-07-20T14-06-07-\(sessionID).jsonl")
    let oversizedHistoricalLine = #"{"type":"response_item","payload":{"type":"message","text":""#
        + String(repeating: "x", count: 400_000)
        + #""}}"#
    let completion = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"recent"}}"#
    try (oversizedHistoricalLine + "\n" + completion + "\n")
        .write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

    let events = TranscriptMonitor(sessionsDirectory: root).poll(now: now)
    #expect(events == [
        .turnCompleted(sessionID: sessionID, turnID: "recent"),
    ])
}
