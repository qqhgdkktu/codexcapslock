import Foundation
import Testing
@testable import CodexCapsLockIndicator

@Test("process detection returns without blocking")
func processDetectionDoesNotBlock() {
    let startedAt = Date()
    _ = CodingAgentProcessDetector().snapshot()
    #expect(Date().timeIntervalSince(startedAt) < 5)
}

@Test("process listing distinguishes Codex and Claude Code from the indicator itself")
func processDetectionClassifiesBothAgents() {
    let listing = """
    10 /Applications/Codex.app/Contents/Resources/codex app-server
    11 /Users/test/.local/bin/claude --resume
    12 /Users/test/.local/bin/codex-capslock-indicator daemon
    13 /usr/bin/pgrep -fl codex|claude
    """

    let state = CodingAgentProcessDetector.classify(processListing: listing)
    #expect(state.codexRunning)
    #expect(state.claudeRunning)
}

@Test("Claude desktop naming alone is not treated as Claude Code")
func processDetectionAvoidsClaudeDesktopFalsePositive() {
    let state = CodingAgentProcessDetector.classify(
        processListing: "20 /Applications/Claude.app/Contents/MacOS/Claude"
    )
    #expect(!state.claudeRunning)
}
