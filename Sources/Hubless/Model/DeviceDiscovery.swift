import Foundation
import IOKit
import IOKit.hid
import IOKit.usb
import CoreMediaIO

/// A thread with its own run loop, used for IOHIDManager callbacks so the main thread
/// (or a request waiting on a reply) never blocks HID input delivery.
final class RunLoopThread: Thread, @unchecked Sendable {
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // Keep the run loop alive even with no sources yet.
        let port = NSMachPort()
        RunLoop.current.add(port, forMode: .default)
        ready.signal()
        while !isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    func waitUntilReady() -> CFRunLoop {
        ready.wait()
        return runLoop!
    }
}

/// Watches for Logitech HID++ devices (vendor usage page 0xFF43/0xFF00) and UVC cameras.
final class DeviceDiscovery: @unchecked Sendable {
    var onHIDPPArrived: ((IOHIDDevice) -> Void)?
    var onHIDPPRemoved: ((IOHIDDevice) -> Void)?
    var onCameraArrived: ((io_service_t) -> Void)?
    var onCameraRemoved: ((UInt64) -> Void)?

    static let logitechVendorID = 0x046D

    private let hidThread = RunLoopThread()
    private var hidManager: IOHIDManager?
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    func start() {
        startHID()
        startUSB()
    }

    // MARK: HID++

    private func startHID() {
        hidThread.name = "Hubless HID"
        hidThread.start()
        let runLoop = hidThread.waitUntilReady()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [0xFF43, 0xFF00].map {
            [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDDeviceUsagePageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<DeviceDiscovery>.fromOpaque(ctx).takeUnretainedValue()
            guard DeviceDiscovery.hasLongReport(device) else { return }
            me.onHIDPPArrived?(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DeviceDiscovery>.fromOpaque(ctx).takeUnretainedValue().onHIDPPRemoved?(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
        CFRunLoopWakeUp(runLoop)
    }

    /// HID++ long reports are 20 bytes (report ID 0x11). Receivers/devices without them are skipped.
    static func hasLongReport(_ device: IOHIDDevice) -> Bool {
        let out = IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
        return out >= 20
    }

    // MARK: USB / UVC

    private func startUSB() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()

        func matching() -> CFDictionary {
            let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            m["IOPropertyMatch"] = ["idVendor": Self.logitechVendorID]
            return m
        }

        let kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), { ctx, iterator in
            guard let ctx else { return }
            Unmanaged<DeviceDiscovery>.fromOpaque(ctx).takeUnretainedValue().drainAdded(iterator)
        }, context, &addedIterator)
        if CommandLine.arguments.contains("--diagnose") { print("USB notify kr=\(kr) iterator=\(addedIterator)") }
        drainAdded(addedIterator)

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), { ctx, iterator in
            guard let ctx else { return }
            Unmanaged<DeviceDiscovery>.fromOpaque(ctx).takeUnretainedValue().drainRemoved(iterator)
        }, context, &removedIterator)
        drainRemoved(removedIterator)
    }

    private func drainAdded(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            onCameraArrived?(service)
            IOObjectRelease(service)
        }
    }

    private func drainRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            onCameraRemoved?(id)
            IOObjectRelease(service)
        }
    }
}

extension io_service_t {
    var registryID: UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(self, &id)
        return id
    }
}

/// Observes CoreMediaIO so camera settings can be re-applied when an app starts using the camera.
final class CameraUsageMonitor: @unchecked Sendable {
    var onCameraStarted: ((_ vendorID: Int, _ productID: Int) -> Void)?
    private var watched = Set<CMIOObjectID>()

    func start() {
        // Allow CMIO to see screen-capture/DAL devices as well; harmless for UVC.
        refresh()
        var addr = Self.address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.refresh()
        }
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func devices() -> [CMIOObjectID] {
        var addr = Self.address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids)
        return ids
    }

    private func modelUID(_ id: CMIOObjectID) -> String? {
        var addr = Self.address(kCMIODevicePropertyModelUID)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &value) == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func isRunning(_ id: CMIOObjectID) -> Bool {
        var addr = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return running != 0
    }

    /// UVC model UIDs look like "UVC Camera VendorID_1133 ProductID_2140".
    static func parseModel(_ uid: String) -> (Int, Int)? {
        func number(after token: String) -> Int? {
            guard let r = uid.range(of: token) else { return nil }
            return Int(uid[r.upperBound...].prefix { $0.isNumber })
        }
        guard let v = number(after: "VendorID_"), let p = number(after: "ProductID_") else { return nil }
        return (v, p)
    }

    private func refresh() {
        for id in devices() where !watched.contains(id) {
            guard let uid = modelUID(id), let (vid, pid) = Self.parseModel(uid) else { continue }
            watched.insert(id)
            var addr = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
                guard let self, self.isRunning(id) else { return }
                self.onCameraStarted?(vid, pid)
            }
        }
    }
}
