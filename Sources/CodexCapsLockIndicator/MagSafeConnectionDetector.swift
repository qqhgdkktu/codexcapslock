import Foundation
import IOKit
import IOKit.ps

struct MagSafePortState: Equatable, Sendable {
    let typeDescription: String?
    let portType: Int?
    let connectionActive: Bool

    var isMagSafe: Bool {
        typeDescription?.hasPrefix("MagSafe") == true || portType == 17
    }
}

struct MagSafeConnectionSnapshot: Equatable, Sendable {
    let portPresent: Bool
    let connectionActive: Bool
    let externalPowerAttached: Bool

    var connected: Bool {
        portPresent && connectionActive && externalPowerAttached
    }
}

final class MagSafeConnectionDetector {
    private static let portClassNames = [
        "AppleHPMInterfaceType11",
        "AppleTCControllerType11",
    ]

    func snapshot() -> MagSafeConnectionSnapshot {
        Self.evaluate(
            ports: Self.readPorts(),
            externalPowerAttached: IOPSCopyExternalPowerAdapterDetails() != nil
        )
    }

    static func evaluate(
        ports: [MagSafePortState],
        externalPowerAttached: Bool
    ) -> MagSafeConnectionSnapshot {
        let magSafePorts = ports.filter(\.isMagSafe)
        return MagSafeConnectionSnapshot(
            portPresent: !magSafePorts.isEmpty,
            connectionActive: magSafePorts.contains(where: \.connectionActive),
            externalPowerAttached: externalPowerAttached
        )
    }

    private static func readPorts() -> [MagSafePortState] {
        portClassNames.flatMap { className -> [MagSafePortState] in
            guard let matching = IOServiceMatching(className) else {
                return [MagSafePortState]()
            }

            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                matching,
                &iterator
            ) == KERN_SUCCESS else {
                return [MagSafePortState]()
            }
            defer { IOObjectRelease(iterator) }

            var ports: [MagSafePortState] = []
            while true {
                let service = IOIteratorNext(iterator)
                guard service != IO_OBJECT_NULL else {
                    break
                }
                defer { IOObjectRelease(service) }

                var unmanagedProperties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(
                    service,
                    &unmanagedProperties,
                    kCFAllocatorDefault,
                    0
                ) == KERN_SUCCESS,
                    let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else {
                    continue
                }

                ports.append(MagSafePortState(
                    typeDescription: properties["PortTypeDescription"] as? String,
                    portType: intValue(properties["PortType"]),
                    connectionActive: boolValue(properties["ConnectionActive"])
                ))
            }
            return ports
        }
    }

    private static func boolValue(_ value: Any?) -> Bool {
        (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }
}
