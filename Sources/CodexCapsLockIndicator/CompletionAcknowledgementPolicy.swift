import Foundation

enum CompletionAcknowledgementReason: Equatable, Sendable {
    case capsLockKey
    case codexViewed
}

struct CompletionAcknowledgementPolicy: Sendable {
    private var observedMode: IndicatorMode = .off
    private var observedCompletionID: UUID?
    private var doneSince: TimeInterval?
    private var codexFrontmostSince: TimeInterval?
    private var lastCapsLockState: Bool

    init(initialCapsLockState: Bool) {
        lastCapsLockState = initialCapsLockState
    }

    mutating func resetCapsLockBaseline(_ actualCapsLockState: Bool) {
        lastCapsLockState = actualCapsLockState
    }

    mutating func observe(
        mode: IndicatorMode,
        completionID: UUID? = nil,
        codexFrontmost: Bool,
        actualCapsLockState: Bool,
        capsLockAcknowledgementEnabled: Bool = true,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CompletionAcknowledgementReason? {
        defer { lastCapsLockState = actualCapsLockState }

        if mode != observedMode || completionID != observedCompletionID {
            observedMode = mode
            observedCompletionID = completionID
            doneSince = mode == .done ? uptime : nil
            codexFrontmostSince = mode == .done && codexFrontmost ? uptime : nil
        }

        guard mode == .done else {
            return nil
        }

        if capsLockAcknowledgementEnabled && actualCapsLockState != lastCapsLockState {
            return .capsLockKey
        }

        if codexFrontmost {
            codexFrontmostSince = codexFrontmostSince ?? uptime
        } else {
            codexFrontmostSince = nil
        }

        guard let doneSince,
              let codexFrontmostSince,
              uptime - doneSince >= Constants.minimumDoneVisibility,
              uptime - codexFrontmostSince >= Constants.codexFocusAcknowledgementDelay else {
            return nil
        }
        return .codexViewed
    }
}
