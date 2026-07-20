import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("working has priority over waiting and done")
func effectiveModePriority() {
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

    #expect(tracker.effectiveMode == .working)
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

@Test("acknowledgement clears only completed sessions")
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
