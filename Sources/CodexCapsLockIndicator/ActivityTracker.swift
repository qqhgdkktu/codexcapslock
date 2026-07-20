import Foundation

struct SessionActivity: Sendable {
    var mode: IndicatorMode
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

        if signal.state == .off {
            sessions.removeValue(forKey: signal.sessionID)
            return
        }

        sessions[signal.sessionID] = SessionActivity(
            mode: signal.state,
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
                turnID: turnID,
                pendingInputCallID: nil,
                waitingStatusObserved: false,
                updatedAt: date
            )

        case let .waitingForInput(sessionID, callID):
            var activity = sessions[sessionID] ?? SessionActivity(
                mode: .waiting,
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

    var effectiveMode: IndicatorMode {
        if sessions.values.contains(where: { $0.mode == .working }) {
            return .working
        }
        if sessions.values.contains(where: { $0.mode == .waiting }) {
            return .waiting
        }
        if sessions.values.contains(where: { $0.mode == .done }) {
            return .done
        }
        return .off
    }
}
