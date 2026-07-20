import IOKit
import IOKit.hidsystem

final class CapsLockModifierController {
    private var connection: io_connect_t = 0

    init() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != 0 else {
            return
        }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &openedConnection
        ) == KERN_SUCCESS else {
            return
        }
        connection = openedConnection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard connection != 0 else {
            return false
        }
        return IOHIDSetModifierLockState(
            connection,
            Int32(kIOHIDCapsLockState),
            enabled
        ) == KERN_SUCCESS
    }
}
