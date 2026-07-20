import Foundation

enum IndicatorMode: String, Codable, Sendable {
    case off
    case working
    case waiting
    case done
}

struct HookSignal: Codable, Sendable {
    let state: IndicatorMode
    let sessionID: String
    let turnID: String?
    let hookEventName: String?
    let timestamp: Date
}

struct HookInput: Decodable {
    let sessionID: String?
    let turnID: String?
    let hookEventName: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case hookEventName = "hook_event_name"
    }
}

struct DaemonStatus: Codable, Sendable {
    let pid: Int32
    let mode: IndicatorMode
    let output: IndicatorOutput
    let ledOn: Bool
    let keyboardAvailable: Bool
    let keyboardName: String?
    let magSafePortPresent: Bool
    let magSafeConnected: Bool
    let magSafeControlAvailable: Bool
    let magSafeLEDMode: MagSafeLEDMode?
    let activeSessions: Int
    let codexProcessRunning: Bool
    let updatedAt: Date
    let version: String
}

enum TranscriptEvent: Equatable, Sendable {
    case turnStarted(sessionID: String, turnID: String?)
    case turnCompleted(sessionID: String, turnID: String?)
    case waitingForInput(sessionID: String, callID: String?)
    case activityResumed(sessionID: String, callID: String?)
    case sessionEnded(sessionID: String)
}

enum Constants {
    static let version = "1.2.0"
    static let blinkHalfPeriod: TimeInterval = 0.5
    static let tickInterval: TimeInterval = 0.25
    static let magSafeConnectionPollInterval: TimeInterval = 1.0
    static let magSafeProbeInterval: TimeInterval = 30.0
    static let magSafeRetryInterval: TimeInterval = 5.0
    static let transcriptPollInterval: TimeInterval = 0.5
    static let logPollInterval: TimeInterval = 1.0
    static let processPollInterval: TimeInterval = 5.0
    static let statusRefreshInterval: TimeInterval = 30.0
    static let minimumDoneVisibility: TimeInterval = 2.0
    static let codexFocusAcknowledgementDelay: TimeInterval = 1.0
    static let acknowledgementEventName = "CodexCapsLockAcknowledge"
    static let codexBundleIdentifier = "com.openai.codex"
}

struct RuntimePaths: Sendable {
    let baseDirectory: URL
    let eventJournal: URL
    let statusFile: URL
    let codexHome: URL
    let sessionsDirectory: URL
    let logsDatabase: URL

    var lockFile: URL {
        baseDirectory.appendingPathComponent("daemon.lock")
    }

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimePaths {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        let baseDirectory: URL
        if let override = environment["CODEX_CAPS_INDICATOR_STATE_DIR"], !override.isEmpty {
            baseDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            baseDirectory = home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("CodexCapsLockIndicator", isDirectory: true)
        }

        let codexHome: URL
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            codexHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }

        return RuntimePaths(
            baseDirectory: baseDirectory,
            eventJournal: baseDirectory.appendingPathComponent("events.jsonl"),
            statusFile: baseDirectory.appendingPathComponent("status.json"),
            codexHome: codexHome,
            sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            logsDatabase: codexHome.appendingPathComponent("logs_2.sqlite")
        )
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
