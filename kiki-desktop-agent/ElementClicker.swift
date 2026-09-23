//
//  ElementClicker.swift
//  kiki-desktop-agent
//
//  Posts a real click, a real scroll or a real drag for the user — the one place the app acts on
//  the machine rather than merely suggesting — plus `PointerCarrier`, which takes the user's
//  pointer along with it.
//
//  Pressing through the Accessibility API was the first design and was abandoned on
//  measurement: the element the feature exists for offered `AXShowMenu` and `AXScrollToVisible`
//  at every level and never `AXPress`, so a verified, correctly located element could not be
//  pressed at all. Nothing here reads that tree now, and the refusals are only the ones
//  decidable without asking the screen anything.
//

import AppKit
import ApplicationServices

/// Which gesture is performed at the point: the left button once, twice or three times, or the
/// right button once.
///
/// One value rather than a count and a button, because those two would be two answers to the same
/// question and could disagree — which is why `buttonThatIsPressed` and the number of presses are
/// both derived from here rather than passed alongside it. The model decides the gesture by which
/// tag it wrote; it is never inferred from how the element looks. Guessing is wrong in every
/// direction at once — it double-clicks buttons, single-clicks the files that needed opening, and
/// opens a context menu over a button that wanted pressing.
enum ElementClickKind {
    case singleClick
    case doubleClick
    /// Three presses of the left button, which selects a whole paragraph in a body of text.
    case tripleClick
    /// One press of the right button, which opens the element's context menu.
    case rightClick

    /// The button this gesture presses. A double or triple click is that many presses of the left
    /// one.
    var buttonThatIsPressed: CGMouseButton {
        switch self {
        case .singleClick, .doubleClick, .tripleClick: return .left
        case .rightClick: return .right
        }
    }

    /// How many times the button goes down, which is the whole of the difference between a single
    /// click and a double or triple one. A right click is one press like any other.
    ///
    /// Written as a switch over every case rather than as a comparison against the one gesture that
    /// is different, because a count that is merely wrong still posts a click: a new gesture added
    /// beside this line would press once and nothing would say so.
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

/// Which way a scroll goes.
///
/// The other gesture axis. The two never mix: a click is decided by which button and how many
/// times, a scroll by which way and how far, and no value here has a button to press.
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

/// How far a scroll goes, in whichever unit the request was made in.
///
/// A tag's `:x3` and `kiki scrolldown -b 3` both count screenfuls, which is the only unit a reader
/// of the screen can be asked for: it says how much of what they are looking at will move. A scroll
/// the user made is a number of points, and rounding that to a screenful would replay a small
/// scroll as a large one, so it is kept in its own unit rather than converted.
///
/// One value with two units rather than two cases of `ElementActionOnArrival`, because almost
/// nothing downstream cares which unit it is — the distance is passed along — and what does care
/// asks for it here.
enum ElementScrollDistance: Equatable {
    /// A number of screenfuls, as a tag or a terminal counts them.
    case screenfuls(Int)
    /// A distance in points, as a wheel event reports it.
    case points(CGFloat)
}

extension ElementScrollDistance: CustomStringConvertible {
    var description: String {
        switch self {
        case .screenfuls(let count): return "\(count) screenful(s)"
        case .points(let points): return "\(Int(points.rounded())) point(s)"
        }
    }
}

/// Who named the thing being clicked, which decides whether naming nothing is a refusal.
///
/// The refusals are otherwise identical for both — a destructive label and a missing grant are
/// reasons not to press whatever it is either way — so this is an input rather than a second
/// gate to keep in step with the first.
enum ElementClickOrigin {
    /// A tag in the model's reply. The label is the only clue to which element was meant, so a
    /// tag without one names nothing that could be clicked.
    case theModelsTag
    /// A command the user typed. The coordinate form names a point rather than an element, so
    /// carrying no text is the ordinary case rather than a defect.
    case theUsersOwnCommand
}

/// What the cursor does when it gets there: press a button, or scroll.
///
/// The place the two gesture axes meet, and one value rather than a kind beside a flag because
/// four separate decisions are read off it and they must not be able to disagree — whether the
/// flight is a red one, which bubble is said over the element, whether anything happens on
/// arrival at all, and whether the user's pointer is taken along.
enum ElementActionOnArrival: Equatable {
    case press(ElementClickKind)
    case scroll(ElementScrollDirection, distance: ElementScrollDistance)
    /// The one action that is a movement between two points. It carries no payload: where it lets
    /// go is not a property of the gesture but of the flight it was asked for, so it travels beside
    /// this on the same values the point it starts from does — a `PointingTourStop` or a
    /// `TerminalActionInFlight` — and is read at the moment the drag runs.
    case drag

    /// Whether this action needs the user's pointer to be at the element.
    ///
    /// A press says yes for legibility rather than for aim: a posted click carries its own point, so
    /// what the pointer is bought for is the red carry, the only thing that says "Kiki is about to
    /// press this" before it happens.
    ///
    /// A scroll says yes on measurement, which is not where it was expected to land. A wheel event
    /// carries a point and the window under **that point** receives it rather than the one under the
    /// pointer, so the point is what aims a scroll — but posting one whose point is elsewhere drags
    /// the pointer there too. Every tap that delivers a synthesized scroll does that, and the one
    /// tap that leaves the pointer alone delivers nothing at all. A scroll therefore cannot land
    /// somewhere with the pointer staying where it was, and what is left is to carry it legibly
    /// rather than let it teleport.
    ///
    /// A drag says yes because it *is* the pointer moving: unlike a press, the point on the event
    /// and the pointer's position have to agree the whole way, or what the app underneath sees is a
    /// press with the mouse standing still and a jump at the end.
    var carriesTheUsersPointer: Bool { true }
}

/// What came of asking for a click.
///
/// No case per gesture: which button was pressed and how many times is an input to this rather
/// than a result of it.
enum ElementClickOutcome {
    case clicked
    /// Nothing was posted, and the reason is on this side of the event system.
    case failedToPostTheClick
    case refusedBecauseTheTagCarriedNoLabel
    /// Accessibility is not granted. Synthesising an event needs it.
    case refusedBecauseAccessibilityIsNotEnabled
    case refusedBecauseTheLabelLooksDestructive(matchedWord: String)
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

/// What came of asking for a scroll.
///
/// Deliberately shaped like `ElementClickOutcome`, so the two read as one family with one
/// difference to explain. There is no "the tag carried no label" and no "the label looks
/// destructive", because a scroll asks neither question: a coordinate is a point and a point can
/// be scrolled, and whatever a scroll moves, scrolling back undoes.
enum ElementScrollOutcome {
    case scrolled
    /// Nothing was posted, and the reason is on this side of the event system.
    case failedToPostTheScroll
    /// Accessibility is not granted. Synthesising an event needs it.
    case refusedBecauseAccessibilityIsNotEnabled
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

/// What came of asking for a drag.
///
/// The third of the family, shaped like the other two. There is no "the label looks destructive":
/// the destination carries no label to judge, and a drag is undoable by dragging back — the same
/// reason a scroll is not asked the question. What is here instead is a missing destination, which
/// is the one thing a drag can be asked for without.
enum ElementDragOutcome {
    case dragged
    /// Nothing was posted, and the reason is on this side of the event system.
    case failedToPostTheDrag
    /// The drag named nowhere to let go, and half a drag is a press held down on the thing the user
    /// was moving.
    case refusedBecauseNoDestinationWasNamed
    /// Accessibility is not granted. Synthesising an event needs it.
    case refusedBecauseAccessibilityIsNotEnabled
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

/// Why a drag is never posted, decided without asking the screen anything.
///
/// Two cases, and the missing destination is the one no other gesture has: a press and a scroll are
/// complete gestures at a single point, while a drag is defined by where it stops.
enum ElementDragRefusal {
    case noDestinationWasNamed
    /// Accessibility is not granted. Synthesising an event needs it.
    case accessibilityIsNotEnabled

    /// The outcome that reports this refusal, for the path that reaches the decision by running the
    /// drag rather than by asking about it first.
    var outcome: ElementDragOutcome {
        switch self {
        case .noDestinationWasNamed:
            return .refusedBecauseNoDestinationWasNamed
        case .accessibilityIsNotEnabled:
            return .refusedBecauseAccessibilityIsNotEnabled
        }
    }
}

/// Why a click is never posted, decided without asking the screen anything.
///
/// Separate from `ElementClickOutcome` because the two answer different questions: an outcome
/// says what happened, while a refusal says what was decided here — which is what makes it
/// knowable *before* the click runs, and it is the question the click sound is played on.
enum ElementClickRefusal {
    case theTagCarriedNoLabel
    case theLabelLooksDestructive(matchedWord: String)
    /// Accessibility is not granted. Synthesising an event needs it.
    case accessibilityIsNotEnabled

    /// The outcome that reports this refusal, for the path that reaches the decision by running
    /// the click rather than by asking about it first.
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

/// Why a scroll is never posted, decided without asking the screen anything.
///
/// One case against the click's three, which is the whole of what a scroll refuses: the other two
/// are answers to questions about a label, and a scroll is not about a label.
enum ElementScrollRefusal {
    /// Accessibility is not granted. Synthesising an event needs it.
    case accessibilityIsNotEnabled

    /// The outcome that reports this refusal, for the path that reaches the decision by running
    /// the scroll rather than by asking about it first.
    var outcome: ElementScrollOutcome {
        switch self {
        case .accessibilityIsNotEnabled:
            return .refusedBecauseAccessibilityIsNotEnabled
        }
    }
}

/// Clicks a point on the screen for the user.
enum ElementClicker {

    // MARK: - Limits

    /// How long the button is held up between two presses of one multi-click gesture, in seconds.
    ///
    /// One constant for a double click and a triple click alike, because the system decides both
    /// with the same `NSEvent.doubleClickInterval`: a third press has to follow the second as
    /// closely as the second followed the first, or it is not counted as a third click at all.
    ///
    /// Bounded from both sides. Above, it has to sit inside `NSEvent.doubleClickInterval`, which
    /// the user can turn down to about 0.15 s, or the app sees two unrelated clicks. Below, it
    /// cannot be zero: a real double click has a gap, and four events posted back to back carry
    /// timestamps microseconds apart.
    private static let secondsBetweenThePressesOfOneGesture = 0.05

    /// `.hidSystemState` describes the state a real mouse would report, which is what makes the
    /// events indistinguishable from hardware to the app receiving them.
    private static let clickEventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: - Clicking

    /// Whether a click carrying this label would be refused, and why — without clicking
    /// anything.
    ///
    /// Split out of `clickElement` so a caller can ask before the click runs, which is what lets
    /// the click sound go out with the click instead of after it and stay silent for one that
    /// was declined. `clickElement` decides through this same function, so the rule has one
    /// copy — and the copy that drifted would be the one deciding whether something destructive
    /// gets clicked.
    ///
    /// Only the missing-label refusal depends on `origin`. An unlabelled click from a terminal is
    /// a click at a point; the access check below still applies to it, because synthesising an
    /// event needs the grant no matter who asked.
    static func refusalOfClick(
        matchingElementLabel elementLabel: String?,
        origin: ElementClickOrigin
    ) -> ElementClickRefusal? {
        let trimmedElementLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedElementLabel.isEmpty {
            // A tag with no label names nothing to click; a command's coordinate has no label to
            // carry, which is the ordinary way to give it. Neither skips the access check below.
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

    /// Clicks a point given in global AppKit screen coordinates.
    ///
    /// `primaryScreenHeightInPoints` is passed in rather than read here because `NSScreen` is
    /// AppKit and this file is self-contained.
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

    /// Posts a real click at a point, in the coordinate space the Accessibility API uses.
    ///
    /// A posted event carries its own point, so it lands where the event says rather than where
    /// the pointer happens to be standing — but `mouseCursorPosition` is the cursor's position
    /// rather than a mere target, so the real cursor does end up at the point.
    private static func postClick(
        atAccessibilityScreenPoint accessibilityScreenPoint: CGPoint,
        kind: ElementClickKind
    ) async -> ElementClickOutcome {
        // Every event of every press is built before any is posted: half a double click is worse
        // than none, because it reads to the app as an ordinary single click and the thing the
        // user asked to open is merely selected. The same goes for a triple click cut short.
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
            // A gap exists only between two clicks; the first goes out the moment it is built.
            if clickIndex > 0 {
                try? await Task.sleep(nanoseconds: UInt64(secondsBetweenThePressesOfOneGesture * 1_000_000_000))
            }
            for event in eventsForThisClick {
                event.post(tap: .cghidEventTap)
            }
        }

        return .clicked
    }

    /// The press and release of one click, stamped with the state that says which click of a
    /// multi-click gesture it is, or nil if either event could not be built.
    ///
    /// The click state is stated rather than left to timing, and a single click says 1 out loud
    /// so that a click landing close behind the user's own is not counted as the second half of
    /// a double click.
    private static func mouseEvents(
        forOneClickWithClickState clickState: Int64,
        using button: CGMouseButton,
        atAccessibilityScreenPoint accessibilityScreenPoint: CGPoint
    ) -> [CGEvent]? {
        // The event type and the button are chosen together and have to be changed together. A
        // `.leftMouseDown` carrying the right button, or a `.rightMouseDown` carrying the left
        // one, is delivered to the other button's handler — so it presses the wrong button while
        // looking from this side exactly like a click that was posted correctly.
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

    /// Converts a global AppKit screen location into the coordinate space `CGEvent` posts in,
    /// which is the one the Accessibility API also uses.
    ///
    /// Both are called "global screen coordinates" and they disagree in two ways at once, which
    /// is what makes this the most error-prone step on the path. That space's origin is the
    /// top-left corner of the primary display with y increasing downward; AppKit's is the
    /// bottom-left corner of the same display with y increasing upward. So the flip is one
    /// subtraction, and x needs nothing. Other displays need no special case — the two spaces are
    /// congruent everywhere else, including a display above the primary, which this maps to the
    /// negative y that space describes it with.
    ///
    /// `fileprivate` so `PointerCarrier` converts through this same function. A second copy of
    /// the flip would carry the mouse to somewhere the click does not land.
    fileprivate static func accessibilityPoint(
        fromAppKitScreenLocation appKitScreenLocation: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: appKitScreenLocation.x,
            y: primaryScreenHeightInPoints - appKitScreenLocation.y
        )
    }

    /// Converts the other way: a point from the space `CGEvent` and the Accessibility API use back
    /// into AppKit's.
    ///
    /// Needed because a coordinate typed on the command line arrives in the space it will be
    /// posted in, while everything that resolves a point to an element works in AppKit's. The
    /// flip is its own inverse — the same subtraction a second time undoes the first — so this
    /// calls the one above rather than writing the arithmetic out again.
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

    /// Whatever the model writes, a tag whose label names one of these is never clicked. A
    /// refusal costs a click the user can perform themselves; accepting costs a deletion.
    private static let destructiveChineseWords = [
        "删除", "清空", "卸载", "格式化", "重置", "还原", "退出", "关机", "重启", "注销", "购买", "支付", "发送",
    ]

    private static let destructiveEnglishWords = [
        "delete", "remove", "erase", "uninstall", "format", "reset", "restore",
        "quit", "shutdown", "restart", "log out", "buy", "purchase", "pay", "send",
    ]

    /// Matched on word boundaries rather than anywhere in the string: "display" contains "pay"
    /// and "preset" contains "reset", and declining to click a display panel over a substring
    /// would be a bug of its own.
    private static let destructiveEnglishWordPattern: NSRegularExpression? = {
        let escapedWords = destructiveEnglishWords.map { NSRegularExpression.escapedPattern(for: $0) }
        return try? NSRegularExpression(
            pattern: "\\b(\(escapedWords.joined(separator: "|")))\\b",
            options: [.caseInsensitive]
        )
    }()

    /// The destructive word this text contains, or nil when it names none.
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

/// Scrolls at a point on the screen for the user.
///
/// The sibling of `ElementClicker`, and the second half of what this file is the only place for.
/// Nothing here presses anything: the whole of what a scroll can do, scrolling back undoes.
enum ElementScroller {

    // MARK: - Limits

    /// How much of the display's own edge one screenful covers.
    ///
    /// Under a whole screen on purpose. A scroll of exactly one screen leaves none of what the
    /// reader was looking at still in front of them, and what they were following is lost; the
    /// fifth left over is what makes the next screenful read as movement rather than as a new page.
    private static let fractionOfTheDisplayOneScreenfulCovers: CGFloat = 0.8

    /// The most screenfuls one request can carry.
    ///
    /// Twenty screens is already past the end of anything a person reads on a display, so a larger
    /// number is a way of writing "all the way" rather than a distance anyone means. The bound is
    /// here rather than at the tags because both callers — a model writing `:x200` and a script
    /// passing `-b 200` — can produce one.
    static let mostScreenfulsInOneRequest = 20

    /// The gap between two screenfuls of the same request.
    ///
    /// One event per screenful rather than one large delta: three screens is three ordinary
    /// scrolls, which is what the app on the other side expects to be handed, what the user can
    /// follow as pages rather than as a jump, and what keeps an oversized delta from being run
    /// through whatever wheel-to-whatever rule that app applies to numbers it never sees in
    /// practice. Short enough that the three read as one gesture.
    private static let secondsBetweenScreenfuls = 0.02

    /// `.hidSystemState` describes the state a real wheel would report, which is what makes the
    /// events indistinguishable from hardware to the app receiving them.
    private static let scrollEventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: - Scrolling

    /// Whether a scroll would be refused, and why — without scrolling anything.
    ///
    /// The counterpart of `ElementClicker.refusalOfClick`, and split out for the same reason: the
    /// red flight says "I am about to do this here", so it has to be able to ask first, or a
    /// refused scroll would still have said it.
    static func refusalOfScroll() -> ElementScrollRefusal? {
        guard AXIsProcessTrusted() else {
            return .accessibilityIsNotEnabled
        }
        return nil
    }

    /// What one screenful covers at a point, in the display's own points.
    ///
    /// Each direction is measured along the edge it actually moves, so a screenful of sideways
    /// scroll on a wide display is a different number from a screenful of its vertical one.
    static func oneScreenfulInPoints(
        for direction: ElementScrollDirection,
        displayFrame: CGRect
    ) -> CGFloat {
        switch direction {
        case .up, .down: return displayFrame.height * fractionOfTheDisplayOneScreenfulCovers
        case .left, .right: return displayFrame.width * fractionOfTheDisplayOneScreenfulCovers
        }
    }

    /// Scrolls at a point given in global AppKit screen coordinates.
    ///
    /// `displayFrame` is the screen the point is on, in AppKit screen coordinates, and is what a
    /// screenful is measured against — passed in for the same reason as
    /// `primaryScreenHeightInPoints`, which is that `NSScreen` is AppKit and this file is not.
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

        // Every event is built before any is posted, as in the click: a request that gave up half
        // way has already moved the screen, and reporting "it failed" would then be a report about
        // a thing the user watched happen.
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
            // The gap exists only between two events; the first goes out the moment it is built.
            if wheelEventIndex > 0 {
                try? await Task.sleep(nanoseconds: UInt64(secondsBetweenScreenfuls * 1_000_000_000))
            }
            event.post(tap: .cghidEventTap)
        }

        return .scrolled
    }

    /// The whole distance broken into one wheel event per screenful, with what is left over as an
    /// event of its own.
    ///
    /// A recorded distance is the only one that is not a whole number of screenfuls, and it is kept
    /// exact rather than rounded: fifty points goes out as fifty points, because a recording
    /// replayed at a different size is not a recording of what the user did. It is bounded in its
    /// own unit, at the same total the screenful form is bounded at, so a flung scroll carrying a
    /// thousand points cannot become a hundred events.
    private static func pointsOfEachWheelEvent(
        for distance: ElementScrollDistance,
        pointsPerScreenful: CGFloat
    ) -> [CGFloat] {
        switch distance {
        case .screenfuls(let screenfuls):
            let numberOfScreenfuls = min(max(screenfuls, 1), mostScreenfulsInOneRequest)
            return Array(repeating: pointsPerScreenful, count: numberOfScreenfuls)

        case .points(let points):
            // A floor of one point: below that the event rounds to a delta that moves nothing, and
            // a scroll that does nothing is not what a gesture in the recording was.
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

    /// One screenful, as one wheel event.
    ///
    /// **The point goes on the event because that is what aims it.** A wheel event's `location` is
    /// read the same way a click's is — the window under *that* point receives the scroll, not the
    /// window under the pointer — so the scroll stays aimed at the element even if the pointer has
    /// been pushed off it since the carry finished.
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

    /// The two wheel values for one screenful of a direction, and the sign convention they follow.
    ///
    /// **Down and right are the negative values, and that is measured rather than assumed.** A
    /// synthesized wheel is in the same space a trackpad reports: a negative `wheel1` moves the
    /// document's visible origin down, revealing what was below the fold, and a negative `wheel2`
    /// does the same to the right. Measured against a real `NSScrollView` over a flipped document,
    /// from the middle of the document so that neither direction was answered by a clamp:
    /// `wheel1 = -720` moved the origin by +720 points and `wheel1 = +720` moved it by -720, and
    /// the same held for `wheel2`. The magnitude came back exactly as sent, so with `.pixel` units
    /// a point of delta is a point of movement with no scaling in between.
    ///
    /// Only one wheel ever carries a value — a scroll goes one way — and the wheel count is
    /// derived from that rather than passed alongside it, because a horizontal scroll built with a
    /// single wheel is silently a vertical one.
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

/// Drags from one point to another for the user, with the left button held all the way.
///
/// The third sibling, and the only one that is a movement rather than an event: a press and a
/// scroll are complete at a single point, so what they have to get right is the point, where a drag
/// is defined by the two ends and by the path between them. It lives in this file because the
/// AppKit ↔ Accessibility flip is `fileprivate` on `ElementClicker`, and a second copy of it would
/// land the drag a screen height from where it was aimed.
enum ElementDragger {

    // MARK: - Limits

    /// How many steps the movement is broken into, which is one more than the number of events
    /// between the press and the release.
    ///
    /// The movement is posted as many small ones rather than as one jump because of who decides
    /// where a drag lands: an app that accepts a drop learns that something is being dragged over
    /// it from the dragged events passing across it, so a single jump arrives at a window that was
    /// never told anything was coming and is refused. Over half a second this reads as one
    /// movement and is few enough not to flood the event tap.
    private static let stepsInOneDrag = 25

    /// The gap between two steps.
    ///
    /// The pace `ElementScroller` uses between two screenfuls, and for the same end: a sequence the
    /// app on the other side can follow and act on as it arrives. Half a second end to end, which
    /// has to fit inside `CompanionManager.pointingTourArrivalTimeoutSeconds` alongside the flight
    /// that precedes it.
    private static let secondsBetweenTheStepsOfADrag = 0.02

    /// `.hidSystemState` describes the state a real mouse would report at each step, which is what
    /// makes the events indistinguishable from a hand moving the mouse.
    private static let dragEventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: - Dragging

    /// Whether a drag would be refused, and why — without dragging anything.
    ///
    /// Asked before the red flight for the same reason the click and the scroll ask: the flight says
    /// "I am about to do this here", and a refused drag that still made the gesture would have said
    /// it about nothing.
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

    /// Drags from one point to another, in global AppKit screen coordinates.
    ///
    /// `primaryScreenHeightInPoints` is passed in rather than read here because `NSScreen` is AppKit
    /// and this file is self-contained.
    ///
    /// `onEachStep` is told where the drag has the pointer at every step, so a caller can draw the
    /// cursor following it rather than watching it land and then wait. A callback rather than a
    /// returned path because the drag takes half a second and what the caller does with the position
    /// has to happen while it runs — which is also why it is `@MainActor`: the caller is drawing, and
    /// an unannotated closure type would not be isolated to the actor the drawing happens on.
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
            // Unreachable behind the check above. Written out rather than force-unwrapped so that a
            // change to either cannot turn the other into a crash.
            return .refusedBecauseNoDestinationWasNamed
        }

        // Interpolated in AppKit's space rather than in the one the events are posted in. It is the
        // same straight line either way, and doing it here keeps the point reported to the caller
        // and the point on the event the same point, so the cursor cannot be drawn somewhere the
        // press is not.
        let appKitScreenLocationAtEachStep = (0...stepsInOneDrag).map { stepNumber in
            let howFarAlong = CGFloat(stepNumber) / CGFloat(stepsInOneDrag)
            return CGPoint(
                x: startAppKitScreenLocation.x
                    + (destinationAppKitScreenLocation.x - startAppKitScreenLocation.x) * howFarAlong,
                y: startAppKitScreenLocation.y
                    + (destinationAppKitScreenLocation.y - startAppKitScreenLocation.y) * howFarAlong
            )
        }

        // Every step's event is built before any is posted, as in the click and the scroll. Here it
        // matters most of all: a drag that gave up part way through has already pressed the button
        // on the thing it was moving, and nothing left to post would let go of it.
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
            // The gap exists only between two steps; the press goes out the moment it is built.
            if stepNumber > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(secondsBetweenTheStepsOfADrag * 1_000_000_000)
                )
            }
            event.post(tap: .cghidEventTap)

            let appKitScreenLocation = appKitScreenLocationAtEachStep[stepNumber]
            // The pointer is brought along rather than left standing where the press started. The
            // call is guarded on a carry being in flight, so it does nothing when the overlay is
            // not running the flight — and the events carry their own points, so the drag is made
            // either way.
            PointerCarrier.carryThePointer(
                toAppKitScreenLocation: appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
            onEachStep?(appKitScreenLocation)
        }

        return .dragged
    }

    /// One step of the drag as one event, carrying the point that step is at.
    ///
    /// The event type and the button are chosen together, exactly as in the click: a
    /// `.leftMouseDragged` carrying any other button is delivered to *that* button's handler, so the
    /// wrong thing is moved while looking from this side like a drag that was posted correctly. The
    /// button is fixed at the left one because a drag has one button and no second axis to decide it
    /// along, which is why nothing here takes a `CGMouseButton`.
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

        // Stated rather than left to timing, as in a single click: a drag that landed close behind
        // the user's own press must not be counted as the second half of their double click.
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }
}

/// Takes the user's pointer along with the cursor while it carries the mouse to a click.
///
/// This is what makes "Kiki is about to operate this for me" legible before anything is pressed:
/// the cursor fetches the pointer, turns red, and carries it to the element.
///
/// **The hold has to be re-stated, not just declared.** `CGWarpMouseCursorPosition` — the call a
/// carry is made of — disassociates the physical mouse from the pointer for about a quarter of a
/// second *by itself* and schedules the re-association on its own, so a hold declared once is
/// overwritten by the carry's own frames. While the cursor is flying, every frame's warp re-arms
/// it and the hold reads as total; the moment the flying stops the warps stop with it, the
/// quarter second runs out, and the pointer goes back to the user's hand in the middle of the
/// dwell — which is what 「落地就撒手」 was. `keepThePointerWhereKikiLeftIt()` is the answer, on a
/// timer faster than the interval it is racing.
///
/// **Every path out has to re-associate.** A process that dies while detached may leave the user
/// with a pointer that no longer answers to their mouse and no system UI to reconnect it, so
/// `releaseThePointerIfCarrying()` is called from every teardown the overlay has, and
/// `CompanionAppDelegate` calls `reattachTheMouseUnconditionally()` at launch as the net under
/// the teardowns that never got to run.
enum PointerCarrier {

    /// Whether the physical mouse is currently detached from the pointer.
    private(set) static var isCarryingThePointer = false

    /// Where this type last put the pointer, in global AppKit screen coordinates. Kept so the
    /// guard can answer "is the pointer still where Kiki left it" without asking the overlay for
    /// anything — the dwell is exactly the stretch where nothing else is running.
    private static var appKitScreenLocationThePointerIsHeldAt: CGPoint?

    /// The primary screen height the pointer was last placed with, since putting it back is
    /// another warp and a warp needs the same flip the placement did.
    private static var primaryScreenHeightWhileThePointerIsHeldInPoints: CGFloat = 0

    /// Re-states the hold sixty times a second for as long as a carry lasts.
    private static var pointerHoldGuardTimer: Timer?

    /// Detaches the physical mouse and puts the pointer under the cursor, ready to be carried.
    ///
    /// The warp is not a nicety: the carry is only honest if the pointer starts the journey in
    /// the cursor's hand. It also covers a pointer on another display, which the cursor cannot
    /// fly to.
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

    /// Moves the pointer to a point, part-way through a carry.
    ///
    /// Guarded on a carry being in flight, so a stray call cannot move the user's pointer
    /// without having taken it first.
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

    /// Ends a carry: re-attaches the physical mouse, then puts the pointer exactly on the point.
    ///
    /// The warp comes *last* on purpose — re-attaching hands over the movement accumulated while
    /// detached, and warping after it is what overwrites that jump.
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

    /// Re-attaches the physical mouse if a carry is in flight, and does nothing otherwise.
    ///
    /// Idempotent, because the paths that call it are teardowns that cannot know whether a carry
    /// was running: a screen being unplugged, the overlay's view going away, a tour cut off by
    /// the next question.
    static func releaseThePointerIfCarrying() {
        guard isCarryingThePointer else { return }
        reattachTheMouseUnconditionally()
    }

    /// Re-attaches the physical mouse without asking whether this process detached it.
    ///
    /// A detachment outlives the process that made it, so the launch-time call that exists to
    /// undo a crash finds `isCarryingThePointer == false` — the flag belongs to the dead process —
    /// and a guarded call would silently do nothing while the user's pointer sat frozen.
    static func reattachTheMouseUnconditionally() {
        // Stopped before anything else, and stopped rather than left to find the flag false on
        // its next tick: a tick landing between the re-attachment below and the flag being
        // cleared would detach the mouse all over again.
        stopGuardingThePointerHold()
        appKitScreenLocationThePointerIsHeldAt = nil
        isCarryingThePointer = false

        // Spends whatever the physical mouse accumulated while detached, which the re-attachment
        // would otherwise hand to the pointer all at once. The value is deliberately not read —
        // spending it is the point.
        _ = CGGetLastMouseDelta()

        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Starts the timer that re-states the hold while a carry is in flight.
    ///
    /// Added in `.common` rather than left in the default mode: a timer in the default mode stops
    /// firing while the run loop is in event-tracking mode, and a hold that lapses for as long as
    /// the user holds a drag down is a hold that is not there.
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

    /// Stops the timer, and only the timer: where the pointer is being held is the carry's to set
    /// and the release's to forget, and a stop that cleared it too would wipe the hold out from
    /// under a carry that is starting.
    ///
    /// Idempotent, and safe to call from inside the guard's own tick.
    private static func stopGuardingThePointerHold() {
        pointerHoldGuardTimer?.invalidate()
        pointerHoldGuardTimer = nil
    }

    /// Re-states that the mouse is not the user's, and puts the pointer back if it slipped away.
    ///
    /// Both halves are needed. The re-statement mostly wins the race against the quarter-second
    /// re-association a warp schedules; the warping back is for the moment it does not, when the
    /// pointer *is* the user's for a frame or two. Snap-back rather than re-grip is the right
    /// shape for that, because the cursor never let go of the element — the mouse did.
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
        // A point of slack, because the pointer is reported by the window server rather than by
        // this process and a whole-number round trip through it is not the user moving the mouse.
        guard howFarThePointerHasMovedInPoints > 1.0 else { return }

        moveThePointer(
            toAppKitScreenLocation: appKitScreenLocationThePointerIsHeldAt,
            primaryScreenHeightInPoints: primaryScreenHeightWhileThePointerIsHeldInPoints
        )
    }

    /// Warps the pointer to a global AppKit screen location.
    ///
    /// The conversion goes through `ElementClicker.accessibilityPoint` rather than being written
    /// again here.
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

        // Each warp schedules the mouse's return to the user's hand, so a carry re-states the
        // hold behind every one of its own frames. Guarded on the flag, which is what keeps this
        // out of `releaseThePointer`'s way — that path clears the flag before warping.
        if isCarryingThePointer {
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }
}
