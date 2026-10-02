//
//  ElementClicker.swift
//  kiki-desktop-agent
//
//  Posts a real click, a real scroll, a real drag and real keystrokes for the user — the one place
//  the app acts on the machine rather than merely suggesting — plus `PointerCarrier`, which takes
//  the user's pointer along with it.
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
    ///
    /// Fractional, in steps of half a screenful. A whole screen takes everything the reader was
    /// following off the display, so what they were reading is gone and the line they were looking
    /// for is as likely to be in the part that just went past as in the part that arrived — half a
    /// screen is the distance that keeps it. Whole screenfuls are the special case, not the unit.
    case screenfuls(CGFloat)
    /// A distance in points, as a wheel event reports it.
    case points(CGFloat)

    /// A screenful count as it is written out: `0.5` and `1.5` keep their fraction, and a whole
    /// count reads `1` rather than the `1.0` a `CGFloat` prints on its own.
    ///
    /// Shared rather than written twice, because the sentence a terminal is answered with and the
    /// bubble over the cursor are both made from it and 「往下滚 1 屏」 must not come out as
    /// 「往下滚 1.0 屏」 in one of them.
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

/// What Kiki types at the element, rather than what it does to it with the mouse.
///
/// The third gesture family, and the one that is not a mouse event at all: a press and a scroll act
/// on the thing under the point, where typing acts on whatever holds the input focus there. The
/// point still matters — it is where the cursor flies, what the bubble is said over, and in the
/// text's case the point that is clicked to put the focus in — so this rides the same flight as
/// everything else rather than being a path of its own.
enum ElementKeyboardInput: Equatable {
    /// A run of characters, typed one at a time into the element.
    case text(String)
    /// One key press, with the modifiers that are held while it goes down.
    ///
    /// The name as the model or the terminal wrote it (`cmd+s`, `⌘⇧T`, `return`) rather than a
    /// decoded value, because a name that cannot be read is a refusal with a sentence attached to
    /// it — 「这个组合键 Kiki 不认识」 — and a value that failed to decode would have nothing to
    /// say that in. Decoding happens inside `ElementKeyboard`, twice through one implementation:
    /// once to refuse before the flight, once to press at the end of it.
    case combination(name: String)
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

/// What the cursor does when it gets there: press a button, scroll, drag, or type.
///
/// The place the gesture families meet — a click's axis, a scroll's, a drag with no axis of its
/// own, and what is typed — and one value rather than a kind beside a flag because four separate
/// decisions are read off it and they must not be able to disagree — whether the flight is a red
/// one, which bubble is said over the element, whether anything happens on arrival at all, and
/// whether the user's pointer is taken along.
enum ElementActionOnArrival: Equatable {
    case press(ElementClickKind)
    case scroll(ElementScrollDirection, distance: ElementScrollDistance)
    /// The one action that is a movement between two points. It carries no payload: where it lets
    /// go is not a property of the gesture but of the flight it was asked for, so it travels beside
    /// this on the same values the point it starts from does — a `PointingTourStop` or a
    /// `TerminalActionInFlight` — and is read at the moment the drag runs.
    case drag
    /// What is typed at the element, and the one action that is not a mouse event.
    case keyboard(ElementKeyboardInput)

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
    ///
    /// A keyboard action says yes for the same reason a press does. Nothing about typing needs the
    /// pointer to be anywhere — a keystroke is delivered to whatever holds the input focus, and the
    /// carry is what puts the focus where Kiki is about to type. Which is also the whole of what
    /// the red flight is for here: 「Kiki 要在这儿打字了」 before a character goes in.
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

extension ElementClickOutcome {
    /// Whether the click actually went out, which is the one thing a caller that is not the terminal
    /// can do anything with: a refusal and a failed post are both "the screen is unchanged".
    ///
    /// A `switch` over every case rather than a comparison against `.clicked`, so a case added later
    /// fails to build here instead of silently reading as a failure.
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

extension ElementScrollOutcome {
    /// Whether the scroll actually went out. See `ElementClickOutcome.isASuccess`.
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

extension ElementDragOutcome {
    /// Whether the drag actually went out. See `ElementClickOutcome.isASuccess`.
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

/// What came of asking for keystrokes.
///
/// One case for both halves of the family, because what was asked for is an input to this rather
/// than a result of it — the same shape the click's outcome has for its four gestures.
enum ElementKeyboardOutcome {
    /// The characters went in one at a time, or the combination went down and came back up.
    case postedTheKeystrokes
    /// Nothing was posted, and the reason is on this side of the event system — either the focus
    /// click that typing begins with could not be posted, or an event could not be built.
    case failedToPostTheKeystrokes
    /// Typing begins by clicking the element to put the input focus in it, so a point that cannot
    /// be clicked is a point nothing can be typed into. The click's own reason travels inside.
    case refusedBecauseTheElementCannotBeClicked(ElementClickRefusal)
    case refusedBecauseTheCombinationIsADangerousOne(matchedName: String)
    case refusedBecauseTheCombinationIsNotOneKikiKnows(name: String)
    case refusedBecauseTheTextIsLongerThanKikiWillType(characterCount: Int)
    /// Accessibility is not granted. Synthesising an event needs it.
    case refusedBecauseAccessibilityIsNotEnabled
}

extension ElementKeyboardOutcome {
    /// Whether the keystrokes actually went out. See `ElementClickOutcome.isASuccess`.
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

/// Why keystrokes are never posted, decided without asking the screen anything.
///
/// The click's three refusals are not repeated here as a keyboard's own copies: typing begins by
/// clicking the element to put the input focus in it, so the first case carries the click's answer
/// to the same question. What is here instead are the two things only a combination can be —
/// one Kiki will not press, and one it cannot read — and the text that is simply too long to type.
enum ElementKeyboardRefusal {
    /// Typing begins by clicking the element. See `refusalOfTyping`.
    case theElementCannotBeClicked(ElementClickRefusal)
    /// A combination in `ElementKeyboard.writtenFormsKikiWillNotPress`.
    case theCombinationIsADangerousOne(matchedName: String)
    /// A name that does not read as a key and its modifiers.
    case theCombinationIsNotOneKikiKnows(name: String)
    case theTextIsLongerThanKikiWillType(characterCount: Int)
    /// Accessibility is not granted. Synthesising an event needs it.
    case accessibilityIsNotEnabled

    /// The outcome that reports this refusal, for the path that reaches the decision by running the
    /// keystrokes rather than by asking about them first.
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
    /// Every caller converts through this same function — `PointerCarrier`, which carries the mouse,
    /// and the command line tool's answers, which are read by a terminal in the space its own clicks
    /// are posted in. A second copy of the flip would carry the mouse to somewhere the click does not
    /// land, or hand a terminal a coordinate a screen height from the thing it names.
    static func accessibilityPoint(
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

    /// The smallest distance one request can carry, in screenfuls.
    ///
    /// Half a screen, and it is a floor rather than a value the callers are merely expected to stay
    /// above: a request for half a screen clamped up to a whole one is precisely the scroll the
    /// request was made to avoid, and it would happen silently.
    static let smallestScreenfulsInOneRequest: CGFloat = 0.5

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
    /// The leftover event is what carries a fractional request: `:x2.5` goes out as two screenfuls
    /// and one of half, so a distance that is not a whole number reads as one gesture of that length
    /// rather than being rounded up into a longer one. A recorded distance is kept exact for the
    /// same reason — fifty points goes out as fifty points, because a recording replayed at a
    /// different size is not a recording of what the user did. It is bounded in its own unit, at the
    /// same total the screenful form is bounded at, so a flung scroll carrying a thousand points
    /// cannot become a hundred events.
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

/// One key on the keyboard: the code the system presses, and the way the key is written.
struct ElementKey: Equatable {
    /// The physical key, which is what the system matches a combination against.
    let virtualKeyCode: CGKeyCode
    /// How the key is written in a combination, the way a menu writes it: a letter as its capital,
    /// and a key that has a symbol as that symbol.
    let name: String
}

/// Which modifiers are held while a key goes down.
///
/// An option set of its own rather than `CGEventFlags`: this value travels on the flight, which the
/// overlay reads, and that side has no business with CoreGraphics. The conversion is one place, at
/// the bottom of this file beside the events it is for.
struct ElementKeyModifiers: OptionSet {
    let rawValue: Int

    static let control = ElementKeyModifiers(rawValue: 1 << 0)
    static let option = ElementKeyModifiers(rawValue: 1 << 1)
    static let shift = ElementKeyModifiers(rawValue: 1 << 2)
    static let command = ElementKeyModifiers(rawValue: 1 << 3)
}

/// Which key goes down, and which modifiers are held while it does.
struct ElementKeyCombination: Equatable {
    let key: ElementKey
    let modifiers: ElementKeyModifiers

    /// The combination as a menu prints it: the modifiers in the order macOS shows them, then the
    /// key.
    var writtenAs: String { modifiers.writtenAs + key.name }
}

extension ElementKeyModifiers {
    /// ⌃⌥⇧⌘ — macOS's own order, which is the order a menu prints and the reason the shortcut for
    /// logging out is written ⇧⌘Q here rather than ⌘⇧Q.
    var writtenAs: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// The modifier flags as the event system carries them, and the keys those flags describe.
private extension ElementKeyModifiers {
    var asEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    /// Each modifier as the key a keyboard presses, in the order a combination presses them — the
    /// ⌃⌥⇧⌘ order a menu writes them in.
    ///
    /// The left-hand key of each pair, because a combination names a modifier and not a side. Every
    /// one of these codes and the key name printed on it: 55 is ⌘, 56 ⇧, 58 ⌥, 59 ⌃.
    var asKeysInTheOrderTheyArePressed: [(modifier: ElementKeyModifiers, virtualKeyCode: CGKeyCode)] {
        var keys: [(modifier: ElementKeyModifiers, virtualKeyCode: CGKeyCode)] = []
        if contains(.control) { keys.append((.control, 59)) }
        if contains(.option) { keys.append((.option, 58)) }
        if contains(.shift) { keys.append((.shift, 56)) }
        if contains(.command) { keys.append((.command, 55)) }
        return keys
    }
}

/// Types and presses keys for the user.
///
/// The fourth sibling of `ElementClicker`, `ElementScroller` and `ElementDragger`, and the only one
/// that posts no mouse event of its own: a keystroke is delivered to whatever holds the input focus,
/// so the point is where the focus is put rather than where the keys are aimed.
///
/// **Two mechanisms, and neither is a choice.** Text is carried on the event itself
/// (`keyboardSetUnicodeString`), because no key code produces 季 and a code's meaning depends on the
/// keyboard layout. A combination is a real key code with the modifier flags on it, because AppKit
/// matches a menu's key equivalent on the code and the flags — an event carrying the character "s"
/// with ⌘ down triggers nothing at all.
enum ElementKeyboard {

    // MARK: - Limits

    /// How fast Kiki types, in characters a second.
    ///
    /// Slow enough to watch and to interrupt, which is the whole of what typing buys over pasting:
    /// the text is seen arriving, and the keyboard can be taken back mid-word.
    static let charactersTypedPerSecond = 8

    /// The gap between two typed characters, derived from the rate so that changing the speed is
    /// changing one number.
    private static var secondsBetweenTypedCharacters: Double {
        1.0 / Double(charactersTypedPerSecond)
    }

    /// The most Kiki will type in one action. At `charactersTypedPerSecond` this is fifteen seconds
    /// of watching, which is already long for a gesture whose end the user cannot see; anything
    /// longer is a paste, and Kiki does not paste.
    static let maximumCharacterCountKikiWillType = 120

    /// The combinations Kiki will never press, by the way a menu writes them.
    ///
    /// Judged as a click's label is judged: a refusal costs the user one keystroke they can perform
    /// themselves, and accepting costs something that cannot be undone. These are the ones with no
    /// undo — emptying the trash and logging out, both of which macOS asks about but both of which
    /// are the user's decisions to make; force quit, which takes whatever is unsaved in the app it
    /// hits; and locking the screen. Quitting the frontmost app is here for the reason 「退出」 is on
    /// the click's list: it is the same act written as a shortcut.
    private static let writtenFormsKikiWillNotPress: Set<String> = [
        "⇧⌘⌫",  // 清空废纸篓
        "⇧⌘Q",  // 注销
        "⌥⌘⎋",  // 强制退出
        "⌃⌘Q",  // 锁屏
        "⌘Q",   // 退出当前 App
    ]

    /// `.hidSystemState` describes the state a real keyboard would report, as on the click path.
    private static let keyboardEventSource = CGEventSource(stateID: .hidSystemState)

    /// Every key a combination may name: the code the system presses, and the way it is written.
    ///
    /// The code is what a shortcut is matched on, so it is the physical key rather than the
    /// character — which is why a combination is read from a name and never derived from text.
    private static let keysByName: [String: ElementKey] = {
        var keys: [String: ElementKey] = [:]

        // Letters and digits are written as themselves, a letter as its capital — the way a menu
        // writes ⌘S.
        let letterAndDigitKeyCodes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        ]
        for (name, virtualKeyCode) in letterAndDigitKeyCodes {
            keys[name] = ElementKey(virtualKeyCode: virtualKeyCode, name: name.uppercased())
        }

        // The punctuation keys, written as the character printed on them.
        let punctuationKeyCodes: [String: CGKeyCode] = [
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
            ",": 43, ".": 47, "/": 44, "`": 50,
        ]
        for (name, virtualKeyCode) in punctuationKeyCodes {
            keys[name] = ElementKey(virtualKeyCode: virtualKeyCode, name: name)
        }

        // The keys whose name is not a character, written the way a menu writes them. Several names
        // for one key are what that key is called, not several keys.
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

    /// Every way a modifier is written: the words a developer types and the symbols a menu prints.
    private static let modifiersByName: [String: ElementKeyModifiers] = [
        "control": .control, "ctrl": .control, "⌃": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "command": .command, "cmd": .command, "⌘": .command,
    ]

    // MARK: - Reading a combination

    /// Reads a combination from the way it is written: `cmd+shift+s` or `⌘⇧S`, `return`, `esc`.
    ///
    /// Both ways round — the words a developer types and the symbols a menu prints — in either case
    /// and in any order, because the model writes whichever it saw last. Nil for anything that does
    /// not read as a key with modifiers, so that a caller can say so out loud rather than press
    /// something near it.
    private static func combination(named name: String) -> ElementKeyCombination? {
        let writtenName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !writtenName.isEmpty else { return nil }

        var modifiers: ElementKeyModifiers = []
        var remainder = Substring(writtenName)

        // A name written in symbols has no separator to split on — ⌘⇧S is one run of modifiers and
        // then the key — so those are peeled off the front before anything is split.
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

    /// A combination as it is written, the way a menu writes it — `⌘⇧S`.
    ///
    /// The one place a combination becomes words, because two readers want it and they must not
    /// disagree about which key was pressed: the bubble over the cursor, and the sentence the
    /// terminal is answered with. A name that does not read as a combination comes back as it was
    /// written, which is what the refusal sentence has to name.
    static func phraseForPressingKey(_ name: String) -> String {
        combination(named: name)?.writtenAs ?? name
    }

    // MARK: - Refusing

    /// Whether typing into this element would be refused, and why — without typing anything.
    ///
    /// Typing begins by clicking the element to put the input focus in it, so the question is the
    /// click's question — a tag with no label, a label naming something destructive, no
    /// Accessibility — and it is answered by the click's own rules rather than by a keyboard copy of
    /// them. The copy that drifted would be the one deciding whether 删除 gets typed into.
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

    /// Whether a combination would be refused, and why — without pressing anything.
    ///
    /// Asked before the flight, which is what makes a refused combination not even turn the cursor
    /// red: the cursor never going red is the whole of what "Kiki will not press that" looks like
    /// from the user's side.
    static func refusalOfCombination(named name: String) -> ElementKeyboardRefusal? {
        guard let combination = combination(named: name) else {
            return .theCombinationIsNotOneKikiKnows(name: name)
        }
        return refusalOfCombination(combination)
    }

    /// The rules themselves, for a combination that has already been read — so that the path that
    /// asks before the flight and the path that presses at the end of it run the same ones.
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

    /// Types a run of characters into the element at a point, one character at a time.
    ///
    /// The click comes first and is a real left click: it is what puts the input focus into the
    /// field, and without it the characters land wherever the focus was last left. It goes through
    /// `ElementClicker.clickElement` rather than a pair of events built here, because it is an
    /// ordinary single click and a second copy of one is a second answer to what a click is.
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
        // Unreachable behind the refusal above, which asked the click's own question with these same
        // arguments. One outcome covers it rather than a translation of each of the click's: the
        // refusals have already been reported, and what is left is a click that did not land — in
        // which case there is nowhere for the text to go either way.
        guard case .clicked = focusClickOutcome else {
            return .failedToPostTheKeystrokes
        }

        // Every character's events are built before any is posted, as in a multi-press click and a
        // drag: half a text is text the user has to notice and delete.
        var eventsByCharacter: [[CGEvent]] = []
        for character in text {
            guard let events = keystrokeEvents(forTyping: String(character)) else {
                return .failedToPostTheKeystrokes
            }
            eventsByCharacter.append(events)
        }

        for (characterNumber, eventsForThisCharacter) in eventsByCharacter.enumerated() {
            // A gap exists only between two characters; the first goes out the moment it is built.
            // `Task.sleep` and not `usleep`: this is the main actor, and the overlay is drawing the
            // cursor on it for the whole of the time the text is going in.
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

    /// The press and the release of one typed character, or nil if either could not be built.
    ///
    /// The character rides on the event rather than being looked up as a key code: no code produces
    /// 季, and a code's meaning depends on the layout and on what else is held down. This is also
    /// what keeps the text from being a paste in any sense the app could notice — the characters go
    /// in as keystrokes, the input method is not involved, and the pasteboard is never touched.
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
            // Stated rather than inherited. An event built from `keyboardEventSource` starts with
            // whatever flags that source is carrying, and a combination posted a moment before is
            // enough to leave ⌘ on them — which delivers every character as a shortcut rather than
            // as text into the field the click just put the focus in.
            event.flags = []

            // The key code types nothing of its own; the text on the event is the whole of what goes
            // in. A character is more than one UTF-16 unit often enough that its count is the length
            // handed over, not one.
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

    /// Presses a combination at the input focus.
    ///
    /// Nothing is clicked first, deliberately: a click moves the insertion point, and no combination
    /// Kiki presses wants the caret somewhere other than where the user left it.
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

        // The modifiers are pressed as keys of their own before the key they modify, and released
        // after it, because a flags field describes a modifier without ever pressing one. A pair of
        // flagged events on its own leaves ⌘ down in the system once Kiki has finished — the window
        // server holds it until some later event clears it — and the next thing to be typed, by
        // Kiki or by the user, arrives as a shortcut rather than as text.
        //
        // The flags accumulate on the way down and unwind on the way up, so the last event of the
        // sequence carries none and the keyboard is handed back as it was found.
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
            // On the release as well as the press: a key equivalent is matched on the flags the
            // event carries, and the key going up is what an app sees of the gesture being finished
            // rather than abandoned.
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
