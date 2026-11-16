import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("Home", systemImage: "square.grid.2x2").tag(SidebarItem.home)
                }
                Section("Devices") {
                    ForEach(model.speakers) { s in
                        Label(s.shortName, systemImage: "hifispeaker.2.fill").tag(SidebarItem.speaker(s.id))
                    }
                    ForEach(model.cameras) { c in
                        Label(c.shortName, systemImage: "web.camera.fill").tag(SidebarItem.camera(c.id))
                    }
                    if model.speakers.isEmpty && model.cameras.isEmpty {
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
                Section("Library") {
                    Label("Profiles", systemImage: "person.crop.rectangle.stack").tag(SidebarItem.profiles)
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                detail
                if let banner = model.banner {
                    Text(banner)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .padding(.bottom, 20)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.banner = nil }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ProfileMenu() }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .home {
        case .home:
            HomeView()
        case .speaker(let id):
            if let s = model.speakers.first(where: { $0.id == id }) { SpeakerView(speaker: s).id(s.id) } else { HomeView() }
        case .camera(let id):
            if let c = model.cameras.first(where: { $0.id == id }) { CameraView(camera: c).id(c.id) } else { HomeView() }
        case .profiles:
            ProfilesView()
        case .settings:
            SettingsView()
        }
    }
}

struct ProfileMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(model.library.profiles) { p in
                Button {
                    model.activate(p.id)
                } label: {
                    if p.id == model.library.activeProfileID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("Manage Profiles…") { model.selection = .profiles }
        } label: {
            Label(model.activeProfile.name, systemImage: "person.crop.rectangle.stack")
        }
        .help("Active profile")
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Devices").font(.system(size: 28, weight: .bold))
                    Spacer()
                    Text("Active profile: \(model.activeProfile.name)").foregroundStyle(Theme.secondaryText)
                }
                if model.speakers.isEmpty && model.cameras.isEmpty {
                    Card {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Looking for Logitech devices… Connect a device over USB.")
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                ForEach(model.speakers) { s in
                    DeviceCard(title: s.shortName, subtitle: s.name, detail: speakerSummary(s)) {
                        SpeakerArt(zoneColors: s.settings.zones.map { $0.effect == .off ? .clear : $0.color.color }, size: 100)
                    } action: { model.selection = .speaker(s.id) }
                }
                ForEach(model.cameras) { c in
                    DeviceCard(title: c.shortName, subtitle: c.name, detail: cameraSummary(c)) {
                        CameraArt(size: 70)
                    } action: { model.selection = .camera(c.id) }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private func speakerSummary(_ s: SpeakerController) -> String {
        var parts: [String] = []
        if let z = s.settings.zones.first, s.supportsLighting {
            parts.append(s.settings.syncZones ? "\(z.effect.title) lighting" : "\(s.zones.count) zones")
        }
        if s.hasBrightness { parts.append("Brightness \(s.settings.brightness)%") }
        if let sub = s.settings.subwoofer, s.hasSubwoofer { parts.append("Sub \(sub)") }
        if s.equalizer != nil { parts.append("EQ: \(s.settings.equalizerPreset ?? "Custom")") }
        return parts.joined(separator: " · ")
    }

    private func cameraSummary(_ c: CameraController) -> String {
        var parts: [String] = []
        if let z = c.settings.values["zoom"] { parts.append(String(format: "Zoom %.1f×", Double(z) / 100)) }
        parts.append(c.autoFocus ? "Autofocus" : "Manual focus")
        parts.append(c.autoExposure ? "Auto exposure" : "Manual exposure")
        return parts.joined(separator: " · ")
    }
}

struct DeviceCard<Art: View>: View {
    let title: String
    let subtitle: String
    let detail: String
    @ViewBuilder var art: Art
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 28) {
                art.frame(width: 220, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
