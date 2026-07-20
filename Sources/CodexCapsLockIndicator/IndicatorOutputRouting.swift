import Foundation

enum IndicatorOutput: String, Codable, Sendable {
    case capsLock = "caps-lock"
    case magSafe = "magsafe"
}

enum IndicatorOutputRouting {
    static func select(
        magSafe: MagSafeConnectionSnapshot,
        magSafeControlAvailable: Bool
    ) -> IndicatorOutput {
        magSafe.connected && magSafeControlAvailable ? .magSafe : .capsLock
    }

    static func magSafeMode(for indicatorMode: IndicatorMode) -> MagSafeLEDMode {
        switch indicatorMode {
        case .working:
            .blinkSlow
        case .waiting, .done:
            .green
        case .off:
            .system
        }
    }

    static func shouldApplyMagSafeMode(
        requested: MagSafeLEDMode,
        applied: MagSafeLEDMode?,
        currentValue: UInt8?,
        reconciliationRequested: Bool
    ) -> Bool {
        reconciliationRequested
            || requested != applied
            || currentValue.map { $0 != requested.aclcValue } == true
    }
}
