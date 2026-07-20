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

struct CodexProcessDetector {
    private let applicationMonitor = CodexApplicationMonitor()

    func isRunning() -> Bool {
        if applicationMonitor.isRunning {
            return true
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "codex"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        let output = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output,
              let text = String(data: output, encoding: .utf8) else {
            return false
        }

        return text.split(separator: "\n").contains { line in
            let command = String(line)
            if command.contains("codex-capslock-indicator") {
                return false
            }
            return command.contains("/Contents/Resources/codex")
                || command.contains("@openai/codex")
        }
    }
}
