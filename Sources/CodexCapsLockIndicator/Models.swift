import Darwin
import Foundation

enum IndicatorMode: String, Codable, Sendable {
    case off
    case working
    case waiting
    case done
}

enum CodingAgent: String, Codable, Sendable {
    case codex
    case claude

    func scopedSessionID(_ sessionID: String) -> String {
        switch self {
        case .codex:
            return sessionID
        case .claude:
            return "claude:\(sessionID)"
        }
    }
}

enum CompletionOutcome: String, Codable, Sendable {
    case completed
    case failed
    case aborted
}

enum LifecycleAction: String, CaseIterable, Sendable {
    case promptSubmitted = "prompt-submitted"
    case toolStarted = "tool-started"
    case permissionRequested = "permission-requested"
    case inputRequested = "input-requested"
    case toolFinished = "tool-finished"
    case stopped
    case stopFailed = "stop-failed"
    case sessionEnded = "session-ended"
}

enum LifecycleEventKind: Codable, Sendable, Equatable {
    case promptSubmitted
    case toolStarted(callID: String?)
    case permissionRequested(callID: String?)
    case inputRequested(callID: String?)
    case toolFinished(callID: String?)
    case stopped(outcome: CompletionOutcome)
    case sessionEnded
    case acknowledged(completionID: UUID?)
    case acknowledgedAll
}

struct LifecycleRecord: Codable, Sendable, Equatable {
    static let schemaVersion: UInt8 = 2

    let schemaVersion: UInt8
    let eventID: UUID
    let source: CodingAgent
    let sessionID: String
    let turnID: String?
    let emittedAtMillis: Int64
    let kind: LifecycleEventKind

    init(
        eventID: UUID = UUID(),
        source: CodingAgent,
        sessionID: String,
        turnID: String?,
        emittedAtMillis: Int64,
        kind: LifecycleEventKind
    ) {
        schemaVersion = Self.schemaVersion
        self.eventID = eventID
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.emittedAtMillis = emittedAtMillis
        self.kind = kind
    }
}

struct HookInput: Decodable {
    let sessionID: String?
    let turnID: String?
    let hookEventName: String?
    let callID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case hookEventName = "hook_event_name"
        case toolUseID = "tool_use_id"
        case callID = "call_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
        callID = try container.decodeIfPresent(String.self, forKey: .toolUseID)
            ?? container.decodeIfPresent(String.self, forKey: .callID)
    }
}

struct DaemonStatus: Codable, Sendable {
    let pid: Int32
    let mode: IndicatorMode
    let output: IndicatorOutput
    let ledOn: Bool
    let keyboardAvailable: Bool
    let keyboardName: String?
    let capsLockLogicalState: Bool?
    let capsLockLEDActual: Bool?
    let capsLockLEDExpected: Bool?
    let capsLockSynchronized: Bool?
    let magSafePortPresent: Bool
    let magSafeConnected: Bool
    let magSafeControlAvailable: Bool
    let magSafeLEDMode: MagSafeLEDMode?
    let magSafeRawValue: UInt8?
    let magSafeExpectedValue: UInt8?
    let magSafeSynchronized: Bool?
    let magSafeLastWriteAt: Date?
    let activeSessions: Int
    let completionQueueDepth: Int?
    let firstCompletionID: UUID?
    let firstCompletionSource: CodingAgent?
    let firstCompletionOutcome: CompletionOutcome?
    let lifecycleProtocolVersion: UInt8?
    let compatibilityFallbacksEnabled: Bool?
    let codexProcessRunning: Bool
    let claudeProcessRunning: Bool?
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
    static let version = "2.0.0"
    static let blinkHalfPeriod: TimeInterval = 0.5
    static let tickInterval: TimeInterval = 0.25
    static let magSafeConnectionPollInterval: TimeInterval = 1.0
    static let magSafeProbeInterval: TimeInterval = 30.0
    static let magSafeRetryInterval: TimeInterval = 5.0
    static let capsLockProbeInterval: TimeInterval = 2.0
    static let magSafeLeaseHeartbeatInterval: TimeInterval = 1.0
    static let statusRefreshInterval: TimeInterval = 30.0
    static let minimumDoneVisibility: TimeInterval = 2.0
    static let codexFocusAcknowledgementDelay: TimeInterval = 1.0
    static let codexBundleIdentifier = "com.openai.codex"
    static let maximumHookPayloadBytes = 1_048_576
    static let maximumLifecycleRecordBytes = 16_384
    static let maximumSpoolBytes = 4 * 1_048_576
    static let maximumStatusBytes = 65_536
    static let maximumIdentifierBytes = 512
    static let maximumActiveGenerations = 1_024
    static let maximumPendingCallsPerGeneration = 64
    static let maximumCompletionQueueDepth = 4_096
    static let maximumPastEventAgeMillis: Int64 = 24 * 60 * 60 * 1_000
    static let maximumFutureEventSkewMillis: Int64 = 5 * 60 * 1_000
}

enum RuntimePathError: Error {
    case unsafeStateDirectory
}

struct RuntimePaths: Sendable {
    let baseDirectory: URL
    let eventSpool: URL
    let statusFile: URL
    let codexHome: URL
    let sessionsDirectory: URL
    let logsDatabase: URL

    // Retained as a source-compatible label for tests and older internal callers.
    init(
        baseDirectory: URL,
        eventJournal: URL,
        statusFile: URL,
        codexHome: URL,
        sessionsDirectory: URL,
        logsDatabase: URL
    ) {
        self.baseDirectory = baseDirectory
        eventSpool = eventJournal
        self.statusFile = statusFile
        self.codexHome = codexHome
        self.sessionsDirectory = sessionsDirectory
        self.logsDatabase = logsDatabase
    }

    var eventJournal: URL {
        eventSpool
    }

    var stateSnapshot: URL {
        baseDirectory.appendingPathComponent("state-v2.json")
    }

    var legacyEventJournal: URL {
        baseDirectory.appendingPathComponent("events.jsonl")
    }

    var lockFile: URL {
        baseDirectory.appendingPathComponent("daemon.lock")
    }

    var controlSocket: URL {
        baseDirectory.appendingPathComponent("control.sock")
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
            eventJournal: baseDirectory.appendingPathComponent("events.spool"),
            statusFile: baseDirectory.appendingPathComponent("status.json"),
            codexHome: codexHome,
            sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            logsDatabase: codexHome.appendingPathComponent("logs_2.sqlite")
        )
    }

    func prepare() throws {
        var information = stat()
        if lstat(baseDirectory.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFDIR,
                  information.st_uid == geteuid() else {
                throw RuntimePathError.unsafeStateDirectory
            }
            if information.st_mode & 0o777 != 0o700,
               chmod(baseDirectory.path, 0o700) != 0 {
                throw RuntimePathError.unsafeStateDirectory
            }
            return
        }
        guard errno == ENOENT else {
            throw RuntimePathError.unsafeStateDirectory
        }
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard lstat(baseDirectory.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid() else {
            throw RuntimePathError.unsafeStateDirectory
        }
        guard chmod(baseDirectory.path, 0o700) == 0 else {
            throw RuntimePathError.unsafeStateDirectory
        }
    }
}
