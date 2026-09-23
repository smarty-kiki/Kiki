//
//  scroll-injection-check.swift
//  Kiki
//
//  Measures where a synthesized scroll wheel event lands, and which sign of
//  delta means which direction.
//
//  Why this exists: a click carries its own point — that is a rule this project
//  already relies on — but a scroll wheel event is not documented to. Whether
//  the window under the event's `location` gets the scroll, or the window under
//  the physical pointer, or the key window, decides whether Kiki's cursor can
//  scroll an element on its own or has to drag the user's pointer there first.
//  That is a boolean in the shipping code, and it is not a boolean to guess at.
//
//  How it measures: three windows of its own, each with one job.
//
//    * Two plain windows that write down every `scrollWheel:` they are handed.
//      The pointer is parked over one while the event's point names the other,
//      and which of the two records the scroll is the answer.
//    * One window holding a real `NSScrollView` over a flipped, oversized
//      document. This is the ground truth for direction: "down" is defined by
//      the document moving the way a person expects when they scroll down, not
//      by a sign guessed at from a header.
//
//  Nothing here is Kiki's own code; this file does not import or depend on the
//  app. The deltas it posts are shaped the way `ElementScroller.wheelDeltas`
//  shapes them, so the numbers measured here transfer directly — but they are
//  copies, and a copy goes stale.
//
//  Accessibility permission is required to post events at all, and it is judged
//  against the process responsible for this one — running from a terminal means
//  the TERMINAL needs the grant, not this binary. If neither recording window
//  sees anything, that grant is the first thing to check.
//
//  Usage:
//      swiftc -O scripts/scroll-injection-check.swift -o /tmp/scroll-injection-check
//      /tmp/scroll-injection-check
//

import AppKit
import Foundation
import ApplicationServices

// MARK: - Coordinate conversion

/// The screen the events are aimed at, and the one number the two coordinate
/// spaces differ by.
///
/// `CGEvent`'s `location`, `CGWarpMouseCursorPosition` and the Accessibility API
/// all use one space: origin at the **top-left** corner of the primary display,
/// y increasing downward. AppKit uses the bottom-left corner of that same
/// display with y increasing upward. Only the primary display's height
/// separates them, which is what this carries.
struct ScreenSpace {
    let primaryScreenHeightInPoints: CGFloat

    func accessibilityPoint(fromAppKitPoint appKitPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: appKitPoint.x,
            y: primaryScreenHeightInPoints - appKitPoint.y
        )
    }
}

// MARK: - The two recording windows

/// A view that writes down every scroll it is handed, so "where did it land" is
/// answered by the receiving side rather than by the posting side. Nothing here
/// moves: the only thing this window can report is that it was the one chosen.
final class ScrollRecordingView: NSView {
    struct ReceivedScroll {
        let scrollingDeltaX: CGFloat
        let scrollingDeltaY: CGFloat
        let deltaX: CGFloat
        let deltaY: CGFloat
        let hasPreciseScrollingDeltas: Bool
        let locationInWindow: CGPoint
    }

    private(set) var receivedScrolls: [ReceivedScroll] = []

    override var acceptsFirstResponder: Bool { true }

    func forgetEverythingReceived() {
        receivedScrolls = []
    }

    override func scrollWheel(with event: NSEvent) {
        receivedScrolls.append(ReceivedScroll(
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            locationInWindow: event.locationInWindow
        ))
    }

    /// A borderless window refuses key status by default. The probe needs exactly
    /// one window that is deliberately **not** key, so that "the key window got
    /// it" stays separable from "the window under the pointer got it".
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

// MARK: - The window that can really scroll

/// A document taller and wider than its clip view, flipped so that the clip
/// view's `bounds.origin` runs the same way the reader does: (0, 0) at the
/// top-left, growing down and to the right.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Running one trial

/// What one ownership trial saw. Both counts are reported rather than one
/// verdict, because "the other window got it" and "nobody got it" are different
/// findings and a single boolean cannot hold both.
struct OwnershipTrialOutcome {
    let name: String
    let pointerWasOver: String
    let pointWasOver: String
    let leftWindowScrollCount: Int
    let rightWindowScrollCount: Int
    let deltaYTheReceiverSaw: CGFloat
}

// MARK: - The check

@MainActor
final class ScrollInjectionCheck {
    private let screenSpace: ScreenSpace
    private let leftWindow: ScrollRecordingView.KeyableWindow
    private let leftView: ScrollRecordingView
    private let rightWindow: ScrollRecordingView.KeyableWindow
    private let rightView: ScrollRecordingView
    private let scrollingWindow: NSWindow
    private let scrollingView: NSScrollView

    private let leftCenterInAccessibilitySpace: CGPoint
    private let rightCenterInAccessibilitySpace: CGPoint
    private let scrollingCenterInAccessibilitySpace: CGPoint

    /// One screenful the way the app defines it: 80% of the display's edge, so
    /// that a scroll leaves a fifth of the previous view on screen and the
    /// reader can tell where they were.
    private let oneScreenfulInPoints: CGFloat

    private static let settlingSeconds: TimeInterval = 0.15
    private static let afterPostingSeconds: TimeInterval = 0.15

    init() {
        let primaryScreen = NSScreen.screens[0]
        self.screenSpace = ScreenSpace(primaryScreenHeightInPoints: primaryScreen.frame.height)
        let screenFrame = primaryScreen.frame
        self.oneScreenfulInPoints = screenFrame.height * 0.8

        // Two small windows high up, far apart, and one wide window below them.
        // Nothing overlaps, so "which window" is never a question about z-order.
        let leftFrameInAppKitCoordinates = NSRect(
            x: screenFrame.minX + screenFrame.width * 0.06,
            y: screenFrame.minY + screenFrame.height * 0.66,
            width: 260,
            height: 200
        )
        let rightFrameInAppKitCoordinates = NSRect(
            x: screenFrame.minX + screenFrame.width * 0.74,
            y: screenFrame.minY + screenFrame.height * 0.66,
            width: 260,
            height: 200
        )
        let scrollingFrameInAppKitCoordinates = NSRect(
            x: screenFrame.minX + screenFrame.width * 0.3,
            y: screenFrame.minY + screenFrame.height * 0.14,
            width: 420,
            height: 300
        )

        self.leftView = ScrollRecordingView(frame: NSRect(origin: .zero, size: leftFrameInAppKitCoordinates.size))
        self.leftWindow = ScrollRecordingView.KeyableWindow(
            contentRect: leftFrameInAppKitCoordinates,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.rightView = ScrollRecordingView(frame: NSRect(origin: .zero, size: rightFrameInAppKitCoordinates.size))
        self.rightWindow = ScrollRecordingView.KeyableWindow(
            contentRect: rightFrameInAppKitCoordinates,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.scrollingWindow = NSWindow(
            contentRect: scrollingFrameInAppKitCoordinates,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.scrollingView = NSScrollView(frame: NSRect(origin: .zero, size: scrollingFrameInAppKitCoordinates.size))

        for (window, view) in [(leftWindow, leftView as NSView), (rightWindow, rightView as NSView)] {
            window.contentView = view
            window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
            window.isOpaque = true
            window.level = .normal
        }
        leftWindow.title = "左"
        rightWindow.title = "右"

        let documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 4000, height: 4000))
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1).cgColor
        scrollingView.documentView = documentView
        scrollingView.hasVerticalScroller = true
        scrollingView.hasHorizontalScroller = true
        scrollingWindow.contentView = scrollingView
        scrollingWindow.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        scrollingWindow.isOpaque = true
        scrollingWindow.level = .normal
        scrollingWindow.title = "滚动"

        self.leftCenterInAccessibilitySpace = screenSpace.accessibilityPoint(
            fromAppKitPoint: CGPoint(x: leftFrameInAppKitCoordinates.midX, y: leftFrameInAppKitCoordinates.midY)
        )
        self.rightCenterInAccessibilitySpace = screenSpace.accessibilityPoint(
            fromAppKitPoint: CGPoint(x: rightFrameInAppKitCoordinates.midX, y: rightFrameInAppKitCoordinates.midY)
        )
        self.scrollingCenterInAccessibilitySpace = screenSpace.accessibilityPoint(
            fromAppKitPoint: CGPoint(x: scrollingFrameInAppKitCoordinates.midX, y: scrollingFrameInAppKitCoordinates.midY)
        )
    }

    static func run() async {
        guard AXIsProcessTrusted() else {
            print("❌ 没有辅助功能权限，事件发不出去。")
            print("   权限判给的是「为这个进程负责的那个 app」——从终端跑，要授权的是终端本身。")
            print("   打开「系统设置 → 隐私与安全性 → 辅助功能」，把你的终端加进去再跑一次。")
            exit(1)
        }

        let check = ScrollInjectionCheck()
        check.showTheWindows()
        await check.runOwnershipTrials()
        await check.runWhatTheReceiverSees()
        await check.runDirectionOnARealScrollView()
        print("\n（探针到此结束，窗口不会自己关。）")
    }

    private func showTheWindows() {
        leftWindow.orderFrontRegardless()
        rightWindow.orderFrontRegardless()
        scrollingWindow.orderFrontRegardless()
        // The key window is made the *right* one and the pointer is parked over
        // the *left* one, so the three candidate rules have three different
        // answers and no two of them can be mistaken for each other.
        rightWindow.makeKey()
        print("左窗口 \(NSStringFromRect(leftWindow.frame))（AppKit 坐标）")
        print("右窗口 \(NSStringFromRect(rightWindow.frame))")
        print("滚动窗口 \(NSStringFromRect(scrollingWindow.frame))，文档 4000×4000，已翻转")
        print("一屏 = \(Int(oneScreenfulInPoints)) 点（主屏高度的 80%）")
        print("当前 key window：\(NSApp.keyWindow?.title ?? "（没有）")")
    }

    // MARK: - 归属

    /// Parks the pointer over one window, names the other in the event's point,
    /// and reports which of the two recorded the scroll.
    ///
    /// The two trials that matter are the first and the second, and they are
    /// chosen so that the three candidate rules give three different pairs:
    ///
    ///   | 指针在 | 事件点在 | A（事件自带点） | B（指针所在） | C（key 窗口）|
    ///   |   左   |    右    |       右        |      左      |      右      |
    ///   |   左   |    左    |       左        |      左      |      右      |
    ///
    /// A and B part company on the first row; B and C on the second.
    private func runOwnershipTrials() async {
        print("\n════════ 一、滚轮事件落到哪个窗口 ════════")
        print("（指针停在一个窗口上，事件自带的点写在另一个里。key window 始终是右边那个。）")

        var outcomes: [OwnershipTrialOutcome] = []
        outcomes.append(await runOwnershipTrial(
            named: "指针在左，点写在右",
            pointerPoint: leftCenterInAccessibilitySpace,
            eventPoint: rightCenterInAccessibilitySpace
        ))
        outcomes.append(await runOwnershipTrial(
            named: "指针在左，点写在左",
            pointerPoint: leftCenterInAccessibilitySpace,
            eventPoint: leftCenterInAccessibilitySpace
        ))
        outcomes.append(await runOwnershipTrial(
            named: "指针在左，点不写",
            pointerPoint: leftCenterInAccessibilitySpace,
            eventPoint: nil
        ))
        outcomes.append(await runOwnershipTrial(
            named: "指针在右，点写在左",
            pointerPoint: rightCenterInAccessibilitySpace,
            eventPoint: leftCenterInAccessibilitySpace
        ))

        print("\n  \(Self.paddedToColumn("试验", width: 22))| 左窗口 | 右窗口 | 收到的 dy")
        print("  " + String(repeating: "-", count: 22) + "|--------|--------|----------")
        for outcome in outcomes {
            print("  " + Self.paddedToColumn(outcome.name, width: 22)
                  + "| " + Self.paddedToColumn("\(outcome.leftWindowScrollCount) 条", width: 6)
                  + " | " + Self.paddedToColumn("\(outcome.rightWindowScrollCount) 条", width: 6)
                  + " | \(outcome.deltaYTheReceiverSaw)")
        }

        print("\n  判读：")
        let firstRow = outcomes[0]
        let secondRow = outcomes[1]
        let firstWasRight = firstRow.rightWindowScrollCount > 0
        let secondWasLeft = secondRow.leftWindowScrollCount > 0
        if firstWasRight && secondWasLeft {
            print("    A —— 事件自带的点决定窗口。指针可以完全不动，光标自己滚得动。")
        } else if !firstWasRight && secondWasLeft {
            print("    B —— 指针所在的窗口决定窗口。滚动必须先把指针带过去。")
        } else if firstWasRight && !secondWasLeft {
            print("    C —— key / 最前面的窗口决定窗口。搬指针救不了，只有最前面的窗口滚得动。")
        } else {
            print("    ？—— 两个窗口都没收到。先查辅助功能权限，或换成由 app 来发这一轮。")
        }
    }

    private func runOwnershipTrial(
        named name: String,
        pointerPoint: CGPoint,
        eventPoint: CGPoint?
    ) async -> OwnershipTrialOutcome {
        CGWarpMouseCursorPosition(pointerPoint)
        try? await Task.sleep(nanoseconds: UInt64(Self.settlingSeconds * 1_000_000_000))
        leftView.forgetEverythingReceived()
        rightView.forgetEverythingReceived()

        await postScroll(vertical: 100, horizontal: 0, at: eventPoint)

        try? await Task.sleep(nanoseconds: UInt64(Self.afterPostingSeconds * 1_000_000_000))
        let leftReceived = leftView.receivedScrolls
        let rightReceived = rightView.receivedScrolls
        print("  · \(name)：左 \(leftReceived.count) 条，右 \(rightReceived.count) 条")

        return OwnershipTrialOutcome(
            name: name,
            pointerWasOver: pointerPoint == leftCenterInAccessibilitySpace ? "左" : "右",
            pointWasOver: eventPoint.map {
                $0 == leftCenterInAccessibilitySpace ? "左" : ($0 == rightCenterInAccessibilitySpace ? "右" : "其它")
            } ?? "没写",
            leftWindowScrollCount: leftReceived.count,
            rightWindowScrollCount: rightReceived.count,
            deltaYTheReceiverSaw: (leftReceived + rightReceived).first?.scrollingDeltaY ?? 0
        )
    }

    // MARK: - 接收方看到的 delta

    /// What a receiver is handed for each direction at one and three
    /// screenfuls, and how many events it took. This is the number the app's
    /// `wheelDeltas` has to produce, and the count is what says whether one
    /// screenful should be one event or three.
    private func runWhatTheReceiverSees() async {
        print("\n════════ 二、接收方看到的 scrollingDelta ════════")
        print("（指针与点都在左窗口上；纵向按 app 的做法用 wheelCount 1，横向用 2。）")

        for (directionName, vertical, horizontal) in Self.directionsWithDelta(oneScreenful: oneScreenfulInPoints) {
            for screenfuls in [1, 3] {
                leftView.forgetEverythingReceived()
                for _ in 0..<screenfuls {
                    await postScroll(vertical: vertical, horizontal: horizontal, at: leftCenterInAccessibilitySpace)
                    try? await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.afterPostingSeconds * 1_000_000_000))
                let received = leftView.receivedScrolls
                let totalVertical = received.map(\.scrollingDeltaY).reduce(0, +)
                let totalHorizontal = received.map(\.scrollingDeltaX).reduce(0, +)
                let precise = received.first?.hasPreciseScrollingDeltas
                print(String(
                    format: "  %@ %d 屏：收到 %d 条，Σdy=%.0f Σdx=%.0f，精确 delta=%@",
                    Self.paddedToColumn(directionName, width: 10), screenfuls, received.count,
                    totalVertical, totalHorizontal,
                    precise.map { $0 ? "是" : "否" } ?? "—"
                ))
            }
        }
    }

    /// The four directions as the app sends them: a vertical scroll carries one
    /// wheel, a horizontal one carries two with the first at zero.
    private static func directionsWithDelta(
        oneScreenful: CGFloat
    ) -> [(name: String, vertical: Int32, horizontal: Int32)] {
        let oneScreenfulAsInteger = Int32(oneScreenful.rounded())
        return [
            ("往下滚", oneScreenfulAsInteger, 0),
            ("往上滚", -oneScreenfulAsInteger, 0),
            ("往右滚", 0, oneScreenfulAsInteger),
            ("往左滚", 0, -oneScreenfulAsInteger)
        ]
    }

    // MARK: - 符号

    /// What the sign means, read off a real scroll view rather than guessed at.
    ///
    /// A flipped document runs the same way the reader does, so "the content
    /// moved down" is `bounds.origin.y` growing. This is the definition the app
    /// needs: `[SCROLLDOWN:…]` has to reveal what is currently below the fold,
    /// whatever sign that turns out to require.
    ///
    /// Every direction is measured from the middle of the document. Started from
    /// an edge, the first two directions are answered by the clamp rather than
    /// by the sign — "the document did not move" is what both "it scrolled the
    /// other way" and "there was nothing left to reveal" look like.
    private func runDirectionOnARealScrollView() async {
        print("\n════════ 三、在一个真的 NSScrollView 上，哪个符号是往下 / 往右 ════════")
        print("（文档已翻转：(0,0) 在左上角，origin.y 变大 = 内容往下走。每个方向都从文档中间起测。）")

        for (name, vertical, horizontal) in Self.directionsWithDelta(oneScreenful: oneScreenfulInPoints) {
            await moveTheDocumentToTheMiddle()
            let before = scrollingView.contentView.bounds.origin
            await postScroll(vertical: vertical, horizontal: horizontal, at: scrollingCenterInAccessibilitySpace)
            try? await Task.sleep(nanoseconds: UInt64(Self.afterPostingSeconds * 1_000_000_000))
            let after = scrollingView.contentView.bounds.origin
            print(String(
                format: "  %@ wheel1=%6d wheel2=%6d → origin 移动 (%+.0f, %+.0f)，起测位置 (%.0f, %.0f)",
                Self.paddedToColumn(name, width: 10), vertical, horizontal,
                after.x - before.x, after.y - before.y, before.x, before.y
            ))
        }

        print("\n  判读：")
        print("    origin 往正方向移动的那个符号 = 内容往下 / 往右走，也就 [SCROLLDOWN] / [SCROLLRIGHT] 要发的符号。")
        print("    移动量 ÷ 一屏 = 接收方把 delta 缩了多少（1.0 表示不缩）。")
    }

    /// Re-centres the document so every direction has room to move in.
    ///
    /// The sign used here is the one section three is measuring, which would be
    /// circular if the read-back were not printed: the row reports the position
    /// it actually started from, so a centring that failed is visible as a start
    /// near an edge rather than silently explaining a zero.
    private func moveTheDocumentToTheMiddle() async {
        CGWarpMouseCursorPosition(scrollingCenterInAccessibilitySpace)
        try? await Task.sleep(nanoseconds: UInt64(Self.settlingSeconds * 1_000_000_000))

        let clipView = scrollingView.contentView
        let middleOfTheDocument = CGPoint(
            x: (scrollingView.documentView!.frame.width - clipView.frame.width) / 2,
            y: (scrollingView.documentView!.frame.height - clipView.frame.height) / 2
        )
        let distanceToTheMiddle = CGPoint(
            x: middleOfTheDocument.x - clipView.bounds.origin.x,
            y: middleOfTheDocument.y - clipView.bounds.origin.y
        )
        await postScroll(
            vertical: Int32(-distanceToTheMiddle.y.rounded()),
            horizontal: Int32(-distanceToTheMiddle.x.rounded()),
            at: scrollingCenterInAccessibilitySpace
        )
        try? await Task.sleep(nanoseconds: UInt64(Self.afterPostingSeconds * 1_000_000_000))
    }

    // MARK: - Posting

    /// Builds and posts one scroll exactly the way `ElementScroller` will: pixel
    /// units, HID source, `wheelCount` derived from whether the horizontal wheel
    /// carries anything, and the point written onto the event.
    private func postScroll(vertical: Int32, horizontal: Int32, at point: CGPoint?) async {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: horizontal == 0 ? 1 : 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
              ) else {
            return
        }
        if let point {
            event.location = point
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Reporting

    /// Pads to a column, counting a character from a wide script as the two
    /// terminal columns it actually occupies. `String.padding` counts UTF-16
    /// units and would leave a row with Chinese in it out of line with the rest.
    private static func paddedToColumn(_ text: String, width: Int) -> String {
        let displayWidth = text.unicodeScalars.reduce(0) { runningTotal, scalar in
            let isWide = (0x1100...0x115F).contains(scalar.value)
                || (0x2E80...0xA4CF).contains(scalar.value)
                || (0xAC00...0xD7A3).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0xFE30...0xFE6F).contains(scalar.value)
                || (0xFF00...0xFF60).contains(scalar.value)
                || (0xFFE0...0xFFE6).contains(scalar.value)
            return runningTotal + (isWide ? 2 : 1)
        }
        return text + String(repeating: " ", count: max(0, width - displayWidth))
    }
}

// MARK: - Entry point

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.activate(ignoringOtherApps: true)

Task { @MainActor in
    await ScrollInjectionCheck.run()
    exit(0)
}

application.run()
