//
//  KikiApp.swift
//  kiki-desktop-agent
//
//  Menu bar-only companion app. No dock icon, no main window — just a status item
//  in the macOS menu bar that opens a floating panel with the voice controls.

import SwiftUI

@main
struct KikiApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel. This empty Settings scene only satisfies
        // SwiftUI's requirement for at least one scene, and is never shown.
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
        // A carry detaches the physical mouse from the pointer, and a detachment outlives the
        // process that made it: nothing in macOS hands it back and no UI reports it, so a crash
        // while carrying leaves a frozen pointer only the next launch can undo. Unconditional
        // on purpose — the in-flight flag belongs to the dead process and reads false here.
        PointerCarrier.reattachTheMouseUnconditionally()

        print("🎯 Kiki: Starting...")
        print("🎯 Kiki: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        KikiAnalytics.configure()
        KikiAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still has something to do: onboarding, or permissions.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        // Deliberately not registered as a login item. Whether Kiki starts with the session is the
        // user's decision, and `SMAppService` cannot tell "never registered" from "turned off in
        // System Settings", so registering on every launch would silently undo that choice. Nothing
        // here needs it: `kiki` starts the app through `open` when it finds nothing listening.
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()

        // The same net at the other end of the process's life: a quit inside the several
        // seconds a run holds the pointer would exit with the mouse still detached.
        PointerCarrier.reattachTheMouseUnconditionally()
    }
}
