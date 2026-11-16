import SwiftUI

struct SpeakerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var speaker: SpeakerController
    @AppStorage("speakerTab") private var tab: Tab = .lighting
    @State private var selectedZone = 0
    @State private var renamingZone: Int?
    @State private var zoneNameDraft = ""

    enum Tab: String, CaseIterable, Codable { case lighting = "Lighting", sound = "Sound", info = "Device Info" }

    private var availableTabs: [Tab] {
        Tab.allCases.filter { t in
            switch t {
            case .lighting: speaker.supportsLighting || speaker.hasBrightness
            case .sound: speaker.equalizer != nil || speaker.hasSubwoofer || speaker.volume.isAvailable
            case .info: true
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Picker("", selection: $tab) {
                    ForEach(availableTabs, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                if let err = speaker.lastError { ErrorBanner(message: err) }

                switch tab {
                case .lighting: lighting
                case .sound:
                    VStack(alignment: .leading, spacing: 16) {
                        SpeakerLevelsCard(speaker: speaker, volume: speaker.volume)
                        equalizer
                    }
                case .info: info
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .onAppear { if !availableTabs.contains(tab) { tab = availableTabs.first ?? .info } }
        .sheet(item: Binding(get: { renamingZone.map { RenameTarget(id: $0) } }, set: { renamingZone = $0?.id })) { target in
            RenameSheet(title: "Rename zone", text: $zoneNameDraft) {
                model.setZoneName(speaker, target.id, zoneNameDraft)
                renamingZone = nil
            } onCancel: { renamingZone = nil }
        }
    }

    private var zoneColors: [Color] {
        speaker.settings.zones.map { z in
            switch z.effect {
            case .off: Color.clear
            case .cycle, .onboard: Color(hue: 0.55, saturation: 0.8, brightness: 1)
            default: z.color.color.opacity(max(0.15, Double(speaker.settings.brightness) / 100))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            SpeakerArt(zoneColors: zoneColors, size: 130)
                .frame(width: 260)
            VStack(alignment: .leading, spacing: 6) {
                Text(speaker.shortName).font(.system(size: 30, weight: .bold))
                Text(speaker.name).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 6) {
                    StatusDot(ok: speaker.isReady)
                    Text("Connected · Profile: \(model.activeProfile.name)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
        }
    }

    // MARK: Lighting

    private var lighting: some View {
        VStack(alignment: .leading, spacing: 16) {
            if speaker.hasBrightness {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Brightness", subtitle: "Applies to all zones")
                        Picker("", selection: Binding(
                            get: { speaker.settings.brightness },
                            set: { v in model.update(speaker) { $0.brightness = v } })) {
                            ForEach(speaker.brightnessLevels, id: \.self) { Text($0 == 0 ? "Off" : "\($0)%").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }
            }

            if speaker.supportsLighting {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            SectionTitle(title: "Lighting Zones", subtitle: "Pick a zone, then choose an effect")
                            Spacer()
                            Toggle("Sync all zones", isOn: Binding(
                                get: { speaker.settings.syncZones },
                                set: { on in model.update(speaker) { s in
                                    s.syncZones = on
                                    if on { let z = s.zones[min(selectedZone, s.zones.count - 1)]; s.zones = s.zones.map { _ in z } }
                                } }))
                            .toggleStyle(.switch)
                        }
                        if !speaker.settings.syncZones {
                            zonePicker
                        }
                        Divider().overlay(Theme.stroke)
                        zoneEditor(index: speaker.settings.syncZones ? 0 : min(selectedZone, speaker.zones.count - 1))
                    }
                }
            }
        }
    }

    private var zonePicker: some View {
        HStack(spacing: 10) {
            ForEach(speaker.zones.indices, id: \.self) { i in
                let z = speaker.settings.zones[i]
                Button {
                    selectedZone = i
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(z.effect == .off ? Color.gray.opacity(0.3) : (z.effect == .cycle ? Color.purple : z.color.color))
                            .frame(width: 12, height: 12)
                        Text(model.zoneName(speaker, i)).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selectedZone == i ? Theme.accent.opacity(0.25) : Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedZone == i ? Theme.accent : .clear))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename…") { zoneNameDraft = model.zoneName(speaker, i); renamingZone = i }
                    Button("Identify") { speaker.identify(zone: i) }
                }
            }
        }
    }

    @ViewBuilder
    private func zoneEditor(index: Int) -> some View {
        let zone = speaker.settings.zones[index]
        let supported = speaker.zones[index].supportedEffects
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(speaker.settings.syncZones ? "All zones" : model.zoneName(speaker, index))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !speaker.settings.syncZones {
                    Button { zoneNameDraft = model.zoneName(speaker, index); renamingZone = index } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
                Button { identifyCurrent(index) } label: { Label("Identify", systemImage: "lightbulb.max") }
                    .help("Flash this zone so you can see which light it is")
            }

            HStack(spacing: 10) {
                ForEach(supported) { effect in
                    let active = zone.effect == effect
                    Button { setZone(index) { z in
                        z.effect = effect
                        if effect == .onboard && z.rawEffectID == nil {
                            // Default parameters as reported by the G560 for its onboard effect 0x0007.
                            z.rawEffectID = speaker.zones[index].onboardEffectIDs.first
                            z.rawParams = [0x01, 0, 0, 0, 0, 0x13, 0x88, 0, 0, 0]
                        }
                    } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: icon(effect)).font(.system(size: 20))
                            Text(effect.title).font(.system(size: 11, weight: .semibold))
                        }
                        .frame(width: 96, height: 64)
                        .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.accent.opacity(0.22) : Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Theme.accent : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if zone.effect == .onboard {
                Text("A built-in effect of the device (ID 0x\(String(format: "%04X", zone.rawEffectID ?? 0))). Hubless preserves its on-device parameters.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }

            if zone.effect.usesColor {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color").font(.system(size: 13, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach(Self.swatches, id: \.self) { c in
                            Button { setZone(index) { $0.color = c } } label: {
                                Circle().fill(c.color).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Color.white, lineWidth: zone.color == c ? 2 : 0))
                            }.buttonStyle(.plain)
                        }
                        Divider().frame(height: 22)
                        ColorPicker("", selection: Binding(
                            get: { zone.color.color },
                            set: { c in setZone(index) { $0.color = RGB(c) } }), supportsOpacity: false)
                        .labelsHidden()
                        Text(zone.color.hex).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            if zone.effect.usesSpeed {
                ValueSlider(
                    title: "Speed",
                    value: Binding(get: { 21000 - zone.periodMs }, set: { v in setZone(index) { $0.periodMs = 21000 - v } }),
                    range: 1000...20000, step: 500,
                    format: { String(format: "%.1fs cycle", Double(21000 - $0) / 1000) })
                ValueSlider(
                    title: "Intensity",
                    value: Binding(get: { zone.intensity }, set: { v in setZone(index) { $0.intensity = v } }),
                    range: 1...100, format: { "\($0)%" })
            }
        }
    }

    private func identifyCurrent(_ index: Int) {
        if speaker.settings.syncZones {
            for i in speaker.zones.indices { speaker.identify(zone: i) }
        } else {
            speaker.identify(zone: index)
        }
    }

    private func setZone(_ index: Int, _ change: @escaping (inout ZoneLighting) -> Void) {
        model.update(speaker) { s in
            if s.syncZones {
                var z = s.zones[0]
                change(&z)
                s.zones = s.zones.map { _ in z }
            } else {
                change(&s.zones[index])
            }
        }
    }

    private func icon(_ e: LightEffect) -> String {
        switch e {
        case .off: "power"
        case .fixed: "circle.fill"
        case .cycle: "rainbow"
        case .breathing: "wind"
        case .onboard: "sparkles"
        }
    }

    static let swatches: [RGB] = [
        RGB(r: 0x00, g: 0xB4, b: 0xFF), RGB(r: 0x8D, g: 0x40, b: 0xFF), RGB(r: 0xFF, g: 0x2D, b: 0x55),
        RGB(r: 0xFF, g: 0x8A, b: 0x00), RGB(r: 0xFF, g: 0xE0, b: 0x00), RGB(r: 0x30, g: 0xFF, b: 0x6A),
        RGB(r: 0x00, g: 0xFF, b: 0xE0), .white,
    ]

    // MARK: Equalizer

    @ViewBuilder
    private var equalizer: some View {
        if let eq = speaker.equalizer {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionTitle(title: "Equalizer", subtitle: "\(eq.frequencies.count) bands · \(eq.minGain) to +\(eq.maxGain) dB (hardware limits)")
                        Spacer()
                        Menu(speaker.settings.equalizerPreset ?? "Custom") {
                            ForEach(EqualizerPreset.allCases) { p in
                                Button(p.rawValue) {
                                    model.update(speaker) { s in
                                        s.equalizer = p.gains(bands: eq.frequencies.count, range: eq.minGain...eq.maxGain)
                                        s.equalizerPreset = p.rawValue
                                    }
                                }
                            }
                        }
                        .frame(width: 150)
                        Button("Reset") {
                            model.update(speaker) { s in
                                s.equalizer = Array(repeating: 0, count: eq.frequencies.count)
                                s.equalizerPreset = EqualizerPreset.flat.rawValue
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: 0) {
                        VStack(spacing: 8) {
                            Text(" ").font(.system(size: 11, design: .monospaced))
                            GeometryReader { geo in
                                let span = CGFloat(eq.maxGain - eq.minGain)
                                let zeroY = geo.size.height * CGFloat(eq.maxGain) / span
                                ZStack(alignment: .topTrailing) {
                                    Text("+\(eq.maxGain) dB").offset(y: -6)
                                    Text("0").offset(y: zeroY - 6)
                                    Text("\(eq.minGain)").offset(y: geo.size.height - 6)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .frame(width: 44, height: 200)
                            Text(" ").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.caption2).foregroundStyle(Theme.secondaryText).padding(.trailing, 8)
                        ForEach(eq.frequencies.indices, id: \.self) { i in
                            VStack(spacing: 8) {
                                Text(signed(speaker.settings.equalizer[safe: i] ?? 0))
                                    .font(.system(size: 11, design: .monospaced))
                                VerticalSlider(
                                    value: Binding(
                                        get: { speaker.settings.equalizer[safe: i] ?? 0 },
                                        set: { v in model.update(speaker) { s in
                                            s.equalizer[i] = v
                                            s.equalizerPreset = nil
                                        } }),
                                    range: eq.minGain...eq.maxGain, height: 200)
                                Text(freqLabel(eq.frequencies[i])).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
    private func freqLabel(_ f: Int) -> String { f >= 1000 ? "\(f / 1000)k" : "\(f)" }

    // MARK: Info

    private var info: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Device")
                infoRow("Name", speaker.name)
                infoRow("Model", speaker.modelKey.uppercased())
                infoRow("Firmware", speaker.firmware.isEmpty ? "—" : speaker.firmware)
                infoRow("Protocol", "HID++ 2.0 (USB)")
                infoRow("Lighting zones", speaker.zones.isEmpty ? "—" : "\(speaker.zones.count)")
                infoRow("Subwoofer level", speaker.hasSubwoofer ? "Supported (HID++ 0x8305)" : "—")
                infoRow("Equalizer", speaker.equalizer.map { "\($0.frequencies.count) bands" } ?? "—")
                HStack {
                    Spacer()
                    Button("Re-apply profile to device") { speaker.apply(model.speakerSettings(for: speaker), force: true) }
                }
            }
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.secondaryText).frame(width: 140, alignment: .leading)
            Text(v).textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 13))
    }
}

/// System volume (CoreAudio, live) and subwoofer level (HID++, stored in the profile).
struct SpeakerLevelsCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var speaker: SpeakerController
    @ObservedObject var volume: OutputVolume

    var body: some View {
        if volume.isAvailable || speaker.hasSubwoofer {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Speakers")
                    if volume.isAvailable {
                        HStack(alignment: .bottom, spacing: 12) {
                            ValueSlider(
                                title: "System volume",
                                value: Binding(get: { Int((volume.level * 100).rounded()) }, set: { volume.setLevel(Double($0) / 100) }),
                                range: 0...100,
                                format: { "\($0)" },
                                disabled: volume.muted)
                            if volume.supportsMute {
                                Button { volume.setMuted(!volume.muted) } label: {
                                    Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                                }
                                .help(volume.muted ? "Unmute" : "Mute")
                            }
                        }
                        Text(volume.isDefaultOutput
                             ? "Same as the macOS volume. It isn't stored in profiles."
                             : "\(speaker.shortName) is not the current macOS output device. Set it in System Settings › Sound to hear it.")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    if speaker.hasSubwoofer {
                        ValueSlider(
                            title: "Subwoofer level",
                            value: Binding(
                                get: { speaker.settings.subwoofer ?? 50 },
                                set: { v in model.update(speaker) { $0.subwoofer = v } }),
                            range: 0...100,
                            format: { "\($0)" })
                    }
                }
            }
        }
    }
}

struct RenameTarget: Identifiable { let id: Int }

struct RenameSheet: View {
    let title: String
    @Binding var text: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 280).onSubmit(onSave)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
