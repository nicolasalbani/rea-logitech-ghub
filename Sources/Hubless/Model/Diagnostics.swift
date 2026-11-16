import Foundation

/// `Hubless --diagnose` prints what the app discovered and the active profile, then exits.
/// Useful for verifying device communication without the UI.
@MainActor
enum Diagnostics {
    static var requested: Bool { CommandLine.arguments.contains("--diagnose") }

    static func run(_ model: AppModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            var lines: [String] = ["Hubless diagnostics", "Profile store: \(model.storageURL.path)",
                                   "Active profile: \(model.activeProfile.name) (\(model.library.profiles.count) total)"]
            for s in model.speakers {
                lines.append("SPEAKER \(s.name) [\(s.modelKey)] fw \(s.firmware)")
                lines.append("  zones: \(s.zones.map { "#\($0.index) loc \($0.location) effects \($0.supportedEffects.map(\.title))" })")
                lines.append("  lighting: \(s.settings.zones.map { "\($0.effect.title) \($0.color.hex)" }) brightness \(s.settings.brightness)")
                lines.append("  subwoofer: \(s.hasSubwoofer ? String(describing: s.settings.subwoofer) : "n/a")  volume: \(s.volume.isAvailable ? String(format: "%.0f%%%@", s.volume.level * 100, s.volume.muted ? " (muted)" : "") : "n/a")")
                if let eq = s.equalizer { lines.append("  eq: \(eq.frequencies) Hz range \(eq.minGain)...\(eq.maxGain) -> \(s.settings.equalizer)") }
                if let e = s.lastError { lines.append("  ERROR: \(e)") }
            }
            for c in model.cameras {
                lines.append("CAMERA \(c.name) [\(c.modelKey)]")
                for (k, v) in c.values.sorted(by: { $0.key < $1.key }) {
                    lines.append("  \(k): \(c.settings.values[k].map(String.init) ?? "?") range \(v.range.min)...\(v.range.max) step \(v.range.step) def \(v.range.defaultValue)")
                }
                if let e = c.lastError { lines.append("  ERROR: \(e)") }
            }
            print(lines.joined(separator: "\n"))
            exit(0)
        }
    }
}

/// `Hubless --selftest`: exercises profile switching against real hardware and verifies by read-back,
/// then restores the original profile and removes the temporary one.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }

    static func run(_ model: AppModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                print(ok ? "PASS" : "FAIL", what)
                if !ok { failures += 1 }
            }
            let original = model.library.activeProfileID
            let test = model.createProfile(named: "SelfTest", copyingCurrent: true)
            model.activate(test.id)
            for s in model.speakers {
                model.update(s) { st in
                    st.syncZones = true
                    st.zones = st.zones.map { _ in ZoneLighting(effect: .breathing, color: RGB(r: 255, g: 0, b: 80), periodMs: 4000, intensity: 90) }
                    st.equalizer = EqualizerPreset.bassBoost.gains(bands: st.equalizer.count, range: -19...5)
                    st.brightness = 50
                    if s.hasSubwoofer { st.subwoofer = 40 }
                }
            }
            for c in model.cameras {
                model.update(c) { $0.values["brightness"] = 150; $0.values["zoom"] = 200; $0.values["pan"] = 3600 }
            }
            try? await Task.sleep(for: .seconds(1.5))
            for s in model.speakers {
                let t = s.transport
                let z = try? t.readZone(s.zones[0])
                check(z?.effect == .breathing && z?.color == RGB(r: 255, g: 0, b: 80) && z?.periodMs == 4000, "\(s.shortName) zone breathing read-back \(String(describing: z))")
                let eq = try? t.readEqualizer(bands: s.equalizer?.frequencies.count ?? 0)
                check(eq == s.settings.equalizer, "\(s.shortName) EQ read-back \(eq ?? [])")
                check((try? t.readBrightness()) == 50, "\(s.shortName) brightness 50")
                if s.hasSubwoofer { check((try? t.readSubwoofer()) == 40, "\(s.shortName) subwoofer 40") }
            }
            for c in model.cameras {
                let get = { (k: String) -> Int? in c.values[k].flatMap { v in (try? c.camera.read(v.spec))?[v.component] } }
                check(get("brightness") == 150, "\(c.shortName) brightness 150 (got \(String(describing: get("brightness"))))")
                check(get("zoom") == 200, "\(c.shortName) zoom 200")
                check(get("pan") == 3600, "\(c.shortName) pan 1°")
            }
            // Switch back and verify the original profile is restored on hardware.
            model.activate(original)
            try? await Task.sleep(for: .seconds(1.5))
            for s in model.speakers {
                let want = model.activeProfile.speakers[s.modelKey]!
                let z = try? s.transport.readZone(s.zones[0])
                check(z?.effect == want.zones[0].effect && z?.color == want.zones[0].color, "\(s.shortName) restored zone \(String(describing: z?.color.hex))")
                check((try? s.transport.readEqualizer(bands: want.equalizer.count)) == want.equalizer, "\(s.shortName) restored EQ")
                check((try? s.transport.readBrightness()) == want.brightness, "\(s.shortName) restored brightness")
                if s.hasSubwoofer { check((try? s.transport.readSubwoofer()) == want.subwoofer, "\(s.shortName) restored subwoofer \(String(describing: want.subwoofer))") }
            }
            for c in model.cameras {
                let want = model.activeProfile.cameras[c.modelKey]!
                for k in ["brightness", "zoom", "pan"] {
                    let v = c.values[k].flatMap { v in (try? c.camera.read(v.spec))?[v.component] }
                    check(v == want.values[k], "\(c.shortName) restored \(k)=\(String(describing: v))")
                }
            }
            model.delete(test.id)
            model.saveNow()
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

import AppKit

/// `Hubless --snapshot <dir>`: renders each page of the main window to PNG (for docs / visual checks).
@MainActor
enum Snapshot {
    static var directory: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func run(_ model: AppModel) {
        guard let dir = directory else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let savedTab = UserDefaults.standard.string(forKey: "speakerTab")
            var pages: [(String, SidebarItem, String?)] = [("home", .home, nil)]
            for s in model.speakers {
                pages += [("speaker", .speaker(s.id), SpeakerView.Tab.lighting.rawValue),
                          ("sound", .speaker(s.id), SpeakerView.Tab.sound.rawValue)]
            }
            pages += model.cameras.map { ("camera", .camera($0.id), nil) }
            pages += [("profiles", .profiles, nil), ("settings", .settings, nil)]
            defer { UserDefaults.standard.set(savedTab, forKey: "speakerTab") }
            for (name, item, tab) in pages {
                if let tab { UserDefaults.standard.set(tab, forKey: "speakerTab") }
                model.selection = item
                try? await Task.sleep(for: .seconds(1.2))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                      let view = window.contentView else { continue }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                print("wrote \(name).png")
            }
            UserDefaults.standard.set(savedTab, forKey: "speakerTab")
            exit(0)
        }
    }
}
