import Foundation

struct SessionActivity: Sendable {
    var mode: IndicatorMode
    var source: CodingAgent
    var turnID: String?
    var pendingInputCallID: String?
    var waitingStatusObserved: Bool
    var updatedAt: Date
}

struct ActivityTracker: Sendable {
    private(set) var sessions: [String: SessionActivity] = [:]

    mutating func apply(_ signal: HookSignal) {
        guard Date().timeIntervalSince(signal.timestamp) < 24 * 60 * 60 else {
            return
        }

        if signal.hookEventName == Constants.acknowledgementEventName {
            acknowledgeCompleted()
            return
        }
        if signal.hookEventName == Constants.legacyAcknowledgementEventName {
            acknowledgeAllCompleted()
            return
        }

        if signal.state == .off {
            sessions.removeValue(forKey: signal.sessionID)
            return
        }

        sessions[signal.sessionID] = SessionActivity(
            mode: signal.state,
            source: signal.source ?? .codex,
            turnID: signal.turnID,
            pendingInputCallID: nil,
            waitingStatusObserved: false,
            updatedAt: signal.timestamp
        )
    }

    mutating func apply(_ event: TranscriptEvent, at date: Date = Date()) {
        switch event {
        case let .turnStarted(sessionID, turnID):
            sessions[sessionID] = SessionActivity(
                mode: .working,
                source: .codex,
                turnID: turnID,
                pendingInputCallID: nil,
                waitingStatusObserved: false,
                updatedAt: date
            )

        case let .turnCompleted(sessionID, turnID):
            if let currentTurnID = sessions[sessionID]?.turnID,
               let turnID,
               currentTurnID != turnID {
                return
            }
            sessions[sessionID] = SessionActivity(
                mode: .done,
                source: sessions[sessionID]?.source ?? .codex,
                turnID: turnID,
                pendingInputCallID: nil,
                waitingStatusObserved: false,
                updatedAt: date
            )

        case let .waitingForInput(sessionID, callID):
            var activity = sessions[sessionID] ?? SessionActivity(
                mode: .waiting,
                source: .codex,
                turnID: nil,
                pendingInputCallID: nil,
                waitingStatusObserved: false,
                updatedAt: date
            )
            activity.mode = .waiting
            activity.pendingInputCallID = callID
            activity.waitingStatusObserved = false
            activity.updatedAt = date
            sessions[sessionID] = activity

        case let .activityResumed(sessionID, callID):
            guard var activity = sessions[sessionID], activity.mode == .waiting else {
                return
            }
            if let pendingCallID = activity.pendingInputCallID,
               let callID,
               pendingCallID != callID {
                return
            }
            activity.mode = .working
            activity.pendingInputCallID = nil
            activity.waitingStatusObserved = false
            activity.updatedAt = date
            sessions[sessionID] = activity

        case let .sessionEnded(sessionID):
            sessions.removeValue(forKey: sessionID)
        }
    }

    mutating func noteThreadStatusChanged(at date: Date = Date()) {
        let candidates = sessions
            .filter { $0.value.mode == .waiting }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }

        guard let candidate = candidates.first else {
            return
        }

        var activity = candidate.value
        if activity.waitingStatusObserved {
            activity.mode = .working
            activity.pendingInputCallID = nil
            activity.waitingStatusObserved = false
        } else {
            activity.waitingStatusObserved = true
        }
        activity.updatedAt = date
        sessions[candidate.key] = activity
    }

    mutating func clear() {
        sessions.removeAll(keepingCapacity: true)
    }

    mutating func clearUnfinishedSessions(for source: CodingAgent? = nil) {
        sessions = sessions.filter { _, activity in
            activity.mode == .done || (source != nil && activity.source != source)
        }
    }

    @discardableResult
    mutating func acknowledgeCompleted() -> Bool {
        guard let completedSessionID = firstCompletedSession?.key else {
            return false
        }
        sessions.removeValue(forKey: completedSessionID)
        return true
    }

    @discardableResult
    mutating func acknowledgeAllCompleted() -> Bool {
        let completedSessionIDs = sessions.compactMap { sessionID, activity in
            activity.mode == .done ? sessionID : nil
        }
        for sessionID in completedSessionIDs {
            sessions.removeValue(forKey: sessionID)
        }
        return !completedSessionIDs.isEmpty
    }

    var effectiveMode: IndicatorMode {
        if firstCompletedSession != nil {
            return .done
        }
        if sessions.values.contains(where: { $0.mode == .waiting }) {
            return .waiting
        }
        if sessions.values.contains(where: { $0.mode == .working }) {
            return .working
        }
        return .off
    }

    var firstCompletedSource: CodingAgent? {
        firstCompletedSession?.value.source
    }

    var firstCompletedSessionID: String? {
        firstCompletedSession?.key
    }

    private var firstCompletedSession: (key: String, value: SessionActivity)? {
        sessions
            .filter { $0.value.mode == .done }
            .min { lhs, rhs in
                if lhs.value.updatedAt == rhs.value.updatedAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.updatedAt < rhs.value.updatedAt
            }
    }
}
