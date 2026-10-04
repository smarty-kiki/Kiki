//
//  KikiApp.swift
//  kiki-desktop-agent
//

import SwiftUI

@main
struct KikiApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // Satisfies SwiftUI's requirement for at least one scene; never shown.
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts the voice pipeline.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A detachment outlives the process that made it and nothing in macOS hands it back, so a
        // crash while carrying leaves a frozen pointer only the next launch can undo.
        // Unconditional on purpose — the in-flight flag belongs to the dead process and reads false.
        PointerCarrier.reattachTheMouseUnconditionally()

        print("Kiki: Starting...")
        print("Kiki: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        // Deliberately not a login item: `SMAppService` cannot tell "never registered" from
        // "turned off in System Settings", so registering at launch would silently undo the user's
        // choice there. Nothing needs it — `kiki` starts the app through `open` instead.
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()

        // The same net at the other end: a quit mid-run would exit with the mouse still detached.
        PointerCarrier.reattachTheMouseUnconditionally()
    }
}
