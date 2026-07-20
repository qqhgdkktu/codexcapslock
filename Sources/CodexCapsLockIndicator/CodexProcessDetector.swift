import AppKit
import Foundation

struct CodexApplicationMonitor {
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Constants.codexBundleIdentifier
        ).isEmpty
    }

    var isFrontmost: Bool {
        let query = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Constants.codexBundleIdentifier
        }
        if Thread.isMainThread {
            return query()
        }
        return DispatchQueue.main.sync(execute: query)
    }
}

struct CodingAgentProcessState: Equatable, Sendable {
    let codexRunning: Bool
    let claudeRunning: Bool

    var anyRunning: Bool {
        codexRunning || claudeRunning
    }
}

struct CodingAgentProcessDetector {
    private let applicationMonitor = CodexApplicationMonitor()

    func snapshot() -> CodingAgentProcessState {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "codex|claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CodingAgentProcessState(
                codexRunning: applicationMonitor.isRunning,
                claudeRunning: false
            )
        }

        let output = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output,
              let text = String(data: output, encoding: .utf8) else {
            return CodingAgentProcessState(
                codexRunning: applicationMonitor.isRunning,
                claudeRunning: false
            )
        }

        return Self.classify(processListing: text, codexApplicationRunning: applicationMonitor.isRunning)
    }

    static func classify(
        processListing: String,
        codexApplicationRunning: Bool = false
    ) -> CodingAgentProcessState {
        var codexRunning = codexApplicationRunning
        var claudeRunning = false

        for line in processListing.split(separator: "\n") {
            let command = String(line)
            if command.contains("codex-capslock-indicator") || command.contains("/pgrep ") {
                continue
            }
            if command.contains("/Contents/Resources/codex") || command.contains("@openai/codex") {
                codexRunning = true
            }

            let fields = command.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            let executable = fields.count >= 2 ? String(fields[1]) : ""
            if URL(fileURLWithPath: executable).lastPathComponent == "claude"
                || command.contains("@anthropic-ai/claude-code")
                || command.contains("/claude-code") {
                claudeRunning = true
            }
        }

        return CodingAgentProcessState(
            codexRunning: codexRunning,
            claudeRunning: claudeRunning
        )
    }
}
