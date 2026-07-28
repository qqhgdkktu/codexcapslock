import Foundation

enum LifecyclePhase: String, Codable, Sendable {
    case working
    case waiting
}

struct ActiveGeneration: Codable, Sendable, Equatable {
    let generationID: UUID
    let source: CodingAgent
    let sessionID: String
    var turnID: String?
    var phase: LifecyclePhase
    var pendingCallIDs: Set<String>
    var lastEventAtMillis: Int64
}

struct CompletionRecord: Codable, Sendable, Equatable {
    let completionID: UUID
    let ordinal: UInt64
    let source: CodingAgent
    let sessionID: String
    let generationID: UUID
    let outcome: CompletionOutcome
    let completedAtMillis: Int64
}

struct SessionActivity: Sendable {
    var mode: IndicatorMode
    var source: CodingAgent
    var turnID: String?
    var pendingInputCallID: String?
    var waitingStatusObserved: Bool
    var updatedAt: Date
}

struct LifecycleReducer: Codable, Sendable {
    private(set) var activeGenerations: [String: ActiveGeneration]
    private(set) var completionQueue: [CompletionRecord]
    private(set) var nextCompletionOrdinal: UInt64
    private var seenEventIDs: [UUID]

    init(
        activeGenerations: [String: ActiveGeneration] = [:],
        completionQueue: [CompletionRecord] = [],
        nextCompletionOrdinal: UInt64 = 1,
        seenEventIDs: [UUID] = []
    ) {
        self.activeGenerations = activeGenerations
        self.completionQueue = completionQueue.sorted { $0.ordinal < $1.ordinal }
        let highestOrdinal = completionQueue.map(\.ordinal).max() ?? 0
        let ordinalAfterHighest = highestOrdinal == UInt64.max
            ? UInt64.max
            : highestOrdinal + 1
        self.nextCompletionOrdinal = max(nextCompletionOrdinal, ordinalAfterHighest)
        self.seenEventIDs = Array(seenEventIDs.suffix(Self.maximumRememberedEventIDs))
    }

    @discardableResult
    mutating func apply(
        _ record: LifecycleRecord,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> Bool {
        guard record.schemaVersion == LifecycleRecord.schemaVersion,
              !seenEventIDs.contains(record.eventID),
              record.emittedAtMillis >= nowMillis - Constants.maximumPastEventAgeMillis,
              record.emittedAtMillis <= nowMillis + Constants.maximumFutureEventSkewMillis else {
            return false
        }

        remember(record.eventID)

        switch record.kind {
        case .acknowledged(let completionID):
            return acknowledgeCompleted(completionID: completionID)
        case .acknowledgedAll:
            return acknowledgeAllCompleted()
        case .promptSubmitted:
            return beginGeneration(for: record)
        case .toolStarted(let callID):
            return applyWorkingEvent(record, callID: callID, removesPendingCall: false)
        case .permissionRequested(let callID), .inputRequested(let callID):
            return applyWaitingEvent(record, callID: callID)
        case .toolFinished(let callID):
            return applyWorkingEvent(record, callID: callID, removesPendingCall: true)
        case .stopped(let outcome):
            return finishGeneration(for: record, outcome: outcome)
        case .sessionEnded:
            return endSession(for: record)
        }
    }

    mutating func apply(_ event: TranscriptEvent, at date: Date = Date()) {
        // Compatibility adapters are intentionally weaker than hooks. They can
        // project active Codex state, but cannot overwrite a terminal queue.
        let millis = Int64(date.timeIntervalSince1970 * 1_000)
        let record: LifecycleRecord
        switch event {
        case let .turnStarted(sessionID, turnID):
            record = LifecycleRecord(
                source: .codex,
                sessionID: sessionID,
                turnID: turnID,
                emittedAtMillis: millis,
                kind: .promptSubmitted
            )
        case let .turnCompleted(sessionID, turnID):
            record = LifecycleRecord(
                source: .codex,
                sessionID: sessionID,
                turnID: turnID,
                emittedAtMillis: millis,
                kind: .stopped(outcome: .completed)
            )
        case let .waitingForInput(sessionID, callID):
            record = LifecycleRecord(
                source: .codex,
                sessionID: sessionID,
                turnID: activeGenerations[sessionID]?.turnID,
                emittedAtMillis: millis,
                kind: .inputRequested(callID: callID)
            )
        case let .activityResumed(sessionID, callID):
            record = LifecycleRecord(
                source: .codex,
                sessionID: sessionID,
                turnID: activeGenerations[sessionID]?.turnID,
                emittedAtMillis: millis,
                kind: .toolFinished(callID: callID)
            )
        case let .sessionEnded(sessionID):
            record = LifecycleRecord(
                source: .codex,
                sessionID: sessionID,
                turnID: activeGenerations[sessionID]?.turnID,
                emittedAtMillis: millis,
                kind: .sessionEnded
            )
        }
        _ = apply(record, nowMillis: millis)
    }

    mutating func clear() {
        activeGenerations.removeAll(keepingCapacity: true)
        completionQueue.removeAll(keepingCapacity: true)
    }

    mutating func clearUnfinishedSessions(for source: CodingAgent? = nil) {
        activeGenerations = activeGenerations.filter { _, generation in
            source != nil && generation.source != source
        }
    }

    @discardableResult
    mutating func acknowledgeCompleted(completionID: UUID? = nil) -> Bool {
        guard let first = completionQueue.first,
              completionID == nil || completionID == first.completionID else {
            return false
        }
        completionQueue.removeFirst()
        return true
    }

    @discardableResult
    mutating func acknowledgeAllCompleted() -> Bool {
        guard !completionQueue.isEmpty else {
            return false
        }
        completionQueue.removeAll(keepingCapacity: true)
        return true
    }

    var effectiveMode: IndicatorMode {
        if !completionQueue.isEmpty {
            return .done
        }
        if activeGenerations.values.contains(where: { $0.phase == .waiting }) {
            return .waiting
        }
        if !activeGenerations.isEmpty {
            return .working
        }
        return .off
    }

    var firstCompletedSource: CodingAgent? {
        completionQueue.first?.source
    }

    var firstCompletedSessionID: String? {
        completionQueue.first?.sessionID
    }

    var firstCompletionID: UUID? {
        completionQueue.first?.completionID
    }

    var firstCompletionOutcome: CompletionOutcome? {
        completionQueue.first?.outcome
    }

    var activeGenerationCount: Int {
        activeGenerations.count
    }

    var sessions: [String: SessionActivity] {
        var projected = activeGenerations.mapValues { generation in
            SessionActivity(
                mode: generation.phase == .waiting ? .waiting : .working,
                source: generation.source,
                turnID: generation.turnID,
                pendingInputCallID: generation.pendingCallIDs.first,
                waitingStatusObserved: false,
                updatedAt: Date(timeIntervalSince1970: Double(generation.lastEventAtMillis) / 1_000)
            )
        }
        for completion in completionQueue where projected[completion.sessionID] == nil {
            projected[completion.sessionID] = SessionActivity(
                mode: .done,
                source: completion.source,
                turnID: nil,
                pendingInputCallID: nil,
                waitingStatusObserved: false,
                updatedAt: Date(timeIntervalSince1970: Double(completion.completedAtMillis) / 1_000)
            )
        }
        return projected
    }

    // A full 4 MiB spool cannot contain more valid records than this at the
    // minimum encoded record size, so a crash between snapshot and compaction
    // still replays every record idempotently.
    private static let maximumRememberedEventIDs = 32_768

    private mutating func remember(_ eventID: UUID) {
        seenEventIDs.append(eventID)
        if seenEventIDs.count > Self.maximumRememberedEventIDs {
            seenEventIDs.removeFirst(seenEventIDs.count - Self.maximumRememberedEventIDs)
        }
    }

    private mutating func beginGeneration(for record: LifecycleRecord) -> Bool {
        if let current = activeGenerations[record.sessionID] {
            guard record.emittedAtMillis >= current.lastEventAtMillis else {
                return false
            }
            if let turnID = record.turnID, current.turnID == turnID {
                return false
            }
        }
        guard activeGenerations[record.sessionID] != nil
                || activeGenerations.count < Constants.maximumActiveGenerations else {
            return false
        }
        activeGenerations[record.sessionID] = ActiveGeneration(
            generationID: UUID(),
            source: record.source,
            sessionID: record.sessionID,
            turnID: record.turnID,
            phase: .working,
            pendingCallIDs: [],
            lastEventAtMillis: record.emittedAtMillis
        )
        return true
    }

    private mutating func applyWaitingEvent(
        _ record: LifecycleRecord,
        callID: String?
    ) -> Bool {
        guard var generation = matchingGeneration(for: record),
              record.emittedAtMillis >= generation.lastEventAtMillis else {
            return false
        }
        generation.phase = .waiting
        if let callID {
            guard generation.pendingCallIDs.contains(callID)
                    || generation.pendingCallIDs.count
                        < Constants.maximumPendingCallsPerGeneration else {
                return false
            }
            generation.pendingCallIDs.insert(callID)
        }
        generation.lastEventAtMillis = record.emittedAtMillis
        activeGenerations[record.sessionID] = generation
        return true
    }

    private mutating func applyWorkingEvent(
        _ record: LifecycleRecord,
        callID: String?,
        removesPendingCall: Bool
    ) -> Bool {
        guard var generation = matchingGeneration(for: record),
              record.emittedAtMillis >= generation.lastEventAtMillis else {
            return false
        }
        if removesPendingCall, !generation.pendingCallIDs.isEmpty {
            guard let callID, generation.pendingCallIDs.contains(callID) else {
                return false
            }
            generation.pendingCallIDs.remove(callID)
        }
        generation.phase = generation.pendingCallIDs.isEmpty ? .working : .waiting
        generation.lastEventAtMillis = record.emittedAtMillis
        activeGenerations[record.sessionID] = generation
        return true
    }

    private mutating func finishGeneration(
        for record: LifecycleRecord,
        outcome: CompletionOutcome
    ) -> Bool {
        guard let generation = matchingGeneration(for: record),
              record.emittedAtMillis >= generation.lastEventAtMillis else {
            return false
        }
        guard !completionQueue.contains(where: { $0.generationID == generation.generationID }) else {
            return false
        }
        guard completionQueue.count < Constants.maximumCompletionQueueDepth,
              nextCompletionOrdinal < UInt64.max else {
            return false
        }

        completionQueue.append(CompletionRecord(
            completionID: UUID(),
            ordinal: nextCompletionOrdinal,
            source: record.source,
            sessionID: record.sessionID,
            generationID: generation.generationID,
            outcome: outcome,
            completedAtMillis: record.emittedAtMillis
        ))
        nextCompletionOrdinal += 1
        activeGenerations.removeValue(forKey: record.sessionID)
        return true
    }

    private mutating func endSession(for record: LifecycleRecord) -> Bool {
        guard let generation = activeGenerations[record.sessionID],
              generation.source == record.source,
              record.emittedAtMillis >= generation.lastEventAtMillis,
              record.turnID == nil || record.turnID == generation.turnID else {
            return false
        }
        activeGenerations.removeValue(forKey: record.sessionID)
        return true
    }

    private func matchingGeneration(for record: LifecycleRecord) -> ActiveGeneration? {
        guard let generation = activeGenerations[record.sessionID],
              generation.source == record.source,
              generation.turnID == record.turnID else {
            return nil
        }
        return generation
    }
}

typealias ActivityTracker = LifecycleReducer
