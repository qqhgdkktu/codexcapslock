import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("MagSafe is selected only when connected and controllable")
func magSafeSelectionRequiresConnectionAndControl() {
    let connected = MagSafeConnectionSnapshot(
        portPresent: true,
        connectionActive: true,
        externalPowerAttached: true
    )
    #expect(IndicatorOutputRouting.select(
        magSafe: connected,
        magSafeControlAvailable: true
    ) == .magSafe)
    #expect(IndicatorOutputRouting.select(
        magSafe: connected,
        magSafeControlAvailable: false
    ) == .capsLock)
}

@Test("Caps Lock is selected when MagSafe is disconnected")
func capsLockFallbackWhenMagSafeDisconnected() {
    let disconnected = MagSafeConnectionSnapshot(
        portPresent: true,
        connectionActive: false,
        externalPowerAttached: true
    )
    #expect(IndicatorOutputRouting.select(
        magSafe: disconnected,
        magSafeControlAvailable: true
    ) == .capsLock)
}

@Test("MagSafe connection needs both port activity and current external power")
func magSafeConnectionRejectsStalePortState() {
    let port = MagSafePortState(
        typeDescription: "MagSafe 3",
        portType: 17,
        connectionActive: true
    )
    let stale = MagSafeConnectionDetector.evaluate(
        ports: [port],
        externalPowerAttached: false
    )
    let live = MagSafeConnectionDetector.evaluate(
        ports: [port],
        externalPowerAttached: true
    )

    #expect(stale.portPresent)
    #expect(!stale.connected)
    #expect(live.connected)
}

@Test("Codex lifecycle maps to firmware MagSafe modes")
func lifecycleMapsToMagSafeModes() {
    #expect(IndicatorOutputRouting.magSafeMode(for: .working) == .blinkSlow)
    #expect(IndicatorOutputRouting.magSafeMode(for: .waiting) == .green)
    #expect(IndicatorOutputRouting.magSafeMode(for: .done) == .green)
    #expect(IndicatorOutputRouting.magSafeMode(for: .off) == .system)
}
