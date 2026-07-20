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

private struct DaemonStatusFingerprint: Equatable {
    let mode: IndicatorMode
    let keyboardAvailable: Bool
    let keyboardName: String?
    let activeSessions: Int
    let codexProcessRunning: Bool
}

final class IndicatorDaemon: @unchecked Sendable {
    private let paths: RuntimePaths
    private let queue = DispatchQueue(label: "com.mikita.codex-capslock-indicator")
    private let led: HIDCapsLockController
    private let journal: HookJournalReader
    private let journalWriter: HookJournalWriter
    private let transcripts: TranscriptMonitor
    private let logWatcher: CodexLogWatcher
    private let processDetector = CodexProcessDetector()
    private let applicationMonitor = CodexApplicationMonitor()
    private var tracker = ActivityTracker()
    private var acknowledgementPolicy: CompletionAcknowledgementPolicy
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var startedAt = Date()
    private var lastBlinkTransition = Date()
    private var lastStatusWrite = Date.distantPast
    private var lastProcessCheck = Date.distantPast
    private var lastLogCheck = Date.distantPast
    private var lastTranscriptCheck = Date.distantPast
    private var lastStatusFingerprint: DaemonStatusFingerprint?
    private var codexRunning = false
    private var processWasSeen = false
    private var processAbsentSince: Date?
    private var ledOn = false
    private var blinkOn = true
    private var forceActualLEDRestoreUntil: Date?
    private var stopping = false
    private var lockDescriptor: Int32 = -1

    init(paths: RuntimePaths) {
        self.paths = paths
        let led = HIDCapsLockController()
        self.led = led
        journal = HookJournalReader(url: paths.eventJournal)
        journalWriter = HookJournalWriter(paths: paths)
        transcripts = TranscriptMonitor(sessionsDirectory: paths.sessionsDirectory)
        logWatcher = CodexLogWatcher(databaseURL: paths.logsDatabase)
        acknowledgementPolicy = CompletionAcknowledgementPolicy(
            initialCapsLockState: led.actualCapsLockState
        )
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
        while true {
            _ = RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    private func tick() {
        guard !stopping else {
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastTranscriptCheck) >= Constants.transcriptPollInterval {
            for event in transcripts.poll(now: now) {
                tracker.apply(event, at: now)
            }
            lastTranscriptCheck = now
        }
        if now.timeIntervalSince(lastLogCheck) >= Constants.logPollInterval {
            for _ in 0..<logWatcher.pollThreadStatusChangeCount() {
                tracker.noteThreadStatusChanged(at: now)
            }
            lastLogCheck = now
        }
        // Lifecycle hooks are authoritative and therefore applied after fallback sources.
        for signal in journal.readNewSignals() {
            tracker.apply(signal)
        }

        if now.timeIntervalSince(lastProcessCheck) >= Constants.processPollInterval {
            updateProcessState(now: now)
            lastProcessCheck = now
        }

        var actualCapsLockState = led.actualCapsLockState
        let modeBeforeAcknowledgement = tracker.effectiveMode
        let codexFrontmost = modeBeforeAcknowledgement == .done && applicationMonitor.isFrontmost
        if let reason = acknowledgementPolicy.observe(
            mode: modeBeforeAcknowledgement,
            codexFrontmost: codexFrontmost,
            actualCapsLockState: actualCapsLockState,
            at: now
        ) {
            if reason != .capsLockKey
                || !actualCapsLockState
                || led.setActualCapsLockState(false) {
                if reason == .capsLockKey {
                    actualCapsLockState = false
                    forceActualLEDRestoreUntil = now.addingTimeInterval(1)
                }
                acknowledgeCompleted()
                _ = acknowledgementPolicy.observe(
                    mode: tracker.effectiveMode,
                    codexFrontmost: codexFrontmost,
                    actualCapsLockState: actualCapsLockState,
                    at: now
                )
            }
        }

        let effectiveMode = tracker.effectiveMode
        applyLED(for: effectiveMode, actualCapsLockState: actualCapsLockState, now: now)

        writeStatusIfNeeded(mode: effectiveMode, now: now)
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

    private func acknowledgeCompleted() {
        guard tracker.acknowledgeCompleted() else {
            return
        }
        try? journalWriter.appendAcknowledgement()
    }

    private func applyLED(
        for mode: IndicatorMode,
        actualCapsLockState: Bool,
        now: Date
    ) {
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
            if let restoreUntil = forceActualLEDRestoreUntil {
                setLED(actualCapsLockState)
                if now >= restoreUntil {
                    forceActualLEDRestoreUntil = nil
                }
            } else if ledOn != actualCapsLockState {
                setLED(actualCapsLockState)
            }
        }
    }

    private func setLED(_ enabled: Bool) {
        if led.setIndicator(enabled) {
            ledOn = enabled
        }
    }

    private func writeStatusIfNeeded(mode: IndicatorMode, now: Date, force: Bool = false) {
        let fingerprint = DaemonStatusFingerprint(
            mode: mode,
            keyboardAvailable: led.isAvailable,
            keyboardName: led.keyboardName,
            activeSessions: tracker.sessions.count,
            codexProcessRunning: codexRunning
        )
        guard force
                || fingerprint != lastStatusFingerprint
                || now.timeIntervalSince(lastStatusWrite) >= Constants.statusRefreshInterval else {
            return
        }

        let status = DaemonStatus(
            pid: getpid(),
            mode: mode,
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
        do {
            try data.write(to: paths.statusFile, options: .atomic)
        } catch {
            return
        }
        lastStatusFingerprint = fingerprint
        lastStatusWrite = now
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
        writeStatusIfNeeded(mode: .off, now: Date(), force: true)
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
        exit(EXIT_SUCCESS)
    }
}
