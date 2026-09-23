//
//  MenuBarPanelManager.swift
//  kiki-desktop-agent
//
//  Manages the NSStatusItem and the custom borderless NSPanel that drops down below it.
//  The panel is non-activating so it does not steal focus from the user's current app,
//  and auto-dismisses on an outside click.

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let kikiDismissPanel = Notification.Name("kikiDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    /// How long the pointer has to stay put on the icon before the cursor goes into it.
    private let cursorMergeDwellSeconds: Double = 3.0
    /// How long the pointer has to stay put near the icon before the cursor comes back out.
    private let cursorWakingDwellSeconds: Double = 3.0
    /// How near the icon counts as near enough to call the cursor back. The icon itself is inside
    /// this, which is only safe because of `pointerHasBeenAwayFromTheCursorWakingRange`.
    private let cursorWakingDistanceFromTheStatusItemIconPoints: CGFloat = 100
    /// Deliberately coarse: this timer runs for the whole life of the app rather than for the length
    /// of a flight, so the tick is also the longest the process is ever allowed to sleep.
    /// A quarter second because it is exact in binary, so the accumulator lands on whole seconds —
    /// a three-second wait fires on the twelfth tick rather than the thirteenth.
    private let statusItemIconDwellTickSeconds: Double = 0.25
    private var cursorMergeDwellElapsedSeconds: Double = 0
    private var cursorWakingDwellElapsedSeconds: Double = 0
    /// Whether the pointer has been off the icon since the last wait for it ran out. Without it the
    /// pointer left sitting on the icon would be a wait that never stops being satisfied, and the
    /// cursor would fly in again the moment it came back out.
    private var pointerHasBeenAwayFromTheStatusItemIcon: Bool = true
    /// The same idea for the wait that brings the cursor out: the pointer has to have left the whole
    /// waking range and come back, so parking on the icon keeps Kiki resting indefinitely.
    private var pointerHasBeenAwayFromTheCursorWakingRange: Bool = true
    private var statusItemIconDwellTimer: Timer?
    private var statusItemIconPhaseCancellable: AnyCancellable?

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
    }

    deinit {
        statusItemIconDwellTimer?.invalidate()
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
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

    /// Draws the kiki triangle as a menu bar icon, with the in-app cursor's shape and rotation.
    ///
    /// `glowBlurRadius` of zero draws the plain triangle. Anything larger puts a halo of the same
    /// colour behind it, which is what the icon wears while the cursor is inside it.
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

        // Before the fill, not after: a shadow applies to the drawing that follows it. Full alpha
        // would make the halo a second solid edge rather than a glow around the triangle.
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

    /// Opens the panel automatically on app launch so the user sees permissions and the key field.
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

    /// Runs whichever of the two waits is the one in play, so neither of them ever counts for a
    /// pointer the other one is about to move.
    ///
    /// A timer here rather than in the cursor view, which is a value type: the elapsed time would
    /// have to live in `@State`, and a write per tick marks the whole body dirty — the thing the
    /// 60Hz pointer tracking is careful never to do. Nothing is written here at all until a wait
    /// runs out.
    private func startTheStatusItemIconDwellTimer() {
        let timer = Timer(timeInterval: statusItemIconDwellTickSeconds, repeats: true) { [weak self] _ in
            // The timer is on the main run loop, so this is the main actor; `assumeIsolated` is what
            // says so to the compiler rather than hopping to it once every tick.
            MainActor.assumeIsolated {
                self?.advanceTheStatusItemIconDwell()
            }
        }
        // `.common` rather than the default mode: the usual reason to reach for it is a menu being
        // tracked, and here that menu can be Kiki's own panel.
        RunLoop.main.add(timer, forMode: .common)
        statusItemIconDwellTimer = timer
    }

    private func advanceTheStatusItemIconDwell() {
        // Cleanup, not part of either wait: a cursor in the icon's hands cannot outlive the cursor
        // itself, and the overlay going away takes the cursor with it.
        if companionManager.isNotTakingInputBecauseOfTheStatusItemIcon,
           !companionManager.isOverlayVisible {
            companionManager.endTheStatusItemIconVisit()
            return
        }

        if companionManager.isRestingInTheStatusItemIcon {
            advanceTheCursorWakingDwell()
        } else {
            advanceTheCursorMergeDwell()
        }
    }

    /// The wait that ends with the cursor inside the icon: three seconds of the pointer sitting
    /// still on it, and not a moment of it while Kiki has anything else to do.
    private func advanceTheCursorMergeDwell() {
        guard let iconScreenFrame = statusItemIconScreenFrame,
              canTheCursorMergeIntoTheStatusItemIcon else {
            cursorMergeDwellElapsedSeconds = 0
            return
        }

        // The pointer wandering off resets the wait rather than pausing it: the three seconds are
        // three seconds of resting on the icon, and a pointer that left has not been resting.
        guard iconScreenFrame.contains(NSEvent.mouseLocation) else {
            pointerHasBeenAwayFromTheStatusItemIcon = true
            cursorMergeDwellElapsedSeconds = 0
            return
        }

        // The wait is for a pointer that arrived at the icon, not one that was already on it. The
        // cursor coming back out puts the pointer a few dozen points away at most, and without this
        // the wait would still be satisfied and the cursor would go straight back in — in and out,
        // every three seconds, on a mouse that never moved.
        guard pointerHasBeenAwayFromTheStatusItemIcon else {
            cursorMergeDwellElapsedSeconds = 0
            return
        }

        cursorMergeDwellElapsedSeconds += statusItemIconDwellTickSeconds
        guard cursorMergeDwellElapsedSeconds >= cursorMergeDwellSeconds else { return }

        cursorMergeDwellElapsedSeconds = 0
        // Both waits are re-armed here, at the one moment the cursor is committed to the icon. The
        // waking wait in particular has to be: the pointer that just put the cursor in is inside the
        // waking range by definition, and a wait already satisfied would start counting the instant
        // the cursor landed.
        pointerHasBeenAwayFromTheStatusItemIcon = false
        pointerHasBeenAwayFromTheCursorWakingRange = false
        companionManager.beginStatusItemIconMerge(iconScreenFrame: iconScreenFrame)
    }

    /// Whether the cursor may go and rest in the icon at this moment.
    ///
    /// The first test is the manager's answer to what Kiki is doing, which is what every way into the
    /// app asks — so this wait and those entry points agree on when Kiki is busy instead of each
    /// keeping its own list. Both icon states are excluded, and the waking one is not idle
    /// bookkeeping: while the cursor is flying back out, a pointer parked on the icon would otherwise
    /// satisfy this wait and send the cursor straight back in, which is the in-and-out every three
    /// seconds on a mouse that never moved that the two latches below exist to prevent.
    ///
    /// The rest is what this gesture needs that the shared answer does not cover: a cursor to send,
    /// and nowhere else for it to be.
    private var canTheCursorMergeIntoTheStatusItemIcon: Bool {
        companionManager.whatKikiIsDoingRightNow == .waiting
            && companionManager.isOverlayVisible
            && companionManager.isKikiCursorEnabled
            && companionManager.pointingTarget == nil
            && !companionManager.showOnboardingVideo
    }

    /// The wait that brings the cursor back out: three seconds of the pointer near the icon, after
    /// having been away from it.
    private func advanceTheCursorWakingDwell() {
        // Only from inside the icon. A pointer that comes back while the cursor is still on its way
        // in gets no say — that flight was committed, and the waking wait is the gesture that
        // undoes it, not this one.
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

        // Near the icon is not enough on its own: a pointer that has been sitting there since before
        // the cursor went in has not come back to anything, and waiting it out must not wake Kiki.
        guard pointerHasBeenAwayFromTheCursorWakingRange else {
            cursorWakingDwellElapsedSeconds = 0
            return
        }

        cursorWakingDwellElapsedSeconds += statusItemIconDwellTickSeconds
        guard cursorWakingDwellElapsedSeconds >= cursorWakingDwellSeconds else { return }

        cursorWakingDwellElapsedSeconds = 0
        companionManager.beginWakingFromTheStatusItemIcon()
    }

    /// The icon rectangle grown by the waking distance on every side. Past the corners this reaches
    /// about 141 points, which reads as "around the icon" and is not worth a rounded-corner shape.
    private var cursorWakingRangeAroundTheStatusItemIcon: CGRect? {
        statusItemIconScreenFrame?.insetBy(
            dx: -cursorWakingDistanceFromTheStatusItemIconPoints,
            dy: -cursorWakingDistanceFromTheStatusItemIconPoints
        )
    }

    /// Where the icon is right now, in AppKit screen coordinates — the space `NSEvent.mouseLocation`
    /// and `positionPanelBelowStatusItem()` are already in, so `contains` needs no flip.
    ///
    /// Read fresh every tick rather than cached: displays come and go, the menu bar hides itself for
    /// a full-screen app, and the icon can be ⌘-dragged somewhere else, none of which announces
    /// itself here. A hidden menu bar answers with an off-screen frame, which fails `contains` on
    /// its own and needs no special case.
    private var statusItemIconScreenFrame: CGRect? {
        statusItem?.button?.window?.frame
    }

    /// Repaints the icon the moment the cursor lands in it, and the moment it leaves: the visit's
    /// two visible halves are the icon taking the cursor's colour and giving it back, and both
    /// belong to an arrival rather than to a flight.
    private func observeTheCursorVisitingTheStatusItemIcon() {
        statusItemIconPhaseCancellable = companionManager.$statusItemIconPhase
            .sink { [weak self] phase in
                guard let self, let button = self.statusItem?.button else { return }

                switch phase {
                case .cursorRestingInIcon:
                    button.image = self.makeKikiMenuBarIcon(
                        fillColor: NSColor(DS.Colors.overlayCursorBlue),
                        glowBlurRadius: 4
                    )
                    // A template image is the system's to tint, and it would recolour this one back
                    // to black or white — the purple would vanish with nothing to show for it.
                    button.image?.isTemplate = false

                case .notInTheIcon, .cursorFlyingToIcon, .cursorWakingFromIcon:
                    button.image = self.makeKikiMenuBarIcon(fillColor: .black, glowBlurRadius: 0)
                    button.image?.isTemplate = true
                }
            }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
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

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // The hosting view's fitting size, so the panel wraps the SwiftUI content rather than
        // using `panelHeight` as a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel on a click outside it.
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
