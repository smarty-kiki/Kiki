//
//  MenuBarPanelManager.swift
//  kiki-desktop-agent
//
//  Manages the NSStatusItem and the custom borderless NSPanel that drops down below it:
//  non-activating, so it does not steal focus, and dismissed by an outside click.

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let kikiDismissPanel = Notification.Name("kikiDismissPanel")
    /// Posted by the onboarding guide when a segment needs the panel on screen to point at.
    static let kikiShowPanel = Notification.Name("kikiShowPanel")
    /// Posted after the panel is repositioned: a window moving changes no view's frame, so the
    /// anchor reporters need telling to read their screen frames again.
    static let kikiPanelDidReposition = Notification.Name("kikiPanelDidReposition")
}

/// An NSPanel that can become key even with `.nonactivatingPanel`, so text fields receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380
    private let gapBelowTheMenuBarPoints: CGFloat = 4

    private let cursorMergeDwellSeconds: Double = 3.0
    private let cursorWakingDwellSeconds: Double = 3.0
    /// How near the icon counts as near enough to call the cursor back — the icon itself is inside it,
    /// which only `pointerHasBeenAwayFromTheCursorWakingRange` makes safe.
    private let cursorWakingDistanceFromTheStatusItemIconPoints: CGFloat = 100
    /// Deliberately coarse: this timer runs for the life of the app, so the tick is also the longest
    /// the process may sleep — and a quarter second is exact in binary, so accumulator ticks are whole.
    private let statusItemIconDwellTickSeconds: Double = 0.25
    private var cursorMergeDwellElapsedSeconds: Double = 0
    private var cursorWakingDwellElapsedSeconds: Double = 0
    /// Whether the pointer has been off the icon since the last wait ran out; without it the wait never
    /// stops being satisfied.
    private var pointerHasBeenAwayFromTheStatusItemIcon: Bool = true
    /// The same for the waking wait: the pointer must have left the whole range and come back, so parking
    /// on the icon keeps Kiki resting indefinitely.
    private var pointerHasBeenAwayFromTheCursorWakingRange: Bool = true
    private var statusItemIconDwellTimer: Timer?
    private var statusItemIconPhaseCancellable: AnyCancellable?

    /// The chain that re-places the panel once the menu bar has placed the status item, if one is running
    /// — one at a time, because a launch asks for the panel more than once.
    private var panelRepositionRetryTask: Task<Void, Never>?

    /// Whether the panel is standing at the fallback position, still waiting for the menu bar to place the
    /// status item; the dwell tick below is what catches a later placement.
    private var panelIsWaitingAtTheFallbackPosition = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()
        startTheStatusItemIconDwellTimer()
        observeTheCursorVisitingTheStatusItemIcon()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .kikiDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .kikiShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPanel()
        }
    }

    deinit {
        statusItemIconDwellTimer?.invalidate()
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeKikiMenuBarIcon(fillColor: .black, glowBlurRadius: 0)
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the kiki triangle as a menu bar icon, with the in-app cursor's shape and rotation. A
    /// non-zero `glowBlurRadius` puts a halo of the same colour behind it, worn while the cursor is in.
    private func makeKikiMenuBarIcon(fillColor: NSColor, glowBlurRadius: CGFloat) -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        // Before the fill, not after: a shadow applies to the drawing that follows it, and full alpha
        // would make the halo a second solid edge rather than a glow.
        if glowBlurRadius > 0 {
            let glow = NSShadow()
            glow.shadowColor = fillColor.withAlphaComponent(0.9)
            glow.shadowBlurRadius = glowBlurRadius
            glow.shadowOffset = .zero
            glow.set()
        }

        fillColor.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel at launch so the user sees the permission rows and the key field.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Resting In The Status Item Icon

    /// Runs whichever of the two waits is in play, so neither ever counts for a pointer the other is about
    /// to move. A timer here rather than in the cursor view, which is a value type whose elapsed time would
    /// live in `@State`, where a write per tick would mark the whole body dirty.
    private func startTheStatusItemIconDwellTimer() {
        let timer = Timer(timeInterval: statusItemIconDwellTickSeconds, repeats: true) { [weak self] _ in
            // The timer is on the main run loop, so this is the main actor; `assumeIsolated` says so.
            MainActor.assumeIsolated {
                self?.advanceTheStatusItemIconDwell()
            }
        }
        // `.common` rather than the default mode: the menu being tracked can be Kiki's own panel.
        RunLoop.main.add(timer, forMode: .common)
        statusItemIconDwellTimer = timer
    }

    private func advanceTheStatusItemIconDwell() {
        // Cleanup, not part of either wait: a visit cannot outlive the cursor the overlay carries.
        if companionManager.isNotTakingInputBecauseOfTheStatusItemIcon,
           !companionManager.isOverlayVisible {
            companionManager.endTheStatusItemIconVisit()
            return
        }

        repositionThePanelIfItIsStillWaitingAtTheFallbackPosition()

        if companionManager.isRestingInTheStatusItemIcon {
            advanceTheCursorWakingDwell()
        } else {
            advanceTheCursorMergeDwell()
        }
    }

    /// The wait that ends with the cursor inside the icon: three seconds of the pointer sitting still on
    /// it, and not a moment of it while Kiki has anything else to do.
    private func advanceTheCursorMergeDwell() {
        guard let iconScreenFrame = statusItemIconScreenFrame,
              canTheCursorMergeIntoTheStatusItemIcon else {
            cursorMergeDwellElapsedSeconds = 0
            return
        }

        // The pointer wandering off resets the wait rather than pausing it — seconds of resting on the icon.
        guard iconScreenFrame.contains(NSEvent.mouseLocation) else {
            pointerHasBeenAwayFromTheStatusItemIcon = true
            cursorMergeDwellElapsedSeconds = 0
            return
        }

        // The wait is for a pointer that arrived at the icon: the cursor coming back out leaves the pointer
        // a few dozen points away, so the wait would still be satisfied.
        guard pointerHasBeenAwayFromTheStatusItemIcon else {
            cursorMergeDwellElapsedSeconds = 0
            return
        }

        cursorMergeDwellElapsedSeconds += statusItemIconDwellTickSeconds
        guard cursorMergeDwellElapsedSeconds >= cursorMergeDwellSeconds else { return }

        cursorMergeDwellElapsedSeconds = 0
        // Both waits are re-armed here, the one moment the cursor is committed to the icon — the waking
        // wait because the pointer that just put the cursor in is inside the waking range by definition.
        pointerHasBeenAwayFromTheStatusItemIcon = false
        pointerHasBeenAwayFromTheCursorWakingRange = false
        companionManager.beginStatusItemIconMerge(iconScreenFrame: iconScreenFrame)
    }

    /// Whether the cursor may rest in the icon at this moment. The first test is the manager's shared
    /// answer to what Kiki is doing, so this wait and every entry point agree on when Kiki is busy; both
    /// icon states are excluded, because a pointer parked on the icon would otherwise satisfy the wait.
    private var canTheCursorMergeIntoTheStatusItemIcon: Bool {
        companionManager.whatKikiIsDoingRightNow == .waiting
            && companionManager.isOverlayVisible
            && companionManager.isKikiCursorEnabled
            && companionManager.pointingTarget == nil
            && !companionManager.showOnboardingVideo
    }

    /// The wait that brings the cursor back out: three seconds near the icon after having been away — and
    /// only from inside the icon, since a flight still on its way in was committed.
    private func advanceTheCursorWakingDwell() {
        guard companionManager.statusItemIconPhase == .cursorRestingInIcon else { return }

        guard let wakingRange = cursorWakingRangeAroundTheStatusItemIcon else {
            cursorWakingDwellElapsedSeconds = 0
            return
        }

        guard wakingRange.contains(NSEvent.mouseLocation) else {
            pointerHasBeenAwayFromTheCursorWakingRange = true
            cursorWakingDwellElapsedSeconds = 0
            return
        }

        // Near the icon is not enough: a pointer there since before the cursor went in has not come back.
        guard pointerHasBeenAwayFromTheCursorWakingRange else {
            cursorWakingDwellElapsedSeconds = 0
            return
        }

        cursorWakingDwellElapsedSeconds += statusItemIconDwellTickSeconds
        guard cursorWakingDwellElapsedSeconds >= cursorWakingDwellSeconds else { return }

        cursorWakingDwellElapsedSeconds = 0
        companionManager.beginWakingFromTheStatusItemIcon()
    }

    /// The icon rectangle grown by the waking distance on every side — past the corners, some 141 points.
    private var cursorWakingRangeAroundTheStatusItemIcon: CGRect? {
        statusItemIconScreenFrame?.insetBy(
            dx: -cursorWakingDistanceFromTheStatusItemIconPoints,
            dy: -cursorWakingDistanceFromTheStatusItemIconPoints
        )
    }

    /// Where the icon is right now, in AppKit screen coordinates — the space `NSEvent.mouseLocation`
    /// and `positionPanelBelowStatusItem()` are already in, so `contains` needs no flip. Read fresh
    /// rather than cached: displays come and go, the menu bar hides itself, the icon can be ⌘-dragged,
    /// none of which announces itself, and a hidden menu bar's off-screen frame fails `contains` alone.
    private var statusItemIconScreenFrame: CGRect? {
        statusItem?.button?.window?.frame
    }

    /// Repaints the icon on the cursor's landing and again on its leaving: the visit's two visible halves.
    private func observeTheCursorVisitingTheStatusItemIcon() {
        statusItemIconPhaseCancellable = companionManager.$statusItemIconPhase
            .sink { [weak self] phase in
                guard let self, let button = self.statusItem?.button else { return }

                switch phase {
                case .cursorRestingInIcon:
                    button.image = self.makeKikiMenuBarIcon(
                        fillColor: NSColor(DS.Colors.overlayCursorPurple),
                        glowBlurRadius: 4
                    )
                    // A template image is the system's to tint: it would recolour this one back to black
                    // or white, and the purple would vanish with nothing to show for it.
                    button.image?.isTemplate = false

                case .notInTheIcon, .cursorFlyingToIcon, .cursorWakingFromIcon:
                    button.image = self.makeKikiMenuBarIcon(fillColor: .black, glowBlurRadius: 0)
                    button.image?.isTemplate = true
                }
            }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        // The link can be made or broken while the app is up, so the install row is asked at every open.
        companionManager.refreshCommandLineToolInstallation()

        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
        companionManager.theSettingsPanelCameOnScreen()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        companionManager.theSettingsPanelWentOffScreen()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    /// Whether a status item frame is one the menu bar has actually placed, rather than the placeholder
    /// it wears before that. The placeholder straddles the bottom-left corner of the primary display, so
    /// it passes a plain screen-intersection test while being nowhere near the icon's real home. An icon
    /// genuinely parked out of reach fails this test too, and is answered the same way: fallback, wait.
    private func isTheStatusItemIconInAMenuBar(_ statusItemFrame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.intersects(statusItemFrame)
                && statusItemFrame.midY >= screen.visibleFrame.maxY
        }
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }

        // The frame only means something once the menu bar has placed the icon, which on a cold launch can
        // be later than the first show — a panel placed from the placeholder lands off the visible screen.
        guard let statusItemFrame = statusItemIconScreenFrame,
              isTheStatusItemIconInAMenuBar(statusItemFrame) else {
            positionPanelAtTheTopRightOfTheMainScreen()
            scheduleARepositionForOnceTheMenuBarHasPlacedTheIcon()
            return
        }

        panelRepositionRetryTask?.cancel()
        panelRepositionRetryTask = nil
        panelIsWaitingAtTheFallbackPosition = false

        // The hosting view's fitting size, so the panel wraps the SwiftUI content rather than using a
        // fixed `panelHeight`.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowTheMenuBarPoints

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )

        NotificationCenter.default.post(name: .kikiPanelDidReposition, object: panel)
    }

    /// Where the panel waits out an icon the menu bar has not placed yet: the top right, where the icon is
    /// heading anyway.
    private func positionPanelAtTheTopRightOfTheMainScreen() {
        guard let panel, let mainScreen = NSScreen.main else { return }

        panelIsWaitingAtTheFallbackPosition = true

        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let visibleFrame = mainScreen.visibleFrame

        panel.setFrame(
            NSRect(
                x: visibleFrame.maxX - panelWidth - 8,
                y: visibleFrame.maxY - fittingSize.height - gapBelowTheMenuBarPoints,
                width: panelWidth,
                height: fittingSize.height
            ),
            display: true
        )

        NotificationCenter.default.post(name: .kikiPanelDidReposition, object: panel)
    }

    /// Watches for the menu bar to place the status item, then puts the panel under it: the placement
    /// announces nothing, so this is a chain of short looks rather than one delayed call.
    private func scheduleARepositionForOnceTheMenuBarHasPlacedTheIcon() {
        guard panelRepositionRetryTask == nil else { return }

        panelRepositionRetryTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }

                guard let statusItemFrame = self.statusItemIconScreenFrame,
                      self.isTheStatusItemIconInAMenuBar(statusItemFrame) else {
                    continue
                }

                self.panelRepositionRetryTask = nil
                self.positionPanelBelowStatusItem()
                return
            }

            self?.panelRepositionRetryTask = nil
        }
    }

    /// Puts the panel under the icon whenever the menu bar gets round to placing it. The retry chain is a
    /// handful of seconds long and a placeholder frame can last minutes; this tick runs for the app's life.
    private func repositionThePanelIfItIsStillWaitingAtTheFallbackPosition() {
        guard panelIsWaitingAtTheFallbackPosition, let panel, panel.isVisible else { return }
        guard let statusItemFrame = statusItemIconScreenFrame,
              isTheStatusItemIconInAMenuBar(statusItemFrame) else { return }

        positionPanelBelowStatusItem()
    }

    // MARK: - Click Outside Dismissal

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // The delay covers a system permission dialog taking focus just after the Grant
            // click that opened it — dismissing there pulls the panel out from under the user.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // A system dialog can hold focus mid-onboarding; don't dismiss there either.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
