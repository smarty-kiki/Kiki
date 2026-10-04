import Foundation

/// One file compiled into both `Kiki.app` and the `kiki` tool: a second copy of the path derivation
/// fails one way only — the CLI stops finding a running app. `nonisolated` because the app target
/// defaults unannotated declarations to the main actor and the socket queue is not on it.
nonisolated enum KikiCommandProtocol {

    /// Application Support rather than `/tmp`, which the system may clear under a running process.
    static let socketDirectoryPath: String = {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory.appendingPathComponent("Kiki", isDirectory: true).path
    }()

    static let socketPath: String = socketDirectoryPath + "/command.sock"

    /// `sun_path` holds 104 bytes *including* the NUL; the real path is nowhere near it.
    static let maximumSocketPathByteCount = 103

    /// Gesture values. Strings, so an old build still decodes one it has never heard of — and must
    /// refuse it rather than read a default; absent means a single click.
    nonisolated enum Gesture {
        static let singleClick = "singleClick"
        static let doubleClick = "doubleClick"
        static let tripleClick = "tripleClick"
        static let rightClick = "rightClick"
        static let scrollUp = "scrollUp"
        static let scrollDown = "scrollDown"
        static let scrollLeft = "scrollLeft"
        static let scrollRight = "scrollRight"

        /// A movement between two points, not an event at one; the only gesture the destination fields serve.
        static let drag = "drag"

        /// Types the words in `KikiClickRequest.typedText` at the point, one character at a time.
        static let typeText = "typeText"

        /// Presses `KikiClickRequest.keyCombination` at the point, clicking nothing first — a click would
        /// move the insertion point out from under the keys.
        static let pressKey = "pressKey"
    }

    /// Message `type` values; strings, so an unknown type is ignored rather than a decoding failure.
    nonisolated enum MessageType {
        static let ready = "ready"
        static let accepted = "accepted"
        static let text = "text"
        static let done = "done"
        static let failed = "failed"
        static let superseded = "superseded"
        static let command = "command"
        static let cancel = "cancel"

        /// The one-shot mouse family. Named for its first member and left so on purpose: the name is on the
        /// wire, and renaming it would blind every installed `kiki` to a new app.
        static let click = "click"

        /// An action landed, reused for scrolling — an old tool reads that answer as readily as a click's.
        static let clicked = "clicked"

        /// A picture of one screen, base64 JPEG in the one JSON line — a side channel would be a second
        /// protocol to keep in step.
        static let screenshot = "screenshot"

        static let captured = "captured"

        /// Where text is on screen: no point, no ordinal — every appearance is wanted, unlike a click by text.
        static let locate = "locate"

        static let located = "located"
    }

    /// The coders both ends use, so formatting cannot make one end unreadable to the other; sorted keys
    /// keep the wire form stable for a human reading a capture.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Whether the app can run a command at all, and what is missing when it cannot — answered by the app,
/// never guessed at: the API key and the screen recording grant are its own to judge.
nonisolated struct KikiCommandReadiness: Codable {
    let canRunCommands: Bool
    let problems: [String]

    /// Whether the app knows the scroll gestures, which the two flags above do not answer. Asked before
    /// sending, because rebuilding without restarting leaves an old Kiki listening; absent reads as "no".
    let understandsScrolling: Bool?

    /// The same question for the triple click; one field per gesture rather than one naming a version.
    let understandsTripleClick: Bool?

    /// And again for the drag, where being unknown is worst: a pre-drag app decodes the destination
    /// fields and ignores them, so the drag arrives as a press at the starting point.
    let understandsDragging: Bool?

    /// And again for a scroll shorter than a whole screenful — not answered by `understandsScrolling`,
    /// which is about the gesture and not how far it goes. A pre-fractional app reads the distance as a
    /// whole number, so a fractional one fails to decode the *whole* request: silence, not a short scroll.
    /// Only a non-whole distance is asked about; `-b 3` such an app reads correctly.
    let understandsFractionalScreenfuls: Bool?

    /// And again for the two keyboard gestures, named separately rather than as one "understands the
    /// keyboard": an app that types but does not press combinations is a real thing to be talking to.
    let understandsTyping: Bool?
    let understandsPressingKeys: Bool?

    /// And again for the two commands that only read the screen. Neither is a gesture, but they meet the
    /// same trap: a request *type* an app does not know is ignored in silence, so a newer tool talking to
    /// an older Kiki sits out its whole timeout, which it cannot tell from Kiki having gone away.
    let understandsScreenshots: Bool?
    let understandsLocatingText: Bool?
}

/// Where a terminal wants a mouse action performed: a point, or a piece of text to look for.
nonisolated struct KikiClickRequest: Codable {
    /// A point in the global screen space — the primary display's top-left as origin, y increasing
    /// downward, the same space a posted event lands in. Both or neither.
    var globalScreenX: Double?
    var globalScreenY: Double?

    /// The text to look for on screen; nil when a point was given instead. Also what the destructive-word
    /// refusal is asked about, so it is the text the user named, never anything derived from the screen.
    var elementText: String?

    /// Which occurrence of `elementText` was meant, 1-based in capture order. Absent is read as 1.
    var occurrenceNumber: Int?

    /// The one screen to look on, 1-based in that same order. Absent means every screen.
    var screenNumber: Int?

    /// Which gesture to make at that point — one of `KikiCommandProtocol.Gesture`. One field rather than
    /// a flag per gesture, because two flags can both be set; absent is read as a single click, because a
    /// sender that does not set it predates the field. Named back in a refusal, so the terminal is told
    /// which gesture was refused.
    var gesture: String?

    /// How far a scroll should go, in screenfuls of the display it lands on; absent is read as 1, and only
    /// the scrolling gestures read it. A `Double`, in half-screenful steps, because a whole screen moves
    /// everything the user was following off the display — and because the app knows how tall the display
    /// is and the terminal does not have to guess.
    var screenfuls: Double?

    /// Where a drag lets go, in the same space as `globalScreenX`/`globalScreenY`. Both or neither, and
    /// read only by `Gesture.drag`.
    ///
    /// Two flat fields rather than a nested point, so an app built before dragging decodes the whole
    /// request — its answer is then the refusal `understandsDragging` exists to make. A drag with no
    /// destination is refused rather than read as a press.
    var dragToGlobalScreenX: Double?
    var dragToGlobalScreenY: Double?

    /// The words to type, read only by `Gesture.typeText`; a flat optional rather than a nested payload,
    /// for the drag's reason.
    var typedText: String?

    /// The combination to press, spelled the way `ElementKeyCombination` reads it — `cmd+s`, `cmd+shift+t`,
    /// `⌘⇧S`. Read only by `Gesture.pressKey`.
    ///
    /// A name rather than a key code and a modifier mask: the table of combinations Kiki will not press is
    /// matched on the written form, and a terminal encoding `⌥⌘⎋` as bits would need that table to spell it.
    var keyCombination: String?
}

nonisolated struct KikiScreenshotRequest: Codable {
    /// The one screen to capture, 1-based in capture order — the pointer's screen first, the same numbering
    /// `KikiClickRequest.screenNumber` uses. Absent means that first screen, which is the one the user is
    /// looking at.
    var screenNumber: Int?
}

nonisolated struct KikiLocateRequest: Codable {
    /// The character or word to look for, as the user typed it.
    var text: String

    /// The one screen to search, 1-based in that same order. Absent means every screen, which is what a
    /// search wants: the text is wanted wherever it is.
    var screenNumber: Int?
}

nonisolated struct KikiLocatedPoint: Codable {
    /// The centre of the text, in the global screen space `KikiClickRequest` takes its point in, so a
    /// terminal can hand it straight back as `kiki click -x -y`.
    var globalScreenX: Double
    var globalScreenY: Double

    /// Which screen it is on, 1-based in capture order.
    var screenNumber: Int
}

/// A line the CLI sent to the app. Synthesised `Codable` omits a nil `text`, so a `cancel` goes out as
/// `{"type":"cancel"}`.
nonisolated struct KikiCommandRequest: Codable {
    let type: String
    var text: String?

    /// Whether this turn's reply should be read aloud. Absent is read as `true`, because a sender that
    /// does not set it predates the field and reading the reply out is all it knew how to ask for.
    var speakReply: Bool?

    var click: KikiClickRequest?

    /// A nested payload rather than more flat fields, so a `screenshot` arriving at an app built before it
    /// is a request whose *type* it does not know — ignored whole — rather than one it half reads.
    var screenshot: KikiScreenshotRequest?
    var locate: KikiLocateRequest?

    static func command(_ commandText: String, speakReply: Bool) -> KikiCommandRequest {
        KikiCommandRequest(
            type: KikiCommandProtocol.MessageType.command,
            text: commandText,
            speakReply: speakReply
        )
    }

    static func click(_ clickRequest: KikiClickRequest) -> KikiCommandRequest {
        KikiCommandRequest(type: KikiCommandProtocol.MessageType.click, click: clickRequest)
    }

    static func screenshot(_ screenshotRequest: KikiScreenshotRequest) -> KikiCommandRequest {
        KikiCommandRequest(type: KikiCommandProtocol.MessageType.screenshot, screenshot: screenshotRequest)
    }

    static func locate(_ locateRequest: KikiLocateRequest) -> KikiCommandRequest {
        KikiCommandRequest(type: KikiCommandProtocol.MessageType.locate, locate: locateRequest)
    }

    static let cancel = KikiCommandRequest(type: KikiCommandProtocol.MessageType.cancel)
}

/// A line the app sent to the CLI. Every field but `type` is optional because the messages are a union.
nonisolated struct KikiCommandEvent: Codable {
    let type: String
    var canRunCommands: Bool?
    var problems: [String]?
    var spokenTextSoFar: String?
    var spokenText: String?
    var message: String?
    var understandsScrolling: Bool?
    var understandsTripleClick: Bool?
    var understandsDragging: Bool?
    var understandsFractionalScreenfuls: Bool?
    var understandsTyping: Bool?
    var understandsPressingKeys: Bool?
    var understandsScreenshots: Bool?
    var understandsLocatingText: Bool?

    /// The picture, base64-encoded JPEG, because the message is one JSON line and a JPEG's own bytes
    /// would not survive it.
    var screenshotJPEGBase64: String?

    /// Which screen the picture is of, 1-based in capture order.
    var screenNumber: Int?

    /// Every place the text was found, in reading order — top to bottom, left to right, screen 1 before
    /// screen 2. Never empty: a search that found nothing is a refusal.
    var locatedPoints: [KikiLocatedPoint]?

    /// Whether a `failed` was the app declining to act rather than trying and not managing it: the two
    /// need different exit codes, and `message` alone cannot be read for it.
    var isRefusal: Bool?

    /// Hand-written, because these fields are `var` optionals: a readiness flag added to the struct would
    /// default to nil in a synthesised initialiser and this copy would go on compiling without it, telling
    /// every terminal Kiki is too old — the very refusal the flag exists to make true.
    static func ready(_ readiness: KikiCommandReadiness) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.ready,
            canRunCommands: readiness.canRunCommands,
            problems: readiness.problems,
            understandsScrolling: readiness.understandsScrolling,
            understandsTripleClick: readiness.understandsTripleClick,
            understandsDragging: readiness.understandsDragging,
            understandsFractionalScreenfuls: readiness.understandsFractionalScreenfuls,
            understandsTyping: readiness.understandsTyping,
            understandsPressingKeys: readiness.understandsPressingKeys,
            understandsScreenshots: readiness.understandsScreenshots,
            understandsLocatingText: readiness.understandsLocatingText
        )
    }

    /// The request has been accepted and the slow part is about to start. `message` is the app's own
    /// sentence — 「Kiki 正在看屏幕…」 — absent when there is nothing slow ahead to announce, which is a
    /// terminal asking by coordinate; every sentence the user reads as Kiki's is written in `CompanionManager`.
    static func accepted(message: String?) -> KikiCommandEvent {
        KikiCommandEvent(type: KikiCommandProtocol.MessageType.accepted, message: message)
    }

    /// An absolute snapshot of the reply so far, never a delta: a dropped or coalesced message then costs
    /// the terminal nothing.
    static func text(spokenTextSoFar: String) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.text,
            spokenTextSoFar: spokenTextSoFar
        )
    }

    static func done(spokenText: String) -> KikiCommandEvent {
        KikiCommandEvent(type: KikiCommandProtocol.MessageType.done, spokenText: spokenText)
    }

    /// The click landed, and `message` says what was clicked and where. A type of its own because there
    /// is no reply to wait on.
    static func clicked(message: String) -> KikiCommandEvent {
        KikiCommandEvent(type: KikiCommandProtocol.MessageType.clicked, message: message)
    }

    /// The picture arrived, base64-encoded in `screenshotJPEGBase64`. `message` is the app's own sentence
    /// about which screen it is, and goes to the terminal's stderr, because stdout is carrying the bytes.
    static func captured(message: String, screenshotJPEGBase64: String, screenNumber: Int) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.captured,
            message: message,
            screenshotJPEGBase64: screenshotJPEGBase64,
            screenNumber: screenNumber
        )
    }

    static func located(message: String, locatedPoints: [KikiLocatedPoint]) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.located,
            message: message,
            locatedPoints: locatedPoints
        )
    }

    static func failed(message: String, isRefusal: Bool) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.failed,
            message: message,
            isRefusal: isRefusal
        )
    }

    /// Sent to a terminal that another connection is about to displace, so that a hang-up can be read:
    /// without it the displaced terminal sees only its connection closed, which is what Kiki dying looks
    /// like — and the two are simultaneous, so asking afterwards whether the app still runs does not help.
    static let superseded = KikiCommandEvent(type: KikiCommandProtocol.MessageType.superseded)
}
