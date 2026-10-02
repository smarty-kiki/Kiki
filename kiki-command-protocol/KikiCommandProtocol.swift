import Foundation

/// Where the command socket lives and what goes over it.
///
/// Compiled into both `Kiki.app` and the `kiki` command line tool. Deliberately one file for
/// both: a second copy of the path derivation fails in one direction only — the CLI stops
/// finding an app that is running perfectly well — and that is a bad afternoon to debug.
///
/// Everything here is `nonisolated` because the app target defaults unannotated declarations to
/// the main actor and the socket queue is not on it. These are constants and plain values, so
/// there is nothing for an actor to protect.
nonisolated enum KikiCommandProtocol {

    /// `~/Library/Application Support/Kiki/command.sock`.
    ///
    /// Application Support rather than `/tmp` because the socket is created once per launch and
    /// lives as long as the app does; a directory the system may clear underneath a running
    /// process is the wrong home for it.
    static let socketDirectoryPath: String = {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory.appendingPathComponent("Kiki", isDirectory: true).path
    }()

    static let socketPath: String = socketDirectoryPath + "/command.sock"

    /// `sun_path` holds 104 bytes *including* the terminating NUL, so a longer path cannot be
    /// bound at all. The real path is nowhere near it; a very long user name could get close.
    static let maximumSocketPathByteCount = 103

    /// Gesture `gesture` values, naming the gesture rather than the subcommand that sends it.
    ///
    /// Strings rather than an enum, so that a value an old build has never heard of is still a
    /// decodable request rather than a decoding failure — the refusal is then a sentence the app can
    /// write, instead of a message that never arrives and a terminal left guessing.
    ///
    /// A gesture a build does not recognise must be refused, never read as some default. Pressing
    /// the left button is not a harmless interpretation of "scroll down": it follows a link or
    /// answers a dialog. Absent is the one exception, and it means a single click, because a sender
    /// that leaves the field out predates it and single clicks are all it could ever have meant.
    nonisolated enum Gesture {
        static let singleClick = "singleClick"
        static let doubleClick = "doubleClick"
        static let tripleClick = "tripleClick"
        static let rightClick = "rightClick"
        static let scrollUp = "scrollUp"
        static let scrollDown = "scrollDown"
        static let scrollLeft = "scrollLeft"
        static let scrollRight = "scrollRight"

        /// The one gesture that is a movement between two points rather than an event at one, and
        /// the only one `KikiClickRequest.dragToGlobalScreenX` means anything for.
        static let drag = "drag"

        /// Typing words into whatever has the focus at the point, one character at a time. The
        /// words are `KikiClickRequest.typedText` and are the only gesture with a payload that is
        /// the action itself rather than a parameter of it.
        static let typeText = "typeText"

        /// Pressing a combination — `cmd+s`, `⌘⇧T` — at the point. `KikiClickRequest.keyCombination`
        /// names it, and unlike typing this presses no mouse button first: a click would move the
        /// insertion point out from under the keys.
        static let pressKey = "pressKey"
    }

    /// Message `type` values, for both directions. Strings rather than an enum so that an
    /// unknown type is ignored rather than a decoding failure.
    nonisolated enum MessageType {
        static let ready = "ready"
        static let accepted = "accepted"
        static let text = "text"
        static let done = "done"
        static let failed = "failed"
        static let superseded = "superseded"
        static let command = "command"
        static let cancel = "cancel"

        /// The whole family of one-shot mouse actions — a press, two presses, a right press, a
        /// scroll. Named for the first of them and left that way on purpose: the name is on the
        /// wire, so renaming it would make every `kiki` already installed on the machine invisible
        /// to a new app, and being understood matters more than being tidy.
        static let click = "click"

        /// An action from that family landed. Reused for scrolling rather than given a type of its
        /// own, because the terminal is waiting on the same question either way — "did it happen,
        /// and where" — and an old tool reads a scroll's answer as readily as a click's.
        static let clicked = "clicked"

        /// A picture of one screen, as base64 JPEG in the one JSON line. Base64 rather than a
        /// second channel because the socket is one JSON message per line and both ends already
        /// frame it that way; a side channel would be a second protocol to keep in step with this
        /// one, and the first thing to drift would be which of the two was authoritative.
        static let screenshot = "screenshot"

        /// The picture arrived, in `KikiCommandEvent.screenshotJPEGBase64`.
        static let captured = "captured"

        /// Where a piece of text is on screen: a question with no action in it at all. Neither a
        /// point nor an occurrence number is sent — every appearance is wanted, which is the whole
        /// difference between this and a click by text.
        static let locate = "locate"

        /// The answer to that question, in `KikiCommandEvent.locatedPoints`.
        static let located = "located"
    }

    /// The coders both ends use, so a change to formatting cannot make one end unreadable to
    /// the other. Sorting keys keeps the wire form stable for a human reading a packet capture.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Whether the app can run a command at all, and what is missing when it cannot.
///
/// Answered by the app rather than guessed at by the CLI: the API key is a Keychain item the
/// app owns and the screen recording grant is judged against the app's own code signature.
nonisolated struct KikiCommandReadiness: Codable {
    let canRunCommands: Bool
    let problems: [String]

    /// Whether the running app knows the scroll gestures, which the two flags above do not answer.
    ///
    /// A terminal asks this before it sends one, because the app it is talking to is not necessarily
    /// the one it was built beside: rebuilding without restarting leaves an old Kiki listening, and
    /// a scroll it refuses as unknown is a refusal the terminal can explain. Optional so that an
    /// older app, which does not send the field at all, reads as "no".
    let understandsScrolling: Bool?

    /// The same question for the triple click, and for the same reason. One field per gesture
    /// rather than one field naming a version, because an app's vocabulary is a fact about which
    /// gestures it knows and a version number is not: the terminal would have to hold a map from
    /// versions to gestures, and that map is a second answer to a question the app already answers.
    let understandsTripleClick: Bool?

    /// And again for the drag, which is the gesture a build is likeliest to be asked for while not
    /// knowing it: two destination fields a pre-drag app decodes and ignores would turn a drag into
    /// a press at the starting point.
    let understandsDragging: Bool?

    /// And again for a scroll shorter than a whole screenful.
    ///
    /// Not answered by `understandsScrolling`, which is about the gesture and not about how far it
    /// goes: an app that scrolls reads the distance as a whole number, so a fractional one fails to
    /// decode the *whole* request — the terminal is answered with silence and a wait that runs out,
    /// rather than with a scroll of the wrong length. Only a distance that is not whole is asked
    /// about, because such an app still reads `-b 3` correctly.
    let understandsFractionalScreenfuls: Bool?

    /// And again for the two keyboard gestures.
    ///
    /// Named per gesture rather than as one "understands the keyboard", for the reason the drag's
    /// flag gives: an app built between the two — one that types but does not press combinations —
    /// is a real thing to be talking to, and one flag would have it refuse a request it understands.
    let understandsTyping: Bool?
    let understandsPressingKeys: Bool?

    /// And again for the two commands that only read the screen.
    ///
    /// Neither is a gesture — nothing on the machine changes and no switch has an opinion — but they
    /// meet the same trap the flags above exist for, and the one they would fall into is worse than
    /// any of those: an app that does not know a request type ignores it in silence, so a newer tool
    /// talking to an older Kiki would sit out its whole timeout and report a wait that ran out, which
    /// it cannot tell from Kiki having gone away. Named per command rather than as one "understands
    /// reading the screen", for the reason the keyboard's two are separate: an app built between
    /// them is a real thing to be talking to.
    let understandsScreenshots: Bool?
    let understandsLocatingText: Bool?
}

/// Where a terminal wants a mouse action performed, in one of the two ways it can say: a point, or
/// a piece of text to look for.
///
/// One type for both ends rather than the CLI's flags and the app's parameters being separate
/// shapes: the CLI builds this, the app reads it off the wire, and neither has to know how the
/// other names any of it.
nonisolated struct KikiClickRequest: Codable {
    /// A point in the global screen space — the primary display's top-left as origin, y increasing
    /// downward, the same space a posted event lands in. Both or neither.
    var globalScreenX: Double?
    var globalScreenY: Double?

    /// The text to look for on screen. Nil when the terminal gave a point instead.
    ///
    /// Also what the destructive-word refusal is asked about, so it has to be the text the user
    /// named rather than anything derived from the screen.
    var elementText: String?

    /// Which occurrence of `elementText` was meant, 1-based across the screens, in the order they
    /// were captured. Absent is read as 1.
    var occurrenceNumber: Int?

    /// The one screen to look on, 1-based in that same order. Absent means every screen.
    var screenNumber: Int?

    /// Which gesture to make at that point — one of `KikiCommandProtocol.Gesture`.
    ///
    /// One field rather than a flag per gesture, because two flags can both be set and that is one
    /// question with two answers. Absent is read as a single click, because a sender that does not
    /// set it predates the field. The gesture is named back in the answer rather than left for the
    /// terminal to infer from which subcommand it sent, because a refusal has to be able to say
    /// which gesture it refused.
    var gesture: String?

    /// How far a scroll should go, counted in screenfuls of the display it lands on. Absent is read
    /// as 1, and only the scrolling gestures read it.
    ///
    /// Fractional, in steps of half a screenful: a whole screen moves everything the user was
    /// following off the display, so half is what a scroll made in order to read is asked for. An app
    /// built before this was fractional refuses the request by failing to decode it, which is what
    /// `KikiCommandReadiness.understandsFractionalScreenfuls` exists to catch first.
    ///
    /// Screenfuls rather than points because the app knows how tall the display is and the terminal
    /// does not have to: a distance in points would be derived from a screen size the caller guessed
    /// at, and the app would then scale that guess again.
    var screenfuls: Double?

    /// Where a drag lets go, in the same space `globalScreenX`/`globalScreenY` are given in. Both
    /// or neither, and read only by `Gesture.drag`.
    ///
    /// Two more point fields rather than a nested point type, so that an app built before dragging
    /// decodes the whole request rather than failing on a shape it has never seen — its answer is
    /// then the refusal `understandsDragging` exists to make, instead of a message that never
    /// arrives. A drag with no destination is refused rather than read as a press.
    var dragToGlobalScreenX: Double?
    var dragToGlobalScreenY: Double?

    /// The words to type, read only by `Gesture.typeText`.
    ///
    /// A `var` optional rather than a nested payload type, for the drag's reason: an app built
    /// before typing decodes the request whole and ignores the field, rather than failing on a
    /// shape it has never seen — so what an old app does with it is refuse the gesture it does not
    /// know, which is a sentence the terminal can read, instead of a dropped connection.
    var typedText: String?

    /// The combination to press, spelled the way `ElementKeyCombination` reads it — `cmd+s`,
    /// `cmd+shift+t`, `⌘⇧S`. Read only by `Gesture.pressKey`.
    ///
    /// A name rather than a key code and a modifier mask, deliberately: the table of combinations
    /// Kiki will not press lives in the app and is matched on the written form, and a terminal that
    /// had to encode `⌥⌘⎋` as bits would have to know that table to spell it the way it is matched.
    var keyCombination: String?
}

/// Which screen a terminal wants a picture of.
nonisolated struct KikiScreenshotRequest: Codable {
    /// The one screen to capture, 1-based in capture order — the pointer's screen first, the rest
    /// behind it, the same numbering `KikiClickRequest.screenNumber` uses. Absent means that first
    /// screen, because a picture is one screen's worth by construction and the one the user is
    /// looking at is the one they mean.
    var screenNumber: Int?
}

/// The text a terminal wants located on screen.
nonisolated struct KikiLocateRequest: Codable {
    /// The character or word to look for, as the user typed it.
    var text: String

    /// The one screen to search, 1-based in that same order. Absent means every screen, which is
    /// what a search wants: the text is wanted wherever it is.
    var screenNumber: Int?
}

/// One place a piece of text was found on screen.
nonisolated struct KikiLocatedPoint: Codable {
    /// The centre of the text, in the global screen space — the same one `KikiClickRequest` takes
    /// its point in, so a terminal can hand it straight back as `kiki click -x -y`.
    var globalScreenX: Double
    var globalScreenY: Double

    /// Which screen it is on, 1-based in capture order.
    var screenNumber: Int
}

/// A line the CLI sent to the app.
///
/// Synthesised `Codable` omits a nil `text`, so a `cancel` goes out as `{"type":"cancel"}`.
nonisolated struct KikiCommandRequest: Codable {
    let type: String
    var text: String?

    /// Whether this turn's reply should be read aloud. Absent is read as `true`, because a sender
    /// that does not set it predates the field and reading the reply out is all it knew how to ask
    /// for.
    var speakReply: Bool?

    var click: KikiClickRequest?

    /// A nested payload rather than more fields on this type, for the drag's reason read the other
    /// way round: a `screenshot` arriving at an app built before it is then a request whose *type*
    /// it does not know — ignored whole — rather than one it half reads.
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

/// A line the app sent to the CLI.
///
/// Every field but `type` is optional because the messages are a union; a `text` message carries
/// `spokenTextSoFar` and nothing else, and encoding the absent ones as `null` costs nothing.
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

    /// The picture, base64-encoded JPEG. Base64 because the message is one JSON line and a JPEG's
    /// own bytes would not survive it.
    var screenshotJPEGBase64: String?

    /// Which screen the picture is of, 1-based in capture order.
    var screenNumber: Int?

    /// Every place the text was found, in reading order — top to bottom, left to right, screen 1
    /// before screen 2. Never empty: a search that found nothing is a refusal, so a terminal that
    /// reads a `located` always has at least one coordinate to use.
    var locatedPoints: [KikiLocatedPoint]?

    /// Whether a `failed` was the app declining to act rather than trying and not managing it.
    ///
    /// The two need different exit codes — a refusal means nothing was attempted and the machine
    /// is untouched, where a failure means a click was meant to go out and did not — and `message`
    /// alone cannot be read for it.
    var isRefusal: Bool?

    /// Hand-written rather than memberwise, because these fields are `var` optionals: a readiness
    /// flag added to the struct defaults to nil in a synthesised initialiser and this copy would go
    /// on compiling without it — and the terminal would be told Kiki is too old, which is exactly
    /// the refusal the flag exists to make true.
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

    /// The request has been accepted and the slow part is about to start.
    ///
    /// `message` is the app's own sentence about what it is doing — 「Kiki 正在看屏幕…」 — and is
    /// absent when there is nothing slow ahead to announce, which is a terminal asking by coordinate
    /// rather than by text. It is the app's words rather than the tool's because every sentence the
    /// user reads as Kiki saying something is written where the other ones are, in `CompanionManager`.
    static func accepted(message: String?) -> KikiCommandEvent {
        KikiCommandEvent(type: KikiCommandProtocol.MessageType.accepted, message: message)
    }

    /// An absolute snapshot of the reply so far, never a delta: a dropped or coalesced message
    /// then costs the terminal nothing, where a delta would leave it permanently out of step.
    static func text(spokenTextSoFar: String) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.text,
            spokenTextSoFar: spokenTextSoFar
        )
    }

    static func done(spokenText: String) -> KikiCommandEvent {
        KikiCommandEvent(type: KikiCommandProtocol.MessageType.done, spokenText: spokenText)
    }

    /// The click landed, and `message` says what was clicked and where.
    ///
    /// A separate type from `done` because there is no reply: the terminal is waiting on whether a
    /// click went out, not on text.
    static func clicked(message: String) -> KikiCommandEvent {
        KikiCommandEvent(type: KikiCommandProtocol.MessageType.clicked, message: message)
    }

    /// The picture arrived, base64-encoded in `screenshotJPEGBase64`.
    ///
    /// `message` is the app's own sentence about which screen it is — 「已截取第 1/2 块屏幕。」 —
    /// and goes to the terminal's stderr, because this command's stdout is carrying the bytes.
    static func captured(message: String, screenshotJPEGBase64: String, screenNumber: Int) -> KikiCommandEvent {
        KikiCommandEvent(
            type: KikiCommandProtocol.MessageType.captured,
            message: message,
            screenshotJPEGBase64: screenshotJPEGBase64,
            screenNumber: screenNumber
        )
    }

    /// Where the text was found, in `locatedPoints` and in reading order.
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

    /// Sent to a terminal that another connection is about to displace.
    ///
    /// It exists so that a hang-up can be read: the displaced terminal otherwise sees only that
    /// its connection closed, which is the same thing it would see if Kiki died — and the two are
    /// simultaneous, so asking whether the app is still running does not separate them either.
    static let superseded = KikiCommandEvent(type: KikiCommandProtocol.MessageType.superseded)
}
