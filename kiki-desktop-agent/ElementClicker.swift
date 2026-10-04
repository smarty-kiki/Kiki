//
//  ElementClicker.swift
//  kiki-desktop-agent
//
//  Posts real mouse and keyboard events — the one place the app acts on the machine rather than
//  merely suggesting. Nothing here reads the Accessibility tree: the elements this exists for never
//  offer `AXPress`.
//

import AppKit
import ApplicationServices

/// The gesture performed at the point — button and press count in one value, so they cannot disagree.
enum ElementClickKind {
    case singleClick
    case doubleClick
    case tripleClick
    case rightClick

    var buttonThatIsPressed: CGMouseButton {
        switch self {
        case .singleClick, .doubleClick, .tripleClick: return .left
        case .rightClick: return .right
        }
    }

    /// How many times the button goes down. A `switch` over every case, so a kind added later fails to
    /// build rather than silently pressing once.
    var numberOfPresses: Int {
        switch self {
        case .singleClick: return 1
        case .doubleClick: return 2
        case .tripleClick: return 3
        case .rightClick: return 1
        }
    }
}

extension ElementClickKind: CustomStringConvertible {
    var description: String {
        switch self {
        case .singleClick: return "single click"
        case .doubleClick: return "double click"
        case .tripleClick: return "triple click"
        case .rightClick: return "right click"
        }
    }
}

/// Which way a scroll goes — the other gesture axis; the two never mix.
enum ElementScrollDirection {
    case up
    case down
    case left
    case right
}

extension ElementScrollDirection: CustomStringConvertible {
    var description: String {
        switch self {
        case .up: return "scroll up"
        case .down: return "scroll down"
        case .left: return "scroll left"
        case .right: return "scroll right"
        }
    }
}

/// How far a scroll goes, in the unit the request was made in: screenfuls for a tag or a terminal, points
/// for a recorded scroll, which a screenful would replay at another distance.
enum ElementScrollDistance: Equatable {
    case screenfuls(CGFloat)
    case points(CGFloat)

    /// A whole screenful count reads `1` rather than `1.0` — the one copy, so the terminal's sentence
    /// and the cursor's bubble cannot disagree.
    static func screenfulsAsText(_ screenfuls: CGFloat) -> String {
        let wholeScreenfuls = screenfuls.rounded()
        if screenfuls == wholeScreenfuls {
            return String(Int(wholeScreenfuls))
        }
        return String(Double(screenfuls))
    }
}

extension ElementScrollDistance: CustomStringConvertible {
    var description: String {
        switch self {
        case .screenfuls(let count): return "\(Self.screenfulsAsText(count)) screenful(s)"
        case .points(let points): return "\(Int(points.rounded())) point(s)"
        }
    }
}

/// What Kiki types rather than what it does with the mouse.
enum ElementKeyboardInput: Equatable {
    case text(String)
    /// The combination as it was written (`cmd+s`, `⌘⇧T`, `return`), not a decoded value, so a name
    /// that does not read can be refused with a sentence rather than failing to decode silently.
    case combination(name: String)
}

/// Who named the thing being clicked, which decides whether naming nothing is a refusal.
enum ElementClickOrigin {
    /// A tag in the model's reply — the label is the only clue to which element was meant, so a tag
    /// without one names nothing that could be clicked.
    case theModelsTag
    /// A command the user typed — the coordinate form names a point rather than an element, so
    /// carrying no text is the ordinary case.
    case theUsersOwnCommand
}

/// Where the gesture families meet — one value rather than a kind beside a flag, because the four
/// decisions read off it must not disagree: red flight, bubble, arrival action, pointer carry.
enum ElementActionOnArrival: Equatable {
    case press(ElementClickKind)
    case scroll(ElementScrollDirection, distance: ElementScrollDistance)
    /// The one action that is a movement between two points; where it lets go travels beside this,
    /// because it is the flight's property rather than the gesture's.
    case drag
    case keyboard(ElementKeyboardInput)

    /// A press and a keyboard action carry the pointer for legibility — the red carry is what says "Kiki is
    /// about to press this" — a scroll because the point is what aims it, since the tap that leaves the
    /// pointer alone delivers nothing, and a drag because it *is* the pointer moving.
    var carriesTheUsersPointer: Bool { true }
}

/// No case per gesture: which button and how many times is an input to this rather than a result.
enum ElementClickOutcome {
    case clicked
    /// Nothing was posted, and the reason is on this side of the event system.
    case failedToPostTheClick
    case refusedBecauseTheTagCarriedNoLabel
    /// Accessibility is not granted. Synthesising an event needs it.
    case refusedBecauseAccessibilityIsNotEnabled
    case refusedBecauseTheLabelLooksDestructive(matchedWord: String)
}

extension ElementClickOutcome {
    /// Whether the click actually went out — a refusal and a failed post are both "the screen is
    /// unchanged". A `switch` over every case, so one added later fails to build rather than reading as
    /// a failure.
    var isASuccess: Bool {
        switch self {
        case .clicked: return true
        case .failedToPostTheClick, .refusedBecauseTheTagCarriedNoLabel,
             .refusedBecauseAccessibilityIsNotEnabled, .refusedBecauseTheLabelLooksDestructive:
            return false
        }
    }
}

extension ElementClickOutcome: CustomStringConvertible {
    var description: String {
        switch self {
        case .clicked:
            return "clicked"
        case .failedToPostTheClick:
            return "the click could not be posted"
        case .refusedBecauseTheTagCarriedNoLabel:
            return "refused: the tag named no element"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "refused: accessibility is not granted"
        case .refusedBecauseTheLabelLooksDestructive(let matchedWord):
            return "refused: the label says \"\(matchedWord)\""
        }
    }
}

enum ElementScrollOutcome {
    case scrolled
    case failedToPostTheScroll
    case refusedBecauseAccessibilityIsNotEnabled
}

extension ElementScrollOutcome {
    var isASuccess: Bool {
        switch self {
        case .scrolled: return true
        case .failedToPostTheScroll, .refusedBecauseAccessibilityIsNotEnabled: return false
        }
    }
}

extension ElementScrollOutcome: CustomStringConvertible {
    var description: String {
        switch self {
        case .scrolled:
            return "scrolled"
        case .failedToPostTheScroll:
            return "the scroll could not be posted"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "refused: accessibility is not granted"
        }
    }
}

enum ElementDragOutcome {
    case dragged
    case failedToPostTheDrag
    /// The drag named nowhere to let go, and half a drag is a press held down on the thing it was
    /// moving.
    case refusedBecauseNoDestinationWasNamed
    case refusedBecauseAccessibilityIsNotEnabled
}

extension ElementDragOutcome {
    var isASuccess: Bool {
        switch self {
        case .dragged: return true
        case .failedToPostTheDrag, .refusedBecauseNoDestinationWasNamed,
             .refusedBecauseAccessibilityIsNotEnabled:
            return false
        }
    }
}

extension ElementDragOutcome: CustomStringConvertible {
    var description: String {
        switch self {
        case .dragged:
            return "dragged"
        case .failedToPostTheDrag:
            return "the drag could not be posted"
        case .refusedBecauseNoDestinationWasNamed:
            return "refused: the drag named no destination"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "refused: accessibility is not granted"
        }
    }
}

/// One case for both halves of the family: what was asked for is an input to this, not a result.
enum ElementKeyboardOutcome {
    case postedTheKeystrokes
    case failedToPostTheKeystrokes
    case refusedBecauseTheElementCannotBeClicked(ElementClickRefusal)
    case refusedBecauseTheCombinationIsADangerousOne(matchedName: String)
    case refusedBecauseTheCombinationIsNotOneKikiKnows(name: String)
    case refusedBecauseTheTextIsLongerThanKikiWillType(characterCount: Int)
    case refusedBecauseAccessibilityIsNotEnabled
}

extension ElementKeyboardOutcome {
    var isASuccess: Bool {
        switch self {
        case .postedTheKeystrokes:
            return true
        case .failedToPostTheKeystrokes, .refusedBecauseTheElementCannotBeClicked,
             .refusedBecauseTheCombinationIsADangerousOne,
             .refusedBecauseTheCombinationIsNotOneKikiKnows,
             .refusedBecauseTheTextIsLongerThanKikiWillType,
             .refusedBecauseAccessibilityIsNotEnabled:
            return false
        }
    }
}

extension ElementKeyboardOutcome: CustomStringConvertible {
    var description: String {
        switch self {
        case .postedTheKeystrokes:
            return "posted the keystrokes"
        case .failedToPostTheKeystrokes:
            return "the keystrokes could not be posted"
        case .refusedBecauseTheElementCannotBeClicked(let clickRefusal):
            return "refused: the element cannot be clicked (\(clickRefusal))"
        case .refusedBecauseTheCombinationIsADangerousOne(let matchedName):
            return "refused: \(matchedName) is a combination Kiki will not press"
        case .refusedBecauseTheCombinationIsNotOneKikiKnows(let name):
            return "refused: \(name) is not a combination Kiki knows"
        case .refusedBecauseTheTextIsLongerThanKikiWillType(let characterCount):
            return "refused: \(characterCount) characters is more than Kiki will type"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "refused: accessibility is not granted"
        }
    }
}

/// A drag is defined by where it stops, so a missing destination is a refusal no other gesture has.
enum ElementDragRefusal {
    case noDestinationWasNamed
    case accessibilityIsNotEnabled

    var outcome: ElementDragOutcome {
        switch self {
        case .noDestinationWasNamed:
            return .refusedBecauseNoDestinationWasNamed
        case .accessibilityIsNotEnabled:
            return .refusedBecauseAccessibilityIsNotEnabled
        }
    }
}

/// Separate from the outcome because a refusal is decided *before* the click runs — the question the click
/// sound is played on.
enum ElementClickRefusal {
    case theTagCarriedNoLabel
    case theLabelLooksDestructive(matchedWord: String)
    case accessibilityIsNotEnabled

    var outcome: ElementClickOutcome {
        switch self {
        case .theTagCarriedNoLabel:
            return .refusedBecauseTheTagCarriedNoLabel
        case .theLabelLooksDestructive(let matchedWord):
            return .refusedBecauseTheLabelLooksDestructive(matchedWord: matchedWord)
        case .accessibilityIsNotEnabled:
            return .refusedBecauseAccessibilityIsNotEnabled
        }
    }
}

/// One case against the click's three: a scroll is not about a label.
enum ElementScrollRefusal {
    case accessibilityIsNotEnabled

    var outcome: ElementScrollOutcome {
        switch self {
        case .accessibilityIsNotEnabled:
            return .refusedBecauseAccessibilityIsNotEnabled
        }
    }
}

/// Typing begins by clicking the element, so the first case carries the click's own refusal; the rest are a
/// combination Kiki will not press or cannot read, and text too long to type.
enum ElementKeyboardRefusal {
    case theElementCannotBeClicked(ElementClickRefusal)
    /// A combination in `ElementKeyboard.writtenFormsKikiWillNotPress`.
    case theCombinationIsADangerousOne(matchedName: String)
    case theCombinationIsNotOneKikiKnows(name: String)
    case theTextIsLongerThanKikiWillType(characterCount: Int)
    case accessibilityIsNotEnabled

    var outcome: ElementKeyboardOutcome {
        switch self {
        case .theElementCannotBeClicked(let clickRefusal):
            return .refusedBecauseTheElementCannotBeClicked(clickRefusal)
        case .theCombinationIsADangerousOne(let matchedName):
            return .refusedBecauseTheCombinationIsADangerousOne(matchedName: matchedName)
        case .theCombinationIsNotOneKikiKnows(let name):
            return .refusedBecauseTheCombinationIsNotOneKikiKnows(name: name)
        case .theTextIsLongerThanKikiWillType(let characterCount):
            return .refusedBecauseTheTextIsLongerThanKikiWillType(characterCount: characterCount)
        case .accessibilityIsNotEnabled:
            return .refusedBecauseAccessibilityIsNotEnabled
        }
    }
}

enum ElementClicker {

    // MARK: - Limits

    /// One constant for a double and a triple alike, because the system counts both with
    /// `NSEvent.doubleClickInterval` — which also bounds this from above, at the ~0.15 s the user can turn
    /// it down to, past which the app sees two unrelated clicks. Bounded from below by non-zero, because
    /// events posted back to back carry timestamps microseconds apart.
    private static let secondsBetweenThePressesOfOneGesture = 0.05

    /// `.hidSystemState` describes the state a real mouse would report — indistinguishable from hardware.
    private static let clickEventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: - Clicking

    /// Both the click sound's question and `clickElement` ask it here, before the click runs, so the sound
    /// stays silent for a declined click. Only the missing-label refusal depends on `origin` — a terminal's
    /// click at a coordinate has no label by construction.
    static func refusalOfClick(
        matchingElementLabel elementLabel: String?,
        origin: ElementClickOrigin
    ) -> ElementClickRefusal? {
        let trimmedElementLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedElementLabel.isEmpty {
            if origin == .theModelsTag {
                return .theTagCarriedNoLabel
            }
        } else if let matchedWord = destructiveWord(in: trimmedElementLabel) {
            return .theLabelLooksDestructive(matchedWord: matchedWord)
        }

        guard AXIsProcessTrusted() else {
            return .accessibilityIsNotEnabled
        }

        return nil
    }

    /// `primaryScreenHeightInPoints` is passed in because `NSScreen` is AppKit and this file is not.
    static func clickElement(
        atAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat,
        matchingElementLabel elementLabel: String?,
        kind: ElementClickKind,
        origin: ElementClickOrigin
    ) async -> ElementClickOutcome {
        if let refusal = refusalOfClick(matchingElementLabel: elementLabel, origin: origin) {
            return refusal.outcome
        }

        return await postClick(
            atAccessibilityScreenPoint: accessibilityPoint(
                fromAppKitScreenLocation: appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            ),
            kind: kind
        )
    }

    /// The point is in the Accessibility API's coordinate space, and the event carries it, so the click
    /// lands where the event says rather than where the pointer stands.
    private static func postClick(
        atAccessibilityScreenPoint accessibilityScreenPoint: CGPoint,
        kind: ElementClickKind
    ) async -> ElementClickOutcome {
        // Every event of every press is built before any is posted: half a double click reads as an
        // ordinary single click, merely selecting the thing the user asked to open.
        var eventsByClick: [[CGEvent]] = []
        for pressNumber in 1...kind.numberOfPresses {
            guard let events = mouseEvents(
                forOneClickWithClickState: Int64(pressNumber),
                using: kind.buttonThatIsPressed,
                atAccessibilityScreenPoint: accessibilityScreenPoint
            ) else {
                return .failedToPostTheClick
            }
            eventsByClick.append(events)
        }

        for (clickIndex, eventsForThisClick) in eventsByClick.enumerated() {
            if clickIndex > 0 {
                try? await Task.sleep(nanoseconds: UInt64(secondsBetweenThePressesOfOneGesture * 1_000_000_000))
            }
            for event in eventsForThisClick {
                event.post(tap: .cghidEventTap)
            }
        }

        return .clicked
    }

    /// The press and release of one click. The click state is stated rather than left to timing: a single
    /// click says 1, so one landing close behind the user's own is not read as the second half of their
    /// double click. The event type and the button change together: a `.leftMouseDown` carrying the right
    /// button goes to the other button's handler, pressing the wrong button while this side sees a correct
    /// click.
    private static func mouseEvents(
        forOneClickWithClickState clickState: Int64,
        using button: CGMouseButton,
        atAccessibilityScreenPoint accessibilityScreenPoint: CGPoint
    ) -> [CGEvent]? {
        let (mouseDownType, mouseUpType): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)

        var events: [CGEvent] = []
        for mouseType in [mouseDownType, mouseUpType] {
            guard let event = CGEvent(
                mouseEventSource: clickEventSource,
                mouseType: mouseType,
                mouseCursorPosition: accessibilityScreenPoint,
                mouseButton: button
            ) else {
                return nil
            }
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            events.append(event)
        }
        return events
    }

    // MARK: - Coordinates

    /// Converts a global AppKit screen location into the coordinate space `CGEvent` posts in, which the
    /// Accessibility API also uses: origin at the primary display's top-left with y growing downward,
    /// against AppKit's bottom-left with y growing up. No display needs a special case, including one above
    /// the primary, which this maps to the negative y that space describes.
    ///
    /// The only copy: a second one would put a click a whole screen height from its aim.
    static func accessibilityPoint(
        fromAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: appKitScreenLocation.x,
            y: primaryScreenHeightInPoints - appKitScreenLocation.y
        )
    }

    /// The other direction, for a coordinate typed on the command line; the flip is its own inverse, so
    /// this calls the one above.
    static func appKitScreenLocation(
        fromAccessibilityScreenPoint accessibilityScreenPoint: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) -> CGPoint {
        accessibilityPoint(
            fromAppKitScreenLocation: accessibilityScreenPoint,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    // MARK: - Destructive labels

    /// A label naming one of these is never clicked: a refusal costs a click the user can perform
    /// themselves, accepting costs a deletion.
    private static let destructiveChineseWords = [
        "删除", "清空", "卸载", "格式化", "重置", "还原", "退出", "关机", "重启", "注销", "购买", "支付", "发送",
    ]

    private static let destructiveEnglishWords = [
        "delete", "remove", "erase", "uninstall", "format", "reset", "restore",
        "quit", "shutdown", "restart", "log out", "buy", "purchase", "pay", "send",
    ]

    /// Matched on word boundaries rather than anywhere: "display" contains "pay" and "preset" contains
    /// "reset".
    private static let destructiveEnglishWordPattern: NSRegularExpression? = {
        let escapedWords = destructiveEnglishWords.map { NSRegularExpression.escapedPattern(for: $0) }
        return try? NSRegularExpression(
            pattern: "\\b(\(escapedWords.joined(separator: "|")))\\b",
            options: [.caseInsensitive]
        )
    }()

    private static func destructiveWord(in text: String) -> String? {
        guard !text.isEmpty else { return nil }

        if let chineseWord = destructiveChineseWords.first(where: { text.contains($0) }) {
            return chineseWord
        }

        guard let match = destructiveEnglishWordPattern?.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ), let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}

/// Nothing here presses anything: the whole of what a scroll can do, scrolling back undoes — which is why a
/// scroll has no destructive-word rule.
enum ElementScroller {

    // MARK: - Limits

    /// How much of the display's own edge one screenful covers — under a whole screen on purpose, so
    /// some of what the reader was following stays in view.
    private static let fractionOfTheDisplayOneScreenfulCovers: CGFloat = 0.8

    /// The smallest distance one request can carry — clamping half a screen up to a whole one is
    /// silently the scroll the request was made to avoid.
    static let smallestScreenfulsInOneRequest: CGFloat = 0.5

    /// The most screenfuls one request can carry — twenty screens is past the end of anything a person
    /// reads, and both callers can produce a larger number.
    static let mostScreenfulsInOneRequest = 20

    /// The gap between two screenfuls of one request — one event per screenful rather than one large
    /// delta, which keeps an oversized delta out of any wheel-scaling rule.
    private static let secondsBetweenScreenfuls = 0.02

    private static let scrollEventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: - Scrolling

    /// Asked before the red flight, which says "I am about to do this here" and must not be made for a
    /// scroll that will not happen.
    static func refusalOfScroll() -> ElementScrollRefusal? {
        guard AXIsProcessTrusted() else {
            return .accessibilityIsNotEnabled
        }
        return nil
    }

    /// What one screenful covers at a point — measured along the edge the direction moves, so sideways and
    /// vertical screenfuls differ on a wide display.
    static func oneScreenfulInPoints(
        for direction: ElementScrollDirection,
        displayFrame: CGRect
    ) -> CGFloat {
        switch direction {
        case .up, .down: return displayFrame.height * fractionOfTheDisplayOneScreenfulCovers
        case .left, .right: return displayFrame.width * fractionOfTheDisplayOneScreenfulCovers
        }
    }

    /// `displayFrame` is what a screenful is measured against, passed in because `NSScreen` is AppKit and
    /// this file is not.
    static func scrollElement(
        atAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat,
        direction: ElementScrollDirection,
        distance: ElementScrollDistance,
        displayFrame: CGRect
    ) async -> ElementScrollOutcome {
        if let refusal = refusalOfScroll() {
            return refusal.outcome
        }

        let pointsOfEachEvent = pointsOfEachWheelEvent(
            for: distance,
            pointsPerScreenful: oneScreenfulInPoints(for: direction, displayFrame: displayFrame)
        )
        let accessibilityScreenPoint = ElementClicker.accessibilityPoint(
            fromAppKitScreenLocation: appKitScreenLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )

        // Every event is built before any is posted: a request that gave up half way has already moved
        // the screen.
        var eventForEachWheelEvent: [CGEvent] = []
        for points in pointsOfEachEvent {
            guard let event = scrollEvent(
                for: direction,
                byPoints: points,
                atAccessibilityScreenPoint: accessibilityScreenPoint
            ) else {
                return .failedToPostTheScroll
            }
            eventForEachWheelEvent.append(event)
        }

        for (wheelEventIndex, event) in eventForEachWheelEvent.enumerated() {
            if wheelEventIndex > 0 {
                try? await Task.sleep(nanoseconds: UInt64(secondsBetweenScreenfuls * 1_000_000_000))
            }
            event.post(tap: .cghidEventTap)
        }

        return .scrolled
    }

    /// One wheel event per screenful, plus the leftover as an event of its own — which is what carries a
    /// fractional request, so `:x2.5` is that long rather than rounded up. Each unit is bounded at the same
    /// total, so a thousand points cannot become a hundred events.
    private static func pointsOfEachWheelEvent(
        for distance: ElementScrollDistance,
        pointsPerScreenful: CGFloat
    ) -> [CGFloat] {
        switch distance {
        case .screenfuls(let screenfuls):
            var screenfulsLeft = min(max(screenfuls, smallestScreenfulsInOneRequest),
                                     CGFloat(mostScreenfulsInOneRequest))
            var pointsOfEachEvent: [CGFloat] = []
            while screenfulsLeft > 0 {
                let screenfulsThisEvent = min(screenfulsLeft, 1)
                pointsOfEachEvent.append(screenfulsThisEvent * pointsPerScreenful)
                screenfulsLeft -= screenfulsThisEvent
            }
            return pointsOfEachEvent

        case .points(let points):
            // A floor of one point: below that the delta rounds to nothing, which is not the gesture
            // that was recorded.
            var pointsLeft = min(max(points, 1), pointsPerScreenful * CGFloat(mostScreenfulsInOneRequest))
            var pointsOfEachEvent: [CGFloat] = []
            while pointsLeft > 0 {
                let pointsThisEvent = min(pointsLeft, pointsPerScreenful)
                pointsOfEachEvent.append(pointsThisEvent)
                pointsLeft -= pointsThisEvent
            }
            return pointsOfEachEvent
        }
    }

    /// One screenful, as one wheel event. The point on the event aims it — the window under *that point*
    /// receives the scroll — so the scroll stays aimed at the element even if the pointer was pushed off it.
    private static func scrollEvent(
        for direction: ElementScrollDirection,
        byPoints points: CGFloat,
        atAccessibilityScreenPoint accessibilityScreenPoint: CGPoint
    ) -> CGEvent? {
        let deltas = wheelDeltas(for: direction, byPoints: points)
        guard let event = CGEvent(
            scrollWheelEvent2Source: scrollEventSource,
            units: .pixel,
            wheelCount: deltas.horizontal == 0 ? 1 : 2,
            wheel1: deltas.vertical,
            wheel2: deltas.horizontal,
            wheel3: 0
        ) else {
            return nil
        }
        event.location = accessibilityScreenPoint
        return event
    }

    /// The two wheel values for one screenful, and their sign convention: down and right are the negative
    /// values — the space a trackpad reports in, measured rather than assumed. Only one wheel ever carries a
    /// value, and the wheel count is derived from it, because a horizontal scroll built with a single wheel
    /// is silently a vertical one.
    static func wheelDeltas(
        for direction: ElementScrollDirection,
        byPoints points: CGFloat
    ) -> (vertical: Int32, horizontal: Int32) {
        let wholePoints = Int32(points.rounded())
        switch direction {
        case .down: return (-wholePoints, 0)
        case .up: return (wholePoints, 0)
        case .right: return (0, -wholePoints)
        case .left: return (0, wholePoints)
        }
    }
}

/// Drags from one point to another, the left button held all the way — the one sibling that is a movement
/// rather than an event. It lives in this file to reach `ElementClicker`'s flip rather than keep a second
/// copy of it.
enum ElementDragger {

    // MARK: - Limits

    /// How many steps the movement is broken into — an app accepts a drop from the dragged events it sees
    /// pass over it, so a single jump arrives at a window that was never told anything was coming.
    private static let stepsInOneDrag = 25

    /// The gap between two steps, so the app can follow the sequence — half a second end to end, which has
    /// to fit inside `CompanionManager.pointingTourArrivalTimeoutSeconds` alongside the flight before it.
    private static let secondsBetweenTheStepsOfADrag = 0.02

    private static let dragEventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: - Dragging

    /// Asked before the red flight, which says "I am about to do this here" and must not be made for a drag
    /// that will not happen.
    static func refusalOfDrag(
        toAppKitScreenLocation destinationAppKitScreenLocation: CGPoint?
    ) -> ElementDragRefusal? {
        // There is no destructive-word case here, unlike the click's: the destination is a point
        // with no label to judge, and whatever a drag moves, dragging it back undoes.
        guard destinationAppKitScreenLocation != nil else {
            return .noDestinationWasNamed
        }

        guard AXIsProcessTrusted() else {
            return .accessibilityIsNotEnabled
        }

        return nil
    }

    /// `onEachStep` reports where the drag has the pointer as it goes, so a caller can draw the cursor
    /// following it — a callback rather than a returned path, because the position is used while the drag
    /// runs.
    static func dragElement(
        fromAppKitScreenLocation startAppKitScreenLocation: CGPoint,
        toAppKitScreenLocation destinationAppKitScreenLocation: CGPoint?,
        primaryScreenHeightInPoints: CGFloat,
        onEachStep: (@MainActor (CGPoint) -> Void)? = nil
    ) async -> ElementDragOutcome {
        if let refusal = refusalOfDrag(toAppKitScreenLocation: destinationAppKitScreenLocation) {
            return refusal.outcome
        }
        guard let destinationAppKitScreenLocation else {
            // Unreachable behind the check above; written out rather than force-unwrapped so a change
            // to either cannot turn the other into a crash.
            return .refusedBecauseNoDestinationWasNamed
        }

        // Interpolated in AppKit's space so the point reported to the caller and the point on the event
        // are the same one — the cursor is never drawn where the press is not.
        let appKitScreenLocationAtEachStep = (0...stepsInOneDrag).map { stepNumber in
            let howFarAlong = CGFloat(stepNumber) / CGFloat(stepsInOneDrag)
            return CGPoint(
                x: startAppKitScreenLocation.x
                    + (destinationAppKitScreenLocation.x - startAppKitScreenLocation.x) * howFarAlong,
                y: startAppKitScreenLocation.y
                    + (destinationAppKitScreenLocation.y - startAppKitScreenLocation.y) * howFarAlong
            )
        }

        // Every step's event is built before any is posted — here it matters most: a drag that gave up
        // part way has already pressed the button on the thing it was moving, with nothing posted to
        // let go of it.
        var eventsInOrder: [CGEvent] = []
        for (stepNumber, appKitScreenLocation) in appKitScreenLocationAtEachStep.enumerated() {
            let mouseType: CGEventType
            if stepNumber == 0 {
                mouseType = .leftMouseDown
            } else if stepNumber == appKitScreenLocationAtEachStep.count - 1 {
                mouseType = .leftMouseUp
            } else {
                mouseType = .leftMouseDragged
            }

            guard let event = dragEvent(
                mouseType: mouseType,
                atAppKitScreenLocation: appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            ) else {
                return .failedToPostTheDrag
            }
            eventsInOrder.append(event)
        }

        for (stepNumber, event) in eventsInOrder.enumerated() {
            if stepNumber > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(secondsBetweenTheStepsOfADrag * 1_000_000_000)
                )
            }
            event.post(tap: .cghidEventTap)

            let appKitScreenLocation = appKitScreenLocationAtEachStep[stepNumber]
            // The call is guarded on a carry being in flight, and the events carry their own points,
            // so the drag is made whether or not the pointer comes along.
            PointerCarrier.carryThePointer(
                toAppKitScreenLocation: appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
            onEachStep?(appKitScreenLocation)
        }

        return .dragged
    }

    /// The event type and the button change together, as in the click: a `.leftMouseDragged` carrying any
    /// other button is delivered to *that* button's handler, so the wrong thing moves while this side sees a
    /// correct drag.
    private static func dragEvent(
        mouseType: CGEventType,
        atAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: dragEventSource,
            mouseType: mouseType,
            mouseCursorPosition: ElementClicker.accessibilityPoint(
                fromAppKitScreenLocation: appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            ),
            mouseButton: .left
        ) else {
            return nil
        }

        // Stated rather than left to timing: a drag landing close behind the user's own press must not
        // count as the second half of their double click.
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }
}

struct ElementKey: Equatable {
    /// The physical key, which is what the system matches a combination against.
    let virtualKeyCode: CGKeyCode
    /// How the key is written, the way a menu writes it: a letter as its capital, a key as its symbol.
    let name: String
}

/// An option set of its own rather than `CGEventFlags`, because this value travels on the flight, which the
/// overlay reads; the one conversion sits beside the events it is for.
struct ElementKeyModifiers: OptionSet {
    let rawValue: Int

    static let control = ElementKeyModifiers(rawValue: 1 << 0)
    static let option = ElementKeyModifiers(rawValue: 1 << 1)
    static let shift = ElementKeyModifiers(rawValue: 1 << 2)
    static let command = ElementKeyModifiers(rawValue: 1 << 3)
}

struct ElementKeyCombination: Equatable {
    let key: ElementKey
    let modifiers: ElementKeyModifiers

    /// The combination as a menu prints it: the modifiers in the order macOS shows them, then the key.
    var writtenAs: String { modifiers.writtenAs + key.name }
}

extension ElementKeyModifiers {
    /// ⌃⌥⇧⌘ — macOS's own order, which is why logging out is written ⇧⌘Q here rather than ⌘⇧Q.
    var writtenAs: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

private extension ElementKeyModifiers {
    var asEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    /// Each modifier as the key a keyboard presses, in the ⌃⌥⇧⌘ order a combination presses them — the
    /// left-hand key, since a combination names no side. 55 is ⌘, 56 ⇧, 58 ⌥, 59 ⌃.
    var asKeysInTheOrderTheyArePressed: [(modifier: ElementKeyModifiers, virtualKeyCode: CGKeyCode)] {
        var keys: [(modifier: ElementKeyModifiers, virtualKeyCode: CGKeyCode)] = []
        if contains(.control) { keys.append((.control, 59)) }
        if contains(.option) { keys.append((.option, 58)) }
        if contains(.shift) { keys.append((.shift, 56)) }
        if contains(.command) { keys.append((.command, 55)) }
        return keys
    }
}

/// Types and presses keys for the user — the only sibling that posts no mouse event, since a keystroke goes
/// to whatever holds the input focus.
///
/// Text rides on the event itself (`keyboardSetUnicodeString`), because no key code produces 季; a
/// combination is a real key code with its flags, because AppKit matches a menu's key equivalent on the
/// code and the flags.
enum ElementKeyboard {

    // MARK: - Limits

    /// How fast Kiki types, in characters a second: slow enough to watch and to interrupt, which is the
    /// whole of what typing buys over pasting.
    static let charactersTypedPerSecond = 8

    private static var secondsBetweenTypedCharacters: Double {
        1.0 / Double(charactersTypedPerSecond)
    }

    /// The most Kiki will type in one action: at `charactersTypedPerSecond` that is fifteen seconds of
    /// watching, already long for a gesture; anything longer is a paste.
    static let maximumCharacterCountKikiWillType = 120

    /// The combinations Kiki will never press, by the way a menu writes them — a refusal costs one
    /// keystroke the user can make themselves, accepting costs something with no undo.
    private static let writtenFormsKikiWillNotPress: Set<String> = [
        "⇧⌘⌫",  // 清空废纸篓
        "⇧⌘Q",  // 注销
        "⌥⌘⎋",  // 强制退出
        "⌃⌘Q",  // 锁屏
        "⌘Q",   // 退出当前 App
    ]

    private static let keyboardEventSource = CGEventSource(stateID: .hidSystemState)

    /// A shortcut is matched on the code — the physical key, not the character — so a combination is read
    /// from a name and never derived from text.
    private static let keysByName: [String: ElementKey] = {
        var keys: [String: ElementKey] = [:]

        // Letters and digits are written as themselves, a letter as its capital — the way a menu writes ⌘S.
        let letterAndDigitKeyCodes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        ]
        for (name, virtualKeyCode) in letterAndDigitKeyCodes {
            keys[name] = ElementKey(virtualKeyCode: virtualKeyCode, name: name.uppercased())
        }

        let punctuationKeyCodes: [String: CGKeyCode] = [
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
            ",": 43, ".": 47, "/": 44, "`": 50,
        ]
        for (name, virtualKeyCode) in punctuationKeyCodes {
            keys[name] = ElementKey(virtualKeyCode: virtualKeyCode, name: name)
        }

        // The named keys. Several names for one key are what that key is called, not several keys.
        let namedKeyCodes: [(names: [String], virtualKeyCode: CGKeyCode, writtenAs: String)] = [
            (["return", "enter"], 36, "↩"),
            (["tab"], 48, "⇥"),
            (["space"], 49, "␣"),
            (["delete", "backspace"], 51, "⌫"),
            (["forwarddelete", "del"], 117, "⌦"),
            (["escape", "esc"], 53, "⎋"),
            (["left"], 123, "←"),
            (["right"], 124, "→"),
            (["down"], 125, "↓"),
            (["up"], 126, "↑"),
            (["home"], 115, "↖"),
            (["end"], 119, "↘"),
            (["pageup"], 116, "⇞"),
            (["pagedown"], 121, "⇟"),
            (["f1"], 122, "F1"),
            (["f2"], 120, "F2"),
            (["f3"], 99, "F3"),
            (["f4"], 118, "F4"),
            (["f5"], 96, "F5"),
            (["f6"], 97, "F6"),
            (["f7"], 98, "F7"),
            (["f8"], 100, "F8"),
            (["f9"], 101, "F9"),
            (["f10"], 109, "F10"),
            (["f11"], 103, "F11"),
            (["f12"], 111, "F12"),
        ]
        for (names, virtualKeyCode, writtenAs) in namedKeyCodes {
            for name in names {
                keys[name] = ElementKey(virtualKeyCode: virtualKeyCode, name: writtenAs)
            }
        }

        return keys
    }()

    private static let modifiersByName: [String: ElementKeyModifiers] = [
        "control": .control, "ctrl": .control, "⌃": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "command": .command, "cmd": .command, "⌘": .command,
    ]

    // MARK: - Reading a combination

    /// Reads a combination from the way it is written: `cmd+shift+s` or `⌘⇧S`, either way round, any case and
    /// any order. Nil for anything that does not read as a key with modifiers, so a caller can say so rather
    /// than press something near it.
    private static func combination(named name: String) -> ElementKeyCombination? {
        let writtenName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !writtenName.isEmpty else { return nil }

        var modifiers: ElementKeyModifiers = []
        var remainder = Substring(writtenName)

        // A name written in symbols has no separator to split on — ⌘⇧S is one run of modifiers then
        // the key — so those are peeled off the front before anything is split.
        while let firstCharacter = remainder.first,
              let modifier = modifiersByName[String(firstCharacter)] {
            modifiers.insert(modifier)
            remainder = remainder.dropFirst()
        }

        var keyNames = remainder
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = keyNames.popLast() else { return nil }
        for modifierName in keyNames {
            guard let modifier = modifiersByName[modifierName] else { return nil }
            modifiers.insert(modifier)
        }

        guard let key = keysByName[keyName] else { return nil }
        return ElementKeyCombination(key: key, modifiers: modifiers)
    }

    /// The one place a combination becomes words, so the bubble and the terminal's sentence cannot disagree
    /// about which key was pressed; a name that does not read comes back as it was written, for the refusal
    /// to name.
    static func phraseForPressingKey(_ name: String) -> String {
        combination(named: name)?.writtenAs ?? name
    }

    // MARK: - Refusing

    /// Without typing anything: typing begins by clicking the element, so the question is the click's own
    /// rather than a keyboard copy that could drift from it.
    static func refusalOfTyping(
        _ text: String,
        matchingElementLabel elementLabel: String?,
        origin: ElementClickOrigin
    ) -> ElementKeyboardRefusal? {
        let characterCount = text.count
        guard characterCount <= maximumCharacterCountKikiWillType else {
            return .theTextIsLongerThanKikiWillType(characterCount: characterCount)
        }

        if let clickRefusal = ElementClicker.refusalOfClick(
            matchingElementLabel: elementLabel,
            origin: origin
        ) {
            return .theElementCannotBeClicked(clickRefusal)
        }

        return nil
    }

    /// Asked before the flight, so a refused combination never turns the cursor red — which is the whole of
    /// what "Kiki will not press that" looks like, and why no sound is played either.
    static func refusalOfCombination(named name: String) -> ElementKeyboardRefusal? {
        guard let combination = combination(named: name) else {
            return .theCombinationIsNotOneKikiKnows(name: name)
        }
        return refusalOfCombination(combination)
    }

    /// The same rules for a combination already read — so the path that asks before the flight and the one
    /// that presses at the end of it run one copy.
    private static func refusalOfCombination(
        _ combination: ElementKeyCombination
    ) -> ElementKeyboardRefusal? {
        if writtenFormsKikiWillNotPress.contains(combination.writtenAs) {
            return .theCombinationIsADangerousOne(matchedName: combination.writtenAs)
        }

        guard AXIsProcessTrusted() else {
            return .accessibilityIsNotEnabled
        }

        return nil
    }

    // MARK: - Typing

    /// Types the run one character at a time, the click first — a real left click is what puts the input
    /// focus into the field — through `ElementClicker.clickElement` rather than a second click built here.
    static func typeText(
        _ text: String,
        atAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat,
        matchingElementLabel elementLabel: String?,
        origin: ElementClickOrigin
    ) async -> ElementKeyboardOutcome {
        if let refusal = refusalOfTyping(text, matchingElementLabel: elementLabel, origin: origin) {
            return refusal.outcome
        }

        let focusClickOutcome = await ElementClicker.clickElement(
            atAppKitScreenLocation: appKitScreenLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints,
            matchingElementLabel: elementLabel,
            kind: .singleClick,
            origin: origin
        )
        // Unreachable behind the refusal above, which asked the click's own question; one outcome
        // covers it, since a click that did not land leaves nowhere for the text to go.
        guard case .clicked = focusClickOutcome else {
            return .failedToPostTheKeystrokes
        }

        // Every character's events are built before any is posted: half a text is text the user has to
        // notice and delete.
        var eventsByCharacter: [[CGEvent]] = []
        for character in text {
            guard let events = keystrokeEvents(forTyping: String(character)) else {
                return .failedToPostTheKeystrokes
            }
            eventsByCharacter.append(events)
        }

        for (characterNumber, eventsForThisCharacter) in eventsByCharacter.enumerated() {
            // `Task.sleep` and not `usleep`: this is the main actor, and the overlay draws the cursor on
            // it for the whole of the time the text is going in.
            if characterNumber > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(secondsBetweenTypedCharacters * 1_000_000_000)
                )
            }
            for event in eventsForThisCharacter {
                event.post(tap: .cghidEventTap)
            }
        }

        return .postedTheKeystrokes
    }

    /// The press and the release of one typed character. The character rides on the event rather than a key
    /// code — no code produces 季, and a code's meaning depends on the layout and what else is held down —
    /// so with no pasteboard and no input method this is not a paste in any sense the app could notice.
    private static func keystrokeEvents(forTyping character: String) -> [CGEvent]? {
        var events: [CGEvent] = []
        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: keyboardEventSource,
                virtualKey: 0,
                keyDown: isKeyDown
            ) else {
                return nil
            }
            // Stated rather than inherited: an event built from `keyboardEventSource` starts with
            // whatever flags that source carries, and a combination posted a moment before is enough
            // to leave ⌘ on them — every character then arrives as a shortcut.
            event.flags = []

            // The key code types nothing of its own — the text on the event is all that goes in — and a
            // character can be more than one UTF-16 unit, so the count handed over is its length.
            var unicodeUnits = Array(character.utf16)
            event.keyboardSetUnicodeString(
                stringLength: unicodeUnits.count,
                unicodeString: &unicodeUnits
            )
            events.append(event)
        }
        return events
    }

    // MARK: - Pressing a combination

    /// Presses a combination at the input focus. Nothing is clicked first, deliberately: a click moves the
    /// insertion point, and no combination Kiki presses wants the caret moved.
    static func pressCombination(named name: String) -> ElementKeyboardOutcome {
        guard let combination = combination(named: name) else {
            return .refusedBecauseTheCombinationIsNotOneKikiKnows(name: name)
        }
        if let refusal = refusalOfCombination(combination) {
            return refusal.outcome
        }

        let flagsOfTheWholeCombination = combination.modifiers.asEventFlags
        let modifierKeys = combination.modifiers.asKeysInTheOrderTheyArePressed

        var events: [CGEvent] = []

        // The modifiers are pressed as keys of their own around the key they modify: a flags field
        // describes a modifier without pressing one, so a pair of flagged events leaves ⌘ down in the system
        // and the next thing typed arrives as a shortcut. Flags accumulate going down and unwind coming up,
        // so the last event carries none.
        var flagsWhileGoingDown: CGEventFlags = []
        for (modifier, virtualKeyCode) in modifierKeys {
            flagsWhileGoingDown.insert(modifier.asEventFlags)
            guard let event = CGEvent(
                keyboardEventSource: keyboardEventSource,
                virtualKey: virtualKeyCode,
                keyDown: true
            ) else {
                return .failedToPostTheKeystrokes
            }
            event.flags = flagsWhileGoingDown
            events.append(event)
        }

        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: keyboardEventSource,
                virtualKey: combination.key.virtualKeyCode,
                keyDown: isKeyDown
            ) else {
                return .failedToPostTheKeystrokes
            }
            // On the release as well as the press: a key equivalent is matched on the flags the event
            // carries, and the key going up is what an app sees of the gesture finishing.
            event.flags = flagsOfTheWholeCombination
            events.append(event)
        }

        var flagsWhileComingUp = flagsOfTheWholeCombination
        for (modifier, virtualKeyCode) in modifierKeys.reversed() {
            flagsWhileComingUp.subtract(modifier.asEventFlags)
            guard let event = CGEvent(
                keyboardEventSource: keyboardEventSource,
                virtualKey: virtualKeyCode,
                keyDown: false
            ) else {
                return .failedToPostTheKeystrokes
            }
            event.flags = flagsWhileComingUp
            events.append(event)
        }

        for event in events {
            event.post(tap: .cghidEventTap)
        }

        return .postedTheKeystrokes
    }
}

/// Carries the user's pointer along with the cursor — the red carry is what makes "Kiki is about to operate
/// this for me" legible before anything is pressed.
///
/// `CGWarpMouseCursorPosition` disassociates the physical mouse for about a quarter of a second by itself,
/// so the hold is re-stated on a timer that beats that interval, and every path out re-associates: a
/// detachment outlives the process that made it, and a crash while detached leaves a pointer that no longer
/// answers to the mouse.
enum PointerCarrier {

    private(set) static var isCarryingThePointer = false

    /// Where this type last put the pointer, in global AppKit screen coordinates — kept so the guard can
    /// answer "is the pointer still where Kiki left it" without asking the overlay anything.
    private static var appKitScreenLocationThePointerIsHeldAt: CGPoint?

    /// The primary screen height the pointer was last placed with: putting it back is another warp, and a
    /// warp needs the same flip the placement did.
    private static var primaryScreenHeightWhileThePointerIsHeldInPoints: CGFloat = 0

    private static var pointerHoldGuardTimer: Timer?

    /// Detaches the physical mouse and puts the pointer under the cursor, ready to be carried — which also
    /// covers a pointer on another display, where the cursor cannot fly to fetch it.
    static func startCarryingThePointer(
        toAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) {
        isCarryingThePointer = true
        appKitScreenLocationThePointerIsHeldAt = appKitScreenLocation
        primaryScreenHeightWhileThePointerIsHeldInPoints = primaryScreenHeightInPoints
        startGuardingThePointerHold()
        moveThePointer(
            toAppKitScreenLocation: appKitScreenLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Moves the pointer to a point, part-way through a carry — guarded on a carry being in flight, so a
    /// stray call cannot move a pointer Kiki never took.
    static func carryThePointer(
        toAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) {
        guard isCarryingThePointer else { return }
        appKitScreenLocationThePointerIsHeldAt = appKitScreenLocation
        primaryScreenHeightWhileThePointerIsHeldInPoints = primaryScreenHeightInPoints
        moveThePointer(
            toAppKitScreenLocation: appKitScreenLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Ends a carry: re-attaches the physical mouse, then puts the pointer exactly on the point. The warp
    /// comes *last* on purpose — re-attaching hands over the movement accumulated while detached, and the
    /// warp after it is what overwrites that jump.
    static func releaseThePointer(
        atAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) {
        releaseThePointerIfCarrying()
        moveThePointer(
            toAppKitScreenLocation: appKitScreenLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Re-attaches the physical mouse if a carry is in flight, and does nothing otherwise — idempotent,
    /// because its callers are teardowns that cannot know whether a carry was running.
    static func releaseThePointerIfCarrying() {
        guard isCarryingThePointer else { return }
        reattachTheMouseUnconditionally()
    }

    /// Re-attaches the physical mouse without asking whether this process detached it: the launch-time call
    /// that undoes a crash finds `isCarryingThePointer == false` — the flag belongs to the dead process —
    /// so a guarded call would silently do nothing while the pointer sat frozen.
    static func reattachTheMouseUnconditionally() {
        // Stopped rather than left to find the flag false on its next tick: a tick landing between
        // the re-attachment below and the flag being cleared would detach the mouse all over again.
        stopGuardingThePointerHold()
        appKitScreenLocationThePointerIsHeldAt = nil
        isCarryingThePointer = false

        // Spends whatever the physical mouse accumulated while detached, which the re-attachment would
        // otherwise hand to the pointer all at once.
        _ = CGGetLastMouseDelta()

        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Starts the timer that re-states the hold while a carry is in flight. Added in `.common` rather than
    /// the default mode, where it stops firing while the run loop is in event-tracking mode.
    private static func startGuardingThePointerHold() {
        stopGuardingThePointerHold()
        let timerThatReStatesTheHold = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            // The timer is on the main run loop, so this is the main actor; `assumeIsolated` is
            // what says so to the compiler rather than hopping to it once every frame.
            MainActor.assumeIsolated {
                keepThePointerWhereKikiLeftIt()
            }
        }
        RunLoop.main.add(timerThatReStatesTheHold, forMode: .common)
        pointerHoldGuardTimer = timerThatReStatesTheHold
    }

    /// Stops the timer, and only the timer: where the pointer is held is the carry's to set and the
    /// release's to forget, and clearing it here is what keeps a starting carry from being wiped out by a
    /// tick of the one before.
    private static func stopGuardingThePointerHold() {
        pointerHoldGuardTimer?.invalidate()
        pointerHoldGuardTimer = nil
    }

    /// Re-states that the mouse is not the user's, and puts the pointer back if it slipped away — both
    /// halves needed, because the re-statement only mostly wins the race against the quarter-second
    /// re-association a warp schedules. Snap-back rather than re-grip: the cursor never let go of the
    /// element, the mouse did.
    private static func keepThePointerWhereKikiLeftIt() {
        guard isCarryingThePointer,
              let appKitScreenLocationThePointerIsHeldAt = appKitScreenLocationThePointerIsHeldAt
        else {
            stopGuardingThePointerHold()
            return
        }
        CGAssociateMouseAndMouseCursorPosition(0)

        let howFarThePointerHasMovedInPoints = hypot(
            NSEvent.mouseLocation.x - appKitScreenLocationThePointerIsHeldAt.x,
            NSEvent.mouseLocation.y - appKitScreenLocationThePointerIsHeldAt.y
        )
        // A point of slack: the pointer is reported by the window server, and a whole-number round trip
        // through it is not the user moving the mouse.
        guard howFarThePointerHasMovedInPoints > 1.0 else { return }

        moveThePointer(
            toAppKitScreenLocation: appKitScreenLocationThePointerIsHeldAt,
            primaryScreenHeightInPoints: primaryScreenHeightWhileThePointerIsHeldInPoints
        )
    }

    /// Warps to a global AppKit screen location through `ElementClicker.accessibilityPoint` rather than
    /// writing the flip again — the coordinate flip has one copy.
    private static func moveThePointer(
        toAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) {
        CGWarpMouseCursorPosition(
            ElementClicker.accessibilityPoint(
                fromAppKitScreenLocation: appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
        )

        // Each warp schedules the mouse's return to the user's hand, so a carry re-states the hold
        // behind every frame. Guarded on the flag, which keeps this out of the release's way.
        if isCarryingThePointer {
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }
}
