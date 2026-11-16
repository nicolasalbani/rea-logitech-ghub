import Foundation

/// Lighting effects of HID++ feature 0x8070 (Color LED Effects) that this app drives.
/// IDs are the device-reported effect IDs; parameter layouts were verified by read-back on a G560.
enum LightEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, fixed, cycle, breathing
    /// An effect the device offers that this app doesn't model (e.g. G560 effect 0x0007).
    /// Its raw ID and parameters are preserved so the app never destroys it.
    case onboard

    var id: String { rawValue }

    var effectID: UInt16 {
        switch self {
        case .off: 0x0000
        case .fixed: 0x0001
        case .cycle: 0x0003
        case .breathing: 0x000A
        case .onboard: 0xFFFF
        }
    }

    init?(effectID: UInt16) {
        guard let match = Self.allCases.first(where: { $0.effectID == effectID && $0 != .onboard }) else { return nil }
        self = match
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .fixed: "Fixed"
        case .cycle: "Color Cycle"
        case .breathing: "Breathing"
        case .onboard: "Onboard"
        }
    }

    var usesColor: Bool { self == .fixed || self == .breathing }
    var usesSpeed: Bool { self == .cycle || self == .breathing }
}

struct RGB: Codable, Hashable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let white = RGB(r: 255, g: 255, b: 255)
    static let logiBlue = RGB(r: 0x00, g: 0xB4, b: 0xFF)

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

struct ZoneLighting: Codable, Hashable, Sendable {
    var effect: LightEffect = .fixed
    var color: RGB = .logiBlue
    /// Effect period in milliseconds (lower = faster).
    var periodMs: Int = 5000
    /// Effect intensity 1...100.
    var intensity: Int = 100
    /// For `.onboard`: the device effect ID and its raw 10 parameter bytes.
    var rawEffectID: UInt16?
    var rawParams: [UInt8]?

    static let periodRange = 1000...20000

    /// Encodes the 10 effect-parameter bytes of setZoneEffect.
    func parameterBytes() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 10)
        let period = UInt16(clamping: periodMs)
        let level = UInt8(clamping: max(1, min(100, intensity)))
        switch effect {
        case .off:
            break
        case .onboard:
            if let raw = rawParams, raw.count == 10 { p = raw }
        case .fixed:
            p[0] = color.r; p[1] = color.g; p[2] = color.b
            p[3] = 0 // ramp: device default
        case .cycle:
            p[5] = UInt8(period >> 8); p[6] = UInt8(period & 0xFF)
            p[7] = level
        case .breathing:
            p[0] = color.r; p[1] = color.g; p[2] = color.b
            p[3] = UInt8(period >> 8); p[4] = UInt8(period & 0xFF)
            p[5] = 0 // waveform: device default
            p[6] = level
        }
        return p
    }

    /// Decodes getZoneEffect parameter bytes back into a setting.
    static func decode(effect: LightEffect, params p: [UInt8]) -> ZoneLighting {
        var z = ZoneLighting()
        z.effect = effect
        guard p.count >= 10 else { return z }
        switch effect {
        case .off:
            break
        case .onboard:
            z.rawParams = Array(p.prefix(10))
        case .fixed:
            z.color = RGB(r: p[0], g: p[1], b: p[2])
        case .cycle:
            z.periodMs = Int(UInt16(p[5]) << 8 | UInt16(p[6]))
            z.intensity = Int(p[7])
        case .breathing:
            z.color = RGB(r: p[0], g: p[1], b: p[2])
            z.periodMs = Int(UInt16(p[3]) << 8 | UInt16(p[4]))
            z.intensity = Int(p[6])
        }
        if !periodRange.contains(z.periodMs) { z.periodMs = 5000 }
        if !(1...100).contains(z.intensity) { z.intensity = 100 }
        return z
    }
}

struct LightingZoneInfo: Hashable, Sendable {
    var index: UInt8
    var location: UInt16
    /// effect ID -> device effect index for this zone
    var effects: [UInt16: UInt8]

    /// Device effect IDs not modelled by `LightEffect` (offered as "Onboard").
    var onboardEffectIDs: [UInt16] {
        effects.keys.filter { LightEffect(effectID: $0) == nil }.sorted()
    }

    var supportedEffects: [LightEffect] {
        LightEffect.allCases.filter { $0 == .onboard ? !onboardEffectIDs.isEmpty : effects[$0.effectID] != nil }
    }

    /// Device effect index for a setting (onboard effects use their preserved raw ID).
    func effectIndex(for setting: ZoneLighting) -> UInt8? {
        if setting.effect == .onboard {
            return effects[setting.rawEffectID ?? onboardEffectIDs.first ?? 0xFFFF]
        }
        return effects[setting.effect.effectID]
    }
}

struct EqualizerInfo: Hashable, Sendable {
    var frequencies: [Int]
    var minGain: Int
    var maxGain: Int
}

/// High-level operations on top of HIDPPDevice for lighting/audio features.
extension HIDPPDevice {
    func lightingZones() throws -> [LightingZoneInfo] {
        let info = try call(.colorLEDEffects, 0)
        let zoneCount = info[0]
        return try (0..<zoneCount).map { zone in
            let zi = try call(.colorLEDEffects, 1, [zone])
            let location = UInt16(zi[1]) << 8 | UInt16(zi[2])
            let effectCount = zi[3]
            var effects: [UInt16: UInt8] = [:]
            for e in 0..<effectCount {
                let ei = try call(.colorLEDEffects, 2, [zone, e])
                effects[UInt16(ei[2]) << 8 | UInt16(ei[3])] = e
            }
            return LightingZoneInfo(index: zone, location: location, effects: effects)
        }
    }

    func readZone(_ zone: LightingZoneInfo) throws -> ZoneLighting? {
        let r = try call(.colorLEDEffects, 0x0E, [zone.index])
        let effectIndex = r[1]
        guard let id = zone.effects.first(where: { $0.value == effectIndex })?.key else { return nil }
        guard let effect = LightEffect(effectID: id) else {
            var z = ZoneLighting.decode(effect: .onboard, params: Array(r[2..<12]))
            z.rawEffectID = id
            return z
        }
        return ZoneLighting.decode(effect: effect, params: Array(r[2..<12]))
    }

    func writeZone(_ zone: LightingZoneInfo, _ setting: ZoneLighting, persist: Bool = true) throws {
        guard let effectIndex = zone.effectIndex(for: setting) else {
            throw HIDPPError.deviceError(code: 2)
        }
        try call(.colorLEDEffects, 3, [zone.index, effectIndex] + setting.parameterBytes() + [persist ? 1 : 0])
    }

    // MARK: Brightness (0x8040)

    func readBrightness() throws -> Int {
        let r = try call(.brightness, 1)
        return Int(UInt16(r[0]) << 8 | UInt16(r[1]))
    }

    func writeBrightness(_ value: Int) throws {
        let v = UInt16(clamping: value)
        try call(.brightness, 2, [UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    // MARK: Subwoofer level (0x8305)

    func readSubwoofer() throws -> Int {
        Int(try call(.subwoofer, 0)[0])
    }

    func writeSubwoofer(_ value: Int) throws {
        try call(.subwoofer, 1, [UInt8(max(0, min(100, value)))])
    }

    // MARK: Equalizer (0x8310)

    func equalizerInfo() throws -> EqualizerInfo {
        let info = try call(.equalizer, 0)
        let count = Int(info[0])
        let dbRange = Int(info[1])
        var dbMin = Int(Int8(bitPattern: info[3]))
        var dbMax = Int(Int8(bitPattern: info[4]))
        if dbMin == 0 { dbMin = -dbRange }
        if dbMax == 0 { dbMax = dbRange }
        var freqs: [Int] = []
        var offset = 0
        while freqs.count < count {
            let r = try call(.equalizer, 1, [UInt8(offset)])
            // reply: [startIndex, f0hi, f0lo, f1hi, ...] — up to 7 per call
            for b in 0..<7 where freqs.count < count {
                freqs.append(Int(UInt16(r[1 + 2 * b]) << 8 | UInt16(r[2 + 2 * b])))
            }
            offset += 7
        }
        // The G560 firmware rejects the reported bounds themselves (-20 / +6 → INVALID_ARGUMENT),
        // accepting only values strictly inside them; verified by write/read-back.
        return EqualizerInfo(frequencies: freqs, minGain: dbMin + 1, maxGain: dbMax - 1)
    }

    func readEqualizer(bands: Int) throws -> [Int] {
        let r = try call(.equalizer, 2, [0])
        return (0..<bands).map { Int(Int8(bitPattern: r[$0])) }
    }

    func writeEqualizer(_ gains: [Int]) throws {
        try call(.equalizer, 3, [0x02] + gains.map { UInt8(bitPattern: Int8(clamping: $0)) })
    }
}
