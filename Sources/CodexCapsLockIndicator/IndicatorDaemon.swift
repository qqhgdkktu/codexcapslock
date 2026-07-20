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
    let output: IndicatorOutput
    let keyboardAvailable: Bool
    let keyboardName: String?
    let magSafePortPresent: Bool
    let magSafeConnected: Bool
    let magSafeControlAvailable: Bool
    let magSafeLEDMode: MagSafeLEDMode?
    let activeSessions: Int
    let codexProcessRunning: Bool
    let claudeProcessRunning: Bool
}

final class IndicatorDaemon: @unchecked Sendable {
    private let paths: RuntimePaths
    private let queue = DispatchQueue(label: "com.mikita.codex-capslock-indicator")
    private let led: HIDCapsLockController
    private let journal: HookJournalReader
    private let journalWriter: HookJournalWriter
    private let transcripts: TranscriptMonitor
    private let logWatcher: CodexLogWatcher
    private let processDetector = CodingAgentProcessDetector()
    private let applicationMonitor = CodexApplicationMonitor()
    private let magSafeConnectionDetector = MagSafeConnectionDetector()
    private let magSafeLED = MagSafeLEDController()
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
    private var lastMagSafeConnectionCheck = Date.distantPast
    private var lastMagSafeProbe = Date.distantPast
    private var lastStatusFingerprint: DaemonStatusFingerprint?
    private var codexRunning = false
    private var claudeRunning = false
    private var codexAbsentSince: Date?
    private var claudeAbsentSince: Date?
    private var ledOn = false
    private var blinkOn = true
    private var output: IndicatorOutput = .capsLock
    private var magSafeSnapshot = MagSafeConnectionSnapshot(
        portPresent: false,
        connectionActive: false,
        externalPowerAttached: false
    )
    private var magSafeControlAvailable = false
    private var appliedMagSafeMode: MagSafeLEDMode?
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
            if signal.hookEventName != Constants.acknowledgementEventName
                && signal.hookEventName != Constants.legacyAcknowledgementEventName {
                switch signal.source ?? .codex {
                case .codex: codexAbsentSince = nil
                case .claude: claudeAbsentSince = nil
                }
            }
        }

        if now.timeIntervalSince(lastProcessCheck) >= Constants.processPollInterval {
            updateProcessState(now: now)
            lastProcessCheck = now
        }
        updateMagSafeState(now: now)

        var actualCapsLockState = led.actualCapsLockState
        let modeBeforeAcknowledgement = tracker.effectiveMode
        let codexFrontmost = modeBeforeAcknowledgement == .done
            && tracker.firstCompletedSource == .codex
            && applicationMonitor.isFrontmost
        if let reason = acknowledgementPolicy.observe(
            mode: modeBeforeAcknowledgement,
            completionID: tracker.firstCompletedSessionID,
            codexFrontmost: codexFrontmost,
            actualCapsLockState: actualCapsLockState,
            capsLockAcknowledgementEnabled: output == .capsLock,
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
                    completionID: tracker.firstCompletedSessionID,
                    codexFrontmost: codexFrontmost,
                    actualCapsLockState: actualCapsLockState,
                    capsLockAcknowledgementEnabled: output == .capsLock,
                    at: now
                )
            }
        }

        let effectiveMode = tracker.effectiveMode
        applyIndicator(for: effectiveMode, actualCapsLockState: actualCapsLockState, now: now)

        writeStatusIfNeeded(mode: effectiveMode, now: now)
    }

    private func updateProcessState(now: Date) {
        let processState = processDetector.snapshot()
        codexRunning = processState.codexRunning
        claudeRunning = processState.claudeRunning
        if codexRunning {
            codexAbsentSince = nil
        } else {
            codexAbsentSince = codexAbsentSince ?? now
            if now.timeIntervalSince(codexAbsentSince ?? now) >= 5 {
                tracker.clearUnfinishedSessions(for: .codex)
            }
        }

        if claudeRunning {
            claudeAbsentSince = nil
        } else {
            claudeAbsentSince = claudeAbsentSince ?? now
            if now.timeIntervalSince(claudeAbsentSince ?? now) >= 5 {
                tracker.clearUnfinishedSessions(for: .claude)
            }
        }

        if !processState.anyRunning,
           tracker.sessions.isEmpty,
           now.timeIntervalSince(startedAt) >= 5 {
            shutdown()
        }
    }

    private func acknowledgeCompleted() {
        guard tracker.firstCompletedSource != nil else {
            return
        }
        do {
            try journalWriter.appendAcknowledgement()
            // Consume the journal marker here so the same acknowledgement is not
            // applied again on the next scheduler tick.
            for signal in journal.readNewSignals() {
                tracker.apply(signal)
            }
        } catch {
            _ = tracker.acknowledgeCompleted()
        }
    }

    private func updateMagSafeState(now: Date) {
        if now.timeIntervalSince(lastMagSafeConnectionCheck) >= Constants.magSafeConnectionPollInterval {
            magSafeSnapshot = magSafeConnectionDetector.snapshot()
            lastMagSafeConnectionCheck = now
        }

        if magSafeSnapshot.portPresent {
            let probeInterval = magSafeControlAvailable
                ? Constants.magSafeProbeInterval
                : Constants.magSafeRetryInterval
            if now.timeIntervalSince(lastMagSafeProbe) >= probeInterval {
                magSafeControlAvailable = magSafeLED.probe()
                lastMagSafeProbe = now
            }
        } else {
            magSafeControlAvailable = false
        }

        let selected = IndicatorOutputRouting.select(
            magSafe: magSafeSnapshot,
            magSafeControlAvailable: magSafeControlAvailable
        )
        if selected != output {
            switchOutput(to: selected, now: now)
        }
    }

    private func switchOutput(to selected: IndicatorOutput, now: Date) {
        if output == .magSafe {
            _ = magSafeLED.setMode(.system)
            appliedMagSafeMode = .system
        }

        output = selected
        blinkOn = true
        lastBlinkTransition = now

        switch selected {
        case .magSafe:
            _ = led.restoreActualCapsLockIndicator()
            ledOn = false
            appliedMagSafeMode = nil
        case .capsLock:
            ledOn = led.hardwareIndicatorState ?? led.actualCapsLockState
        }
    }

    private func applyIndicator(
        for mode: IndicatorMode,
        actualCapsLockState: Bool,
        now: Date
    ) {
        if output == .magSafe {
            let requestedMode = IndicatorOutputRouting.magSafeMode(for: mode)
            if requestedMode != appliedMagSafeMode {
                guard magSafeLED.setMode(requestedMode) else {
                    magSafeControlAvailable = false
                    switchOutput(to: .capsLock, now: now)
                    applyCapsLockLED(for: mode, actualCapsLockState: actualCapsLockState, now: now)
                    return
                }
                appliedMagSafeMode = requestedMode
                ledOn = requestedMode != .system && requestedMode != .off
            }
            return
        }

        applyCapsLockLED(for: mode, actualCapsLockState: actualCapsLockState, now: now)
    }

    private func applyCapsLockLED(
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
            output: output,
            keyboardAvailable: led.isAvailable,
            keyboardName: led.keyboardName,
            magSafePortPresent: magSafeSnapshot.portPresent,
            magSafeConnected: magSafeSnapshot.connected,
            magSafeControlAvailable: magSafeControlAvailable,
            magSafeLEDMode: appliedMagSafeMode,
            activeSessions: tracker.sessions.count,
            codexProcessRunning: codexRunning,
            claudeProcessRunning: claudeRunning
        )
        guard force
                || fingerprint != lastStatusFingerprint
                || now.timeIntervalSince(lastStatusWrite) >= Constants.statusRefreshInterval else {
            return
        }

        let status = DaemonStatus(
            pid: getpid(),
            mode: mode,
            output: output,
            ledOn: ledOn,
            keyboardAvailable: led.isAvailable,
            keyboardName: led.keyboardName,
            magSafePortPresent: magSafeSnapshot.portPresent,
            magSafeConnected: magSafeSnapshot.connected,
            magSafeControlAvailable: magSafeControlAvailable,
            magSafeLEDMode: appliedMagSafeMode,
            activeSessions: tracker.sessions.count,
            codexProcessRunning: codexRunning,
            claudeProcessRunning: claudeRunning,
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
        _ = magSafeLED.setMode(.system)
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
