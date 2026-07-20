import Darwin
import Foundation

enum IndicatorDaemonError: Error, CustomStringConvertible {
    case alreadyRunning
    case lockUnavailable(Int32)

    var description: String {
        switch self {
        case .alreadyRunning: "Фоновый индикатор уже запущен."
        case let .lockUnavailable(code): "Не удалось создать lock-файл индикатора (errno=\(code))."
        }
    }
}

final class IndicatorDaemon: @unchecked Sendable {
    private let paths: RuntimePaths
    private let queue = DispatchQueue(label: "com.mikita.codex-capslock-indicator")
    private let led = HIDCapsLockController()
    private let journal: HookJournalReader
    private let transcripts: TranscriptMonitor
    private let logWatcher: CodexLogWatcher
    private let processDetector = CodexProcessDetector()
    private var tracker = ActivityTracker()
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var startedAt = Date()
    private var lastBlinkTransition = Date()
    private var lastStatusWrite = Date.distantPast
    private var lastProcessCheck = Date.distantPast
    private var lastLogCheck = Date.distantPast
    private var lastTranscriptCheck = Date.distantPast
    private var codexRunning = false
    private var processWasSeen = false
    private var processAbsentSince: Date?
    private var ledOn = false
    private var blinkOn = true
    private var stopping = false
    private var lockDescriptor: Int32 = -1

    init(paths: RuntimePaths) {
        self.paths = paths
        journal = HookJournalReader(url: paths.eventJournal)
        transcripts = TranscriptMonitor(sessionsDirectory: paths.sessionsDirectory)
        logWatcher = CodexLogWatcher(databaseURL: paths.logsDatabase)
    }

    func run() throws -> Never {
        try paths.prepare()
        try acquireSingletonLock()
        startedAt = Date()
        installSignalHandlers()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Constants.tickInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [self] in
            tick()
        }
        self.timer = timer
        timer.resume()
        dispatchMain()
    }

    private func tick() {
        guard !stopping else {
            return
        }

        let now = Date()
        for signal in journal.readNewSignals() {
            tracker.apply(signal)
        }
        if now.timeIntervalSince(lastTranscriptCheck) >= 0.25 {
            for event in transcripts.poll(now: now) {
                tracker.apply(event, at: now)
            }
            lastTranscriptCheck = now
        }
        if now.timeIntervalSince(lastLogCheck) >= 0.25 {
            for _ in 0..<logWatcher.pollThreadStatusChangeCount() {
                tracker.noteThreadStatusChanged(at: now)
            }
            lastLogCheck = now
        }

        if now.timeIntervalSince(lastProcessCheck) >= 2.0 {
            updateProcessState(now: now)
            lastProcessCheck = now
        }

        applyLED(for: tracker.effectiveMode, now: now)

        if now.timeIntervalSince(lastStatusWrite) >= Constants.statusRefreshInterval {
            writeStatus(now: now)
            lastStatusWrite = now
        }
    }

    private func updateProcessState(now: Date) {
        codexRunning = processDetector.isRunning()
        if codexRunning {
            processWasSeen = true
            processAbsentSince = nil
            return
        }

        if processAbsentSince == nil {
            processAbsentSince = now
        }

        let absence = now.timeIntervalSince(processAbsentSince ?? now)
        if processWasSeen, absence >= 5 {
            shutdown()
        } else if !processWasSeen, now.timeIntervalSince(startedAt) >= 2 {
            tracker.clear()
        }
    }

    private func applyLED(for mode: IndicatorMode, now: Date) {
        switch mode {
        case .working:
            if now.timeIntervalSince(lastBlinkTransition) >= Constants.blinkHalfPeriod {
                blinkOn.toggle()
                lastBlinkTransition = now
                setLED(blinkOn)
            }

        case .waiting, .done:
            blinkOn = true
            if !ledOn || now.timeIntervalSince(lastBlinkTransition) >= 2 {
                lastBlinkTransition = now
                setLED(true)
            }

        case .off:
            let actual = led.actualCapsLockState
            if ledOn != actual {
                setLED(actual)
            }
        }
    }

    private func setLED(_ enabled: Bool) {
        if led.setIndicator(enabled) {
            ledOn = enabled
        }
    }

    private func writeStatus(now: Date) {
        let status = DaemonStatus(
            pid: getpid(),
            mode: tracker.effectiveMode,
            ledOn: ledOn,
            keyboardAvailable: led.isAvailable,
            keyboardName: led.keyboardName,
            activeSessions: tracker.sessions.count,
            codexProcessRunning: codexRunning,
            updatedAt: now,
            version: Constants.version
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else {
            return
        }
        try? data.write(to: paths.statusFile, options: .atomic)
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func acquireSingletonLock() throws {
        lockDescriptor = open(paths.lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard lockDescriptor >= 0 else {
            throw IndicatorDaemonError.lockUnavailable(errno)
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor)
            lockDescriptor = -1
            throw IndicatorDaemonError.alreadyRunning
        }
    }

    private func shutdown() -> Never {
        stopping = true
        timer?.cancel()
        tracker.clear()
        _ = led.restoreActualCapsLockIndicator()
        ledOn = led.actualCapsLockState
        writeStatus(now: Date())
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
        exit(EXIT_SUCCESS)
    }
}
