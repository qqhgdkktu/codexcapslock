import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("process detection returns without blocking")
func processDetectionDoesNotBlock() {
    let startedAt = Date()
    _ = CodexProcessDetector().isRunning()
    #expect(Date().timeIntervalSince(startedAt) < 5)
}
