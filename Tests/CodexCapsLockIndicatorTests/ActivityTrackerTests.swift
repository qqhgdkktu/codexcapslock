import Foundation
import Testing
@testable import CodexCapsLockIndicator

private let baseMillis: Int64 = 1_000_000_000

private func record(
    _ kind: LifecycleEventKind,
    sessionID: String = "session",
    turnID: String? = "turn",
    source: CodingAgent = .codex,
    millis: Int64 = baseMillis,
    eventID: UUID = UUID()
) -> LifecycleRecord {
    LifecycleRecord(
        eventID: eventID,
        source: source,
        sessionID: sessionID,
        turnID: turnID,
        emittedAtMillis: millis,
        kind: kind
    )
}

private func apply(
    _ record: LifecycleRecord,
    to reducer: inout LifecycleReducer,
    nowMillis: Int64 = baseMillis + 1_000
) {
    _ = reducer.apply(record, nowMillis: nowMillis)
}

private func complete(
    sessionID: String,
    turnID: String? = "turn",
    source: CodingAgent = .codex,
    millis: Int64,
    reducer: inout LifecycleReducer
) {
    apply(record(
        .promptSubmitted,
        sessionID: sessionID,
        turnID: turnID,
        source: source,
        millis: millis
    ), to: &reducer, nowMillis: millis + 10)
    apply(record(
        .stopped(outcome: .completed),
        sessionID: sessionID,
        turnID: turnID,
        source: source,
        millis: millis + 1
    ), to: &reducer, nowMillis: millis + 10)
}

@Test("the first completed session has priority over waiting and working")
func firstCompletionHasPriority() {
    var reducer = LifecycleReducer()
    complete(sessionID: "done", millis: baseMillis, reducer: &reducer)
    apply(record(.promptSubmitted, sessionID: "waiting", turnID: "2"), to: &reducer)
    apply(record(
        .permissionRequested(callID: "call"),
        sessionID: "waiting",
        turnID: "2",
        millis: baseMillis + 1
    ), to: &reducer)
    apply(record(.promptSubmitted, sessionID: "working", turnID: "3"), to: &reducer)

    #expect(reducer.effectiveMode == .done)
}

@Test("request user input resumes only for the matching call")
func requestUserInputLifecycle() {
    var reducer = LifecycleReducer()
    apply(record(.promptSubmitted), to: &reducer)
    apply(record(.inputRequested(callID: "call-a"), millis: baseMillis + 1), to: &reducer)
    #expect(reducer.effectiveMode == .waiting)

    apply(record(.toolFinished(callID: "call-b"), millis: baseMillis + 2), to: &reducer)
    #expect(reducer.effectiveMode == .waiting)

    apply(record(.toolFinished(callID: nil), millis: baseMillis + 3), to: &reducer)
    #expect(reducer.effectiveMode == .waiting)

    apply(record(.toolFinished(callID: "call-a"), millis: baseMillis + 4), to: &reducer)
    #expect(reducer.effectiveMode == .working)
}

@Test("completion from an older turn cannot finish the current turn")
func ignoresOldCompletion() {
    var reducer = LifecycleReducer()
    apply(record(.promptSubmitted, turnID: "new"), to: &reducer)
    apply(record(
        .stopped(outcome: .completed),
        turnID: "old",
        millis: baseMillis + 1
    ), to: &reducer)
    #expect(reducer.effectiveMode == .working)

    apply(record(
        .stopped(outcome: .completed),
        turnID: "new",
        millis: baseMillis + 2
    ), to: &reducer)
    #expect(reducer.effectiveMode == .done)
}

@Test("stale working after done cannot reopen a terminal generation")
func staleWorkingAfterDone() {
    var reducer = LifecycleReducer()
    complete(sessionID: "session", millis: baseMillis + 10, reducer: &reducer)
    let completion = reducer.completionQueue.first

    apply(record(
        .toolStarted(callID: "late"),
        millis: baseMillis
    ), to: &reducer)

    #expect(reducer.effectiveMode == .done)
    #expect(reducer.completionQueue.first == completion)
    #expect(reducer.activeGenerations.isEmpty)
}

@Test("stale session end cannot remove a newer turn")
func staleSessionEndAfterNewWork() {
    var reducer = LifecycleReducer()
    apply(record(.promptSubmitted, turnID: "new", millis: baseMillis + 10), to: &reducer)
    apply(record(.sessionEnded, turnID: "old", millis: baseMillis), to: &reducer)

    #expect(reducer.effectiveMode == .working)
    #expect(reducer.activeGenerations["session"]?.turnID == "new")
}

@Test("session-wide end can close a current turn without a turn id")
func sessionWideEndClosesCurrentTurn() {
    var reducer = LifecycleReducer()
    apply(record(.promptSubmitted, turnID: "current"), to: &reducer)
    apply(
        record(.sessionEnded, turnID: nil, millis: baseMillis + 1),
        to: &reducer
    )

    #expect(reducer.effectiveMode == .off)
    #expect(reducer.activeGenerations.isEmpty)
}

@Test("stale prompt cannot replace a newer active turn")
func stalePromptCannotReplaceNewerTurn() {
    var reducer = LifecycleReducer()
    apply(
        record(.promptSubmitted, turnID: "new", millis: baseMillis + 10),
        to: &reducer
    )
    apply(
        record(.promptSubmitted, turnID: "old", millis: baseMillis),
        to: &reducer
    )

    #expect(reducer.activeGenerations["session"]?.turnID == "new")
}

@Test("partially identified event cannot complete a correlated turn")
func partialEventCannotCompleteCorrelatedTurn() {
    var reducer = LifecycleReducer()
    apply(record(.promptSubmitted, turnID: "known"), to: &reducer)
    apply(
        record(
            .stopped(outcome: .completed),
            turnID: nil,
            millis: baseMillis + 1
        ),
        to: &reducer
    )

    #expect(reducer.effectiveMode == .working)
    #expect(reducer.completionQueue.isEmpty)
}

@Test("duplicate event IDs and duplicate stops are idempotent")
func duplicateEventsAreIdempotent() {
    var reducer = LifecycleReducer()
    let promptID = UUID()
    let prompt = record(.promptSubmitted, eventID: promptID)
    apply(prompt, to: &reducer)
    apply(prompt, to: &reducer)

    let stop = record(.stopped(outcome: .completed), millis: baseMillis + 1)
    apply(stop, to: &reducer)
    let firstCompletion = reducer.completionQueue.first
    apply(stop, to: &reducer)
    apply(record(.stopped(outcome: .completed), millis: baseMillis + 2), to: &reducer)

    #expect(reducer.completionQueue.count == 1)
    #expect(reducer.completionQueue.first == firstCompletion)
}

@Test("future and expired records are rejected")
func rejectsClockSkew() {
    var reducer = LifecycleReducer()
    let now = baseMillis + Constants.maximumPastEventAgeMillis

    let future = record(
        .promptSubmitted,
        millis: now + Constants.maximumFutureEventSkewMillis + 1
    )
    let expired = record(.promptSubmitted, millis: now - Constants.maximumPastEventAgeMillis - 1)

    let acceptedFuture = reducer.apply(future, nowMillis: now)
    let acceptedExpired = reducer.apply(expired, nowMillis: now)
    #expect(!acceptedFuture)
    #expect(!acceptedExpired)
    #expect(reducer.effectiveMode == .off)
}

@Test("same timestamp completions preserve append order")
func sameTimestampCompletionOrder() {
    var reducer = LifecycleReducer()
    complete(sessionID: "first", millis: baseMillis, reducer: &reducer)
    complete(sessionID: "second", millis: baseMillis, reducer: &reducer)

    #expect(reducer.completionQueue.map(\.sessionID) == ["first", "second"])
    #expect(reducer.completionQueue.map(\.ordinal) == [1, 2])
}

@Test("acknowledgement removes only the exact queue head")
func acknowledgementUsesStableQueue() {
    var reducer = LifecycleReducer()
    complete(sessionID: "first", source: .codex, millis: baseMillis, reducer: &reducer)
    complete(sessionID: "second", source: .claude, millis: baseMillis + 10, reducer: &reducer)
    let secondID = reducer.completionQueue[1].completionID
    let firstID = reducer.completionQueue[0].completionID

    let acknowledgedOutOfOrder = reducer.acknowledgeCompleted(completionID: secondID)
    #expect(!acknowledgedOutOfOrder)
    #expect(reducer.completionQueue.count == 2)
    let acknowledgedHead = reducer.acknowledgeCompleted(completionID: firstID)
    #expect(acknowledgedHead)
    #expect(reducer.firstCompletedSource == .claude)
}

@Test("session end preserves unread completion")
func sessionEndPreservesCompletion() {
    var reducer = LifecycleReducer()
    complete(sessionID: "session", millis: baseMillis, reducer: &reducer)
    apply(record(.sessionEnded, millis: baseMillis + 2), to: &reducer)

    #expect(reducer.effectiveMode == .done)
    #expect(reducer.completionQueue.count == 1)
}

@Test("new work after completion appears after acknowledgement")
func newWorkAfterCompletion() {
    var reducer = LifecycleReducer()
    complete(sessionID: "session", turnID: "old", millis: baseMillis, reducer: &reducer)
    apply(record(
        .promptSubmitted,
        turnID: "new",
        millis: baseMillis + 2
    ), to: &reducer)

    #expect(reducer.effectiveMode == .done)
    let acknowledged = reducer.acknowledgeCompleted()
    #expect(acknowledged)
    #expect(reducer.effectiveMode == .working)
    #expect(reducer.activeGenerations["session"]?.turnID == "new")
}

@Test("agent cleanup removes only matching unfinished work")
func clearUnfinishedIsScopedToAgent() {
    var reducer = LifecycleReducer()
    apply(record(.promptSubmitted, sessionID: "codex", source: .codex), to: &reducer)
    apply(record(
        .promptSubmitted,
        sessionID: "claude:session",
        source: .claude
    ), to: &reducer)
    complete(
        sessionID: "done",
        source: .codex,
        millis: baseMillis + 10,
        reducer: &reducer
    )

    reducer.clearUnfinishedSessions(for: .codex)

    #expect(reducer.activeGenerations["codex"] == nil)
    #expect(reducer.activeGenerations["claude:session"] != nil)
    #expect(reducer.completionQueue.count == 1)
}

@Test("serialized reducer preserves immutable queue order")
func reducerSerializationRoundTrip() throws {
    var reducer = LifecycleReducer()
    complete(sessionID: "first", millis: baseMillis, reducer: &reducer)
    complete(sessionID: "second", millis: baseMillis + 10, reducer: &reducer)

    let data = try JSONEncoder().encode(reducer)
    let restored = try JSONDecoder().decode(LifecycleReducer.self, from: data)

    #expect(restored.completionQueue == reducer.completionQueue)
    #expect(restored.nextCompletionOrdinal == 3)
}

@Test("adversarial event permutations preserve terminal queue")
func adversarialPermutationsPreserveQueue() {
    let lateEvents: [LifecycleEventKind] = [
        .toolStarted(callID: "late"),
        .toolFinished(callID: nil),
        .permissionRequested(callID: "late"),
        .sessionEnded,
        .stopped(outcome: .completed),
    ]

    for kind in lateEvents {
        var reducer = LifecycleReducer()
        complete(sessionID: "session", millis: baseMillis + 10, reducer: &reducer)
        let expected = reducer.completionQueue
        apply(record(kind, millis: baseMillis), to: &reducer)
        #expect(reducer.completionQueue == expected)
    }
}
