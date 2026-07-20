import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("status files from version 1.3.0 remain readable")
func legacyDaemonStatusRemainsReadable() throws {
    let json = """
    {
      "activeSessions": 1,
      "claudeProcessRunning": false,
      "codexProcessRunning": true,
      "keyboardAvailable": true,
      "keyboardName": "Apple Internal Keyboard",
      "ledOn": true,
      "magSafeConnected": true,
      "magSafeControlAvailable": true,
      "magSafeLEDMode": "green",
      "magSafePortPresent": true,
      "mode": "done",
      "output": "magsafe",
      "pid": 42,
      "updatedAt": "2026-07-20T17:00:00Z",
      "version": "1.3.0"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let status = try decoder.decode(DaemonStatus.self, from: Data(json.utf8))

    #expect(status.magSafeRawValue == nil)
    #expect(status.magSafeExpectedValue == nil)
    #expect(status.magSafeSynchronized == nil)
    #expect(status.magSafeLastWriteAt == nil)
}
