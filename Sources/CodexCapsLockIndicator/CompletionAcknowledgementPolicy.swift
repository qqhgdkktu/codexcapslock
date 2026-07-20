import Foundation

enum CompletionAcknowledgementReason: Equatable, Sendable {
    case capsLockKey
    case codexViewed
}

struct CompletionAcknowledgementPolicy: Sendable {
    private var observedMode: IndicatorMode = .off
    private var doneSince: Date?
    private var codexFrontmostSince: Date?
    private var lastCapsLockState: Bool

    init(initialCapsLockState: Bool) {
        lastCapsLockState = initialCapsLockState
    }

    mutating func observe(
        mode: IndicatorMode,
        codexFrontmost: Bool,
        actualCapsLockState: Bool,
        at date: Date = Date()
    ) -> CompletionAcknowledgementReason? {
        defer { lastCapsLockState = actualCapsLockState }

        if mode != observedMode {
            observedMode = mode
            doneSince = mode == .done ? date : nil
            codexFrontmostSince = mode == .done && codexFrontmost ? date : nil
        }

        guard mode == .done else {
            return nil
        }

        if actualCapsLockState != lastCapsLockState {
            return .capsLockKey
        }

        if codexFrontmost {
            codexFrontmostSince = codexFrontmostSince ?? date
        } else {
            codexFrontmostSince = nil
        }

        guard let doneSince,
              let codexFrontmostSince,
              date.timeIntervalSince(doneSince) >= Constants.minimumDoneVisibility,
              date.timeIntervalSince(codexFrontmostSince) >= Constants.codexFocusAcknowledgementDelay else {
            return nil
        }
        return .codexViewed
    }
}
