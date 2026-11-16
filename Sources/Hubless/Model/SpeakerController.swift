import Foundation
import IOKit.hid

/// Live state and settings writer for a HID++ lighting/audio device such as the G560.
@MainActor
final class SpeakerController: ObservableObject, Identifiable {
    nonisolated let id: String
    let hidDevice: IOHIDDevice
    let transport: HIDPPDevice

    @Published private(set) var name: String = "Logitech Device"
    @Published private(set) var firmware: String = ""
    @Published private(set) var zones: [LightingZoneInfo] = []
    @Published private(set) var equalizer: EqualizerInfo?
    @Published private(set) var hasBrightness = false
    @Published private(set) var hasSubwoofer = false
    /// macOS output volume of the matching USB audio device (live, not stored in profiles).
    let volume: OutputVolume
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    @Published var settings = SpeakerSettings()

    let modelKey: String
    /// Brightness levels the G560 firmware accepts (0x8040 reports 4 steps; 75 is rejected).
    let brightnessLevels = [0, 25, 50, 100]

    private let io = DispatchQueue(label: "speaker.io")
    private var applied: SpeakerSettings?
    private var pending: SpeakerSettings?
    private var writeScheduled = false
    /// Level read from the device at connect; fills profiles that predate the subwoofer setting.
    private var deviceSubwoofer: Int?

    init(device: IOHIDDevice) {
        hidDevice = device
        transport = HIDPPDevice(device: device)
        let vid = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        modelKey = String(format: "%04x:%04x", vid, pid)
        id = "hid-\(modelKey)-\(location)"
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech Device"
        volume = OutputVolume(deviceName: product)
        name = product
    }

    var supportsLighting: Bool { !zones.isEmpty }
    var shortName: String {
        name.replacingOccurrences(of: " Gaming Speaker", with: "").replacingOccurrences(of: "Logitech ", with: "")
    }

    struct Snapshot: Sendable {
        var name: String
        var firmware: String
        var zones: [LightingZoneInfo]
        var equalizer: EqualizerInfo?
        var hasBrightness: Bool
        var hasSubwoofer: Bool
        var current: SpeakerSettings
    }

    /// Enumerates features and reads the device's current state (off the main thread).
    func probe() async throws -> Snapshot {
        let t = transport
        return try await withCheckedThrowingContinuation { cont in
            io.async {
                do {
                    _ = try t.request(featureIndex: 0, function: 1, params: [0, 0, 0x5A]) // ping
                    let name = (try? t.deviceName()) ?? "Logitech Device"
                    let fw = (try? t.firmwareVersion()) ?? ""
                    var current = SpeakerSettings()
                    var zones: [LightingZoneInfo] = []
                    if t.supports(.colorLEDEffects) {
                        zones = try t.lightingZones()
                        current.zones = zones.map { z in
                            do { return try t.readZone(z) ?? ZoneLighting() } catch {
                                NSLog("readZone %d failed: %@", z.index, String(describing: error)); return ZoneLighting() }
                        }
                        current.syncZones = Set(current.zones).count <= 1
                    }
                    var eq: EqualizerInfo?
                    if t.supports(.equalizer) {
                        eq = try t.equalizerInfo()
                        current.equalizer = try t.readEqualizer(bands: eq!.frequencies.count)
                        current.equalizerPreset = EqualizerPreset.allCases.first {
                            $0.gains(bands: eq!.frequencies.count, range: eq!.minGain...eq!.maxGain) == current.equalizer
                        }?.rawValue
                    }
                    let hasBrightness = t.supports(.brightness)
                    if hasBrightness { current.brightness = (try? t.readBrightness()) ?? 100 }
                    var hasSubwoofer = false
                    if t.supports(.subwoofer), let level = try? t.readSubwoofer() {
                        hasSubwoofer = true
                        current.subwoofer = level
                    }
                    cont.resume(returning: Snapshot(name: name, firmware: fw, zones: zones, equalizer: eq,
                                                    hasBrightness: hasBrightness, hasSubwoofer: hasSubwoofer, current: current))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func adopt(_ s: Snapshot) {
        name = s.name
        firmware = s.firmware
        zones = s.zones
        equalizer = s.equalizer
        hasBrightness = s.hasBrightness
        hasSubwoofer = s.hasSubwoofer
        deviceSubwoofer = s.current.subwoofer
        applied = s.current
        isReady = true
    }

    /// Normalizes a stored setting against this device's capabilities.
    func normalized(_ s: SpeakerSettings) -> SpeakerSettings {
        var n = s
        if zones.count > 0 {
            while n.zones.count < zones.count { n.zones.append(n.zones.last ?? ZoneLighting()) }
            n.zones = Array(n.zones.prefix(zones.count))
            for (i, z) in zones.enumerated() where !z.supportedEffects.contains(n.zones[i].effect) {
                n.zones[i].effect = z.supportedEffects.first ?? .off
            }
        }
        if let eq = equalizer {
            let count = eq.frequencies.count
            while n.equalizer.count < count { n.equalizer.append(0) }
            n.equalizer = n.equalizer.prefix(count).map { min(eq.maxGain, max(eq.minGain, $0)) }
        }
        if hasSubwoofer {
            n.subwoofer = max(0, min(100, n.subwoofer ?? deviceSubwoofer ?? 50))
        }
        if !brightnessLevels.contains(n.brightness) {
            n.brightness = brightnessLevels.min { abs($0 - n.brightness) < abs($1 - n.brightness) } ?? 100
        }
        return n
    }

    /// Applies settings to hardware. Only changed parts are written unless `force` is set.
    func apply(_ newSettings: SpeakerSettings, force: Bool = false) {
        let target = normalized(newSettings)
        settings = target
        if force { applied = nil }
        pending = target
        guard !writeScheduled else { return }
        writeScheduled = true
        // Coalesce rapid UI changes (slider drags) into one write burst.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        writeScheduled = false
        guard let target = pending else { return }
        pending = nil
        let previous = applied
        applied = target
        let zones = self.zones
        let hasBrightness = self.hasBrightness
        let hasEQ = equalizer != nil
        let hasSubwoofer = self.hasSubwoofer
        let t = transport
        io.async { [weak self] in
            var errors: [String] = []
            for (i, zone) in zones.enumerated() where i < target.zones.count {
                if previous == nil || previous!.zones.count <= i || previous!.zones[i] != target.zones[i] {
                    do { try t.writeZone(zone, target.zones[i]) } catch { errors.append("Zone \(i + 1): \(error)") }
                }
            }
            if hasBrightness, previous?.brightness != target.brightness {
                do { try t.writeBrightness(target.brightness) } catch { errors.append("Brightness: \(error)") }
            }
            if hasEQ, previous?.equalizer != target.equalizer {
                do { try t.writeEqualizer(target.equalizer) } catch { errors.append("Equalizer: \(error)") }
            }
            if hasSubwoofer, let level = target.subwoofer, previous?.subwoofer != level {
                do { try t.writeSubwoofer(level) } catch { errors.append("Subwoofer: \(error)") }
            }
            let message = errors.isEmpty ? nil : errors.joined(separator: "\n")
            DispatchQueue.main.async { self?.lastError = message }
        }
    }

    /// Flashes one zone white so the user can tell which physical light it is.
    func identify(zone index: Int) {
        guard index < zones.count else { return }
        let zone = zones[index]
        let restore = settings.zones[index]
        let t = transport
        io.async {
            let flash = ZoneLighting(effect: .fixed, color: .white, periodMs: 1000, intensity: 100)
            let dark = ZoneLighting(effect: .off)
            for step in 0..<6 {
                try? t.writeZone(zone, step % 2 == 0 ? flash : dark, persist: false)
                Thread.sleep(forTimeInterval: 0.25)
            }
            try? t.writeZone(zone, restore)
        }
    }

    func disconnect() {
        transport.close()
    }
}
