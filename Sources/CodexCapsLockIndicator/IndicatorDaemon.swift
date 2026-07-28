import AppKit
import Darwin
import Foundation

enum IndicatorDaemonError: Error, CustomStringConvertible {
    case alreadyRunning
    case lockUnavailable(Int32)
    case hardwareLockUnavailable(Int32)

    var description: String {
        switch self {
        case .alreadyRunning: "Фоновый индикатор уже запущен."
        case let .lockUnavailable(code): "Не удалось создать lock-файл индикатора (errno=\(code))."
        case let .hardwareLockUnavailable(code):
            "Аппаратный выход временно занят другой операцией (errno=\(code))."
        }
    }
}

private enum DaemonMaintenanceError: Error {
    case keyboardUnavailable
    case capsLockWriteFailed
    case capsLockInvariantFailed
    case magSafeUnavailable
    case magSafeWriteFailed
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
    let magSafeRawValue: UInt8?
    let magSafeExpectedValue: UInt8?
    let magSafeSynchronized: Bool?
    let magSafeLastWriteAt: Date?
    let activeSessions: Int
    let completionQueueDepth: Int
    let firstCompletionID: UUID?
    let firstCompletionSource: CodingAgent?
    let firstCompletionOutcome: CompletionOutcome?
    let codexProcessRunning: Bool
    let claudeProcessRunning: Bool?
}

final class IndicatorDaemon: @unchecked Sendable {
    private let paths: RuntimePaths
    private let outputPreference: String
    private let queue = DispatchQueue(label: "com.mikita.codex-capslock-indicator")
    private let led: HIDCapsLockController
    private let journal: HookJournalReader
    private let stateStore: StateStore
    private let applicationMonitor = CodexApplicationMonitor()
    private let magSafeConnectionDetector = MagSafeConnectionDetector()
    private let magSafeLED = MagSafeLEDController()
    private var tracker = ActivityTracker()
    private var acknowledgementPolicy: CompletionAcknowledgementPolicy
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var controlServer: DaemonControlServer?
    private var startedAt = Date()
    private var lastBlinkTransition = Date()
    private var lastStatusWrite = Date.distantPast
    private var lastMagSafeConnectionCheck = Date.distantPast
    private var lastMagSafeProbe = Date.distantPast
    private var lastMagSafeLeaseHeartbeat = Date.distantPast
    private var lastCapsLockProbe = Date.distantPast
    private var lastStatusFingerprint: DaemonStatusFingerprint?
    private var codexRunning = false
    private var claudeRunning: Bool?
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
    private var magSafeRawValue: UInt8?
    private var magSafeReconciliationRequested = true
    private var magSafeLastWriteAt: Date?
    private var capsLockActualSnapshot: Bool?
    private var forceActualLEDRestoreUntil: Date?
    private var stopping = false
    private var lockDescriptor: Int32 = -1
    private var hardwareLockDescriptor: Int32 = -1

    init(paths: RuntimePaths) {
        self.paths = paths
        outputPreference = ProcessInfo.processInfo.environment[
            "CODEX_CAPS_INDICATOR_OUTPUT"
        ] ?? "auto"
        let led = HIDCapsLockController()
        self.led = led
        journal = HookJournalReader(paths: paths)
        stateStore = StateStore(paths: paths)
        acknowledgementPolicy = CompletionAcknowledgementPolicy(
            initialCapsLockState: led.actualCapsLockState
        )
    }

    func run() throws -> Never {
        try paths.prepare()
        try acquireSingletonLock()
        try acquireHardwareLock()
        stateStore.archiveLegacyJournalIfNeeded()
        restoreOutputsBeforeLoadingState()
        tracker = stateStore.load()
        startedAt = Date()
        installSignalHandlers()
        installWorkspaceObservers()
        let controlServer = DaemonControlServer(socketURL: paths.controlSocket) {
            [weak self] request in
            guard let self else {
                return DaemonControlResponse(
                    requestID: request.requestID,
                    succeeded: false,
                    message: "daemon unavailable"
                )
            }
            return queue.sync {
                handleControlRequest(request)
            }
        }
        try controlServer.start()
        self.controlServer = controlServer

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
        if let batch = journal.readBatch() {
            var candidate = tracker
            var reducerChanged = false
            for record in batch.records {
                reducerChanged = candidate.apply(record) || reducerChanged
            }
            do {
                if reducerChanged {
                    try stateStore.save(candidate)
                    tracker = candidate
                }
                try journal.commit(batch)
            } catch {
                // Leave the spool intact when durable state or compaction fails.
            }
        }

        codexRunning = applicationMonitor.isRunning
        updateMagSafeState(now: now)

        var actualCapsLockState = led.actualCapsLockState
        let modeBeforeAcknowledgement = tracker.effectiveMode
        let codexFrontmost = modeBeforeAcknowledgement == .done
            && tracker.firstCompletedSource == .codex
            && applicationMonitor.isFrontmost
        if let reason = acknowledgementPolicy.observe(
            mode: modeBeforeAcknowledgement,
            completionID: tracker.firstCompletionID,
            codexFrontmost: codexFrontmost,
            actualCapsLockState: actualCapsLockState,
            capsLockAcknowledgementEnabled: output == .capsLock,
            at: ProcessInfo.processInfo.systemUptime
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
                    completionID: tracker.firstCompletionID,
                    codexFrontmost: codexFrontmost,
                    actualCapsLockState: actualCapsLockState,
                    capsLockAcknowledgementEnabled: output == .capsLock,
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
        }

        let effectiveMode = tracker.effectiveMode
        applyIndicator(for: effectiveMode, actualCapsLockState: actualCapsLockState, now: now)
        magSafeReconciliationRequested = false

        writeStatusIfNeeded(mode: effectiveMode, now: now)
        if tracker.sessions.isEmpty,
           now.timeIntervalSince(startedAt) >= 5 {
            shutdown()
        }
    }

    private func acknowledgeCompleted() {
        guard let completionID = tracker.firstCompletionID else {
            return
        }
        var candidate = tracker
        guard candidate.acknowledgeCompleted(completionID: completionID) else {
            return
        }
        do {
            try stateStore.save(candidate)
            tracker = candidate
        } catch {
            return
        }
    }

    private func updateMagSafeState(now: Date) {
        if magSafeReconciliationRequested
            || now.timeIntervalSince(lastMagSafeConnectionCheck) >= Constants.magSafeConnectionPollInterval {
            magSafeSnapshot = magSafeConnectionDetector.snapshot()
            lastMagSafeConnectionCheck = now
        }

        if magSafeSnapshot.connected {
            let probeInterval = magSafeControlAvailable
                ? Constants.magSafeProbeInterval
                : Constants.magSafeRetryInterval
            if magSafeReconciliationRequested || now.timeIntervalSince(lastMagSafeProbe) >= probeInterval {
                magSafeRawValue = magSafeLED.currentValue()
                magSafeControlAvailable = magSafeRawValue != nil
                lastMagSafeProbe = now
            }
            if magSafeControlAvailable,
               output == .magSafe,
               now.timeIntervalSince(lastMagSafeLeaseHeartbeat)
                   >= Constants.magSafeLeaseHeartbeatInterval {
                if !magSafeLED.ping() {
                    magSafeControlAvailable = false
                    magSafeRawValue = nil
                }
                lastMagSafeLeaseHeartbeat = now
            }
        } else {
            if output == .magSafe {
                _ = magSafeLED.setMode(.system)
            }
            magSafeLED.closeLease()
            magSafeControlAvailable = false
            magSafeRawValue = nil
        }

        var selected = IndicatorOutputRouting.select(
            magSafe: magSafeSnapshot,
            magSafeControlAvailable: magSafeControlAvailable
        )
        if outputPreference == "caps-lock" {
            selected = .capsLock
            magSafeLED.closeLease()
        }
        if selected != output {
            switchOutput(to: selected, now: now)
        }
    }

    private func switchOutput(to selected: IndicatorOutput, now: Date) {
        if output == .magSafe {
            if magSafeLED.setMode(.system) {
                appliedMagSafeMode = .system
                magSafeRawValue = MagSafeLEDMode.system.aclcValue
                magSafeLastWriteAt = now
            } else {
                appliedMagSafeMode = nil
                magSafeRawValue = nil
            }
            magSafeLED.closeLease()
        }

        output = selected
        acknowledgementPolicy.resetCapsLockBaseline(led.actualCapsLockState)
        blinkOn = true
        lastBlinkTransition = now

        switch selected {
        case .magSafe:
            _ = led.restoreActualCapsLockIndicator()
            ledOn = false
            capsLockActualSnapshot = led.actualCapsLockState
            appliedMagSafeMode = nil
        case .capsLock:
            ledOn = led.hardwareIndicatorState ?? led.actualCapsLockState
            capsLockActualSnapshot = ledOn
        }
    }

    private func applyIndicator(
        for mode: IndicatorMode,
        actualCapsLockState: Bool,
        now: Date
    ) {
        if output == .magSafe {
            let requestedMode = IndicatorOutputRouting.magSafeMode(for: mode)
            if IndicatorOutputRouting.shouldApplyMagSafeMode(
                requested: requestedMode,
                applied: appliedMagSafeMode,
                currentValue: magSafeRawValue,
                reconciliationRequested: magSafeReconciliationRequested
            ) {
                guard magSafeLED.setMode(requestedMode) else {
                    magSafeControlAvailable = false
                    magSafeRawValue = nil
                    switchOutput(to: .capsLock, now: now)
                    applyCapsLockLED(for: mode, actualCapsLockState: actualCapsLockState, now: now)
                    return
                }
                appliedMagSafeMode = requestedMode
                magSafeRawValue = requestedMode.aclcValue
                magSafeLastWriteAt = now
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
            capsLockActualSnapshot = enabled
        }
    }

    private func writeStatusIfNeeded(mode: IndicatorMode, now: Date, force: Bool = false) {
        let expectedMagSafeValue = output == .magSafe
            ? IndicatorOutputRouting.magSafeMode(for: mode).aclcValue
            : MagSafeLEDMode.system.aclcValue
        let magSafeSynchronized = magSafeRawValue.map {
            $0 == expectedMagSafeValue
        }
        let logicalCapsLock = led.actualCapsLockState
        if force
            || now.timeIntervalSince(lastCapsLockProbe)
                >= Constants.capsLockProbeInterval {
            capsLockActualSnapshot = led.hardwareIndicatorState
            lastCapsLockProbe = now
        }
        let actualCapsLockLED = capsLockActualSnapshot
        let expectedCapsLockLED = output == .capsLock
            ? ledOn
            : logicalCapsLock
        let capsLockSynchronized = actualCapsLockLED.map {
            $0 == expectedCapsLockLED
        }
        let fingerprint = DaemonStatusFingerprint(
            mode: mode,
            output: output,
            keyboardAvailable: led.isAvailable,
            keyboardName: led.keyboardName,
            magSafePortPresent: magSafeSnapshot.portPresent,
            magSafeConnected: magSafeSnapshot.connected,
            magSafeControlAvailable: magSafeControlAvailable,
            magSafeLEDMode: appliedMagSafeMode,
            magSafeRawValue: magSafeRawValue,
            magSafeExpectedValue: expectedMagSafeValue,
            magSafeSynchronized: magSafeSynchronized,
            magSafeLastWriteAt: magSafeLastWriteAt,
            activeSessions: tracker.activeGenerationCount,
            completionQueueDepth: tracker.completionQueue.count,
            firstCompletionID: tracker.firstCompletionID,
            firstCompletionSource: tracker.firstCompletedSource,
            firstCompletionOutcome: tracker.firstCompletionOutcome,
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
            capsLockLogicalState: logicalCapsLock,
            capsLockLEDActual: actualCapsLockLED,
            capsLockLEDExpected: expectedCapsLockLED,
            capsLockSynchronized: capsLockSynchronized,
            magSafePortPresent: magSafeSnapshot.portPresent,
            magSafeConnected: magSafeSnapshot.connected,
            magSafeControlAvailable: magSafeControlAvailable,
            magSafeLEDMode: appliedMagSafeMode,
            magSafeRawValue: magSafeRawValue,
            magSafeExpectedValue: expectedMagSafeValue,
            magSafeSynchronized: magSafeSynchronized,
            magSafeLastWriteAt: magSafeLastWriteAt,
            activeSessions: tracker.activeGenerationCount,
            completionQueueDepth: tracker.completionQueue.count,
            firstCompletionID: tracker.firstCompletionID,
            firstCompletionSource: tracker.firstCompletedSource,
            firstCompletionOutcome: tracker.firstCompletionOutcome,
            lifecycleProtocolVersion: LifecycleRecord.schemaVersion,
            compatibilityFallbacksEnabled: false,
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
            try writePrivateStatus(data)
        } catch {
            return
        }
        lastStatusFingerprint = fingerprint
        lastStatusWrite = now
    }

    private func writePrivateStatus(_ data: Data) throws {
        guard data.count <= Constants.maximumStatusBytes else {
            throw HookJournalError.recordTooLarge
        }
        let temporary = paths.baseDirectory.appendingPathComponent(
            ".status.\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw HookJournalError.openFailed(errno)
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove {
                unlink(temporary.path)
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw HookJournalError.writeFailed(errno)
                }
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporary.path, paths.statusFile.path) == 0 else {
            throw HookJournalError.writeFailed(errno)
        }
        shouldRemove = false
        let directory = open(paths.baseDirectory.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            _ = fsync(directory)
            close(directory)
        }
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

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            queue.async { [weak self] in
                self?.magSafeReconciliationRequested = true
            }
        }
        workspaceObservers.append(wakeObserver)
    }

    private func acquireSingletonLock() throws {
        lockDescriptor = open(
            paths.lockFile.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard lockDescriptor >= 0 else {
            throw IndicatorDaemonError.lockUnavailable(errno)
        }
        var information = stat()
        guard fstat(lockDescriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              fchmod(lockDescriptor, 0o600) == 0 else {
            close(lockDescriptor)
            lockDescriptor = -1
            throw IndicatorDaemonError.lockUnavailable(errno)
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor)
            lockDescriptor = -1
            throw IndicatorDaemonError.alreadyRunning
        }
    }

    private func acquireHardwareLock() throws {
        let lockURL = paths.baseDirectory.appendingPathComponent("hardware.lock")
        hardwareLockDescriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard hardwareLockDescriptor >= 0 else {
            throw IndicatorDaemonError.hardwareLockUnavailable(errno)
        }
        var information = stat()
        guard fstat(hardwareLockDescriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              fchmod(hardwareLockDescriptor, 0o600) == 0,
              flock(hardwareLockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(hardwareLockDescriptor)
            hardwareLockDescriptor = -1
            throw IndicatorDaemonError.hardwareLockUnavailable(code)
        }
    }

    private func restoreOutputsBeforeLoadingState() {
        _ = magSafeLED.setMode(.system)
        magSafeLED.closeLease()
        _ = led.restoreActualCapsLockIndicator()
        ledOn = led.actualCapsLockState
        capsLockActualSnapshot = ledOn
        appliedMagSafeMode = .system
        magSafeRawValue = MagSafeLEDMode.system.aclcValue
    }

    private func handleControlRequest(
        _ request: DaemonControlRequest
    ) -> DaemonControlResponse {
        do {
            let message: String
            switch request.command {
            case .ingestLifecycle:
                guard let record = request.record else {
                    return DaemonControlResponse(
                        requestID: request.requestID,
                        succeeded: false,
                        message: "Lifecycle record отсутствует."
                    )
                }
                var candidate = tracker
                if candidate.apply(record) {
                    try stateStore.save(candidate)
                    tracker = candidate
                    reconcileAfterMaintenance()
                }
                message = "Lifecycle event принят."
            case .acknowledgeNext:
                var candidate = tracker
                guard let completionID = candidate.firstCompletionID,
                      candidate.acknowledgeCompleted(completionID: completionID) else {
                    return DaemonControlResponse(
                        requestID: request.requestID,
                        succeeded: false,
                        message: "Нет завершённых задач для подтверждения."
                    )
                }
                try stateStore.save(candidate)
                tracker = candidate
                reconcileAfterMaintenance()
                message = "Первая завершённая задача отмечена просмотренной."
            case .acknowledgeCompletion:
                var candidate = tracker
                guard let completionID = request.completionID,
                      candidate.acknowledgeCompleted(
                        completionID: completionID
                      ) else {
                    return DaemonControlResponse(
                        requestID: request.requestID,
                        succeeded: false,
                        message: "Указанное завершение не является головой очереди."
                    )
                }
                try stateStore.save(candidate)
                tracker = candidate
                reconcileAfterMaintenance()
                message = "Завершение \(completionID) отмечено просмотренным."
            case .acknowledgeAll:
                var candidate = tracker
                guard candidate.acknowledgeAllCompleted() else {
                    return DaemonControlResponse(
                        requestID: request.requestID,
                        succeeded: false,
                        message: "Нет завершённых задач для подтверждения."
                    )
                }
                try stateStore.save(candidate)
                tracker = candidate
                reconcileAfterMaintenance()
                message = "Все завершённые задачи отмечены просмотренными."
            case .selfTest:
                message = try runDaemonSelfTest()
            case .demo:
                message = try runDaemonDemo()
            case .inspectLED:
                message = [
                    "Клавиатура: \(led.keyboardName ?? "не найдена")",
                    "Физический LED: \(String(describing: led.hardwareIndicatorState))",
                    "Режим Caps Lock: \(led.actualCapsLockState)",
                ].joined(separator: "\n")
            case .inspectMagSafe:
                let current = magSafeLED.currentValue()
                message = [
                    "Порт MagSafe: \(magSafeSnapshot.portPresent ? "найден" : "не найден")",
                    "Физическое подключение: \(magSafeSnapshot.connected ? "да" : "нет")",
                    "Управление: \(magSafeControlAvailable ? "доступно" : "недоступно")",
                    "ACLC: \(current.map(String.init) ?? "нет данных")",
                ].joined(separator: "\n")
            case .repairOutputs:
                _ = magSafeLED.setMode(.system)
                magSafeLED.closeLease()
                guard led.restoreActualCapsLockIndicator() else {
                    throw DaemonMaintenanceError.capsLockWriteFailed
                }
                reconcileAfterMaintenance()
                message = "Оба аппаратных выхода восстановлены и согласованы."
            }
            return DaemonControlResponse(
                requestID: request.requestID,
                succeeded: true,
                message: message
            )
        } catch {
            reconcileAfterMaintenance()
            return DaemonControlResponse(
                requestID: request.requestID,
                succeeded: false,
                message: "Аппаратная операция не выполнена: \(error)"
            )
        }
    }

    private func runDaemonDemo() throws -> String {
        defer { reconcileAfterMaintenance() }
        if output == .magSafe, magSafeSnapshot.connected, magSafeControlAvailable {
            guard magSafeLED.setMode(.blinkSlow) else {
                throw DaemonMaintenanceError.magSafeWriteFailed
            }
            try keepMagSafeLeaseAlive(for: 4)
            guard magSafeLED.setMode(.green) else {
                throw DaemonMaintenanceError.magSafeWriteFailed
            }
            try keepMagSafeLeaseAlive(for: 2)
            return "Демонстрация MagSafe завершена."
        }

        guard led.isAvailable else {
            throw DaemonMaintenanceError.keyboardUnavailable
        }
        for index in 0..<8 {
            guard led.setIndicator(index.isMultiple(of: 2)) else {
                throw DaemonMaintenanceError.capsLockWriteFailed
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard led.setIndicator(true) else {
            throw DaemonMaintenanceError.capsLockWriteFailed
        }
        Thread.sleep(forTimeInterval: 2)
        return "Демонстрация Caps Lock завершена."
    }

    private func runDaemonSelfTest() throws -> String {
        defer { reconcileAfterMaintenance() }
        guard led.isAvailable else {
            throw DaemonMaintenanceError.keyboardUnavailable
        }
        let originalCapsState = led.actualCapsLockState
        let targetLEDState = !(led.hardwareIndicatorState ?? originalCapsState)
        guard led.setIndicator(targetLEDState) else {
            throw DaemonMaintenanceError.capsLockWriteFailed
        }
        Thread.sleep(forTimeInterval: 0.2)
        guard led.hardwareIndicatorState == targetLEDState,
              led.actualCapsLockState == originalCapsState,
              led.restoreActualCapsLockIndicator() else {
            throw DaemonMaintenanceError.capsLockInvariantFailed
        }

        if magSafeSnapshot.connected {
            guard magSafeLED.probe() else {
                throw DaemonMaintenanceError.magSafeUnavailable
            }
            guard magSafeLED.setMode(.green) else {
                throw DaemonMaintenanceError.magSafeWriteFailed
            }
            var verified = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                if magSafeLED.currentValue() == MagSafeLEDMode.green.aclcValue {
                    verified = true
                    break
                }
            }
            guard verified, magSafeLED.setMode(.system) else {
                throw DaemonMaintenanceError.magSafeWriteFailed
            }
        }
        return "OK: hardware self-test пройден, логический Caps Lock не изменился."
    }

    private func keepMagSafeLeaseAlive(for duration: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            Thread.sleep(
                forTimeInterval: max(0.01, min(0.75, deadline.timeIntervalSinceNow))
            )
            guard magSafeLED.ping() else {
                throw DaemonMaintenanceError.magSafeUnavailable
            }
        }
    }

    private func reconcileAfterMaintenance() {
        let now = Date()
        magSafeReconciliationRequested = true
        updateMagSafeState(now: now)
        applyIndicator(
            for: tracker.effectiveMode,
            actualCapsLockState: led.actualCapsLockState,
            now: now
        )
        magSafeReconciliationRequested = false
        writeStatusIfNeeded(mode: tracker.effectiveMode, now: now, force: true)
    }

    private func shutdown() -> Never {
        stopping = true
        timer?.cancel()
        controlServer?.stop()
        controlServer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        try? stateStore.save(tracker)
        let now = Date()
        if magSafeLED.setMode(.system) {
            appliedMagSafeMode = .system
            magSafeRawValue = MagSafeLEDMode.system.aclcValue
            magSafeLastWriteAt = now
        } else {
            appliedMagSafeMode = nil
            magSafeRawValue = nil
        }
        magSafeLED.closeLease()
        _ = led.restoreActualCapsLockIndicator()
        ledOn = led.actualCapsLockState
        capsLockActualSnapshot = ledOn
        writeStatusIfNeeded(mode: .off, now: now, force: true)
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
        if hardwareLockDescriptor >= 0 {
            _ = flock(hardwareLockDescriptor, LOCK_UN)
            close(hardwareLockDescriptor)
            hardwareLockDescriptor = -1
        }
        exit(EXIT_SUCCESS)
    }
}
