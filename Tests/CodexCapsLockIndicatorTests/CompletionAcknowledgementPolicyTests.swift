import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("a Caps Lock state change acknowledges a completed task")
func capsLockAcknowledgement() {
    let start = Date()
    var policy = CompletionAcknowledgementPolicy(initialCapsLockState: false)

    #expect(policy.observe(
        mode: .working,
        codexFrontmost: false,
        actualCapsLockState: false,
        at: start
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        codexFrontmost: false,
        actualCapsLockState: false,
        at: start.addingTimeInterval(1)
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        codexFrontmost: false,
        actualCapsLockState: true,
        at: start.addingTimeInterval(1.25)
    ) == .capsLockKey)
}

@Test("viewing Codex acknowledges only after the visibility dwell")
func focusAcknowledgement() {
    let start = Date()
    var policy = CompletionAcknowledgementPolicy(initialCapsLockState: false)

    #expect(policy.observe(
        mode: .done,
        codexFrontmost: false,
        actualCapsLockState: false,
        at: start
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start.addingTimeInterval(1.5)
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start.addingTimeInterval(2.4)
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start.addingTimeInterval(2.5)
    ) == .codexViewed)
}

@Test("waiting for input cannot be dismissed as a completion")
func waitingIsNotAcknowledged() {
    let start = Date()
    var policy = CompletionAcknowledgementPolicy(initialCapsLockState: false)

    #expect(policy.observe(
        mode: .waiting,
        codexFrontmost: true,
        actualCapsLockState: true,
        at: start
    ) == nil)
}

@Test("Caps Lock remains a normal key while MagSafe is the selected indicator")
func capsLockDoesNotAcknowledgeWithMagSafe() {
    let start = Date()
    var policy = CompletionAcknowledgementPolicy(initialCapsLockState: false)

    #expect(policy.observe(
        mode: .done,
        codexFrontmost: false,
        actualCapsLockState: false,
        capsLockAcknowledgementEnabled: false,
        at: start
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        codexFrontmost: false,
        actualCapsLockState: true,
        capsLockAcknowledgementEnabled: false,
        at: start.addingTimeInterval(1)
    ) == nil)
}

@Test("a queued completion receives its own visibility dwell")
func queuedCompletionResetsFocusDwell() {
    let start = Date()
    var policy = CompletionAcknowledgementPolicy(initialCapsLockState: false)

    #expect(policy.observe(
        mode: .done,
        completionID: "first",
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        completionID: "first",
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start.addingTimeInterval(2)
    ) == .codexViewed)
    #expect(policy.observe(
        mode: .done,
        completionID: "second",
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start.addingTimeInterval(2)
    ) == nil)
    #expect(policy.observe(
        mode: .done,
        completionID: "second",
        codexFrontmost: true,
        actualCapsLockState: false,
        at: start.addingTimeInterval(4)
    ) == .codexViewed)
}
