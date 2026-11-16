import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// IOKit plug-in UUIDs (the C macros are not imported into Swift).
private let kUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
private let kCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
private let kUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

enum UVCUnitKind: String, Codable, Sendable { case cameraTerminal, processingUnit }

/// A UVC 1.x control, as defined by the USB Video Class spec (CT = camera terminal, PU = processing unit).
struct UVCControlSpec: Hashable, Sendable {
    let key: String
    let title: String
    let unit: UVCUnitKind
    let selector: UInt8
    let size: Int
    let signed: Bool
    /// Bit in the unit's bmControls bitmap that advertises support.
    let bit: Int

    static let all: [UVCControlSpec] = [
        .init(key: "aeMode", title: "Auto Exposure", unit: .cameraTerminal, selector: 0x02, size: 1, signed: false, bit: 1),
        .init(key: "aePriority", title: "Low-Light Priority", unit: .cameraTerminal, selector: 0x03, size: 1, signed: false, bit: 2),
        .init(key: "exposure", title: "Exposure", unit: .cameraTerminal, selector: 0x04, size: 4, signed: false, bit: 3),
        .init(key: "focus", title: "Focus", unit: .cameraTerminal, selector: 0x06, size: 2, signed: false, bit: 5),
        .init(key: "zoom", title: "Zoom", unit: .cameraTerminal, selector: 0x0B, size: 2, signed: false, bit: 9),
        .init(key: "panTilt", title: "Pan / Tilt", unit: .cameraTerminal, selector: 0x0D, size: 8, signed: true, bit: 11),
        .init(key: "focusAuto", title: "Autofocus", unit: .cameraTerminal, selector: 0x08, size: 1, signed: false, bit: 17),
        .init(key: "backlight", title: "Backlight Compensation", unit: .processingUnit, selector: 0x01, size: 2, signed: false, bit: 8),
        .init(key: "brightness", title: "Brightness", unit: .processingUnit, selector: 0x02, size: 2, signed: true, bit: 0),
        .init(key: "contrast", title: "Contrast", unit: .processingUnit, selector: 0x03, size: 2, signed: false, bit: 1),
        .init(key: "hue", title: "Hue", unit: .processingUnit, selector: 0x06, size: 2, signed: true, bit: 2),
        .init(key: "gain", title: "Gain", unit: .processingUnit, selector: 0x04, size: 2, signed: false, bit: 9),
        .init(key: "powerLine", title: "Anti-Flicker", unit: .processingUnit, selector: 0x05, size: 1, signed: false, bit: 10),
        .init(key: "saturation", title: "Saturation", unit: .processingUnit, selector: 0x07, size: 2, signed: false, bit: 3),
        .init(key: "sharpness", title: "Sharpness", unit: .processingUnit, selector: 0x08, size: 2, signed: false, bit: 4),
        .init(key: "gamma", title: "Gamma", unit: .processingUnit, selector: 0x09, size: 2, signed: false, bit: 5),
        .init(key: "whiteBalance", title: "White Balance", unit: .processingUnit, selector: 0x0A, size: 2, signed: false, bit: 6),
        .init(key: "whiteBalanceAuto", title: "Auto White Balance", unit: .processingUnit, selector: 0x0B, size: 1, signed: false, bit: 12),
    ]
}

/// Range information for one camera value. Pan/tilt are exposed as two virtual values "pan" and "tilt".
struct UVCRange: Hashable, Sendable {
    var min: Int
    var max: Int
    var step: Int
    var defaultValue: Int
}

enum UVCError: Error, CustomStringConvertible {
    case openFailed(String)
    case request(IOReturn)
    var description: String {
        switch self {
        case .openFailed(let s): return s
        case .request(let r): return "USB control request failed (0x\(String(UInt32(bitPattern: r), radix: 16)))"
        }
    }
}

/// Talks UVC class-specific control requests to a camera's VideoControl interface over the default
/// control pipe. This does not need exclusive access, so it works while the camera is streaming.
final class UVCCamera: @unchecked Sendable {
    private let deviceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>
    private let queue = DispatchQueue(label: "uvc.requests")
    let service: io_service_t
    let vendorID: Int
    let productID: Int
    let productName: String
    let serial: String?
    let locationID: UInt32
    private(set) var interfaceNumber: UInt8 = 0
    private(set) var unitIDs: [UVCUnitKind: UInt8] = [:]
    private(set) var unitControls: [UVCUnitKind: UInt32] = [:]

    init(service: io_service_t) throws {
        self.service = service
        IOObjectRetain(service)
        func prop<T>(_ key: String) -> T? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
        }
        vendorID = prop("idVendor") ?? 0
        productID = prop("idProduct") ?? 0
        productName = prop("USB Product Name") ?? prop("kUSBProductString") ?? "USB Camera"
        serial = prop("USB Serial Number") ?? prop("kUSBSerialNumberString")
        locationID = prop("locationID") ?? 0

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(service, kUSBDeviceUserClientTypeID, kCFPlugInInterfaceID, &plugin, &score)
        guard kr == KERN_SUCCESS, let plugin, let pluginIface = plugin.pointee else {
            IOObjectRelease(service)
            throw UVCError.openFailed("Cannot create USB plug-in (0x\(String(kr, radix: 16)))")
        }
        defer { _ = pluginIface.pointee.Release(plugin) }
        var raw: UnsafeMutableRawPointer?
        let hr = withUnsafeMutablePointer(to: &raw) { p in
            pluginIface.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(kUSBDeviceInterfaceID), UnsafeMutablePointer(OpaquePointer(p)))
        }
        guard hr == 0, let raw else {
            IOObjectRelease(service)
            throw UVCError.openFailed("Cannot query USB device interface")
        }
        deviceInterface = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>.self)
        try parseDescriptors()
    }

    deinit {
        _ = deviceInterface.pointee.pointee.Release(deviceInterface)
        IOObjectRelease(service)
    }

    var modelKey: String { String(format: "%04x:%04x", vendorID, productID) }

    /// Finds the VideoControl interface and its camera-terminal / processing-unit IDs and capability bitmaps.
    private func parseDescriptors() throws {
        var cfg: IOUSBConfigurationDescriptorPtr?
        let kr = deviceInterface.pointee.pointee.GetConfigurationDescriptorPtr(deviceInterface, 0, &cfg)
        guard kr == kIOReturnSuccess, let cfg else { throw UVCError.openFailed("No configuration descriptor") }
        let total = Int(UInt16(littleEndian: cfg.pointee.wTotalLength))
        let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(cfg).assumingMemoryBound(to: UInt8.self), count: total))
        Self.parse(configuration: bytes, into: self)
        guard unitIDs[.cameraTerminal] != nil || unitIDs[.processingUnit] != nil else {
            throw UVCError.openFailed("Not a UVC camera")
        }
    }

    /// Pure descriptor parser (separated for testing).
    static func parse(configuration bytes: [UInt8]) -> (interface: UInt8, units: [UVCUnitKind: UInt8], controls: [UVCUnitKind: UInt32]) {
        var i = 0
        var inVideoControl = false
        var interface: UInt8 = 0
        var units: [UVCUnitKind: UInt8] = [:]
        var controls: [UVCUnitKind: UInt32] = [:]
        func bitmap(_ slice: ArraySlice<UInt8>) -> UInt32 {
            slice.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        while i + 2 <= bytes.count {
            let len = Int(bytes[i])
            guard len > 0, i + len <= bytes.count else { break }
            let d = Array(bytes[i..<(i + len)])
            if d[1] == 0x04, len >= 9 { // INTERFACE
                inVideoControl = d[5] == 0x0E && d[6] == 0x01
                if inVideoControl { interface = d[2] }
            } else if inVideoControl, d[1] == 0x24, len >= 3 { // CS_INTERFACE
                switch d[2] {
                case 0x02 where len >= 15 && d[4] == 0x01 && d[5] == 0x02: // INPUT_TERMINAL, ITT_CAMERA
                    units[.cameraTerminal] = d[3]
                    let size = Int(d[14])
                    controls[.cameraTerminal] = bitmap(d[15..<min(len, 15 + size)])
                case 0x05 where len >= 8: // PROCESSING_UNIT
                    units[.processingUnit] = d[3]
                    let size = Int(d[7])
                    controls[.processingUnit] = bitmap(d[8..<min(len, 8 + size)])
                default: break
                }
            }
            i += len
        }
        return (interface, units, controls)
    }

    private static func parse(configuration bytes: [UInt8], into camera: UVCCamera) {
        let r = parse(configuration: bytes)
        camera.interfaceNumber = r.interface
        camera.unitIDs = r.units
        camera.unitControls = r.controls
    }

    var supportedControls: [UVCControlSpec] {
        UVCControlSpec.all.filter { spec in
            guard unitIDs[spec.unit] != nil, let map = unitControls[spec.unit] else { return false }
            return map & (1 << UInt32(spec.bit)) != 0
        }
    }

    // MARK: Raw requests

    private enum Req: UInt8 { case setCur = 0x01, getCur = 0x81, getMin = 0x82, getMax = 0x83, getRes = 0x84, getInfo = 0x86, getDef = 0x87 }

    private func transfer(_ req: Req, _ spec: UVCControlSpec, data: [UInt8]? = nil) throws -> [UInt8] {
        guard let unit = unitIDs[spec.unit] else { throw UVCError.request(kIOReturnUnsupported) }
        return try queue.sync {
            var buffer = data ?? [UInt8](repeating: 0, count: req == .getInfo ? 1 : spec.size)
            let length = buffer.count
            let result: IOReturn = buffer.withUnsafeMutableBytes { ptr in
                var request = IOUSBDevRequest(
                    bmRequestType: req == .setCur ? 0x21 : 0xA1,
                    bRequest: req.rawValue,
                    wValue: UInt16(spec.selector) << 8,
                    wIndex: UInt16(unit) << 8 | UInt16(interfaceNumber),
                    wLength: UInt16(length),
                    pData: ptr.baseAddress,
                    wLenDone: 0)
                return deviceInterface.pointee.pointee.DeviceRequest(deviceInterface, &request)
            }
            guard result == kIOReturnSuccess else { throw UVCError.request(result) }
            return buffer
        }
    }

    static func decode(_ b: ArraySlice<UInt8>, signed: Bool) -> Int {
        var v = 0
        for (i, x) in b.enumerated() { v |= Int(x) << (8 * i) }
        if signed {
            let bits = b.count * 8
            if v >= 1 << (bits - 1) { v -= 1 << bits }
        }
        return v
    }

    static func encode(_ value: Int, size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// Reads the value(s) of a control. Pan/tilt yields two values.
    func read(_ spec: UVCControlSpec) throws -> [Int] {
        try split(try transfer(.getCur, spec), spec)
    }

    private func split(_ b: [UInt8], _ spec: UVCControlSpec) -> [Int] {
        if spec.key == "panTilt" {
            return [Self.decode(b[0..<4], signed: true), Self.decode(b[4..<8], signed: true)]
        }
        return [Self.decode(b[...], signed: spec.signed)]
    }

    func write(_ spec: UVCControlSpec, _ values: [Int]) throws {
        let data: [UInt8]
        if spec.key == "panTilt" {
            data = Self.encode(values[0], size: 4) + Self.encode(values.count > 1 ? values[1] : 0, size: 4)
        } else {
            data = Self.encode(values[0], size: spec.size)
        }
        _ = try transfer(.setCur, spec, data: data)
    }

    /// Range for each value of a control. Mode-style controls (aeMode, *Auto) don't support GET_MIN/MAX.
    func ranges(_ spec: UVCControlSpec) -> [UVCRange]? {
        guard let def = try? split(transfer(.getDef, spec), spec) else { return nil }
        let mins = (try? split(transfer(.getMin, spec), spec))
        let maxs = (try? split(transfer(.getMax, spec), spec))
        let res = (try? split(transfer(.getRes, spec), spec))
        return def.indices.map { i in
            UVCRange(min: mins?[i] ?? 0, max: maxs?[i] ?? 1, step: max(1, res?[i] ?? 1), defaultValue: def[i])
        }
    }

    /// Supported auto-exposure mode bitmap (GET_RES on AE mode returns the mask).
    func aeModeMask() -> Int {
        guard let spec = UVCControlSpec.all.first(where: { $0.key == "aeMode" }),
              let r = try? transfer(.getRes, spec) else { return 0 }
        return Int(r[0])
    }
}
