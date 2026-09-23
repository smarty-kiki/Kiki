//
//  UserActionRecorder.swift
//  kiki-desktop-agent
//
//  Watches the mouse while the user is recording a run of their own actions, and reduces what it
//  sees to the actions Kiki performs again afterwards. Also owns the shortcut that starts and ends
//  a recording, which it has to watch for at all times because that is what ends one.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// One thing the user did, as the action that would do it again.
///
/// The action is stored as the value the arrival performs rather than as a description of a mouse
/// event, so a recording replays through the same code a tag or a terminal command reaches and
/// there is no translation layer to get the two out of step.
struct RecordedUserAction {
    let action: ElementActionOnArrival
    /// Where it happened, in the global screen space `CGEvent` reports — the same space a terminal
    /// gives `kiki click -x -y` in, and the one `resolveActionTarget` flips.
    let globalScreenPoint: CGPoint
    /// Where a drag let go. The one action with a second point, and nil for every other.
    let dragDestinationGlobalScreenPoint: CGPoint?
}

/// The recorder.
///
/// Listen-only, so the shortcut and everything the user does with the mouse still reach the app
/// underneath — Kiki is watching a recording, not intercepting one.
final class UserActionRecorder: ObservableObject {

    /// Fires once for each press of the shortcut. A press and not a click, because the shortcut has
    /// no meaning on release: what starts a recording and what ends it are the same event.
    let shortcutWasTappedPublisher = PassthroughSubject<Void, Never>()

    // MARK: - Limits

    /// The modifiers the recording shortcut is made of. Modifiers alone, so the chord can be
    /// pressed without the front app receiving a character.
    private static let shortcutModifierFlags: CGEventFlags = [.maskShift, .maskAlternate]

    /// How far the pointer has to travel while the button is down for the gesture to be a drag
    /// rather than a click.
    ///
    /// A few points, because a click is never perfectly still: a hand resting on a mouse moves it
    /// by a point or two between the press and the release, and calling that a drag would replay
    /// every click in the recording as a movement to the same place.
    private static let pointsOfMovementThatMakeAPressADrag: CGFloat = 3

    /// The longest gap between two wheel events that still counts as one scroll.
    ///
    /// A trackpad reports a scroll as a stream of small events and a wheel as one per notch, and
    /// what a recording wants is the gesture rather than the stream: without this, one flick of two
    /// fingers becomes forty recorded scrolls.
    private static let secondsThatSeparateTwoScrollEvents: TimeInterval = 0.15

    /// What a line of a line-based wheel is worth in points, which is the unit a scroll is replayed
    /// in.
    ///
    /// A trackpad reports its deltas in points, and a wheel that clicks from notch to notch reports
    /// the same field in lines — the two cannot be told apart downstream, so the conversion has to
    /// happen here.
    private static let pointsPerLineOfALineBasedWheel: CGFloat = 10

    /// How many actions one recording can hold.
    ///
    /// A recording is replayed in a loop, so its length is how long the user waits for the loop to
    /// come round. Well past any run of steps a person performs on purpose.
    private static let mostActionsInOneRecording = 200

    // MARK: - State

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var isRecordingWhatTheUserIsDoing = false
    private var recordedUserActions: [RecordedUserAction] = []
    private var shortcutWasPressedTheLastTimeTheFlagsChanged = false
    private var pressInProgress: PressInProgress?
    private var scrollInProgress: ScrollInProgress?

    /// A press that has not been recorded yet, because the system may still be counting it.
    ///
    /// The count is the system's own — the `mouseEventClickState` it puts on each press, raised for
    /// a press that continues the one before — so what makes two presses one double click is the
    /// same judgement the app underneath will make when they are replayed.
    private struct PressInProgress {
        let isTheRightButton: Bool
        let pointWhereTheButtonWentDown: CGPoint
        /// The furthest the pointer travelled while the button was down, which is what says
        /// whether this is a drag. Tracked as it moves rather than measured between the press and
        /// the release, so a drag that comes back to where it started is still a drag.
        var furthestPointsTravelled: CGFloat = 0
        var highestClickState: Int
    }

    /// A run of wheel events that has not been recorded yet, for the same reason a press has not:
    /// the gesture is only over once nothing more arrives.
    private struct ScrollInProgress {
        var verticalPoints: CGFloat
        var horizontalPoints: CGFloat
        let pointWhereItStarted: CGPoint
        var timestampOfTheMostRecentEvent: CGEventTimestamp
    }

    deinit {
        stop()
    }

    // MARK: - The tap

    func start() {
        // Never restart a running tap, for the same reason the push-to-talk monitor does not: the
        // permission poller calls start() every few seconds, and a fresh tap would drop the press
        // and scroll in progress.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .scrollWheel,
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let userActionRecorder = Unmanaged<UserActionRecorder>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return userActionRecorder.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Action recorder: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Action recorder: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isRecordingWhatTheUserIsDoing = false
        recordedUserActions = []
        pressInProgress = nil
        scrollInProgress = nil

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    // MARK: - Recording

    func startRecording() {
        recordedUserActions = []
        pressInProgress = nil
        scrollInProgress = nil
        isRecordingWhatTheUserIsDoing = true
    }

    /// Ends the recording and hands back what it holds, with whatever gesture was still in progress
    /// included — the user's last action before the shortcut is as much part of the recording as
    /// the ones before it.
    @discardableResult
    func stopRecording() -> [RecordedUserAction] {
        // Settled before the flag goes down, because settling is what records them: `append` drops
        // everything that arrives once the recording has ended, so the other order loses the very
        // gesture this is here to keep.
        settleThePressInProgress()
        settleTheScrollInProgress()
        isRecordingWhatTheUserIsDoing = false

        let recordedUserActions = self.recordedUserActions
        self.recordedUserActions = []
        return recordedUserActions
    }

    // MARK: - What the tap sees

    private func handleGlobalEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // The shortcut is watched for whether or not a recording is running, because the same press
        // is what starts one, what ends one and what ends a replay. Everything else is dropped the
        // moment it arrives when no recording is running.
        if eventType == .flagsChanged {
            handleTheModifiersChanging(event)
            return Unmanaged.passUnretained(event)
        }

        guard isRecordingWhatTheUserIsDoing else { return Unmanaged.passUnretained(event) }

        switch eventType {
        case .leftMouseDown:
            handleTheLeftButtonGoingDown(event)
        case .leftMouseDragged:
            handleTheMouseMovingWithTheLeftButtonDown(event)
        case .leftMouseUp:
            handleTheLeftButtonComingUp(event)
        case .rightMouseDown:
            handleTheRightButtonGoingDown(event)
        case .scrollWheel:
            handleTheWheelTurning(event)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    /// The shortcut fires on the press, once, and nothing happens on the release.
    private func handleTheModifiersChanging(_ event: CGEvent) {
        let isShortcutPressedNow = event.flags.intersection(Self.shortcutModifierFlags) == Self.shortcutModifierFlags
        guard isShortcutPressedNow != shortcutWasPressedTheLastTimeTheFlagsChanged else { return }

        shortcutWasPressedTheLastTimeTheFlagsChanged = isShortcutPressedNow
        guard isShortcutPressedNow else { return }

        print("⏺ Action recorder: shortcut tapped")
        shortcutWasTappedPublisher.send(())
    }

    private func handleTheLeftButtonGoingDown(_ event: CGEvent) {
        settleTheScrollInProgress()

        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
        // A first press ends whatever the last one turned out to be: the system counting from one
        // again is what says the run is over.
        if clickState <= 1 || pressInProgress == nil || pressInProgress?.isTheRightButton == true {
            settleThePressInProgress()
            pressInProgress = PressInProgress(
                isTheRightButton: false,
                pointWhereTheButtonWentDown: event.location,
                highestClickState: max(clickState, 1)
            )
            return
        }

        // Otherwise this is the second or third press of a gesture the system is still counting, so
        // it is the same action rather than a new one.
        guard var press = pressInProgress else { return }
        press.highestClickState = max(press.highestClickState, clickState)
        pressInProgress = press
    }

    private func handleTheMouseMovingWithTheLeftButtonDown(_ event: CGEvent) {
        guard var press = pressInProgress, !press.isTheRightButton else { return }
        press.furthestPointsTravelled = max(
            press.furthestPointsTravelled,
            event.location.distanceTo(press.pointWhereTheButtonWentDown)
        )
        pressInProgress = press
    }

    private func handleTheLeftButtonComingUp(_ event: CGEvent) {
        guard var press = pressInProgress, !press.isTheRightButton else { return }
        press.furthestPointsTravelled = max(
            press.furthestPointsTravelled,
            event.location.distanceTo(press.pointWhereTheButtonWentDown)
        )

        guard press.furthestPointsTravelled > Self.pointsOfMovementThatMakeAPressADrag else {
            // Still open: the system may report a second press on the same run, which would make
            // this a double click rather than the single click it looks like now.
            pressInProgress = press
            return
        }

        pressInProgress = nil
        append(RecordedUserAction(
            action: .drag,
            globalScreenPoint: press.pointWhereTheButtonWentDown,
            dragDestinationGlobalScreenPoint: event.location
        ))
    }

    private func handleTheRightButtonGoingDown(_ event: CGEvent) {
        settleTheScrollInProgress()

        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
        if clickState <= 1 || pressInProgress == nil || pressInProgress?.isTheRightButton == false {
            settleThePressInProgress()
            pressInProgress = PressInProgress(
                isTheRightButton: true,
                pointWhereTheButtonWentDown: event.location,
                highestClickState: max(clickState, 1)
            )
            return
        }

        guard var press = pressInProgress else { return }
        press.highestClickState = max(press.highestClickState, clickState)
        pressInProgress = press
    }

    private func handleTheWheelTurning(_ event: CGEvent) {
        settleThePressInProgress()

        let movement = Self.pointsOfMovement(ofTheWheelEvent: event)
        let verticalPoints = movement.vertical
        let horizontalPoints = movement.horizontal

        if var scroll = scrollInProgress,
           event.timestamp - scroll.timestampOfTheMostRecentEvent
               < CGEventTimestamp(Self.secondsThatSeparateTwoScrollEvents * 1_000_000_000) {
            scroll.verticalPoints += verticalPoints
            scroll.horizontalPoints += horizontalPoints
            scroll.timestampOfTheMostRecentEvent = event.timestamp
            scrollInProgress = scroll
            return
        }

        settleTheScrollInProgress()
        scrollInProgress = ScrollInProgress(
            verticalPoints: verticalPoints,
            horizontalPoints: horizontalPoints,
            pointWhereItStarted: event.location,
            timestampOfTheMostRecentEvent: event.timestamp
        )
    }

    // MARK: - Recording what is in progress

    /// The press that is still open is recorded as whatever the system's count last said it was.
    private func settleThePressInProgress() {
        guard let press = pressInProgress else { return }
        pressInProgress = nil

        append(RecordedUserAction(
            action: .press(Self.clickKind(forThePress: press)),
            globalScreenPoint: press.pointWhereTheButtonWentDown,
            dragDestinationGlobalScreenPoint: nil
        ))
    }

    /// How far one wheel event moved, in points.
    ///
    /// **A trackpad's movement is in the point delta, and the delta beside it is not the same
    /// number.** Measured on a real flick, `deltaAxis1` is that movement divided by about ten and
    /// rounded to a whole number — one event of the run held `delta1 = -2` beside `pointDelta1 =
    /// -26` — so a recording read from it replays every flick at a tenth of the distance covered.
    /// `fixedPtDeltaAxis1` is the same approximation with its fraction kept, and is no better.
    ///
    /// Read as doubles rather than as the integers the fields are named for: a trackpad reports
    /// fractions of a point, and reading them as integers would turn a slow scroll into no scroll at
    /// all and drop the rest of it on the floor.
    private static func pointsOfMovement(ofTheWheelEvent event: CGEvent) -> (vertical: CGFloat, horizontal: CGFloat) {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
            let pointsPerLine = pointsPerLineOfALineBasedWheel
            return (
                vertical: CGFloat(event.getDoubleValueField(.scrollWheelEventDeltaAxis1)) * pointsPerLine,
                horizontal: CGFloat(event.getDoubleValueField(.scrollWheelEventDeltaAxis2)) * pointsPerLine
            )
        }

        return (
            vertical: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
            horizontal: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        )
    }

    /// A run of wheel events goes out as one scroll along the axis it moved the most, in the
    /// direction it moved it.
    ///
    /// One axis rather than two: a scroll Kiki makes goes one way, so a diagonal flick of two
    /// fingers is recorded as the movement the user would name if asked which way they scrolled.
    private func settleTheScrollInProgress() {
        guard let scroll = scrollInProgress else { return }
        scrollInProgress = nil

        let verticalPoints = abs(scroll.verticalPoints)
        let horizontalPoints = abs(scroll.horizontalPoints)
        guard max(verticalPoints, horizontalPoints) >= 1 else { return }

        let direction: ElementScrollDirection
        let distance: CGFloat
        if verticalPoints >= horizontalPoints {
            // Negative is down, which is the sign convention `ElementScroller.wheelDeltas` writes
            // and the one a trackpad reports in.
            direction = scroll.verticalPoints < 0 ? .down : .up
            distance = verticalPoints
        } else {
            direction = scroll.horizontalPoints < 0 ? .right : .left
            distance = horizontalPoints
        }

        append(RecordedUserAction(
            action: .scroll(direction, distance: .points(distance)),
            globalScreenPoint: scroll.pointWhereItStarted,
            dragDestinationGlobalScreenPoint: nil
        ))
    }

    private func append(_ recordedUserAction: RecordedUserAction) {
        guard isRecordingWhatTheUserIsDoing else { return }
        guard recordedUserActions.count < Self.mostActionsInOneRecording else { return }
        recordedUserActions.append(recordedUserAction)
    }

    /// Which press a run of presses amounts to.
    ///
    /// The count is the system's, and a fourth press of a run is reported as a fourth: there is no
    /// gesture beyond three, so anything at or above three is the three-press one. The right button
    /// has no counted variant, so a run of right presses is one right click.
    private static func clickKind(forThePress press: PressInProgress) -> ElementClickKind {
        guard !press.isTheRightButton else { return .rightClick }
        switch press.highestClickState {
        case 2: return .doubleClick
        case 3...: return .tripleClick
        default: return .singleClick
        }
    }
}

private extension CGPoint {
    func distanceTo(_ otherPoint: CGPoint) -> CGFloat {
        hypot(otherPoint.x - x, otherPoint.y - y)
    }
}
