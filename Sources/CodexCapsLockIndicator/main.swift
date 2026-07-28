import Darwin
import Foundation

private enum CommandError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case keyboardUnavailable
    case ledWriteFailed
    case magSafeUnavailable
    case magSafeWriteFailed
    case statusUnavailable
    case selfTestFailed(String)
    case hookPayloadTooLarge
    case hardwareOwnedByDaemon

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .keyboardUnavailable: "Встроенная клавиатура с LED Caps Lock не найдена."
        case .ledWriteFailed: "macOS не приняла команду управления LED Caps Lock."
        case .magSafeUnavailable: "Привилегированный помощник MagSafe недоступен или ACLC не поддерживается."
        case .magSafeWriteFailed: "macOS не приняла команду управления LED MagSafe."
        case .statusUnavailable: "Индикатор ещё не запущен или не успел записать состояние."
        case let .selfTestFailed(message): "Самопроверка не пройдена: \(message)"
        case .hookPayloadTooLarge: "Lifecycle hook payload превышает допустимый размер."
        case .hardwareOwnedByDaemon:
            "Аппаратный выход принадлежит daemon; используйте control-команду или остановите daemon."
        }
    }
}

enum CodexCapsLockIndicatorMain {
    static func main() {
        do {
            try execute(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func execute(arguments: [String]) throws {
        let command = arguments.first ?? "help"
        let paths = RuntimePaths.live()

        switch command {
        case "daemon":
            try IndicatorDaemon(paths: paths).run()

        case "hook":
            guard (2...3).contains(arguments.count),
                  let action = LifecycleAction(rawValue: arguments[1]),
                  let source = CodingAgent(rawValue: arguments.count == 3 ? arguments[2] : "codex") else {
                throw CommandError.invalidArguments(
                    "Использование: hook EVENT [codex|claude]"
                )
            }
            do {
                let input = try readHookInput()
                try HookJournalWriter(paths: paths).append(
                    action: action,
                    source: source,
                    inputData: input
                )
                launchDaemonIfNeeded(paths: paths)
            } catch {
                // Hooks must never block or fail an agent turn if the indicator is unavailable.
                exit(EXIT_SUCCESS)
            }

        case "status":
            guard arguments.count == 1
                    || (arguments.count == 2 && arguments[1] == "--json") else {
                throw CommandError.invalidArguments(
                    "Использование: status [--json]"
                )
            }
            try printStatus(paths: paths, json: arguments.count == 2)

        case "ack", "acknowledge":
            guard arguments.count <= 2 else {
                throw CommandError.invalidArguments(
                    "Использование: ack [COMPLETION_ID|--all]"
                )
            }
            if arguments.dropFirst().first == "--all" {
                if let response = DaemonControlClient(
                    socketURL: paths.controlSocket
                ).send(.acknowledgeAll) {
                    guard response.succeeded else {
                        throw CommandError.invalidArguments(response.message)
                    }
                    print(response.message)
                    return
                }
                try HookJournalWriter(paths: paths).appendAcknowledgementAll()
                launchDaemonIfNeeded(paths: paths)
                print("OK: все завершённые задачи отмечены просмотренными.")
                return
            }
            if let rawCompletionID = arguments.dropFirst().first {
                guard let completionID = UUID(uuidString: rawCompletionID) else {
                    throw CommandError.invalidArguments(
                        "Использование: ack [COMPLETION_ID|--all]"
                    )
                }
                if let response = DaemonControlClient(
                    socketURL: paths.controlSocket
                ).sendAcknowledgement(completionID: completionID) {
                    guard response.succeeded else {
                        throw CommandError.invalidArguments(response.message)
                    }
                    print(response.message)
                    return
                }
                try HookJournalWriter(paths: paths)
                    .appendAcknowledgement(completionID: completionID)
                launchDaemonIfNeeded(paths: paths)
                print("OK: точное подтверждение \(completionID) поставлено в очередь.")
                return
            }
            if let response = DaemonControlClient(
                socketURL: paths.controlSocket
            ).send(.acknowledgeNext) {
                guard response.succeeded else {
                    throw CommandError.invalidArguments(response.message)
                }
                print(response.message)
                return
            }
            try HookJournalWriter(paths: paths).appendAcknowledgement()
            launchDaemonIfNeeded(paths: paths)
            print("OK: первая завершённая задача отмечена просмотренной.")

        case "led":
            guard arguments.count == 2 else {
                throw CommandError.invalidArguments("Использование: led on|off|restore")
            }
            try withExclusiveHardwareAccess(paths: paths) {
                try setLED(arguments[1])
            }

        case "inspect-led":
            if let response = DaemonControlClient(
                socketURL: paths.controlSocket
            ).send(.inspectLED) {
                print(response.message)
                return
            }
            inspectLED()

        case "inspect-magsafe":
            if let response = DaemonControlClient(
                socketURL: paths.controlSocket
            ).send(.inspectMagSafe) {
                print(response.message)
                return
            }
            inspectMagSafe()

        case "magsafe":
            guard arguments.count == 2 else {
                throw CommandError.invalidArguments(
                    "Использование: magsafe probe|status|system|green|blink-slow"
                )
            }
            try withExclusiveHardwareAccess(paths: paths) {
                try controlMagSafe(arguments[1])
            }

        case "raw-led":
            guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
                throw CommandError.invalidArguments("Использование: raw-led on|off")
            }
            try withExclusiveHardwareAccess(paths: paths) {
                inspectRawLED(setTo: arguments[1] == "on")
            }

        case "demo":
            if let response = DaemonControlClient(
                socketURL: paths.controlSocket
            ).send(.demo) {
                guard response.succeeded else {
                    throw CommandError.selfTestFailed(response.message)
                }
                print(response.message)
                return
            }
            try withExclusiveHardwareAccess(paths: paths) {
                try runDemo()
            }

        case "self-test":
            if let response = DaemonControlClient(
                socketURL: paths.controlSocket
            ).send(.selfTest) {
                guard response.succeeded else {
                    throw CommandError.selfTestFailed(response.message)
                }
                print(response.message)
                return
            }
            try withExclusiveHardwareAccess(paths: paths) {
                try runSelfTest()
            }

        case "repair":
            if let response = DaemonControlClient(
                socketURL: paths.controlSocket
            ).send(.repairOutputs) {
                guard response.succeeded else {
                    throw CommandError.selfTestFailed(response.message)
                }
                print(response.message)
                return
            }
            try withExclusiveHardwareAccess(paths: paths) {
                let magSafe = MagSafeLEDController()
                defer { magSafe.closeLease() }
                _ = magSafe.setMode(.system)
                let controller = HIDCapsLockController()
                guard controller.restoreActualCapsLockIndicator() else {
                    throw CommandError.ledWriteFailed
                }
            }
            print("Оба аппаратных выхода восстановлены.")

        case "version", "--version", "-V":
            print(Constants.version)

        case "help", "--help", "-h":
            printHelp()

        default:
            throw CommandError.invalidArguments("Неизвестная команда: \(command)")
        }
    }

    private static func printStatus(paths: RuntimePaths, json: Bool) throws {
        guard let data = readBoundedUserFile(
                at: paths.statusFile,
                maximumBytes: Constants.maximumStatusBytes
              ),
              let status = try? JSONDecoder.iso8601.decode(DaemonStatus.self, from: data),
              Date().timeIntervalSince(status.updatedAt) <= 60,
              kill(status.pid, 0) == 0,
              daemonLockIsHeld(paths: paths) else {
            throw CommandError.statusUnavailable
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(status)
            print(String(decoding: encoded, as: UTF8.self))
            return
        }

        let labels: [IndicatorMode: String] = [
            .off: "выключен",
            .working: "агент работает — LED мигает",
            .waiting: "агент ждёт действия — LED горит",
            .done: "агент завершил работу — LED горит",
        ]
        print("Состояние: \(labels[status.mode] ?? status.mode.rawValue)")
        print("Индикатор: \(status.output == .magSafe ? "MagSafe" : "Caps Lock")")
        print("Клавиатура: \(status.keyboardName ?? "не найдена")")
        print("Индикация агентов: \(status.ledOn ? "активна" : "неактивна")")
        if let logical = status.capsLockLogicalState {
            let actual = status.capsLockLEDActual.map(String.init) ?? "нет данных"
            let expected = status.capsLockLEDExpected.map(String.init)
                ?? "нет данных"
            let synchronized = status.capsLockSynchronized.map {
                $0 ? "да" : "нет"
            } ?? "не проверяется"
            print(
                "Caps Lock: логический \(logical), LED \(actual), "
                    + "ожидаемый \(expected), синхронизировано: \(synchronized)"
            )
        }
        let magSafeConnection = status.magSafeConnected ? "подключён" : "не подключён"
        let magSafeControl = status.magSafeControlAvailable ? "доступно" : "недоступно"
        print("MagSafe: \(magSafeConnection), управление \(magSafeControl)")
        let rawValue = status.magSafeRawValue.map(String.init) ?? "нет данных"
        let expectedValue = status.magSafeExpectedValue.map(String.init) ?? "не применяется"
        let synchronized: String
        switch status.magSafeSynchronized {
        case true: synchronized = "да"
        case false: synchronized = "нет"
        case nil: synchronized = "не проверяется"
        }
        print("MagSafe ACLC: текущее \(rawValue), ожидаемое \(expectedValue), синхронизировано: \(synchronized)")
        if let lastWrite = status.magSafeLastWriteAt {
            print("Последняя запись MagSafe: \(ISO8601DateFormatter().string(from: lastWrite))")
        }
        print("Codex: \(status.codexProcessRunning ? "запущен" : "не запущен")")
        let claudeProcess: String
        switch status.claudeProcessRunning {
        case true: claudeProcess = "запущен"
        case false: claudeProcess = "не запущен"
        case nil: claudeProcess = "не определяется в hooks-only режиме"
        }
        print("Claude Code: \(claudeProcess)")
        print("Активных сессий: \(status.activeSessions)")
        print("Завершений в очереди: \(status.completionQueueDepth ?? 0)")
        if let completionID = status.firstCompletionID {
            let source = status.firstCompletionSource?.rawValue ?? "неизвестно"
            let outcome = status.firstCompletionOutcome?.rawValue ?? "неизвестно"
            print("Первое завершение: \(completionID) (\(source), \(outcome))")
        }
        if let protocolVersion = status.lifecycleProtocolVersion {
            print("Lifecycle protocol: v\(protocolVersion)")
        }
        print("PID: \(status.pid)")
        if status.mode == .done {
            if status.output == .magSafe {
                print("Сброс: откройте Codex для результата Codex или выполните ack; Caps Lock работает обычно.")
            } else {
                print("Сброс: нажмите Caps Lock, откройте Codex или выполните команду ack.")
            }
        }
    }

    private static func readBoundedUserFile(
        at url: URL,
        maximumBytes: Int
    ) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_size >= 0,
              information.st_size <= off_t(maximumBytes) else {
            return nil
        }
        var data = Data()
        var buffer = [UInt8](
            repeating: 0,
            count: min(16_384, max(Int(information.st_size), 1))
        )
        while data.count < Int(information.st_size) {
            let requested = min(
                buffer.count,
                Int(information.st_size) - data.count
            )
            let count = Darwin.read(descriptor, &buffer, requested)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private static func readHookInput() throws -> Data {
        var data = Data()
        while data.count <= Constants.maximumHookPayloadBytes {
            let remaining = Constants.maximumHookPayloadBytes + 1 - data.count
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(65_536, remaining)
            ), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= Constants.maximumHookPayloadBytes else {
            throw CommandError.hookPayloadTooLarge
        }
        return data
    }

    private static func launchDaemonIfNeeded(paths: RuntimePaths) {
        if ProcessInfo.processInfo.environment["CODEX_CAPS_INDICATOR_DISABLE_DAEMON_AUTOSTART"] == "1" {
            return
        }
        guard !daemonLockIsHeld(paths: paths) else {
            return
        }

        let launchAgent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "com.mikita.codex-capslock-indicator.plist"
            )
        if FileManager.default.fileExists(atPath: launchAgent.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = [
                "kickstart",
                "gui/\(getuid())/com.mikita.codex-capslock-indicator",
            ]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_ALL": "C",
            ]
            process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                return
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["daemon"]
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
        ]
        for key in ["CODEX_HOME", "CODEX_CAPS_INDICATOR_STATE_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                environment[key] = value
            }
        }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func daemonLockIsHeld(paths: RuntimePaths) -> Bool {
        let descriptor = open(
            paths.lockFile.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            return true
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            return true
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private static func withExclusiveHardwareAccess<T>(
        paths: RuntimePaths,
        operation: () throws -> T
    ) throws -> T {
        try paths.prepare()
        let lockURL = paths.baseDirectory.appendingPathComponent("hardware.lock")
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw CommandError.hardwareOwnedByDaemon
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CommandError.hardwareOwnedByDaemon
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard !daemonLockIsHeld(paths: paths) else {
            throw CommandError.hardwareOwnedByDaemon
        }
        return try operation()
    }

    private static func setLED(_ value: String) throws {
        let controller = HIDCapsLockController()
        guard controller.isAvailable else {
            throw CommandError.keyboardUnavailable
        }

        let result: Bool
        switch value {
        case "on": result = controller.setIndicator(true)
        case "off": result = controller.setIndicator(false)
        case "restore": result = controller.restoreActualCapsLockIndicator()
        default:
            throw CommandError.invalidArguments("Использование: led on|off|restore")
        }
        guard result else {
            throw CommandError.ledWriteFailed
        }
    }

    private static func inspectLED() {
        let controller = HIDCapsLockController()
        print("Клавиатура: \(controller.keyboardName ?? "не найдена")")
        print("Физический LED: \(String(describing: controller.hardwareIndicatorState))")
        print("Режим Caps Lock: \(controller.actualCapsLockState)")
    }

    private static func inspectMagSafe() {
        let snapshot = MagSafeConnectionDetector().snapshot()
        let controller = MagSafeLEDController()
        let helperAlive = controller.ping()
        let controlSupported = helperAlive && controller.probe()
        let rawValue = controlSupported ? controller.currentValue() : nil
        print("Порт MagSafe: \(snapshot.portPresent ? "найден" : "не найден")")
        print("ConnectionActive: \(snapshot.connectionActive ? "да" : "нет")")
        print("Физическое подключение: \(snapshot.connected ? "да" : "нет")")
        print("Внешнее питание: \(snapshot.externalPowerAttached ? "да" : "нет")")
        print("Привилегированный helper: \(helperAlive ? "отвечает" : "недоступен")")
        print("Ключ ACLC: \(controlSupported ? "поддерживается" : "недоступен")")
        if let rawValue {
            let mode = MagSafeLEDMode(aclcValue: rawValue)?.rawValue ?? "неизвестный"
            print("Текущее ACLC: \(rawValue) (\(mode))")
        }
    }

    private static func controlMagSafe(_ command: String) throws {
        let controller = MagSafeLEDController()
        switch command {
        case "probe":
            guard controller.probe() else {
                throw CommandError.magSafeUnavailable
            }
            print("OK: управление LED MagSafe поддерживается.")
        case "status":
            guard let value = controller.currentValue() else {
                throw CommandError.magSafeUnavailable
            }
            print(value)
        default:
            guard let mode = MagSafeLEDMode(rawValue: command) else {
                throw CommandError.invalidArguments(
                    "Использование: magsafe probe|status|system|green|blink-slow"
                )
            }
            guard controller.setMode(mode) else {
                throw CommandError.magSafeWriteFailed
            }
            print("OK: MagSafe LED — \(mode.rawValue).")
        }
    }

    private static func inspectRawLED(setTo enabled: Bool) {
        let controller = RawHIDCapsLockController()
        let targets = controller.targets
        print("Найдено Caps Lock LED output-элементов: \(targets.count)")
        for target in targets {
            print("- \(target.product); built-in=\(target.builtIn); report=\(target.reportID)")
        }
        let results = controller.setIndicator(enabled)
        for (target, result) in results {
            print("set \(target.product): 0x\(String(UInt32(bitPattern: result), radix: 16))")
            Thread.sleep(forTimeInterval: 0.2)
            let (readResult, value) = controller.readIndicator(target)
            print("read \(target.product): 0x\(String(UInt32(bitPattern: readResult), radix: 16)); value=\(String(describing: value))")
        }
    }

    private static func runDemo() throws {
        let controller = HIDCapsLockController()
        let magSafeSnapshot = MagSafeConnectionDetector().snapshot()
        let magSafe = MagSafeLEDController()

        if magSafeSnapshot.connected && magSafe.probe() {
            defer {
                _ = magSafe.setMode(.system)
                _ = controller.restoreActualCapsLockIndicator()
            }
            _ = controller.restoreActualCapsLockIndicator()
            print("Демонстрация MagSafe: 4 секунды мигания, затем 2 секунды зелёного света.")
            guard magSafe.setMode(.blinkSlow) else {
                throw CommandError.magSafeWriteFailed
            }
            Thread.sleep(forTimeInterval: 4)
            guard magSafe.setMode(.green) else {
                throw CommandError.magSafeWriteFailed
            }
            Thread.sleep(forTimeInterval: 2)
            print("Демонстрация завершена; системная индикация зарядки восстановлена.")
            return
        }

        guard controller.isAvailable else {
            throw CommandError.keyboardUnavailable
        }
        defer { _ = controller.restoreActualCapsLockIndicator() }
        print("Демонстрация Caps Lock: 4 секунды мигания, затем 2 секунды постоянного света.")
        for index in 0..<8 {
            guard controller.setIndicator(index.isMultiple(of: 2)) else {
                throw CommandError.ledWriteFailed
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard controller.setIndicator(true) else {
            throw CommandError.ledWriteFailed
        }
        Thread.sleep(forTimeInterval: 2)
        print("Демонстрация завершена; обычное состояние Caps Lock восстановлено.")
    }

    private static func runSelfTest() throws {
        let controller = HIDCapsLockController()
        guard controller.isAvailable else {
            throw CommandError.keyboardUnavailable
        }

        let originalCapsState = controller.actualCapsLockState
        let targetLEDState = !(controller.hardwareIndicatorState ?? originalCapsState)
        defer { _ = controller.restoreActualCapsLockIndicator() }

        guard controller.setIndicator(targetLEDState) else {
            throw CommandError.ledWriteFailed
        }
        Thread.sleep(forTimeInterval: 0.2)

        guard controller.hardwareIndicatorState == targetLEDState else {
            throw CommandError.selfTestFailed("состояние LED не изменилось")
        }
        guard controller.actualCapsLockState == originalCapsState else {
            throw CommandError.selfTestFailed("изменился реальный режим Caps Lock")
        }
        guard controller.restoreActualCapsLockIndicator() else {
            throw CommandError.selfTestFailed("не удалось восстановить LED")
        }

        print("OK: \(controller.keyboardName ?? "клавиатура найдена")")
        print("OK: LED управляется отдельно от режима ввода Caps Lock")

        let magSafeSnapshot = MagSafeConnectionDetector().snapshot()
        if magSafeSnapshot.connected {
            let magSafe = MagSafeLEDController()
            guard magSafe.probe() else {
                throw CommandError.magSafeUnavailable
            }
            defer { _ = magSafe.setMode(.system) }
            guard magSafe.setMode(.green) else {
                throw CommandError.selfTestFailed("не удалось включить зелёный режим MagSafe")
            }
            var greenVerified = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                if magSafe.currentValue() == 3 {
                    greenVerified = true
                    break
                }
            }
            guard greenVerified else {
                throw CommandError.selfTestFailed("LED MagSafe не перешёл в зелёный режим")
            }
            guard magSafe.setMode(.system) else {
                throw CommandError.selfTestFailed("не удалось восстановить системный режим MagSafe")
            }
            print("OK: подключённый MagSafe управляется и возвращается в системный режим")
        }
    }

    private static func printHelp() {
        print("""
        Codex Caps Lock Indicator \(Constants.version)

        Команды:
          daemon              запустить фоновый индикатор
          hook EVENT [AGENT]  принять semantic lifecycle event Codex/Claude Code
          status [--json]     показать текущее состояние
          ack [ID|--all]      подтвердить первое, указанное или все завершения
          led on|off|restore  напрямую проверить LED
          inspect-led         показать LED и реальный режим Caps Lock
          inspect-magsafe     показать подключение и доступность MagSafe
          magsafe COMMAND     низкоуровневая диагностика MagSafe
          raw-led on|off      экспериментальный прямой HID output-report
          demo                показать выбранный автоматически индикатор
          self-test           проверить Caps Lock и подключённый MagSafe
          repair              восстановить и согласовать оба аппаратных выхода
        """)
    }
}

CodexCapsLockIndicatorMain.main()

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
