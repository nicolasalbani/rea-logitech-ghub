import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Profile?
    @State private var nameDraft = ""
    @State private var confirmDelete: Profile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Profiles").font(.system(size: 28, weight: .bold))
                        Text("A profile stores the settings of every device. Changes you make apply to the active profile and are saved locally.")
                            .foregroundStyle(Theme.secondaryText).font(.callout)
                    }
                    Spacer()
                    Menu {
                        Button("Copy of Current Profile") { start(model.createProfile(named: "\(model.activeProfile.name) Copy", copyingCurrent: true)) }
                        Button("From Device Defaults") { start(model.createProfile(named: "New Profile", copyingCurrent: false)) }
                    } label: { Label("New Profile", systemImage: "plus") }
                    .fixedSize()
                    Button { model.importProfile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                }

                ForEach(model.library.profiles) { p in
                    row(p)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .sheet(item: $renaming) { p in
            RenameSheet(title: "Rename profile", text: $nameDraft) {
                model.rename(p.id, to: nameDraft); renaming = nil
            } onCancel: { renaming = nil }
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = confirmDelete { model.delete(p.id) }; confirmDelete = nil }
        }
    }

    private func start(_ p: Profile) {
        nameDraft = p.name
        renaming = p
    }

    private func row(_ p: Profile) -> some View {
        let active = p.id == model.library.activeProfileID
        return Card(padding: 16) {
            HStack(spacing: 16) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(.system(size: 15, weight: .semibold))
                    Text(summary(p)).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if !active {
                    Button("Activate") { model.activate(p.id) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                } else {
                    Text("ACTIVE").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                }
                Menu {
                    Button("Rename…") { nameDraft = p.name; renaming = p }
                    Button("Duplicate") { model.duplicate(p.id) }
                    Button("Export…") { model.exportProfile(p.id) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = p }
                        .disabled(model.library.profiles.count <= 1)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func summary(_ p: Profile) -> String {
        var parts: [String] = []
        for (key, s) in p.speakers.sorted(by: { $0.key < $1.key }) {
            let name = model.speakers.first { $0.modelKey == key }?.shortName ?? key
            let effect = s.zones.first?.effect.title ?? "—"
            parts.append("\(name): \(s.syncZones ? effect : "per-zone"), EQ \(s.equalizerPreset ?? "Custom")")
        }
        for key in p.cameras.keys.sorted() {
            let name = model.cameras.first { $0.modelKey == key }?.shortName ?? key
            parts.append("\(name): camera settings")
        }
        return parts.isEmpty ? "No device settings yet" : parts.joined(separator: " · ")
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 28, weight: .bold))
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(title: "General")
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                            .toggleStyle(.switch)
                        Toggle("Re-apply camera settings when an app starts using the camera",
                               isOn: Binding(get: { model.reapplyOnCameraStart }, set: { model.reapplyOnCameraStart = $0 }))
                            .toggleStyle(.switch)
                        Text("Settings are also re-applied after the Mac wakes from sleep and whenever a device is reconnected.")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                        HStack {
                            Button("Re-apply Active Profile Now") { model.reapplyAll() }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Storage", subtitle: "Everything is stored on this Mac. No accounts, no cloud sync, no telemetry.")
                        HStack {
                            Text(model.storageURL.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.storageURL]) }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Profile")
        ForEach(model.library.profiles) { p in
            Toggle(p.name, isOn: Binding(get: { p.id == model.library.activeProfileID }, set: { if $0 { model.activate(p.id) } }))
        }
        Divider()
        ForEach(model.speakers) { s in Text("● \(s.shortName)") }
        ForEach(model.cameras) { c in Text("● \(c.shortName)") }
        if model.speakers.isEmpty && model.cameras.isEmpty { Text("No devices connected") }
        Divider()
        Button("Open Hubless") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Re-apply Profile") { model.reapplyAll() }
        Divider()
        Button("Quit Hubless") { model.saveNow(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
