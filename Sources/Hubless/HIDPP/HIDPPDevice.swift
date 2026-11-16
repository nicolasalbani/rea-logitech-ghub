import Foundation
import IOKit.hid

/// HID++ 2.0 feature IDs used by this app (recovered by enumerating the device's feature table).
enum HIDPPFeature: UInt16 {
    case root = 0x0000
    case featureSet = 0x0001
    case firmwareInfo = 0x0003
    case deviceName = 0x0005
    case colorLEDEffects = 0x8070
    case brightness = 0x8040
    case equalizer = 0x8310
    /// G560 subwoofer level (0...100). fn0 reads, fn1 writes; verified against G HUB's "Subwoofer level".
    case subwoofer = 0x8305
}

enum HIDPPError: Error, CustomStringConvertible {
    case writeFailed(IOReturn)
    case timeout
    case deviceError(code: UInt8)
    case featureMissing(UInt16)

    var description: String {
        switch self {
        case .writeFailed(let r): return "HID write failed (0x\(String(UInt32(bitPattern: r), radix: 16)))"
        case .timeout: return "Device did not answer in time"
        case .deviceError(let c): return "Device rejected request (HID++ error \(c)\(c == 2 ? ": invalid argument" : ""))"
        case .featureMissing(let f): return "Feature 0x\(String(f, radix: 16)) not supported"
        }
    }
}

/// A Logitech HID++ 2.0 device reached through a vendor HID interface (long report 0x11, 20 bytes).
///
/// Requests are serialized on a private queue; replies are delivered by an input-report callback
/// scheduled on the shared HID run-loop thread.
final class HIDPPDevice: @unchecked Sendable {
    static let longReportID: UInt8 = 0x11
    static let reportLength = 20
    private static let softwareID: UInt8 = 0x0A

    let device: IOHIDDevice
    private let queue = DispatchQueue(label: "hidpp.requests")
    private let replyLock = NSLock()
    private var pendingMatch: (([UInt8]) -> Bool)?
    private var pendingReply: [UInt8]?
    private let replySignal = DispatchSemaphore(value: 0)
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var featureIndex: [UInt16: UInt8] = [:]

    init(device: IOHIDDevice) {
        self.device = device
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue()
            me.handleInput(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, nil, nil)
        inputBuffer.deallocate()
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func handleInput(_ report: [UInt8]) {
        guard report.count >= 4, report[0] == Self.longReportID || report[0] == 0x10 else { return }
        replyLock.lock()
        if let match = pendingMatch, match(report) {
            pendingReply = report
            pendingMatch = nil
            replyLock.unlock()
            replySignal.signal()
        } else {
            replyLock.unlock()
        }
    }

    /// Sends one HID++ request and waits for the matching reply. Returns the 16 parameter bytes.
    @discardableResult
    func request(featureIndex index: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        try queue.sync {
            var packet = [UInt8](repeating: 0, count: Self.reportLength)
            packet[0] = Self.longReportID
            packet[1] = 0xFF
            packet[2] = index
            packet[3] = (function << 4) | Self.softwareID
            for (i, p) in params.prefix(16).enumerated() { packet[4 + i] = p }

            replyLock.lock()
            pendingReply = nil
            pendingMatch = { r in
                // Success reply echoes feature index + function/swid; error reply is 0xFF <index> <fn|swid> <code>.
                (r[2] == index && r[3] == packet[3]) || (r[2] == 0xFF && r.count > 5 && r[3] == index && r[4] == packet[3])
            }
            replyLock.unlock()

            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReportID), packet, packet.count)
            guard result == kIOReturnSuccess else {
                replyLock.lock(); pendingMatch = nil; replyLock.unlock()
                throw HIDPPError.writeFailed(result)
            }
            if replySignal.wait(timeout: .now() + timeout) == .timedOut {
                replyLock.lock(); pendingMatch = nil; replyLock.unlock()
                throw HIDPPError.timeout
            }
            replyLock.lock(); let reply = pendingReply ?? []; replyLock.unlock()
            if reply[2] == 0xFF { throw HIDPPError.deviceError(code: reply[5]) }
            return Array(reply[4..<min(reply.count, 20)])
        }
    }

    /// Resolves a feature ID to its index through the root feature (cached).
    func index(of feature: HIDPPFeature) throws -> UInt8 {
        if let cached = featureIndex[feature.rawValue] { return cached }
        let r = try request(featureIndex: 0, function: 0, params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)])
        guard r[0] != 0 || feature == .root else { throw HIDPPError.featureMissing(feature.rawValue) }
        featureIndex[feature.rawValue] = r[0]
        return r[0]
    }

    func supports(_ feature: HIDPPFeature) -> Bool {
        (try? index(of: feature)) != nil
    }

    func call(_ feature: HIDPPFeature, _ function: UInt8, _ params: [UInt8] = []) throws -> [UInt8] {
        try request(featureIndex: index(of: feature), function: function, params: params)
    }

    /// All feature IDs the device exposes (feature 0x0001).
    func featureTable() throws -> [UInt16] {
        let count = try call(.featureSet, 0)[0]
        return try (0...count).map { i in
            let r = try call(.featureSet, 1, [i])
            return UInt16(r[0]) << 8 | UInt16(r[1])
        }
    }

    func deviceName() throws -> String {
        let length = Int(try call(.deviceName, 0)[0])
        var name = [UInt8]()
        while name.count < length {
            let chunk = try call(.deviceName, 1, [UInt8(name.count)])
            let part = chunk.prefix(min(16, length - name.count))
            if part.isEmpty { break }
            name.append(contentsOf: part)
        }
        return String(bytes: name.filter { $0 != 0 }, encoding: .utf8) ?? "Logitech device"
    }

    func firmwareVersion() throws -> String {
        let r = try call(.firmwareInfo, 1, [0])
        let prefix = String(bytes: r[1...3], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = UInt16(r[6]) << 8 | UInt16(r[7])
        return String(format: "%@ %02x.%02x.B%04X", prefix, r[4], r[5], build)
    }
}
