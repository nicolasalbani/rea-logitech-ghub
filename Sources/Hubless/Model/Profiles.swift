import Foundation

/// Persisted settings for a HID++ lighting/audio device (e.g. G560), keyed by model in a profile.
struct SpeakerSettings: Codable, Hashable, Sendable {
    var brightness: Int = 100
    var syncZones: Bool = true
    var zones: [ZoneLighting] = Array(repeating: ZoneLighting(), count: 4)
    var equalizer: [Int] = Array(repeating: 0, count: 10)
    var equalizerPreset: String? = "Flat"
    /// Subwoofer level 0...100 (nil in profiles saved before this setting existed).
    var subwoofer: Int?
}

/// Persisted camera values keyed by control key ("brightness", "zoom", "pan", "tilt", ...).
struct CameraSettings: Codable, Hashable, Sendable {
    var values: [String: Int] = [:]
}

struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var speakers: [String: SpeakerSettings] = [:]
    var cameras: [String: CameraSettings] = [:]
    var createdAt = Date()
}

/// User-facing metadata that is not part of a profile (zone names etc.).
struct Preferences: Codable, Hashable, Sendable {
    var zoneNames: [String: [String]] = [:]
    var reapplyOnCameraStart = true
}

struct ProfileLibrary: Codable, Sendable {
    var version = 1
    var profiles: [Profile]
    var activeProfileID: UUID
    var preferences = Preferences()

    static func initial() -> ProfileLibrary {
        let p = Profile(name: "Default")
        return ProfileLibrary(profiles: [p], activeProfileID: p.id)
    }
}

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case vocal = "Vocal"
    case treble = "Bright"
    case movie = "Movie"
    case night = "Night"

    var id: String { rawValue }

    /// Shapes for a 10-band (32 Hz – 16 kHz) EQ; scaled/clamped to the device range.
    var gains: [Int] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [5, 4, 3, 1, 0, 0, 0, 0, 0, 0]
        case .vocal: [-4, -3, -2, 0, 2, 3, 3, 2, 0, -1]
        case .treble: [-2, -2, -1, 0, 0, 1, 2, 3, 4, 5]
        case .movie: [4, 3, 1, 0, -1, 1, 2, 2, 1, 0]
        case .night: [-6, -5, -4, -2, 0, 1, 1, 0, -2, -3]
        }
    }

    func gains(bands: Int, range: ClosedRange<Int>) -> [Int] {
        (0..<bands).map { i in
            let v = i < gains.count ? gains[i] : 0
            return min(range.upperBound, max(range.lowerBound, v))
        }
    }
}

/// Loads/saves the profile library as JSON under Application Support. Everything stays local.
struct ProfileStorage {
    let url: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hubless", isDirectory: true).appendingPathComponent("profiles.json")
    }

    func load() -> ProfileLibrary {
        guard let data = try? Data(contentsOf: url),
              let lib = try? Self.decoder.decode(ProfileLibrary.self, from: data),
              !lib.profiles.isEmpty else { return .initial() }
        var fixed = lib
        if !fixed.profiles.contains(where: { $0.id == fixed.activeProfileID }) {
            fixed.activeProfileID = fixed.profiles[0].id
        }
        return fixed
    }

    func save(_ library: ProfileLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(library).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
