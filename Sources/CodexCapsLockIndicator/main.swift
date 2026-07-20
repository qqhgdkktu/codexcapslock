import Darwin
import Foundation

private enum CommandError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case keyboardUnavailable
    case ledWriteFailed
    case statusUnavailable
    case selfTestFailed(String)

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .keyboardUnavailable: "Встроенная клавиатура с LED Caps Lock не найдена."
        case .ledWriteFailed: "macOS не приняла команду управления LED Caps Lock."
        case .statusUnavailable: "Индикатор ещё не запущен или не успел записать состояние."
        case let .selfTestFailed(message): "Самопроверка не пройдена: \(message)"
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
            guard arguments.count == 2, let state = IndicatorMode(rawValue: arguments[1]) else {
                throw CommandError.invalidArguments("Использование: hook working|waiting|done|off")
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            do {
                try HookJournalWriter(paths: paths).append(state: state, inputData: input)
                launchDaemonIfNeeded(paths: paths)
            } catch {
                // Hooks must never block or fail a Codex turn if the indicator is unavailable.
                exit(EXIT_SUCCESS)
            }

        case "status":
            try printStatus(paths: paths)

        case "ack", "acknowledge":
            try HookJournalWriter(paths: paths).appendAcknowledgement()
            launchDaemonIfNeeded(paths: paths)
            print("OK: завершённые задачи отмечены просмотренными.")

        case "led":
            guard arguments.count == 2 else {
                throw CommandError.invalidArguments("Использование: led on|off|restore")
            }
            try setLED(arguments[1])

        case "inspect-led":
            inspectLED()

        case "raw-led":
            guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
                throw CommandError.invalidArguments("Использование: raw-led on|off")
            }
            inspectRawLED(setTo: arguments[1] == "on")

        case "demo":
            try runDemo()

        case "self-test":
            try runSelfTest()

        case "version", "--version", "-V":
            print(Constants.version)

        case "help", "--help", "-h":
            printHelp()

        default:
            throw CommandError.invalidArguments("Неизвестная команда: \(command)")
        }
    }

    private static func printStatus(paths: RuntimePaths) throws {
        guard let data = try? Data(contentsOf: paths.statusFile),
              let status = try? JSONDecoder.iso8601.decode(DaemonStatus.self, from: data) else {
            throw CommandError.statusUnavailable
        }

        let labels: [IndicatorMode: String] = [
            .off: "выключен",
            .working: "Codex работает — LED мигает",
            .waiting: "Codex ждёт действия — LED горит",
            .done: "Codex завершил работу — LED горит",
        ]
        print("Состояние: \(labels[status.mode] ?? status.mode.rawValue)")
        print("Клавиатура: \(status.keyboardName ?? "не найдена")")
        print("LED: \(status.ledOn ? "включён" : "выключен")")
        print("Codex: \(status.codexProcessRunning ? "запущен" : "не запущен")")
        print("Активных сессий: \(status.activeSessions)")
        print("PID: \(status.pid)")
        if status.mode == .done {
            print("Сброс: нажмите Caps Lock, откройте Codex или выполните команду ack.")
        }
    }

    private static func launchDaemonIfNeeded(paths: RuntimePaths) {
        guard !daemonLockIsHeld(paths: paths) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["daemon"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func daemonLockIsHeld(paths: RuntimePaths) -> Bool {
        let descriptor = open(paths.lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
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
        guard controller.isAvailable else {
            throw CommandError.keyboardUnavailable
        }

        defer { _ = controller.restoreActualCapsLockIndicator() }
        print("Демонстрация: 4 секунды мигания, затем 2 секунды постоянного света.")
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
    }

    private static func printHelp() {
        print("""
        Codex Caps Lock Indicator \(Constants.version)

        Команды:
          daemon              запустить фоновый индикатор
          hook STATE          принять событие Codex (working/waiting/done/off)
          status              показать текущее состояние
          ack                 погасить уведомление о завершённых задачах
          led on|off|restore  напрямую проверить LED
          inspect-led         показать LED и реальный режим Caps Lock
          raw-led on|off      экспериментальный прямой HID output-report
          demo                показать мигание и постоянный свет
          self-test           проверить LED и неизменность режима Caps Lock
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
