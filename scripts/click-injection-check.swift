//
//  click-injection-check.swift
//  Kiki
//
//  Measures what each way of injecting a click actually does to the user's
//  pointer, and whether the click still lands.
//
//  Why this exists: `ElementClicker` posts its events at `.cghidEventTap`, and
//  both the file's own doc comment and `AGENTS.md` claim that leaves the pointer
//  alone ("the click lands where the event says, not where the mouse is
//  standing"). A user reported the pointer being dragged along by the click, and
//  that claim is what is under test here. `CGEventCreateMouseEvent`'s
//  `mouseCursorPosition` argument IS the cursor position — that is the same field
//  the system reads to say where the mouse is — so an event injected at the HID
//  layer plausibly relocates the pointer, and the only way to know is to watch it.
//
//  How it measures: it puts a target window of its own at a known rectangle,
//  parks the cursor far away from it, and then, for each injection method, posts
//  a click at the target's centre while a background timer samples the cursor
//  position every millisecond. Two questions are answered separately, because
//  they can disagree and the disagreement is the whole finding:
//
//    * did the pointer move, and for how long — from the cursor samples
//    * did the target receive the click, and at what point — from the view's
//      `mouseDown`/`mouseUp`
//
//  Nothing here is Kiki's own code; this file does not import or depend on the
//  app. It is a probe, and its conclusion is a candidate rather than an answer:
//  what it CANNOT test is whether a third-party app that hit-tests against the
//  physical pointer rather than against the event would accept a delivery method
//  that leaves the pointer alone. That has to be checked by hand afterwards, in
//  the app, against a real `[CLICK:…]`.
//
//  Accessibility permission is required to post events at all, and it is judged
//  against the process responsible for this one — running from a terminal means
//  the TERMINAL needs the grant, not this binary.
//
//  Usage:
//      swiftc -O scripts/click-injection-check.swift -o /tmp/click-injection-check
//      /tmp/click-injection-check
//
//  Options:
//      --repetitions N   runs per method (default 5)
//      --only NAME       run one method (see the `--help` listing)
//

import AppKit
import Foundation
import ApplicationServices

// MARK: - Coordinate conversion

/// The screen the click is aimed at, and the one number the two coordinate
/// spaces differ by.
///
/// `CGEvent`'s `mouseCursorPosition`, `CGWarpMouseCursorPosition` and the
/// Accessibility API all use one space: origin at the **top-left** corner of the
/// primary display, y increasing downward. AppKit uses the bottom-left corner of
/// that same display with y increasing upward. Only the primary display's height
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

// MARK: - The target

/// A view that writes down every click it is handed, so "did the click land" is
/// answered by the receiving side rather than by the posting side.
final class ClickRecordingView: NSView {
    struct ReceivedClick {
        let phase: String
        let locationInWindow: CGPoint
        let clickCount: Int
    }

    private(set) var receivedClicks: [ReceivedClick] = []

    override var acceptsFirstResponder: Bool { true }

    func forgetEverythingReceived() {
        receivedClicks = []
    }

    override func mouseDown(with event: NSEvent) {
        receivedClicks.append(ReceivedClick(
            phase: "down",
            locationInWindow: event.locationInWindow,
            clickCount: event.clickCount
        ))
    }

    override func mouseUp(with event: NSEvent) {
        receivedClicks.append(ReceivedClick(
            phase: "up",
            locationInWindow: event.locationInWindow,
            clickCount: event.clickCount
        ))
    }

    /// The window is borderless, and a borderless window refuses key status by
    /// default — which is fine for receiving mouse events but would make the
    /// window unclickable in the one sense that matters here: nothing would be
    /// delivered. Allowing it costs nothing and removes the doubt.
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

// MARK: - Watching the pointer

/// Samples the cursor position on a queue of its own for as long as a click is
/// being posted.
///
/// The samples are the only evidence about the pointer, so nothing here may
/// itself move it: `CGEvent(source: nil)` is a null event, and its `location`
/// field is a *read* of where the cursor is standing.
final class CursorPositionSampler {
    struct Sample {
        let secondsSinceSamplingBegan: TimeInterval
        let location: CGPoint
    }

    private let samplingQueue = DispatchQueue(label: "click-injection-check.cursor-sampler")
    private var timer: DispatchSourceTimer?
    private var samples: [Sample] = []
    private var samplingBeganDate = Date()

    func start() {
        samples = []
        samplingBeganDate = Date()
        let newTimer = DispatchSource.makeTimerSource(queue: samplingQueue)
        // 1 ms is under a 60 Hz frame (16.7 ms), which is the resolution the
        // question needs: an excursion shorter than a frame is one the user
        // cannot see, and that is exactly what a save-and-restore would produce.
        newTimer.schedule(deadline: .now(), repeating: .milliseconds(1))
        newTimer.setEventHandler { [weak self] in
            guard let self, let currentCursorEvent = CGEvent(source: nil) else { return }
            self.samples.append(Sample(
                secondsSinceSamplingBegan: Date().timeIntervalSince(self.samplingBeganDate),
                location: currentCursorEvent.location
            ))
        }
        newTimer.resume()
        timer = newTimer
    }

    func stop() -> [Sample] {
        timer?.cancel()
        timer = nil
        return samplingQueue.sync { samples }
    }
}

// MARK: - The methods under test

/// One way of getting a click to a point, named after what it does rather than
/// after the constant it uses, because the table is read as a list of choices.
enum ClickInjectionMethod: String, CaseIterable {
    case hidEventTap = "cghidEventTap"
    case sessionEventTap = "cgSessionEventTap"
    case annotatedSessionEventTap = "cgAnnotatedSessionEventTap"
    case postedToOwningProcess = "CGEventPostToPid"
    /// ASCII only, because the summary pads this to a column and a Chinese
    /// character is two columns wide in a terminal — the name is what the row is
    /// found by, so it has to be the part that lines up.
    case hidEventTapThenWarpBack = "cghidEventTap+warpBack"

    var explanation: String {
        switch self {
        case .hidEventTap:
            return "现状。事件从 HID 层注入，等于替真实鼠标说「我在这儿」。"
        case .sessionEventTap:
            return "低一层，但仍然在系统的鼠标管线里。"
        case .annotatedSessionEventTap:
            return "再低一层，注入前会被重新标注。"
        case .postedToOwningProcess:
            return "直接投进目标进程的事件队列，不经 HID 层——理论上指针不该动。"
        case .hidEventTapThenWarpBack:
            return "现状，投递后立刻把光标挪回原位。"
        }
    }

    /// Whether this method needs the process that owns the window under the
    /// point, which is the thing `CGEventPostToPid` cannot work without.
    var needsOwningProcessIdentifier: Bool {
        self == .postedToOwningProcess
    }
}

// MARK: - Running one trial

/// What one trial saw. Both halves are optional because a method can fail to
/// answer either one, and "it did not deliver anything" is a different finding
/// from "it delivered and moved the pointer".
struct TrialOutcome {
    let method: ClickInjectionMethod
    let isDoubleClick: Bool
    let maximumCursorDisplacementInPoints: CGFloat
    let secondsSpentDisplaced: TimeInterval
    /// Whether the pointer was still away from its parked position on the last
    /// sample. This is what separates "jumped there and came back" from "jumped
    /// there and stayed", and the sampling window alone cannot tell them apart:
    /// a pointer that returns after 390 of 400 sampled milliseconds spends
    /// almost the whole window displaced either way.
    let wasStillDisplacedAtTheEndOfSampling: Bool
    let receivedClickCount: Int
    /// The click as the target saw it, in the Accessibility space, when it
    /// received exactly one.
    let receivedPointInAccessibilitySpace: CGPoint?
    let expectedPointInAccessibilitySpace: CGPoint
    /// The click counts the target reported, in order — this is what says a
    /// double click arrived as a double click.
    let observedClickCounts: [Int]
}

// MARK: - The check

@MainActor
final class ClickInjectionCheck {
    private let screenSpace: ScreenSpace
    private let targetWindow: ClickRecordingView.KeyableWindow
    private let targetView: ClickRecordingView
    /// Where the cursor is parked before every trial: far enough from the target
    /// that any movement towards it is unmistakable, and on the same display so
    /// no display boundary is involved.
    private let cursorHomePointInAccessibilitySpace: CGPoint
    private let targetPointInAccessibilitySpace: CGPoint
    private let repetitions: Int
    private let onlyMethod: ClickInjectionMethod?
    /// The methods this run covers — one when `--only` picked it, all of them
    /// otherwise. Resolved once so the loops that report read from the same list
    /// the trials were run from.
    private let methodsToRun: [ClickInjectionMethod]

    /// Below this, a sample counts as "the pointer did not move" — one point is
    /// under the smallest distance a warp can express and well under the
    /// distance from the parked position to the target.
    private static let displacementThresholdInPoints: CGFloat = 2

    private static let secondsBetweenTheClicksOfADoubleClick: TimeInterval = 0.05
    private static let cursorSettlingSeconds: TimeInterval = 0.05
    private static let samplingSecondsPerTrial: TimeInterval = 0.4

    init(repetitions: Int, onlyMethod: ClickInjectionMethod?) {
        self.repetitions = repetitions
        self.onlyMethod = onlyMethod
        self.methodsToRun = onlyMethod.map { [$0] } ?? ClickInjectionMethod.allCases

        let primaryScreen = NSScreen.screens[0]
        self.screenSpace = ScreenSpace(primaryScreenHeightInPoints: primaryScreen.frame.height)

        // The target sits in the middle of the primary display's lower half, and
        // the cursor is parked up in the top-left corner of the same display.
        // Both are placed relative to the display rather than at absolute numbers
        // so the check does not depend on this machine's resolution.
        let screenFrame = primaryScreen.frame
        let targetFrameInAppKitCoordinates = NSRect(
            x: screenFrame.minX + screenFrame.width * 0.4,
            y: screenFrame.minY + screenFrame.height * 0.25,
            width: 320,
            height: 220
        )

        self.targetView = ClickRecordingView(frame: NSRect(origin: .zero, size: targetFrameInAppKitCoordinates.size))
        self.targetWindow = ClickRecordingView.KeyableWindow(
            contentRect: targetFrameInAppKitCoordinates,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        targetWindow.contentView = targetView
        targetWindow.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        targetWindow.isOpaque = true
        targetWindow.level = .normal
        targetWindow.orderFrontRegardless()

        let targetCenterInAppKitCoordinates = CGPoint(
            x: targetFrameInAppKitCoordinates.midX,
            y: targetFrameInAppKitCoordinates.midY
        )
        self.targetPointInAccessibilitySpace = screenSpace.accessibilityPoint(
            fromAppKitPoint: targetCenterInAppKitCoordinates
        )
        self.cursorHomePointInAccessibilitySpace = screenSpace.accessibilityPoint(
            fromAppKitPoint: CGPoint(
                x: screenFrame.minX + screenFrame.width * 0.06,
                y: screenFrame.minY + screenFrame.height * 0.94
            )
        )
    }

    static func run(repetitions: Int, onlyMethod: ClickInjectionMethod?) async {
        guard AXIsProcessTrusted() else {
            print("❌ 没有辅助功能权限，事件发不出去。")
            print("   权限判给的是「为这个进程负责的那个 app」——从终端跑，要授权的是终端本身。")
            print("   打开「系统设置 → 隐私与安全性 → 辅助功能」，把你的终端加进去再跑一次。")
            exit(1)
        }

        let check = ClickInjectionCheck(repetitions: repetitions, onlyMethod: onlyMethod)
        check.printSetup()
        await check.warmUpTheWindow()
        let outcomes = await check.runEveryMethod()
        check.printTable(outcomes)
        check.printConclusion(outcomes)
    }

    /// Runs the first trial without recording it.
    ///
    /// The window has only just been ordered in, and the click that brings an
    /// inactive app forward is consumed by the activation rather than delivered
    /// to the view — so the first trial of a run is answering a different
    /// question from every other one. The first run of this script recorded that
    /// trial and it read as the shipping method failing to deliver, which it is
    /// not.
    private func warmUpTheWindow() async {
        CGWarpMouseCursorPosition(cursorHomePointInAccessibilitySpace)
        try? await Task.sleep(nanoseconds: UInt64(Self.cursorSettlingSeconds * 1_000_000_000))
        targetView.forgetEverythingReceived()
        await postClick(
            atAccessibilityScreenPoint: targetPointInAccessibilitySpace,
            method: .hidEventTap,
            isDoubleClick: false
        )
        try? await Task.sleep(nanoseconds: UInt64(Self.cursorSettlingSeconds * 1_000_000_000))
        targetView.forgetEverythingReceived()
        print("（热身一次，不计入结果）\n")
    }

    private func printSetup() {
        print("靶子窗口：\(NSStringFromRect(targetWindow.frame))（AppKit 坐标）")
        print(String(
            format: "靶心：辅助功能坐标 (%.0f, %.0f)；光标停在 (%.0f, %.0f)",
            targetPointInAccessibilitySpace.x, targetPointInAccessibilitySpace.y,
            cursorHomePointInAccessibilitySpace.x, cursorHomePointInAccessibilitySpace.y
        ))
        print("每种方式跑 \(repetitions) 次，每次采样 \(Int(Self.samplingSecondsPerTrial * 1000))ms。\n")
    }

    private func runEveryMethod() async -> [TrialOutcome] {
        var outcomes: [TrialOutcome] = []
        for method in methodsToRun {
            print("── \(method.rawValue) ── \(method.explanation)")
            for trialIndex in 0..<repetitions {
                let singleClickOutcome = await runOneTrial(method: method, isDoubleClick: false)
                outcomes.append(singleClickOutcome)
                print(String(
                    format: "   #%d 单击  位移 %6.1f 点 / 停留 %6.1f ms | 收到 %d 个事件 %@",
                    trialIndex + 1,
                    singleClickOutcome.maximumCursorDisplacementInPoints,
                    singleClickOutcome.secondsSpentDisplaced * 1000,
                    singleClickOutcome.receivedClickCount,
                    singleClickOutcome.receivedClickCount == 2 ? "✓" : "✗"
                ))
            }
            // The double click is one extra trial per method rather than a
            // repetition of the same question: what it asks is whether the two
            // pairs still arrive as a double click, which is a property of the
            // method and not something a repetition would sharpen.
            let doubleClickOutcome = await runOneTrial(method: method, isDoubleClick: true)
            outcomes.append(doubleClickOutcome)
            print(String(
                format: "   双击      位移 %6.1f 点 / 停留 %6.1f ms | 收到 %d 个事件，clickCount %@ %@",
                doubleClickOutcome.maximumCursorDisplacementInPoints,
                doubleClickOutcome.secondsSpentDisplaced * 1000,
                doubleClickOutcome.receivedClickCount,
                doubleClickOutcome.observedClickCounts.map(String.init).joined(separator: ","),
                doubleClickOutcome.observedClickCounts == [1, 1, 2, 2] ? "✓ 是双击" : "✗ 不是双击"
            ))
            print("")
        }
        return outcomes
    }

    private func runOneTrial(method: ClickInjectionMethod, isDoubleClick: Bool) async -> TrialOutcome {
        targetView.forgetEverythingReceived()

        CGWarpMouseCursorPosition(cursorHomePointInAccessibilitySpace)
        // A warp needs a moment to take effect before the baseline is trusted;
        // sampling it mid-flight would read the previous position as the home.
        try? await Task.sleep(nanoseconds: UInt64(Self.cursorSettlingSeconds * 1_000_000_000))

        let sampler = CursorPositionSampler()
        sampler.start()

        await postClick(
            atAccessibilityScreenPoint: targetPointInAccessibilitySpace,
            method: method,
            isDoubleClick: isDoubleClick
        )

        try? await Task.sleep(nanoseconds: UInt64(Self.samplingSecondsPerTrial * 1_000_000_000))
        let samples = sampler.stop()

        let receivedClicks = targetView.receivedClicks
        let movement = measureCursorMovement(in: samples)

        return TrialOutcome(
            method: method,
            isDoubleClick: isDoubleClick,
            maximumCursorDisplacementInPoints: movement.maximumDisplacement,
            secondsSpentDisplaced: movement.secondsDisplaced,
            wasStillDisplacedAtTheEndOfSampling: movement.wasStillDisplacedAtTheEnd,
            receivedClickCount: receivedClicks.count,
            receivedPointInAccessibilitySpace: receivedClicks.first.map { click in
                screenSpace.accessibilityPoint(
                    fromAppKitPoint: targetWindow.convertPoint(toScreen: click.locationInWindow)
                )
            },
            expectedPointInAccessibilitySpace: targetPointInAccessibilitySpace,
            observedClickCounts: receivedClicks.map(\.clickCount)
        )
    }

    /// How far the pointer got from where it was parked, and for how long.
    ///
    /// The duration is what separates a flicker from a drag: four events posted
    /// fifty milliseconds apart hold the pointer at the target for the whole gap,
    /// and that is long enough to be seen.
    private func measureCursorMovement(
        in samples: [CursorPositionSampler.Sample]
    ) -> (maximumDisplacement: CGFloat, secondsDisplaced: TimeInterval, wasStillDisplacedAtTheEnd: Bool) {
        var maximumDisplacement: CGFloat = 0
        var firstDisplacedTime: TimeInterval?
        var lastDisplacedTime: TimeInterval?

        for sample in samples {
            let displacement = hypot(
                sample.location.x - cursorHomePointInAccessibilitySpace.x,
                sample.location.y - cursorHomePointInAccessibilitySpace.y
            )
            maximumDisplacement = max(maximumDisplacement, displacement)
            if displacement > Self.displacementThresholdInPoints {
                if firstDisplacedTime == nil {
                    firstDisplacedTime = sample.secondsSinceSamplingBegan
                }
                lastDisplacedTime = sample.secondsSinceSamplingBegan
            }
        }

        let finalDisplacement = CGEvent(source: nil).map { currentCursorEvent in
            hypot(
                currentCursorEvent.location.x - cursorHomePointInAccessibilitySpace.x,
                currentCursorEvent.location.y - cursorHomePointInAccessibilitySpace.y
            )
        } ?? 0

        guard let firstDisplacedTime, let lastDisplacedTime else {
            return (maximumDisplacement, 0, false)
        }
        return (
            maximumDisplacement,
            lastDisplacedTime - firstDisplacedTime,
            finalDisplacement > Self.displacementThresholdInPoints
        )
    }

    /// Builds and posts the click the way `ElementClicker` does, with the one
    /// difference being where the events are injected.
    private func postClick(
        atAccessibilityScreenPoint point: CGPoint,
        method: ClickInjectionMethod,
        isDoubleClick: Bool
    ) async {
        let owningProcessIdentifier = method.needsOwningProcessIdentifier
            ? NSRunningApplication.current.processIdentifier
            : nil

        // Every event of every press is built before any is posted, as in the app: half a double
        // click is worse than none, because it reads to the app as an ordinary single click.
        var eventsByClick: [[CGEvent]] = []
        for pressNumber in 1...(isDoubleClick ? 2 : 1) {
            guard let events = mouseEvents(
                forOneClickWithClickState: Int64(pressNumber),
                using: .left,
                atAccessibilityScreenPoint: point
            ) else { return }
            eventsByClick.append(events)
        }

        for (clickIndex, eventsForThisClick) in eventsByClick.enumerated() {
            // A gap exists only between two clicks; the first goes out the moment it is built.
            if clickIndex > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.secondsBetweenTheClicksOfADoubleClick * 1_000_000_000)
                )
            }
            post(eventsForThisClick, method: method, toProcess: owningProcessIdentifier)
            if method == .hidEventTapThenWarpBack {
                CGWarpMouseCursorPosition(cursorHomePointInAccessibilitySpace)
            }
        }
    }

    private func post(_ events: [CGEvent], method: ClickInjectionMethod, toProcess: pid_t?) {
        for event in events {
            switch method {
            case .hidEventTap, .hidEventTapThenWarpBack:
                event.post(tap: .cghidEventTap)
            case .sessionEventTap:
                event.post(tap: .cgSessionEventTap)
            case .annotatedSessionEventTap:
                event.post(tap: .cgAnnotatedSessionEventTap)
            case .postedToOwningProcess:
                // An event posted straight into a process's queue was never
                // routed by the window server, so it arrives carrying no window
                // and AppKit has nothing to dispatch it to — which would read as
                // "this method does not deliver" when what actually happened is
                // that the test never said where to deliver it. These two fields
                // are that statement.
                event.setIntegerValueField(
                    .mouseEventWindowUnderMousePointer,
                    value: Int64(targetWindow.windowNumber)
                )
                event.setIntegerValueField(
                    .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                    value: Int64(targetWindow.windowNumber)
                )
                guard let toProcess else { continue }
                event.postToPid(toProcess)
            }
        }
    }

    /// The probe only ever presses the left button, but the parameter is carried because the event
    /// type and the button have to be chosen together: a `.leftMouseDown` carrying `.right`, or the
    /// reverse, is delivered to the other button's handler, so it presses the wrong button while
    /// looking from here exactly like a click that was posted correctly.
    private func mouseEvents(
        forOneClickWithClickState clickState: Int64,
        using button: CGMouseButton,
        atAccessibilityScreenPoint point: CGPoint
    ) -> [CGEvent]? {
        let (mouseDownType, mouseUpType): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)

        var events: [CGEvent] = []
        for mouseType in [mouseDownType, mouseUpType] {
            guard let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: mouseType,
                mouseCursorPosition: point,
                mouseButton: button
            ) else {
                return nil
            }
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            events.append(event)
        }
        return events
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

    private func printTable(_ outcomes: [TrialOutcome]) {
        print("\n════════ 汇总 ════════")
        print(Self.paddedToColumn("方式", width: 29) + "| 挪指针 | 最大位移 | 停留中位数 | 结束时仍在 | 送到达 | 双击")
        print(String(repeating: "-", count: 29) + "|--------|----------|------------|------------|--------|------")
        for method in methodsToRun {
            let singleClickTrials = outcomes.filter { $0.method == method && !$0.isDoubleClick }
            guard !singleClickTrials.isEmpty else { continue }

            let trialsThatMovedThePointer = singleClickTrials.filter {
                $0.maximumCursorDisplacementInPoints > Self.displacementThresholdInPoints
            }
            let maximumDisplacement = singleClickTrials.map(\.maximumCursorDisplacementInPoints).max() ?? 0
            let displacedSecondsSorted = singleClickTrials.map(\.secondsSpentDisplaced).sorted()
            let medianDisplacedSeconds = displacedSecondsSorted[displacedSecondsSorted.count / 2]
            let stillDisplacedCount = singleClickTrials.filter(\.wasStillDisplacedAtTheEndOfSampling).count
            let deliveredCount = singleClickTrials.filter { $0.receivedClickCount == 2 }.count

            let doubleClickTrial = outcomes.first { $0.method == method && $0.isDoubleClick }
            let doubleClickVerdict = doubleClickTrial.map { trial in
                trial.observedClickCounts == [1, 1, 2, 2] ? "✓" : "✗"
            } ?? "—"

            print(
                Self.paddedToColumn(method.rawValue, width: 29)
                + "| \(singleClickTrials.count == 1 ? "—" : "\(trialsThatMovedThePointer.count)/\(singleClickTrials.count)")    "
                + "| " + Self.paddedToColumn(String(format: "%.1f 点", maximumDisplacement), width: 8)
                + " | " + Self.paddedToColumn(String(format: "%.0f ms", medianDisplacedSeconds * 1000), width: 10)
                + " | " + Self.paddedToColumn("\(stillDisplacedCount)/\(singleClickTrials.count)", width: 10)
                + " | \(deliveredCount)/\(singleClickTrials.count)   "
                + "| \(doubleClickVerdict)"
            )
        }
    }

    /// Reports how many trials did a thing rather than whether all of them did.
    /// An `allSatisfy` over five noisy trials is a verdict one outlier can
    /// reverse, and it reverses it into the opposite of the truth — which is
    /// exactly what the first run of this script did to the method that is
    /// currently shipping.
    private func printConclusion(_ outcomes: [TrialOutcome]) {
        print("\n════════ 判读 ════════")

        let singleClickTrials = outcomes.filter { !$0.isDoubleClick }
        for method in methodsToRun {
            let trials = singleClickTrials.filter { $0.method == method }
            guard !trials.isEmpty else { continue }

            let trialsThatMovedThePointer = trials.filter {
                $0.maximumCursorDisplacementInPoints > Self.displacementThresholdInPoints
            }
            let deliveredCount = trials.filter { $0.receivedClickCount == 2 }.count

            let movementVerdict: String
            if trialsThatMovedThePointer.isEmpty {
                movementVerdict = "指针一次都没动"
            } else {
                let displacedSecondsSorted = trialsThatMovedThePointer.map(\.secondsSpentDisplaced).sorted()
                let medianDisplacedSeconds = displacedSecondsSorted[displacedSecondsSorted.count / 2]
                let stillDisplacedCount = trialsThatMovedThePointer.filter(\.wasStillDisplacedAtTheEndOfSampling).count
                movementVerdict = String(
                    format: "%d/%d 次挪了指针，停留中位数 %.0f ms，%d 次在采样结束时仍停在靶子上",
                    trialsThatMovedThePointer.count, trials.count,
                    medianDisplacedSeconds * 1000, stillDisplacedCount
                )
            }

            let deliveryVerdict = deliveredCount == trials.count
                ? "每次都送达"
                : (deliveredCount == 0 ? "一次都没送到靶子" : "\(deliveredCount)/\(trials.count) 次送达")
            print("· \(method.rawValue)：\(movementVerdict)；\(deliveryVerdict)。")
        }

        print("")
        print("· 这个脚本测不了的是：按物理指针做命中测试的 app（Chrome、Finder 之类）接不接受")
        print("  一个不挪指针的投递方式。挑出候选之后要拿真实的 [CLICK:…] 在 app 里手测一次。")
    }
}

// MARK: - Entry point

/// Parses only the two options this needs; anything unrecognised is reported
/// rather than ignored, because a typo silently running the default set is how
/// a measurement ends up describing something other than what was asked for.
private func parseArguments() -> (repetitions: Int, onlyMethod: ClickInjectionMethod?) {
    var repetitions = 8
    var onlyMethod: ClickInjectionMethod?
    var arguments = Array(CommandLine.arguments.dropFirst())

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--repetitions":
            guard let parsed = arguments.first.flatMap(Int.init) else {
                print("❌ --repetitions 需要一个数字"); exit(1)
            }
            repetitions = parsed
            arguments.removeFirst()
        case "--only":
            guard let name = arguments.first, let method = ClickInjectionMethod(rawValue: name) else {
                print("❌ --only 需要一个方式名，可选：")
                ClickInjectionMethod.allCases.forEach { print("     \($0.rawValue)") }
                exit(1)
            }
            onlyMethod = method
            arguments.removeFirst()
        default:
            print("❌ 不认识的参数 \(argument)")
            print("   可选：--repetitions N | --only <方式名>")
            ClickInjectionMethod.allCases.forEach { print("     方式名：\($0.rawValue)") }
            exit(1)
        }
    }
    return (repetitions, onlyMethod)
}

let parsedArguments = parseArguments()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

Task { @MainActor in
    await ClickInjectionCheck.run(
        repetitions: parsedArguments.repetitions,
        onlyMethod: parsedArguments.onlyMethod
    )
    exit(0)
}

application.run()
