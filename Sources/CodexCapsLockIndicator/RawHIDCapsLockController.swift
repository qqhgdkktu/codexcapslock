import Foundation
import IOKit.hid

struct RawHIDLEDTarget {
    let device: IOHIDDevice
    let element: IOHIDElement
    let product: String
    let builtIn: Bool
    let reportID: CFIndex
}

final class RawHIDCapsLockController {
    private let manager: IOHIDManager
    private var cachedTargets: [RawHIDLEDTarget]?
    private let cacheLock = NSLock()

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [
                kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
                kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keyboard),
                kIOHIDBuiltInKey: true,
            ] as CFDictionary
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, _ in
                guard let context else { return }
                Unmanaged<RawHIDCapsLockController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .invalidateTargets()
            },
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, _ in
                guard let context else { return }
                Unmanaged<RawHIDCapsLockController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .invalidateTargets()
            },
            context
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var targets: [RawHIDLEDTarget] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedTargets {
            return cachedTargets
        }
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            return []
        }

        let devices = (deviceSet as NSSet).allObjects.map { $0 as! IOHIDDevice }
        let discovered = devices.flatMap { device -> [RawHIDLEDTarget] in
            let matching = [
                kIOHIDElementUsagePageKey: Int(kHIDPage_LEDs),
                kIOHIDElementUsageKey: Int(kHIDUsage_LED_CapsLock),
            ] as CFDictionary
            guard let elements = IOHIDDeviceCopyMatchingElements(
                device,
                matching,
                IOOptionBits(kIOHIDOptionsTypeNone)
            ) as? [IOHIDElement] else {
                return []
            }

            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
                ?? "Unknown HID keyboard"
            let builtInValue = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString)
            let builtIn = (builtInValue as? Bool) == true || (builtInValue as? NSNumber)?.boolValue == true

            return elements.compactMap { element -> RawHIDLEDTarget? in
                guard IOHIDElementGetType(element) == kIOHIDElementTypeOutput else {
                    return nil
                }
                return RawHIDLEDTarget(
                    device: device,
                    element: element,
                    product: product,
                    builtIn: builtIn,
                    reportID: Int(IOHIDElementGetReportID(element))
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.builtIn != rhs.builtIn {
                return lhs.builtIn
            }
            return lhs.product < rhs.product
        }
        cachedTargets = discovered
        return discovered
    }

    @discardableResult
    func setIndicator(_ enabled: Bool, builtInOnly: Bool = true) -> [(RawHIDLEDTarget, IOReturn)] {
        let selected = targets.filter { !builtInOnly || $0.builtIn }
        let results = selected.map { target in
            let openResult = IOHIDDeviceOpen(target.device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                return (target, openResult)
            }
            defer { IOHIDDeviceClose(target.device, IOOptionBits(kIOHIDOptionsTypeNone)) }

            let value = IOHIDValueCreateWithIntegerValue(
                kCFAllocatorDefault,
                target.element,
                0,
                enabled ? 1 : 0
            )
            return (target, IOHIDDeviceSetValue(target.device, target.element, value))
        }
        if results.isEmpty || results.contains(where: { $0.1 != kIOReturnSuccess }) {
            invalidateTargets()
        }
        return results
    }

    func readIndicator(_ target: RawHIDLEDTarget) -> (IOReturn, Int?) {
        let openResult = IOHIDDeviceOpen(target.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return (openResult, nil)
        }
        defer { IOHIDDeviceClose(target.device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        let result = IOHIDDeviceGetValue(target.device, target.element, valuePointer)
        guard result == kIOReturnSuccess else {
            return (result, nil)
        }
        return (result, IOHIDValueGetIntegerValue(valuePointer.pointee.takeUnretainedValue()))
    }

    private func invalidateTargets() {
        cacheLock.lock()
        cachedTargets = nil
        cacheLock.unlock()
    }
}
