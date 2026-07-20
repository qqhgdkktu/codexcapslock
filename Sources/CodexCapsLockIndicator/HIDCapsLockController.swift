import CoreGraphics
import Foundation

final class HIDCapsLockController {
    private let rawController = RawHIDCapsLockController()
    private let modifierController = CapsLockModifierController()

    var keyboardName: String? {
        builtInTarget?.product
    }

    var isAvailable: Bool {
        builtInTarget != nil
    }

    var hardwareIndicatorState: Bool? {
        guard let target = builtInTarget else {
            return nil
        }
        let (result, value) = rawController.readIndicator(target)
        guard result == kIOReturnSuccess, let value else {
            return nil
        }
        return value != 0
    }

    var actualCapsLockState: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    @discardableResult
    func setIndicator(_ enabled: Bool) -> Bool {
        let results = rawController.setIndicator(enabled)
        return !results.isEmpty && results.allSatisfy { $0.1 == kIOReturnSuccess }
    }

    @discardableResult
    func restoreActualCapsLockIndicator() -> Bool {
        setIndicator(actualCapsLockState)
    }

    @discardableResult
    func setActualCapsLockState(_ enabled: Bool) -> Bool {
        modifierController.setEnabled(enabled)
    }

    private var builtInTarget: RawHIDLEDTarget? {
        rawController.targets.first(where: \.builtIn)
    }
}
