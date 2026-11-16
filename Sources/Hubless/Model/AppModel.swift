import Foundation
import AppKit
import IOKit
import IOKit.hid
import ServiceManagement
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case home
    case speaker(String)
    case camera(String)
    case profiles
    case settings
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var library: ProfileLibrary
    @Published private(set) var speakers: [SpeakerController] = []
    @Published private(set) var cameras: [CameraController] = []
    @Published var selection: SidebarItem? = .home
    @Published var banner: String?

    private let storage: ProfileStorage
    private let discovery = DeviceDiscovery()
    private let cameraUsage = CameraUsageMonitor()
    private var saveScheduled = false
    private var started = false

    init(storage: ProfileStorage = ProfileStorage(url: ProfileStorage.defaultURL)) {
        self.storage = storage
        library = storage.load()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        discovery.onHIDPPArrived = { [weak self] device in
            DispatchQueue.main.async { self?.speakerArrived(device) }
        }
        discovery.onHIDPPRemoved = { [weak self] device in
            DispatchQueue.main.async { self?.speakerRemoved(device) }
        }
        discovery.onCameraArrived = { [weak self] service in
            if Diagnostics.requested { print("USB arrival: registry \(service.registryID)") }
            // Open the USB device interface now (service is released after the callback).
            let registryID = service.registryID
            let cam: UVCCamera
            do { cam = try UVCCamera(service: service) } catch {
                if Diagnostics.requested { print("USB device \(registryID) skipped: \(error)") }
                return
            }
            DispatchQueue.main.async { self?.cameraArrived(cam, registryID: registryID) }
        }
        discovery.onCameraRemoved = { [weak self] registryID in
            DispatchQueue.main.async { self?.cameraRemoved(registryID) }
        }
        discovery.start()

        cameraUsage.onCameraStarted = { [weak self] vid, pid in
            guard let self, self.library.preferences.reapplyOnCameraStart else { return }
            // Give the capture pipeline a moment to initialize, then restore the profile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for c in self.cameras where c.camera.vendorID == vid && c.camera.productID == pid {
                    c.apply(self.cameraSettings(for: c), force: true)
                }
            }
        }
        cameraUsage.start()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self?.reapplyAll() }
        }
    }

    // MARK: Devices

    private func speakerArrived(_ device: IOHIDDevice) {
        guard !speakers.contains(where: { $0.hidDevice == device }) else { return }
        let controller = SpeakerController(device: device)
        Task {
            do {
                let snapshot = try await controller.probe()
                guard snapshot.zones.count > 0 || snapshot.equalizer != nil || snapshot.hasBrightness else { return }
                controller.adopt(snapshot)
                speakers.append(controller)
                speakers.sort { $0.name < $1.name }
                if let stored = activeProfile.speakers[controller.modelKey] {
                    controller.apply(stored)
                    if stored.subwoofer == nil, controller.settings.subwoofer != nil {
                        updateProfile { $0.speakers[controller.modelKey] = controller.settings }
                    }
                } else {
                    // First time we see this model: capture its current state into the active profile.
                    controller.apply(snapshot.current)
                    updateProfile { $0.speakers[controller.modelKey] = controller.settings }
                }
            } catch {
                controller.disconnect()
            }
        }
    }

    private func speakerRemoved(_ device: IOHIDDevice) {
        guard let i = speakers.firstIndex(where: { $0.hidDevice == device }) else { return }
        let removed = speakers.remove(at: i)
        removed.disconnect()
        if selection == .speaker(removed.id) { selection = .home }
    }

    private func cameraArrived(_ camera: UVCCamera, registryID: UInt64) {
        guard !cameras.contains(where: { $0.registryID == registryID }) else { return }
        let controller = CameraController(camera: camera, registryID: registryID)
        Task {
            let snapshot = await controller.probe()
            if Diagnostics.requested { print("Camera \(camera.productName): \(snapshot.values.count) controls") }
            guard !snapshot.values.isEmpty else { return }
            controller.adopt(snapshot)
            cameras.append(controller)
            cameras.sort { $0.name < $1.name }
            if let stored = activeProfile.cameras[controller.modelKey] {
                controller.apply(stored, force: true)
            } else {
                updateProfile { $0.cameras[controller.modelKey] = controller.settings }
            }
        }
    }

    private func cameraRemoved(_ registryID: UInt64) {
        guard let i = cameras.firstIndex(where: { $0.registryID == registryID }) else { return }
        let removed = cameras.remove(at: i)
        if selection == .camera(removed.id) { selection = .home }
    }

    func reapplyAll() {
        for s in speakers { s.apply(speakerSettings(for: s), force: true) }
        for c in cameras { c.apply(cameraSettings(for: c), force: true) }
    }

    // MARK: Profiles

    var activeProfile: Profile {
        library.profiles.first { $0.id == library.activeProfileID } ?? library.profiles[0]
    }

    func speakerSettings(for s: SpeakerController) -> SpeakerSettings {
        activeProfile.speakers[s.modelKey] ?? s.settings
    }

    func cameraSettings(for c: CameraController) -> CameraSettings {
        activeProfile.cameras[c.modelKey] ?? c.settings
    }

    /// UI edits go through here: write to hardware and persist into the active profile.
    func update(_ speaker: SpeakerController, _ change: (inout SpeakerSettings) -> Void) {
        var s = speaker.settings
        change(&s)
        speaker.apply(s)
        let normalized = speaker.settings
        updateProfile { $0.speakers[speaker.modelKey] = normalized }
    }

    func update(_ camera: CameraController, _ change: (inout CameraSettings) -> Void) {
        var s = camera.settings
        change(&s)
        camera.apply(s)
        let applied = camera.settings
        updateProfile { $0.cameras[camera.modelKey] = applied }
    }

    private func updateProfile(_ change: (inout Profile) -> Void) {
        guard let i = library.profiles.firstIndex(where: { $0.id == library.activeProfileID }) else { return }
        change(&library.profiles[i])
        scheduleSave()
    }

    func activate(_ id: UUID) {
        guard library.profiles.contains(where: { $0.id == id }) else { return }
        library.activeProfileID = id
        scheduleSave()
        for s in speakers {
            if let stored = activeProfile.speakers[s.modelKey] { s.apply(stored, force: true) }
            else { updateProfile { $0.speakers[s.modelKey] = s.settings } }
        }
        for c in cameras {
            if let stored = activeProfile.cameras[c.modelKey] { c.apply(stored, force: true) }
            else { updateProfile { $0.cameras[c.modelKey] = c.settings } }
        }
    }

    @discardableResult
    func createProfile(named name: String, copyingCurrent: Bool) -> Profile {
        var p = Profile(name: uniqueName(name))
        if copyingCurrent {
            p.speakers = activeProfile.speakers
            p.cameras = activeProfile.cameras
        } else {
            for s in speakers { p.speakers[s.modelKey] = s.normalized(SpeakerSettings()) }
            for c in cameras { p.cameras[c.modelKey] = c.defaults }
        }
        library.profiles.append(p)
        scheduleSave()
        return p
    }

    func duplicate(_ id: UUID) {
        guard let src = library.profiles.first(where: { $0.id == id }) else { return }
        var p = src
        p.id = UUID()
        p.name = uniqueName(src.name + " Copy")
        p.createdAt = Date()
        library.profiles.append(p)
        scheduleSave()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = library.profiles.firstIndex(where: { $0.id == id }) else { return }
        library.profiles[i].name = trimmed
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard library.profiles.count > 1, let i = library.profiles.firstIndex(where: { $0.id == id }) else { return }
        library.profiles.remove(at: i)
        if library.activeProfileID == id { activate(library.profiles[0].id) }
        scheduleSave()
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(library.profiles.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Import / export (local files only)

    func exportProfile(_ id: UUID) {
        guard let p = library.profiles.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(p.name).hubless.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProfileStorage.encoder.encode(p).write(to: url, options: .atomic)
            banner = "Exported “\(p.name)”"
        } catch {
            banner = "Export failed: \(error.localizedDescription)"
        }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var imported = 0
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  var p = try? ProfileStorage.decoder.decode(Profile.self, from: data) else { continue }
            p.id = UUID()
            p.name = uniqueName(p.name)
            library.profiles.append(p)
            imported += 1
        }
        scheduleSave()
        banner = imported > 0 ? "Imported \(imported) profile\(imported == 1 ? "" : "s")" : "No valid profiles found"
    }

    // MARK: Preferences

    func zoneName(_ speaker: SpeakerController, _ index: Int) -> String {
        let names = library.preferences.zoneNames[speaker.modelKey] ?? []
        if index < names.count, !names[index].isEmpty { return names[index] }
        if let builtIn = Self.defaultZoneNames[speaker.modelKey], index < builtIn.count { return builtIn[index] }
        return "Zone \(index + 1)"
    }

    /// Physical zone positions, confirmed by the user with Identify.
    static let defaultZoneNames: [String: [String]] = [
        "046d:0a78": ["Front Left", "Front Right", "Back Left", "Back Right"], // G560
    ]

    func setZoneName(_ speaker: SpeakerController, _ index: Int, _ name: String) {
        var names = library.preferences.zoneNames[speaker.modelKey] ?? []
        while names.count <= index { names.append("") }
        names[index] = name
        library.preferences.zoneNames[speaker.modelKey] = names
        scheduleSave()
    }

    var reapplyOnCameraStart: Bool {
        get { library.preferences.reapplyOnCameraStart }
        set { library.preferences.reapplyOnCameraStart = newValue; scheduleSave() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                banner = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    var storageURL: URL { storage.url }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            do { try self.storage.save(self.library) } catch { self.banner = "Could not save profiles: \(error.localizedDescription)" }
        }
    }

    func saveNow() {
        try? storage.save(library)
    }
}
