import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("the first completed session has priority over waiting and working")
func firstCompletionHasPriority() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .done,
        sessionID: "done",
        turnID: "1",
        hookEventName: "Stop",
        timestamp: now
    ))
    tracker.apply(HookSignal(
        state: .waiting,
        sessionID: "waiting",
        turnID: "2",
        hookEventName: "PermissionRequest",
        timestamp: now
    ))
    tracker.apply(.turnStarted(sessionID: "working", turnID: "3"), at: now)

    #expect(tracker.effectiveMode == .done)
}

@Test("approval status changes move waiting to working")
func approvalLifecycle() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .waiting,
        sessionID: "session",
        turnID: "turn",
        hookEventName: "PermissionRequest",
        timestamp: now
    ))

    #expect(tracker.effectiveMode == .waiting)
    tracker.noteThreadStatusChanged(at: now.addingTimeInterval(1))
    #expect(tracker.effectiveMode == .waiting)
    tracker.noteThreadStatusChanged(at: now.addingTimeInterval(2))
    #expect(tracker.effectiveMode == .working)
}

@Test("request user input resumes only for the matching call")
func requestUserInputLifecycle() {
    var tracker = ActivityTracker()
    tracker.apply(.turnStarted(sessionID: "session", turnID: "turn"))
    tracker.apply(.waitingForInput(sessionID: "session", callID: "call-a"))
    #expect(tracker.effectiveMode == .waiting)

    tracker.apply(.activityResumed(sessionID: "session", callID: "call-b"))
    #expect(tracker.effectiveMode == .waiting)

    tracker.apply(.activityResumed(sessionID: "session", callID: "call-a"))
    #expect(tracker.effectiveMode == .working)
}

@Test("completion from an older turn cannot finish the current turn")
func ignoresOldCompletion() {
    var tracker = ActivityTracker()
    tracker.apply(.turnStarted(sessionID: "session", turnID: "new"))
    tracker.apply(.turnCompleted(sessionID: "session", turnID: "old"))
    #expect(tracker.effectiveMode == .working)

    tracker.apply(.turnCompleted(sessionID: "session", turnID: "new"))
    #expect(tracker.effectiveMode == .done)
}

@Test("acknowledgement clears the first completion and reveals remaining work")
func acknowledgementPreservesActionableSessions() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .done,
        sessionID: "done",
        turnID: "1",
        hookEventName: "Stop",
        timestamp: now
    ))
    tracker.apply(HookSignal(
        state: .waiting,
        sessionID: "waiting",
        turnID: "2",
        hookEventName: "PermissionRequest",
        timestamp: now
    ))

    let didAcknowledge = tracker.acknowledgeCompleted()
    #expect(didAcknowledge)
    #expect(tracker.sessions["done"] == nil)
    #expect(tracker.sessions["waiting"]?.mode == .waiting)
    #expect(tracker.effectiveMode == .waiting)
}

@Test("completed sessions are acknowledged one at a time in completion order")
func acknowledgementUsesCompletionQueue() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .working,
        sessionID: "still-working",
        turnID: "work",
        hookEventName: "PreToolUse",
        timestamp: now,
        source: .claude
    ))
    tracker.apply(HookSignal(
        state: .done,
        sessionID: "first",
        turnID: "1",
        hookEventName: "Stop",
        timestamp: now.addingTimeInterval(1),
        source: .codex
    ))
    tracker.apply(HookSignal(
        state: .done,
        sessionID: "second",
        turnID: "2",
        hookEventName: "Stop",
        timestamp: now.addingTimeInterval(2),
        source: .claude
    ))

    #expect(tracker.effectiveMode == .done)
    #expect(tracker.firstCompletedSource == .codex)
    let acknowledgedFirst = tracker.acknowledgeCompleted()
    #expect(acknowledgedFirst)
    #expect(tracker.sessions["first"] == nil)
    #expect(tracker.sessions["second"]?.mode == .done)
    #expect(tracker.firstCompletedSource == .claude)
    let acknowledgedSecond = tracker.acknowledgeCompleted()
    #expect(acknowledgedSecond)
    #expect(tracker.effectiveMode == .working)
}

@Test("journal acknowledgement signal clears completed work")
func acknowledgementSignal() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .done,
        sessionID: "session",
        turnID: "turn",
        hookEventName: "Stop",
        timestamp: now
    ))
    tracker.apply(HookSignal(
        state: .off,
        sessionID: "*",
        turnID: nil,
        hookEventName: Constants.acknowledgementEventName,
        timestamp: now
    ))

    #expect(tracker.effectiveMode == .off)
}

@Test("legacy acknowledgement records retain their clear-all upgrade semantics")
func legacyAcknowledgementSignal() {
    var tracker = ActivityTracker()
    let now = Date()
    for sessionID in ["first", "second"] {
        tracker.apply(HookSignal(
            state: .done,
            sessionID: sessionID,
            turnID: nil,
            hookEventName: "Stop",
            timestamp: now
        ))
    }
    tracker.apply(HookSignal(
        state: .off,
        sessionID: "*",
        turnID: nil,
        hookEventName: Constants.legacyAcknowledgementEventName,
        timestamp: now
    ))

    #expect(tracker.effectiveMode == .off)
    #expect(tracker.sessions.isEmpty)
}

@Test("agent exit clears unfinished sessions but preserves unread completions")
func clearUnfinishedPreservesCompletionQueue() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .working,
        sessionID: "working",
        turnID: nil,
        hookEventName: "PreToolUse",
        timestamp: now,
        source: .claude
    ))
    tracker.apply(HookSignal(
        state: .done,
        sessionID: "done",
        turnID: nil,
        hookEventName: "Stop",
        timestamp: now,
        source: .codex
    ))

    tracker.clearUnfinishedSessions()

    #expect(tracker.sessions["working"] == nil)
    #expect(tracker.sessions["done"]?.mode == .done)
    #expect(tracker.effectiveMode == .done)
}

@Test("agent exit cleanup does not remove another agent's active session")
func clearUnfinishedIsScopedToAgent() {
    var tracker = ActivityTracker()
    let now = Date()
    tracker.apply(HookSignal(
        state: .working,
        sessionID: "codex",
        turnID: nil,
        hookEventName: "PreToolUse",
        timestamp: now,
        source: .codex
    ))
    tracker.apply(HookSignal(
        state: .working,
        sessionID: "claude:session",
        turnID: nil,
        hookEventName: "PreToolUse",
        timestamp: now,
        source: .claude
    ))

    tracker.clearUnfinishedSessions(for: .codex)

    #expect(tracker.sessions["codex"] == nil)
    #expect(tracker.sessions["claude:session"]?.mode == .working)
}
