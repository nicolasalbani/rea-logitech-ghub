import SwiftUI

@main
struct HublessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Hubless", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1120, height: 780)

        MenuBarExtra("Hubless", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarContent()
                .environmentObject(model)
                .onAppear { model.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running in the menu bar after the window is closed so profiles keep being enforced.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        if Diagnostics.requested { Diagnostics.run(AppModel.shared) }
        if SelfTest.requested { SelfTest.run(AppModel.shared) }
        Snapshot.run(AppModel.shared)
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveNow()
    }
}
