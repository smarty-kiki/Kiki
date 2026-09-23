//
//  CompanionManager.swift
//  kiki-desktop-agent
//
//  Central state manager for the companion voice mode: owns the push-to-talk pipeline
//  and the observable voice state the panel UI reads.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import Speech
import SwiftUI

enum CompanionVoiceState: Equatable {
    case idle
    case listening
    case processing
    case responding
}

/// What Kiki is doing at this moment, as one answer.
///
/// `CompanionVoiceState` and `StatusItemIconPhase` are two independent facts, and every way into the
/// app has to combine them into "may this start now?" — with a different answer each time: a visit to
/// the menu bar icon turns away everything, a reply in flight turns away a click but not a new
/// question. Spelled out at each entry point that combination is a condition per site, and the sites
/// can drift apart; named once, each entry point states only its own policy, and a state added later
/// is a compile error at every one of them rather than a silent pass.
enum WhatKikiIsDoingRightNow {
    /// Nothing in particular — what the panel shows as 等待中.
    case waiting
    /// The cursor is in the menu bar icon's hands: on its way in, or already inside it.
    case restingInTheStatusItemIcon
    /// The cursor is on its way back out of the icon.
    case wakingFromTheStatusItemIcon
    /// Watching what the user does with the mouse, so it can be done again afterwards.
    case recordingWhatTheUserIsDoing
    /// Doing the recorded actions back, in a loop.
    case replayingWhatTheUserDid
    case listeningToTheUser
    /// Capturing, or waiting on the model — including the part of a turn that is not read aloud.
    case processingTheLastTurn
    case replyingToTheLastTurn
}

/// Which half of a recording — if either — Kiki is in.
///
/// One fact rather than two flags, because the three answers are exclusive by construction: a
/// recording that has ended is what the replay begins from, and a tap that arrives during a replay
/// ends it and starts a recording. Two booleans would admit a state where Kiki is doing both, and
/// every reader would then have to decide which one it believes.
enum RecordedActionsPhase: Equatable {
    case neitherRecordingNorReplaying
    case recordingWhatTheUserIsDoing
    case replayingWhatTheUserDid
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    /// Speech Recognition is a TCC service of its own, separate from the microphone, and
    /// macOS asks for it the first time the Speech framework runs.
    @Published private(set) var hasSpeechRecognitionPermission = false

    /// Where the cursor has been sent, and what it is to do when it gets there.
    ///
    /// Written as one value because the five facts in it are one answer, and read as one because a
    /// flight that picked up the last flight's bubble text or click kind would point at the right
    /// place for the wrong reason. The overlay watches `screenLocation` alone, which is what lets
    /// `endPointingTour` withdraw the press of a stop the cursor is still standing on without
    /// sending it back to the spot it never left.
    @Published var pointingTarget: PointingTarget?

    /// Where a drag has the pointer right now, in global AppKit screen coordinates, while one is
    /// running — nil at every other moment.
    ///
    /// A drag is the one action whose cursor position is not one of the two ends: the press and the
    /// release are a flight's shape, while what a drag is doing is somewhere in between and moving.
    /// Written a step at a time by `ElementDragger` and read by the overlay, which draws the cursor
    /// there so it reads as the thing being carried rather than as a cursor that arrived and waited.
    @Published var screenLocationOfTheDragInFlight: CGPoint?

    /// Where the cursor is in its trip into the menu bar icon it was left resting on, and back out.
    ///
    /// Written by `MenuBarPanelManager` when either wait is over and by the overlay when the cursor
    /// lands; read by the overlay to fly, by the manager to redraw the icon, and by
    /// `isNotTakingInputBecauseOfTheStatusItemIcon` to close every way into the app.
    @Published private(set) var statusItemIconPhase: StatusItemIconPhase = .notInTheIcon

    /// The reply being spoken, cut into the pieces the voice is handed one at a time.
    ///
    /// A segment runs to the end of the first sentence that names a tour stop, or of a sentence the
    /// model terminated where a sentence names nothing. That boundary is what lets the words wait
    /// for the cursor, by never handing over the next segment.
    private var speechSegments: [CompanionSpeechSegment] = []
    /// How many of `speechSegments` are beyond revision. The last one is the segment the
    /// model may still be writing, held back because the voice cannot take words back.
    private var finalizedSpeechSegmentCount = 0
    /// Whether the reply has stopped arriving. The voice reaching the end of the finalised segments
    /// is not the end of the reply — the next one may not be written yet — so without this the rest
    /// would never be heard.
    private var isReplyStreamComplete = false
    /// Cuts the reply into segments as it arrives and resolves each tag the moment it
    /// closes. Nil outside a streamed reply — the onboarding demo has none.
    private var streamingReplySegmenter: StreamingReplySegmenter?
    /// Index into `speechSegments` of the segment being spoken.
    private var currentSpeechSegmentIndex = 0
    /// Whether the voice has reported the segment being spoken as spoken through.
    private var hasCurrentSpeechSegmentFinishedSpeaking = false
    /// Whether the reply is still being spoken. Distinct from the TTS client's own
    /// `isPlaying`, which goes false between segments.
    ///
    /// One of the facts `voiceState` depicts, which is why every write to it settles that state
    /// rather than leaving each writer to remember to.
    private var isSpeakingReply = false { didSet { settleVoiceState() } }
    /// Whether this turn's reply is read aloud. A turn raised from the terminal is not, unless it
    /// asked to be: with nothing to listen to, the cursor is what paces the pointing.
    private var isReadingTheReplyAloud = true
    /// Whether a voice was handed this turn's reply and never reported a word of it.
    ///
    /// No word is coming to release a stop, so the cursor paces the tour from there on — the pacing
    /// a reply that is not read aloud gets from the start. Unlike `isReadingTheReplyAloud` the voice
    /// is left alone: it may still be speaking, and only the pointing has to stop waiting on it.
    private var hasTheNarrationGoneSilent = false
    /// Whether a reply is being produced and none of it has been heard yet — what the cursor's
    /// spinner depicts. Wider than the dictation phase the voice-state observer knows about, since
    /// the transcript lands long before the model writes a word, and it ends at the first *sound*,
    /// which `AppleTTSClient` reports from its playback position rather than from a request to play.
    private var isWaitingForTheFirstSoundOfTheReply = false { didSet { settleVoiceState() } }
    /// Whether a turn's reply is being produced, from the transcript being taken to the turn's voice
    /// being done with it.
    ///
    /// Wider than `isWaitingForTheFirstSoundOfTheReply`, which is about what has been *heard*: a turn
    /// that is not read aloud hears nothing and would otherwise read as 等待中 for its whole length —
    /// during which a click from the terminal would be let through into the middle of it.
    private var isProducingAReply = false { didSet { settleVoiceState() } }
    /// How far into the reply's spoken text the narration has got. The voice reports offsets
    /// within the segment it was handed, so this is where they are converted to the reply's.
    private var lastNarrationWordEndOffsetInSpokenText = 0
    /// How far into the segment being spoken the narration has got, compared against the
    /// segment's own length to tell a segment spoken through from one the voice abandoned.
    private var lastSpokenWordEndOffsetInCurrentSpeechSegment = 0

    /// A run of the reply handed to the synthesizer as one utterance.
    private struct CompanionSpeechSegment {
        /// The words this segment speaks, a slice of the reply's spoken text.
        let spokenText: String
        /// Where that slice starts in the reply's spoken text.
        let startOffsetInSpokenText: Int
        /// The tour stops whose elements this segment talks about, as a range into
        /// `resolvedPointingTourStops`. Empty for a segment that names nothing.
        let stopIndexRange: Range<Int>
    }

    // MARK: - Pointing Tour State

    /// The elements the reply being spoken tagged, in the order the model describes them and
    /// already converted into screen locations. One tag is a one-stop tour, so pointing
    /// follows the narration the same way either way.
    private var resolvedPointingTourStops: [ResolvedPointingTourStop] = []
    /// Index into `resolvedPointingTourStops` of the next stop to fly to.
    private var nextPointingTourStopIndex = 0
    /// True while the cursor is driven by a tour rather than by the overlay's own
    /// single-point hold-and-return, which is what decides who receives the arrival.
    @Published var isPointingTourActive = false
    /// Set when the narration has finished and the cursor should come home from the last stop it
    /// was parked on. Read as state by the arrival path and by the predicates that ask whether the
    /// voice still has a cursor to wait for; it is not how the cursor is told.
    @Published var shouldReturnBuddyToCursorAfterPointing = false
    /// Bumped every time the cursor is told to come home and resume following, on every screen at
    /// once. The view on the screen whose buddy is parked is the one that acts.
    ///
    /// A counter rather than a flag: coming home is driven by a `.onChange`, which fires on a
    /// change, so a flag the same teardown writes `false` into takes the request away with it.
    @Published private(set) var buddyReturnHomeRequestCount = 0
    /// True between triggering a flight and hearing that it arrived.
    private var isFlyingToPointingTourStop = false
    /// Writes off a flight that never reports back, so it cannot hold the tour for good.
    private var pointingTourNarrationResumeTimeoutTask: Task<Void, Never>?
    /// Waits to see whether the narration reports any words; see
    /// `schedulePointingTourFallbackIfNarrationIsSilent()`.
    private var pointingTourNarrationFallbackTask: Task<Void, Never>?
    /// Pokes the tour once the cursor has spent its minimum time on the stop it is on.
    private var pointingTourDwellCompletionTask: Task<Void, Never>?
    /// Brings the cursor home if the narration outlasts the last stop's dwell.
    private var pointingTourReturnHomeTimeoutTask: Task<Void, Never>?
    /// Whether the voice has reported any words at all for the reply being spoken — direct
    /// evidence that it reports, where "no flight has started yet" is not.
    private var hasNarrationReportedAnyWords = false
    /// When the narration last showed it was still moving. A reported word counts, and so does an
    /// element sitting on a new sentence, which is what a later chunk moves.
    private var lastNarrationProgressDate: Date?
    /// Unsticks a tour whose narration has fallen silent partway through.
    private var pointingTourStallWatchdogTask: Task<Void, Never>?
    /// When the cursor last landed on a tour stop. The minimum dwell is measured from here.
    private var lastPointingTourStopArrivalDate: Date?

    /// How long a pointing tour waits for a flight to report back before giving up on it.
    /// Comfortably longer than the slowest flight, so it only fires when nothing picked it up.
    private static let pointingTourArrivalTimeoutSeconds: Double = 3.0

    /// How long the cursor stays on a stop before it may leave for the next one. The bubble it
    /// writes there has to be readable, and the narration's next tagged sentence often is not.
    private static let minimumSpokenPointingTourStopDwellSeconds: Double = 1.0

    /// The same hold for a reply nothing is reading aloud. Shorter, because there is no sentence the
    /// bubble has to keep pace with: the terminal is where the reply is read, and the pointing is
    /// watched rather than listened to.
    private static let minimumSilentPointingTourStopDwellSeconds: Double = 0.4

    /// How long the cursor holds a stop in this turn, which is the only thing pacing a tour that is
    /// not being narrated.
    private var minimumPointingTourStopDwellSeconds: Double {
        isReadingTheReplyAloud
            ? Self.minimumSpokenPointingTourStopDwellSeconds
            : Self.minimumSilentPointingTourStopDwellSeconds
    }

    /// How long the cursor waits on the last stop it will visit before flying home, while the
    /// narration is still going. Matches the hold the overlay gives a single point.
    private static let pointingTourStopMaximumDwellSeconds: Double = 3.0

    /// How long to wait for the first word of the narration before concluding this voice will
    /// never report what it is saying.
    private static let pointingTourSilentNarrationFallbackSeconds: Double = 2.5

    /// How long a tour may go without a reported word before its narration is treated as stopped for
    /// good. Has to clear the longest legitimate silence between words, which is a dwell plus an
    /// arrival timeout, plus a second of margin. The spoken dwell, because this watchdog only has
    /// anything to watch when there is a narration.
    private static let pointingTourStallTimeoutSeconds: Double =
        pointingTourArrivalTimeoutSeconds + minimumSpokenPointingTourStopDwellSeconds + 1.0

    /// A tour stop with its screenshot coordinate already converted into a screen location.
    private struct ResolvedPointingTourStop {
        /// The coordinate the model read off the screenshot, kept for the `🎯` log line.
        let screenshotCoordinate: CGPoint
        /// Where the element is in global AppKit screen coordinates.
        let screenLocation: CGPoint
        /// The display frame (global AppKit coords) of the screen the element is on.
        let displayFrame: CGRect
        /// Short label describing the element (e.g. "run button").
        let elementLabel: String?
        /// Offset into the spoken text of the sentence describing this element. A word
        /// reaching it sends the cursor, and it decides which speech segment owns this stop.
        let sentenceStartOffsetInSpokenText: Int
        /// What this stop's arrival bubble should invite the user to do.
        let pointingBubbleInvitation: PointingBubbleInvitation
        /// Where a drag from this stop lets go, in the same global AppKit screen coordinates as
        /// `screenLocation`. Nil for every stop that is not a drag, and nil for a drag whose tag
        /// named no destination — which is what the refusal is read from.
        ///
        /// Beside the point rather than inside `pointingBubbleInvitation`, because the invitation is
        /// what the bubble's words are picked from and knows nothing about coordinates. The two
        /// points are one answer, and they are read by the one call that posts the drag.
        let dragDestinationScreenLocation: CGPoint?
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    /// Something the onboarding demo has already pointed at during this run.
    ///
    /// Each demo is a fresh request with no history, so the model sees a screen it has already
    /// chosen something on with no way of knowing it. Both levers are needed: the next demo is told
    /// what the last one picked, and the rectangle that label resolved to is claimed ground.
    struct OnboardingDemoTarget {
        /// The label the model wrote, verbatim. This is what the next demo is told to avoid.
        let elementLabel: String
        /// The text rectangle the label resolved to, or nil when it matched nothing.
        let matchedTextBox: CGRect?
        /// The display it was found on — a rectangle is in its own screenshot's pixel space.
        let displayFrame: CGRect
    }

    private var onboardingDemoTargetsAlreadyPointedAt: [OnboardingDemoTarget] = []

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Watches the mouse for a run of the user's own actions, and owns the shift+option tap that
    /// starts and ends one.
    let userActionRecorder = UserActionRecorder()


    /// Where the user's DeepSeek API key lives, written by the panel and read by the client.
    let deepSeekAPIKeyStore = DeepSeekAPIKeyStore()

    /// Whether a DeepSeek API key has been saved, so the panel can flip its status text
    /// without reaching into the Keychain itself.
    @Published private(set) var hasDeepSeekAPIKey: Bool = false

    /// Sends chat requests straight to DeepSeek. No proxy sits in front of it, so the key the
    /// user pastes in is the only credential in play and nothing is baked into the binary.
    private lazy var deepSeekAPI: DeepSeekAPI = {
        return DeepSeekAPI(apiKeyStore: deepSeekAPIKeyStore, model: selectedModel)
    }()

    /// Speaks the companion's responses, on-device and with no API key.
    private lazy var ttsClient = AppleTTSClient()

    /// The way in for `kiki command`. Its accept loop, reads and writes all run on a queue of its
    /// own, so nothing here has to be held off the main actor.
    ///
    /// `lazy` because it is handed the four things the app does with what arrives as it is built,
    /// and a closure capturing the manager cannot be written before the manager exists. Read once,
    /// by `startCommandSocketServer`.
    private lazy var commandSocketServer = CompanionCommandSocketServer(
        commandHandler: { [weak self] commandText, speakReply in
            self?.runCommandFromTerminal(commandText, speakReply: speakReply)
        },
        cancelHandler: { [weak self] in
            self?.cancelCommandFromTerminal()
        },
        clickHandler: { [weak self] clickRequest, terminalIdentifier in
            self?.runActionFromTerminal(clickRequest, fromTheTerminalWith: terminalIdentifier)
        },
        readinessProvider: { [weak self] in
            self?.commandReadiness()
                ?? KikiCommandReadiness(
                    canRunCommands: false,
                    problems: ["Kiki 正在关闭。"],
                    understandsScrolling: true,
                    understandsTripleClick: true,
                    understandsDragging: true
                )
        }
    )

    /// Conversation history, so the model remembers prior exchanges within a session.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// What the user said in the turn being answered now. Held rather than passed along
    /// because the history is written from three call stacks that are not the same one.
    private var transcriptOfTheTurnBeingAnswered = ""

    /// Whether the reply being spoken has already gone into `conversationHistory`. Every path
    /// that writes it can run more than once for the same turn.
    private var hasWrittenTheCurrentTurnIntoHistory = false

    /// Which turn the reply currently being streamed belongs to.
    ///
    /// A cancelled read is not a promise of silence: it can resume with one more chunk after the
    /// next turn has begun, and by then such a chunk is legitimately the new turn's.
    private var turnIdentifierOfTheReplyBeingStreamed = UUID()

    /// The action being waited on, while it is waited on: which action it is, so the work which
    /// reads the screen for it can tell after each `await` whether it is still the action Kiki is
    /// going to perform, and who asked, so the one answer it gets goes where it belongs. An action
    /// is not protected from being taken over — a voice turn or a command from another terminal
    /// goes ahead and starts — and this is how the action finds out that it has been.
    ///
    /// One value rather than two optionals, because they are written and cleared together: a stray
    /// write to one of them would answer a terminal that never asked.
    private var actionBeingWaitedOn: ActionBeingWaitedOn?

    /// Which action is outstanding, and who hears the one answer it gets.
    private struct ActionBeingWaitedOn {
        let actionIdentifier: UUID
        let whoHearsTheAnswer: WhoHearsTheAnswer
    }

    /// Where the one answer to an action goes.
    ///
    /// Two sources ask Kiki to do something at a point, and they are told about it in different
    /// currencies: a terminal waits for a sentence, while the replay of the user's own recording
    /// asked in order to move the loop along. Carrying that here rather than as a second field on
    /// the action is what lets both reach the same performance and be answered by it.
    private enum WhoHearsTheAnswer {
        case theTerminalThatAsked(CommandTerminalIdentifier)
        /// Nobody asked in words: the answer's only work is to start the next step.
        case theReplayOfTheUsersRecordedActions
    }

    /// The same action once its point is known and the cursor is on its way there, or nil whenever
    /// there is no such flight. Cleared by `endTheActionBeingWaitedOn` together with the identifier
    /// above, so an action that has been answered is never performed on arrival.
    private var actionInFlight: ActionInFlight?

    /// Whether Kiki is watching the user's hands, doing again what they did, or neither.
    ///
    /// A fact of its own rather than a flag on the recorder, because it decides what every input
    /// path does — the same question `statusItemIconPhase` and `voiceState` answer — and because
    /// the panel and the cursor both draw it.
    @Published private(set) var recordedActionsPhase: RecordedActionsPhase = .neitherRecordingNorReplaying

    /// What the last recording holds. Emptied when the replay is forgotten, so the two are never
    /// out of step in the one direction that matters: a list with no replay running is a recording
    /// nobody asked for.
    private var recordedUserActions: [RecordedUserAction] = []

    /// Where the loop has got to. Advanced before each step is performed rather than after it, so
    /// a step that is interrupted is not the one the loop comes back to.
    private var indexOfTheNextRecordedActionToReplay = 0

    /// The wait between two steps of a replay.
    private var replayStepTask: Task<Void, Never>?

    /// How long the loop waits between two replayed actions.
    ///
    /// The actions themselves are over in milliseconds, so without a wait the cursor would cross
    /// the screen twice before the eye could follow either crossing. It has to stay well under
    /// `pointingTourStopMaximumDwellSeconds`: each arrival schedules the tour's return home, and a
    /// longer wait would have the cursor start flying back to the pointer between two steps.
    private static let secondsBetweenReplayedActions: Double = 0.6

    /// The shortcut that starts, ends and interrupts a replay, and the subscription that listens
    /// for it.
    private var recordedActionsShortcutCancellable: AnyCancellable?

    /// How much of the reply has already gone to the terminal watching it, so a chunk that changed
    /// nothing does not pay for the parse that would work out the same answer.
    private var rawReplyUTF16CountLastSentToTerminal = -1

    /// When the user last started a turn, which decides whether the next one continues this
    /// conversation or starts a new one.
    private var lastUserTurnStartDate: Date?

    /// How many exchanges are carried into the next request.
    private static let maximumExchangeCountCarriedInHistory = 15

    /// How long the user can be away before their next turn counts as a new conversation.
    private static let maximumGapBetweenTurnsInTheSameConversationSeconds: TimeInterval = 10 * 60

    init() {
        // The panel renders the key's saved/empty state before any request is made, so seed
        // it from the Keychain at launch.
        hasDeepSeekAPIKey = deepSeekAPIKeyStore.hasAPIKey

        // The first reports how far into the segment the words have got, which sends the cursor
        // off; the second that it has been spoken through, which releases the next segment.
        ttsClient.onSpokenCharacterRange = { [weak self] spokenCharacterRange in
            self?.handleSpokenCharacterRange(spokenCharacterRange)
        }
        ttsClient.onPlaybackFinished = { [weak self] in
            self?.handlePlaybackFinished()
        }
        // The spinner is held until this arrives, so clearing the wait is what ends the reply's
        // `.processing` state — see `voiceStateTheFactsSupport`. Idempotent, so a report arriving
        // after the reply was written off settles the state onto whatever the facts now say.
        ttsClient.onFirstSoundHeard = { [weak self] in
            self?.isWaitingForTheFirstSoundOfTheReply = false
        }
    }

    /// The running response task, cancelled when the user speaks again.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Observes displays changing so the overlay keeps one window per connected screen.
    private var displayConfigurationChangeObserver: NSObjectProtocol?
    /// Scheduled hide for transient cursor mode, cancelled if the user speaks again.
    private var transientHideTask: Task<Void, Never>?

    /// True when every permission Kiki needs is granted. Every permission has to be in the set: the
    /// panel renders its rows only while this is false, so one left out would become un-grantable
    /// the moment the others were in place.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission
            && hasScreenContentPermission && hasRequiredSpeechRecognitionPermission
    }

    /// Speech Recognition is only required when the resolved transcription backend is Apple's
    /// on-device one — the network providers never touch that TCC service. Read the *resolved*
    /// provider, because the factory falls back to Apple Speech when the preferred one has no key.
    private var hasRequiredSpeechRecognitionPermission: Bool {
        !buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission
            || hasSpeechRecognitionPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    /// The DeepSeek model used for voice responses, persisted under a key of its own so an
    /// install carrying a model saved by an older build falls back to the default.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedDeepSeekModel") ?? DeepSeekAPI.defaultModel

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedDeepSeekModel")
        deepSeekAPI.model = model
    }

    /// Saves the DeepSeek API key the user typed into the settings panel.
    /// - Returns: `true` when the key reached the Keychain.
    @discardableResult
    func saveDeepSeekAPIKey(_ apiKey: String) -> Bool {
        let didSaveAPIKey = deepSeekAPIKeyStore.saveAPIKey(apiKey)
        hasDeepSeekAPIKey = deepSeekAPIKeyStore.hasAPIKey

        // Saving a key is the setup step, so completing it also lets the post-onboarding panel
        // appear on the spot.
        if didSaveAPIKey && hasDeepSeekAPIKey {
            hasCompletedOnboarding = true
            playIntroDemoIfNeeded()
        }

        return didSaveAPIKey
    }

    /// Whether the Kiki cursor should be shown. When off, the overlay is hidden and
    /// push-to-talk is disabled.
    @Published var isKikiCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isKikiCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isKikiCursorEnabled")

    func setKikiCursorEnabled(_ enabled: Bool) {
        isKikiCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isKikiCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether Kiki may press an element the model asked it to operate. A label naming something
    /// the user cannot take back is refused either way, and off means every tag only points.
    @Published var isAutomaticClickingEnabled: Bool = UserDefaults.standard.object(forKey: "isAutomaticClickingEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isAutomaticClickingEnabled")

    func setAutomaticClickingEnabled(_ enabled: Bool) {
        isAutomaticClickingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutomaticClickingEnabled")
    }

    /// The sound that goes out with a click Kiki posts, built once at launch because where it
    /// is needed is inside a stop's one-second dwell.
    private let elementClickSoundPlayer = ElementClickSoundPlayer()

    /// Whether the user has completed onboarding at least once.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the one-time intro demo has already played.
    ///
    /// Separate from `hasCompletedOnboarding` because the two come apart: setup finishes the instant
    /// a key is saved, while the demo needs every permission it uses.
    @Published var hasPlayedIntroDemo: Bool = UserDefaults.standard.bool(forKey: "hasPlayedIntroDemo")

    /// Plays the welcome animation and intro video, once. Called from the key-save path and
    /// the permission refresh both, so the demo is not lost to ordering.
    func playIntroDemoIfNeeded() {
        guard !hasPlayedIntroDemo else { return }

        // The demo is the cursor pointing at things on screen, which needs screen recording,
        // and it ends by asking for Control+Option, which needs Speech Recognition.
        guard hasCompletedOnboarding && allPermissionsGranted else { return }

        hasPlayedIntroDemo = true
        UserDefaults.standard.set(true, forKey: "hasPlayedIntroDemo")

        triggerOnboarding()
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Kiki start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), speech: \(hasSpeechRecognitionPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        startObservingDisplayConfigurationChanges()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindTheRecordingShortcut()
        startCommandSocketServer()
        // Eagerly touch the API so its TLS warmup handshake completes before the demo fires.
        _ = deepSeekAPI

        // If permissions were revoked (e.g. a signing change), the cursor stays hidden and the
        // panel shows its permission rows instead.
        if hasCompletedOnboarding && allPermissionsGranted && isKikiCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    // MARK: - The Command Line Tool

    /// Starts the socket listening. What it does with each thing that arrives was given to it when
    /// it was built, so this is the whole of starting it.
    private func startCommandSocketServer() {
        commandSocketServer.start()
    }

    /// Whether a command sent from the terminal could be run at all, and what is missing when it
    /// could not — answered before the command is sent, so a terminal that cannot be served is
    /// told why instead of watching a turn fail.
    ///
    /// Only the two things this path actually needs. Accessibility is deliberately not one of
    /// them: without it Kiki still sees the screen, answers and points, and only the clicks are
    /// refused — that is a sentence in the reply, not a failure. Neither is the microphone or
    /// Speech Recognition, which this path never touches.
    private func commandReadiness() -> KikiCommandReadiness {
        var problems: [String] = []

        if let refusalReason = whyCommandsCannotRunRightNow {
            problems.append(refusalReason)
        }
        if !deepSeekAPIKeyStore.hasAPIKey {
            problems.append("还没有填 DeepSeek API Key。在菜单栏图标里打开设置填一个。")
        }
        if !hasScreenRecordingPermission {
            problems.append("没有屏幕录制权限。在「系统设置 → 隐私与安全性 → 屏幕录制」里给 Kiki 打开。")
        }

        // What a gesture a build did not have is answered by the build rather than by the moment: a
        // terminal asks so that one sent to an app that predates it is refused with a sentence instead
        // of arriving as some other gesture. Both `true` here and in the shutting-down fallback above,
        // because both describe this build, and neither describes whether a command can run right now.
        return KikiCommandReadiness(
            canRunCommands: problems.isEmpty,
            problems: problems,
            understandsScrolling: true,
            understandsTripleClick: true,
            understandsDragging: true
        )
    }

    /// Why a command cannot be run at this moment, or nil when it can.
    ///
    /// A terminal is turned away down two different paths — the readiness report it is answered with
    /// when it connects, and the failure event sent to one that was already attached when Kiki went
    /// quiet — so the answer is kept in one place rather than written out at both.
    private var whyCommandsCannotRunRightNow: String? {
        switch whatKikiIsDoingRightNow {
        // A command arrives to *be* the next turn, so a reply in flight is not in its way — it is
        // what it replaces, and a replay is one more thing a new question replaces. Only the icon
        // stops it, and so does a recording, which is the user's own hands and not a turn to
        // replace: the command would be running while they are still working out what to record.
        case .waiting, .listeningToTheUser, .processingTheLastTurn, .replyingToTheLastTurn,
             .replayingWhatTheUserDid:
            return nil
        case .restingInTheStatusItemIcon:
            return "Kiki 正在休息，现在不接收命令。"
        case .wakingFromTheStatusItemIcon:
            return "Kiki 正在苏醒，稍等一下再试。"
        case .recordingWhatTheUserIsDoing:
            return "Kiki 正在记录你的操作，先按一下 shift+option 结束记录。"
        }
    }

    /// Runs a command typed on the command line exactly as a spoken one runs: same teardown of the
    /// last turn, same capture, same reply, same pointing — except for the voice, which a terminal
    /// only gets by asking. The dictation callback's twin.
    private func runCommandFromTerminal(_ commandText: String, speakReply: Bool) {
        // A terminal that was already attached when Kiki went quiet never saw the readiness answer
        // that would have turned it away. Unreachable today, because a terminal is only attached for
        // as long as a turn it started is running — but a CLI that held its connection open would
        // land here, and running the command would be exactly what resting must not do.
        if let refusalReason = whyCommandsCannotRunRightNow {
            commandSocketServer.send(.failed(message: refusalReason, isRefusal: true))
            return
        }

        // A command from a terminal takes Kiki over the same way talking to it does, and the click
        // being called off is not deferred behind the turn that takes it — a new question replaces the
        // screen the click was read off, so there is nothing left for that click to be made against.
        // The click's terminal is still connected to be told, whichever terminal this command came
        // from: a command takes the reply away from the terminal watching it, never a click's answer
        // away from the terminal that asked.
        //
        // A replay goes the same way and for the same reason: a typed command is a new question, and
        // the new question replaces whatever Kiki was doing. A recording never reaches here — a
        // command is refused while one is running, above.
        stopRecordingOrReplayingAndForgetIt()
        callOffTheActionBeingWaitedOn(because: "这次操作被打断了：另一个终端发了新命令。")

        lastTranscript = commandText
        print("⌨️ Companion received command: \(commandText)")
        KikiAnalytics.trackUserMessageSent(transcript: commandText)

        // Before the capture rather than after it: what follows is several seconds of screenshot
        // and recognition with nothing to show for it, and a terminal with no way to tell a turn
        // that has started from one that never did is worse than a terminal that is merely quiet.
        commandSocketServer.send(.accepted(message: Self.sentenceForReadingTheScreen))
        sendTranscriptToClaudeWithScreenshot(transcript: commandText, isReadingTheReplyAloud: speakReply)
    }

    /// Stops the turn a terminal is watching, without starting anything in its place.
    ///
    /// The same teardown a key press does, minus everything about the new question that key press
    /// is the start of — there is no new question here, only the user saying they have heard
    /// enough.
    private func cancelCommandFromTerminal() {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        ttsClient.discardPreparedSegments()
        writeTheCurrentTurnIntoHistory(interruption: .theUserStartedANewQuestion)
        abandonSpeakingReply()
        clearDetectedElementLocation()
    }

    // MARK: - Doing What A Terminal Asked

    /// Where the action a terminal asked for is aimed, and what to tell the terminal about it.
    private enum ActionTargetResolution {
        /// `dragDestinationAppKitScreenLocation` is where a drag lets go, and nil for every action
        /// that stays at one point. Carried beside the starting point rather than inside the action
        /// because the action says *what* happens and this says where: a drag is the one gesture whose
        /// where is two places.
        case resolved(
            appKitScreenLocation: CGPoint,
            displayFrame: CGRect,
            dragDestinationAppKitScreenLocation: CGPoint?,
            message: String,
            hint: String?
        )
        case refused(reason: String)
    }

    /// An action a terminal asked for while the cursor is flying to it: what performing it needs once
    /// the cursor lands, since by then the resolution that produced it is long gone.
    ///
    /// The text the terminal named is kept because the refusal rules are asked again on arrival, where
    /// the press is posted — the sound and the red flight both say "I am about to press this", and a
    /// click that will not go out must not say it.
    private struct ActionInFlight {
        /// Which action this flight is for and who is waiting on it: what the arrival asks before
        /// performing it, and where the answer belongs once it has gone out.
        let beingWaitedOn: ActionBeingWaitedOn
        let appKitScreenLocation: CGPoint
        /// The display the point is on, which is the overlay that flies the cursor to it.
        let displayFrame: CGRect
        /// The text the element was named by, or nil when the point is all there was — which is
        /// every action the user typed as a coordinate and every action being replayed.
        let elementText: String?
        /// What is done at the point — which button and how many times, or which way and how far.
        /// Carried by the flight rather than read off the request on arrival, because the action is
        /// not the only thing it decides: the bubble says 「双击这里！」 or 「往下滚！」 and the
        /// terminal is told 「已双击…」 or 「已往下滚 3 屏…」, and all three are one action.
        let action: ElementActionOnArrival
        /// Where a drag lets go, and nil for every action that stays at one point. Read on arrival,
        /// which is where a drag begins: by then the request that named the destination is gone.
        let dragDestinationAppKitScreenLocation: CGPoint?
        /// What to tell the terminal when the action goes out. Written for a replay too, which has
        /// no terminal to read it: it is what the resolution produced, and leaving it out would mean
        /// a branch here and an optional everywhere the answer is assembled.
        let successMessage: String
    }

    /// Why an action asked for from the terminal cannot be made at this moment, or nil when it can.
    ///
    /// Only states that mean Kiki is in the middle of something: the two the menu bar icon owns, and
    /// the three the reply pipeline owns. The cursor still flying home after a reply is deliberately
    /// not one of them — that reply has ended, and a posted event carries its own point, so there is
    /// nothing to wait for the pointer to arrive for.
    private var whyAnActionFromTheTerminalCannotBeMadeRightNow: String? {
        switch whatKikiIsDoingRightNow {
        // Unlike a command, an action takes over nothing: everywhere Kiki is already doing something,
        // it is a conflict rather than a replacement.
        case .waiting:
            return nil
        case .restingInTheStatusItemIcon:
            return "Kiki 正在休息，现在不接受操作。"
        case .wakingFromTheStatusItemIcon:
            return "Kiki 正在苏醒，稍等一下再试。"
        case .listeningToTheUser:
            return "Kiki 正在听你说话，说完再试。"
        case .processingTheLastTurn:
            return "Kiki 正在处理上一条，等它回到「等待中」再试。"
        case .replyingToTheLastTurn:
            return "Kiki 正在回复上一条，等它回到「等待中」再试。"
        case .recordingWhatTheUserIsDoing:
            return "Kiki 正在记录你的操作，现在不接受别的操作。"
        case .replayingWhatTheUserDid:
            return "Kiki 正在重放你的操作，先按一下 shift+option 停下来。"
        }
    }

    /// The action a terminal asked for, read off its request in one place, or nil for a gesture this
    /// build does not recognise.
    ///
    /// One copy, because the flight, the event that goes out and the sentence the terminal is
    /// answered with all describe the same action — a bubble saying 「双击这里！」 over a right click
    /// would be describing a different one.
    ///
    /// A missing gesture is a single click and an unrecognised one is a refusal, and the difference
    /// matters. Missing is what a tool older than this field sends, and those are all `kiki click`,
    /// so reading it as a single click is reading it correctly. Anything else is a newer tool asking
    /// for a gesture this build has never heard of, and the safe reading of "an action I do not
    /// understand" is no action at all — the older fallback quietly turned a request to scroll into
    /// a press of the left button, which on a link is a page load and on a dialog is a lost document.
    private static func actionAskedForByTheTerminal(_ clickRequest: KikiClickRequest) -> ElementActionOnArrival? {
        switch clickRequest.gesture {
        case nil, KikiCommandProtocol.Gesture.singleClick: return .press(.singleClick)
        case KikiCommandProtocol.Gesture.doubleClick: return .press(.doubleClick)
        case KikiCommandProtocol.Gesture.tripleClick: return .press(.tripleClick)
        case KikiCommandProtocol.Gesture.rightClick: return .press(.rightClick)
        case KikiCommandProtocol.Gesture.scrollUp:
            return .scroll(.up, distance: .screenfuls(clickRequest.screenfuls ?? 1))
        case KikiCommandProtocol.Gesture.scrollDown:
            return .scroll(.down, distance: .screenfuls(clickRequest.screenfuls ?? 1))
        case KikiCommandProtocol.Gesture.scrollLeft:
            return .scroll(.left, distance: .screenfuls(clickRequest.screenfuls ?? 1))
        case KikiCommandProtocol.Gesture.scrollRight:
            return .scroll(.right, distance: .screenfuls(clickRequest.screenfuls ?? 1))
        case KikiCommandProtocol.Gesture.drag: return .drag
        default: return nil
        }
    }

    /// Performs where a terminal asked, and does nothing else: no screenshot goes to the model, no
    /// reply is written, nothing is spoken, the cursor stays where it is and the action is not
    /// remembered.
    ///
    /// Never interrupts. A command from a terminal stops the turn before it by design, because what
    /// it brings is a new question; an action brings only a press or a scroll to place, and one
    /// arriving while Kiki is mid-turn is refused instead of queued or squeezed in beside it.
    ///
    /// Every answer goes to `terminalIdentifier` rather than to whichever terminal is watching the
    /// reply — an action asks its own question and hears its own answer, even while a reply streams
    /// to somebody else.
    private func runActionFromTerminal(_ clickRequest: KikiClickRequest, fromTheTerminalWith terminalIdentifier: CommandTerminalIdentifier) {
        // First of the refusals, because nothing below it can be judged about a request whose
        // gesture this build cannot read: whether the switch covers it, whether it would be refused
        // and whether a second one is in flight are all questions about an action, and there is none.
        guard let action = Self.actionAskedForByTheTerminal(clickRequest) else {
            commandSocketServer.send(
                .failed(message: "这个手势 Kiki 不认识，没做。", isRefusal: true),
                toTheTerminalWith: terminalIdentifier
            )
            return
        }

        if let refusalReason = whyAnActionFromTheTerminalCannotBeMadeRightNow {
            commandSocketServer.send(.failed(message: refusalReason, isRefusal: true), toTheTerminalWith: terminalIdentifier)
            return
        }

        guard isAutomaticClickingEnabled else {
            commandSocketServer.send(.failed(message: "「允许 Kiki 用鼠标操作」没打开，Kiki 现在动不了。", isRefusal: true), toTheTerminalWith: terminalIdentifier)
            return
        }

        // Asked before the capture, and only for the half of it that has an opinion: a press naming
        // something destructive, or a missing grant, is answerable now, and the text path is seconds
        // of screenshots and recognition that would otherwise be spent arriving at a conclusion
        // already in hand. A scroll is refused for the grant alone — it can be scrolled back, so the
        // words that stop a press have nothing to stop here. A drag is refused for the grant and for
        // a destination it never named, which is the one refusal in this switch that is about the
        // request rather than about Kiki.
        switch action {
        case .press:
            if let refusal = ElementClicker.refusalOfClick(
                matchingElementLabel: clickRequest.elementText,
                origin: .theUsersOwnCommand
            ) {
                commandSocketServer.send(.failed(message: Self.sentenceForAnActionOutcome(refusal.outcome), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        case .scroll:
            if let refusal = ElementScroller.refusalOfScroll() {
                commandSocketServer.send(.failed(message: Self.sentenceForAnActionOutcome(refusal.outcome), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        case .drag:
            // A drag is refused for the grant and for a missing destination, and the second of those is
            // decided here rather than after the screens are read: a drag that named nowhere to let go
            // is the one request this path can answer without looking at anything.
            if let refusal = ElementDragger.refusalOfDrag(
                toAppKitScreenLocation: Self.dragDestinationAppKitScreenLocation(in: clickRequest)
            ) {
                commandSocketServer.send(.failed(message: Self.sentenceForAnActionOutcome(refusal.outcome), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        }

        // A second action is refused rather than queued, because the tool already serialises them: a
        // `kiki click` returns once its press has been posted, so two of them in a script are one
        // after the other. One that arrives while another is still in flight is a caller that did
        // not wait, and it would be answered against a question the first has not finished asking —
        // the pointer flown to the second point while the first is still on its way to the first.
        //
        // Last of the refusals, after the ones about the request itself, so that a terminal asking
        // for something Kiki will never do hears that rather than a wait it could not shorten by
        // trying again. Deliberately not part of `whyAnActionFromTheTerminalCannotBeMadeRightNow`,
        // which `carryOutTheActionTheTerminalAskedFor` asks again after the capture: by then the
        // action being waited on is this one, and it would refuse itself.
        guard actionBeingWaitedOn == nil else {
            commandSocketServer.send(.failed(message: "Kiki 正在做上一个，等它做完。", isRefusal: true), toTheTerminalWith: terminalIdentifier)
            return
        }

        // Named before the task exists, the way a turn stamps its own identifier before starting:
        // every answer to this action goes through the identifier, so one whose identifier is no
        // longer the one being waited on has already been answered and must answer nothing itself.
        let actionBeingWaitedOn = ActionBeingWaitedOn(
            actionIdentifier: UUID(),
            whoHearsTheAnswer: .theTerminalThatAsked(terminalIdentifier)
        )
        self.actionBeingWaitedOn = actionBeingWaitedOn

        // Sent once every refusal above has been passed, which is what makes it readable as "the
        // screens are about to be read" rather than as "your request was received": a terminal asking
        // by text is facing seconds of capture and recognition, and one asking by coordinate is not —
        // and it is that one that carries no sentence, because it has no wait to be told about.
        commandSocketServer.send(
            .accepted(message: clickRequest.elementText != nil ? Self.sentenceForReadingTheScreen : nil),
            toTheTerminalWith: terminalIdentifier
        )

        Task {
            await carryOutTheActionTheTerminalAskedFor(
                clickRequest,
                action: action,
                actionBeingWaitedOn: actionBeingWaitedOn
            )
        }
    }

    /// Calls off the action being waited on, if there is one, and tells whoever asked.
    ///
    /// Reached by the push-to-talk key, because starting to listen is the instant the answer to "is
    /// Kiki 等待中" stops being yes, by a command from a terminal, because what that brings is a new
    /// question, and by the shortcut, because tapping it ends a replay. The action is not defended
    /// against being taken over and does not delay the turn that takes it: it is simply not made,
    /// rather than landing at a point read off a screen the new turn is about to replace. A terminal
    /// that asked is still attached to be told, because none of those takeovers goes anywhere near it
    /// — a command takes the reply-watching role from the terminal that was watching the reply, and
    /// this terminal never held it.
    private func callOffTheActionBeingWaitedOn(because reason: String) {
        guard let actionBeingWaitedOn else { return }
        endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: reason, isRefusal: true))
    }

    /// Whether this is still the action Kiki is going to perform, and still the one whoever asked is
    /// waiting to hear about.
    ///
    /// Asked after each `await` in the action path — a voice turn or a command can begin while the
    /// screens are being read — and on arrival, where the action may have been answered while the
    /// cursor was on its way.
    private func isStillTheActionBeingWaitedOn(_ actionBeingWaitedOn: ActionBeingWaitedOn) -> Bool {
        self.actionBeingWaitedOn?.actionIdentifier == actionBeingWaitedOn.actionIdentifier
    }

    /// The one answer this action gets, delivered by whoever reaches it first: the press or the
    /// scroll, the flight that never landed, or whatever has taken Kiki over. It cannot be delivered
    /// twice, and afterwards nothing is outstanding — the flight is written off with it, so an
    /// arrival after this performs nothing.
    ///
    /// One delivery, but not one kind of delivery: a terminal is told what happened, while a replay
    /// has nobody to tell and reads this only as the moment its next step may be scheduled.
    private func endTheActionBeingWaitedOn(_ actionBeingWaitedOn: ActionBeingWaitedOn, with event: KikiCommandEvent) {
        guard isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }
        self.actionBeingWaitedOn = nil
        actionInFlight = nil

        switch actionBeingWaitedOn.whoHearsTheAnswer {
        case .theTerminalThatAsked(let terminalIdentifier):
            // Addressed to the terminal that asked, rather than sent to whoever is watching the reply:
            // by now that may be another terminal, or nobody at all.
            commandSocketServer.send(event, toTheTerminalWith: terminalIdentifier)
        case .theReplayOfTheUsersRecordedActions:
            scheduleTheNextStepOfTheReplay()
        }
    }

    /// Resolves the point a terminal named, performs the action there, and reports what happened.
    private func carryOutTheActionTheTerminalAskedFor(
        _ clickRequest: KikiClickRequest,
        action: ElementActionOnArrival,
        actionBeingWaitedOn: ActionBeingWaitedOn
    ) async {
        let resolution = await resolveActionTarget(for: clickRequest, action: action)

        // Reading the screen takes the better part of a second per screen, and a voice turn or a
        // command can begin inside that. Being taken over is answered as being taken over, not as
        // whatever the screen said on its way out: that screen is already the last turn's.
        guard isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }
        if let takeoverReason = whyAnActionFromTheTerminalCannotBeMadeRightNow {
            endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: takeoverReason, isRefusal: true))
            return
        }

        await carryOutTheResolvedAction(
            resolution,
            elementText: clickRequest.elementText,
            action: action,
            actionBeingWaitedOn: actionBeingWaitedOn
        )
    }

    /// Everything from a resolved point onwards — which is where the two things that ask Kiki to act
    /// at a point meet: a terminal, and the replay of what the user recorded.
    ///
    /// They meet here rather than at the flight because the two answers that belong to the *request*
    /// rather than to its source are settled above the flight: whether a drag's destination is on the
    /// display its start resolved to, and the message the terminal is answered with. A second copy of
    /// either would be a second way for an action to reach the machine, and the two would not agree
    /// about what a drag between two displays is.
    ///
    /// What is *not* here is the question of whether this action may start — a takeover, a rule about
    /// the words the element is named by. Each source asks that in its own terms before calling this,
    /// because the answers differ: a terminal is refused while Kiki is replaying, and a replay is
    /// refused while it is not the replay any more.
    private func carryOutTheResolvedAction(
        _ resolution: ActionTargetResolution,
        elementText: String?,
        action: ElementActionOnArrival,
        actionBeingWaitedOn: ActionBeingWaitedOn
    ) async {
        guard case .resolved(let appKitScreenLocation, let displayFrame, let dragDestinationAppKitScreenLocation, let message, let hint) = resolution else {
            guard case .refused(let reason) = resolution else { return }
            endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: reason, isRefusal: true))
            return
        }

        // The one place the two ends of a drag are held against each other, because it is the one place
        // both are in hand: the start is whatever the terminal named, and the destination is a point it
        // gave outright. A movement between two displays would be posted as a press on one and a
        // release over the other, which is not a drag to any app that receives it. Held against the
        // frame the start resolved to rather than against `NSScreen` a second time, because that frame
        // is where the cursor is going.
        if let dragDestinationAppKitScreenLocation, !displayFrame.contains(dragDestinationAppKitScreenLocation) {
            endTheActionBeingWaitedOn(
                actionBeingWaitedOn,
                with: .failed(message: Self.sentenceForADragBetweenTwoScreens, isRefusal: true)
            )
            return
        }

        let actionInFlight = ActionInFlight(
            beingWaitedOn: actionBeingWaitedOn,
            appKitScreenLocation: appKitScreenLocation,
            displayFrame: displayFrame,
            elementText: elementText,
            action: action,
            dragDestinationAppKitScreenLocation: dragDestinationAppKitScreenLocation,
            successMessage: [message, hint].compactMap { $0 }.joined(separator: "\n")
        )

        // Flown when there is a cursor to fly: what was asked for is the action Kiki makes on its own
        // — the cursor going to the point and turning red on the way — and the arrival is what performs
        // it. With the cursor switched off there is no overlay to make that flight, and the action is
        // performed where it stands: neither a press nor a scroll needs a cursor on screen to be made.
        //
        // Whether that flight also carries the user's pointer is the action's own answer, and it is
        // the overlay that asks it.
        guard isOverlayVisible else {
            await performTheActionInFlight(actionInFlight, isClosingTheArrivalFlightAfterwards: false)
            return
        }

        self.actionInFlight = actionInFlight
        flyTheCursorToTheActionBeingWaitedOn(actionInFlight)
    }

    /// Sends the cursor to the point an action is aimed at, so what happens there lands at the end of
    /// the flight the user already reads as "Kiki is about to do this".
    ///
    /// Flown as a pointing tour that has no stops left, which is the state a reply's tour ends in: the
    /// overlay hands the arrival back to Kiki instead of holding three seconds and flying home, and the
    /// cursor stays parked on the element until the tour's own return-home timeout takes it back. An
    /// action asked for while an earlier one's cursor is still parked there therefore takes over
    /// mid-run, with the mouse never leaving the cursor's hand in between.
    private func flyTheCursorToTheActionBeingWaitedOn(_ actionInFlight: ActionInFlight) {
        // An action aimed at the point the cursor is standing on — a script pressing the same button
        // twice, or a recording of two clicks in the same place — has nowhere to fly. The overlay flies
        // when the published location *changes*, and the cursor is still on that spot, still red, still
        // holding the mouse from the press before, so the second action is simply performed. The other
        // half of this is what makes the test safe: a point the cursor is not standing on differs from
        // the published one — a cursor that has gone home has cleared it — so that action is always
        // flown to.
        if !isFlyingToPointingTourStop, pointingTarget?.screenLocation == actionInFlight.appKitScreenLocation {
            // There is no flight to close, so this call is not the one that closes one.
            Task { await performTheActionInFlight(actionInFlight, isClosingTheArrivalFlightAfterwards: false) }
            return
        }

        resolvedPointingTourStops = []
        nextPointingTourStopIndex = 0
        shouldReturnBuddyToCursorAfterPointing = false
        isPointingTourActive = true

        beginFlightOfTheCursor(
            to: actionInFlight.appKitScreenLocation,
            on: actionInFlight.displayFrame,
            with: PointingBubbleInvitation.describing(actionInFlight.action),
            performing: actionInFlight.action
        )

        print("🖱 Action: flying to (\(Int(actionInFlight.appKitScreenLocation.x)), \(Int(actionInFlight.appKitScreenLocation.y)))")
        schedulePointingTourArrivalTimeout()
    }

    /// Performs the action where it was aimed and delivers the one answer — the one performance both
    /// ways of reaching the point go through: a cursor sent to it, and one that was never sent because
    /// there is no overlay to fly.
    ///
    /// `isClosingTheArrivalFlightAfterwards` is true only when a drag began at the arrival, which is
    /// the one action that is still running when the cursor lands: the arrival deliberately leaves the
    /// tour open for it, and this is where it is closed — after the button is up.
    private func performTheActionInFlight(
        _ actionInFlight: ActionInFlight,
        isClosingTheArrivalFlightAfterwards: Bool
    ) async {
        // The flight carries its own action rather than reading the one being waited on, so a flight
        // the cursor has already been sent on does nothing once that action has been answered — by a
        // voice turn, by a command, or by the arrival timeout.
        let actionBeingWaitedOn = actionInFlight.beingWaitedOn

        // However this returns, the flight a drag opened is closed: nothing else is going to close it,
        // because the arrival that would have is the call this one is. The guard inside asks the tour's
        // own state, so a flight a new turn has already torn down is not closed a second time.
        defer {
            if isClosingTheArrivalFlightAfterwards, isFlyingToPointingTourStop {
                finishCurrentPointingTourFlight()
            }
        }

        guard isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }

        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0

        switch actionInFlight.action {
        case .press(let clickKind):
            // Asked again here, as the pointing tour does: this is the last moment before the press,
            // and the sound says "I am about to press this", which a click that will not go out must
            // not say.
            if ElementClicker.refusalOfClick(
                matchingElementLabel: actionInFlight.elementText,
                origin: .theUsersOwnCommand
            ) == nil {
                elementClickSoundPlayer.playClickSound()
            }

            let clickOutcome = await ElementClicker.clickElement(
                atAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                matchingElementLabel: actionInFlight.elementText,
                kind: clickKind,
                origin: .theUsersOwnCommand
            )
            print("🖱 Action: \(clickOutcome)")

            switch clickOutcome {
            case .clicked:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .clicked(message: actionInFlight.successMessage))
            case .failedToPostTheClick:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(clickOutcome), isRefusal: false))
            default:
                // Only reachable if the grant went away between the question above and the press.
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(clickOutcome), isRefusal: true))
            }

        case .scroll(let direction, let distance):
            // No sound here, deliberately: the click's is feedback for a press, and a scroll presses
            // nothing — the content moving is its own feedback.
            let scrollOutcome = await ElementScroller.scrollElement(
                atAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                direction: direction,
                distance: distance,
                displayFrame: actionInFlight.displayFrame
            )
            print("🖱 Action: \(direction) \(distance): \(scrollOutcome)")

            switch scrollOutcome {
            case .scrolled:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .clicked(message: actionInFlight.successMessage))
            case .failedToPostTheScroll:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(scrollOutcome), isRefusal: false))
            case .refusedBecauseAccessibilityIsNotEnabled:
                // Only reachable if the grant went away between the question above and the scroll.
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(scrollOutcome), isRefusal: true))
            }

        case .drag:
            // No sound, for the scroll's reason: the click's is feedback for a press, and a drag is not
            // a press — what moves is its own feedback.
            let dragOutcome = await dragForTheUser(
                fromAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                toAppKitScreenLocation: actionInFlight.dragDestinationAppKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
            print("🖱 Action: \(dragOutcome)")

            switch dragOutcome {
            case .dragged:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .clicked(message: actionInFlight.successMessage))
            case .failedToPostTheDrag:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(dragOutcome), isRefusal: false))
            case .refusedBecauseNoDestinationWasNamed, .refusedBecauseAccessibilityIsNotEnabled:
                // Only reachable if the destination went away between the questions above and the drag,
                // or the grant did.
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(dragOutcome), isRefusal: true))
            }
        }
    }

    /// What the terminal is told while the screens are being read.
    ///
    /// The only slow stretch of either path, and the only thing either one announces before it is
    /// done. Written here rather than in the tool because it is a sentence of Kiki's, and every one
    /// of those is written in this file; the tool prints what it is sent.
    private static let sentenceForReadingTheScreen = "Kiki 正在看屏幕…"

    /// What to tell the terminal about a click, in the terms it thinks in: a refusal is Kiki saying
    /// it will not do this, a failure is one that was meant to go out and did not.
    private static func sentenceForAnActionOutcome(_ clickOutcome: ElementClickOutcome) -> String {
        switch clickOutcome {
        case .clicked:
            return "已点击。"
        case .failedToPostTheClick:
            return "点击没能发出去。"
        case .refusedBecauseTheTagCarriedNoLabel:
            return "这次点击没说要点哪个元素。"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "没有辅助功能权限，Kiki 动不了鼠标。在「系统设置 → 隐私与安全性 → 辅助功能」里给 Kiki 打开。"
        case .refusedBecauseTheLabelLooksDestructive(let matchedWord):
            return "「\(matchedWord)」这种字眼的东西 Kiki 不点，你自己来吧。"
        }
    }

    /// The same for a scroll. The two are separate because the two outcomes are: a click that was
    /// refused named something it will not touch, and a scroll is refused for the grant alone.
    private static func sentenceForAnActionOutcome(_ scrollOutcome: ElementScrollOutcome) -> String {
        switch scrollOutcome {
        case .scrolled:
            return "已滚动。"
        case .failedToPostTheScroll:
            return "滚动没能发出去。"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "没有辅助功能权限，Kiki 动不了鼠标。在「系统设置 → 隐私与安全性 → 辅助功能」里给 Kiki 打开。"
        }
    }

    /// The same for a drag, whose one refusal of its own is a destination it never named.
    private static func sentenceForAnActionOutcome(_ dragOutcome: ElementDragOutcome) -> String {
        switch dragOutcome {
        case .dragged:
            return "已拖动。"
        case .failedToPostTheDrag:
            return "拖拽没能发出去。"
        case .refusedBecauseNoDestinationWasNamed:
            return sentenceForADragThatNamedNoDestination
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "没有辅助功能权限，Kiki 动不了鼠标。在「系统设置 → 隐私与安全性 → 辅助功能」里给 Kiki 打开。"
        }
    }

    /// A drag that named no destination, said once: the terminal path reaches this by asking
    /// `ElementDragger` about the request and the resolution path reaches it on its way to converting
    /// the point, and the two must not explain the same refusal in two different ways.
    private static let sentenceForADragThatNamedNoDestination = "这次拖拽没说要拖到哪儿（要给 --to-x 和 --to-y）。"

    /// A drag asked for between two displays.
    ///
    /// Refused rather than carried out across the gap: the movement is posted as events that each carry
    /// their own point, so one starting on a display and releasing over another is a press and a release
    /// in two places no app receives as a drag — and the thing being moved is left pressed.
    private static let sentenceForADragBetweenTwoScreens = "拖拽的起点和终点不在同一块屏幕上，这次没做。"

    /// Where a drag lets go, as the terminal gave it: a point in the global screen space, or nil for
    /// the two cases that have no destination — a request that named none, and one for an action that
    /// is not a drag.
    ///
    /// Both fields or neither. A request carrying one of the two is a destination that cannot be
    /// made into a point, and half a drag is a press held down on what it was moving.
    private static func dragDestinationGlobalScreenPoint(in clickRequest: KikiClickRequest) -> CGPoint? {
        guard let dragToGlobalScreenX = clickRequest.dragToGlobalScreenX,
              let dragToGlobalScreenY = clickRequest.dragToGlobalScreenY else {
            return nil
        }
        return CGPoint(x: dragToGlobalScreenX, y: dragToGlobalScreenY)
    }

    /// The same destination in the AppKit location a posted event is aimed with, or nil when the
    /// request named none.
    ///
    /// Asked before anything is read off a screen, which is why it reads the request rather than the
    /// resolution: a drag that named nowhere to let go is refused without one.
    private static func dragDestinationAppKitScreenLocation(in clickRequest: KikiClickRequest) -> CGPoint? {
        guard let dragDestinationGlobalScreenPoint = dragDestinationGlobalScreenPoint(in: clickRequest) else {
            return nil
        }
        return ElementClicker.appKitScreenLocation(
            fromAccessibilityScreenPoint: dragDestinationGlobalScreenPoint,
            primaryScreenHeightInPoints: NSScreen.screens.first?.frame.maxY ?? 0
        )
    }

    /// The point the terminal asked for, from whichever of the two ways it said it.
    private func resolveActionTarget(
        for clickRequest: KikiClickRequest,
        action: ElementActionOnArrival
    ) async -> ActionTargetResolution {
        // Read here rather than inside the two ways of naming a start, because a drag is the one
        // action that cannot be made without it, and a request naming its start by text would
        // otherwise spend seconds of screenshots arriving at a conclusion already in hand.
        let dragDestinationGlobalScreenPoint = Self.dragDestinationGlobalScreenPoint(in: clickRequest)
        if action == .drag, dragDestinationGlobalScreenPoint == nil {
            return .refused(reason: Self.sentenceForADragThatNamedNoDestination)
        }

        if let globalScreenX = clickRequest.globalScreenX, let globalScreenY = clickRequest.globalScreenY {
            return resolveActionTarget(
                atGlobalScreenPoint: CGPoint(x: globalScreenX, y: globalScreenY),
                action: action,
                dragDestinationGlobalScreenPoint: dragDestinationGlobalScreenPoint
            )
        }

        let elementText = clickRequest.elementText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !elementText.isEmpty else {
            return .refused(reason: "这次请求既没给坐标也没给文字，不知道要在哪儿动手。")
        }

        return await resolveActionTarget(
            namingText: elementText,
            occurrenceNumber: clickRequest.occurrenceNumber ?? 1,
            screenNumber: clickRequest.screenNumber,
            action: action,
            dragDestinationGlobalScreenPoint: dragDestinationGlobalScreenPoint
        )
    }

    /// The opening of the sentence the terminal is answered with — 「已点击」, 「已双击」, 「已三击」,
    /// 「已右键点击」, 「已往下滚 3 屏：」 or 「已拖动」 — the one part of it that depends on the action.
    ///
    /// Named rather than left for the terminal to infer from which subcommand it sent, because the
    /// tool and the app can disagree about a gesture and the sentence has to describe the action that
    /// was actually made.
    ///
    /// The scroll form ends in a colon and the press forms do not, so that the object of the sentence
    /// reads the same either way: 「已往下滚 3 屏：屏幕坐标 (720, 450)。」 parses and 「已往下滚 3 屏
    /// 屏幕坐标 (720, 450)。」 does not.
    private static func completionPhraseForTheAction(_ action: ElementActionOnArrival) -> String {
        switch action {
        case .press(.singleClick): return "已点击"
        case .press(.doubleClick): return "已双击"
        case .press(.tripleClick): return "已三击"
        case .press(.rightClick): return "已右键点击"
        case .scroll(let direction, let distance): return "已\(Self.phraseForScrolling(direction, distance: distance))："
        case .drag: return "已拖动"
        }
    }

    /// How a scroll is described in words — 「往下滚 3 屏」, 「往下滚 240 点」 — said the same way in
    /// the sentence the terminal is answered with and in the bubble over the cursor.
    ///
    /// A distance says itself in its own unit rather than being converted into the other, because the
    /// two are not interchangeable to the person reading: a screenful is what a terminal asked for and
    /// a count of points is what they scrolled by hand, and rounding the second into the first would
    /// describe a scroll nobody made.
    private static func phraseForScrolling(_ direction: ElementScrollDirection, distance: ElementScrollDistance) -> String {
        let directionWord: String
        switch direction {
        case .up: directionWord = "上"
        case .down: directionWord = "下"
        case .left: directionWord = "左"
        case .right: directionWord = "右"
        }
        switch distance {
        case .screenfuls(let screenfuls): return "往\(directionWord)滚 \(screenfuls) 屏"
        case .points(let points): return "往\(directionWord)滚 \(Int(points.rounded())) 点"
        }
    }

    /// A point the terminal gave in the global screen space, turned into the AppKit location every
    /// other part of the app works in.
    ///
    /// A point on no display is refused rather than acted on: the event would land where the user
    /// cannot see it, and reporting that as done is a claim the terminal has no way to check.
    private func resolveActionTarget(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        action: ElementActionOnArrival,
        dragDestinationGlobalScreenPoint: CGPoint?
    ) -> ActionTargetResolution {
        let appKitScreenLocation = ElementClicker.appKitScreenLocation(
            fromAccessibilityScreenPoint: globalScreenPoint,
            primaryScreenHeightInPoints: NSScreen.screens.first?.frame.maxY ?? 0
        )

        guard let display = NSScreen.screens.first(where: { $0.frame.contains(appKitScreenLocation) }) else {
            return .refused(reason: "屏幕坐标 (\(Int(globalScreenPoint.x)), \(Int(globalScreenPoint.y))) 不在任何一块屏幕里。")
        }

        let completionPhrase = Self.completionPhraseForTheAction(action)
        let startPoint = "屏幕坐标 (\(Int(globalScreenPoint.x)), \(Int(globalScreenPoint.y)))"

        // A drag is the one action whose sentence describes a movement rather than a place, so it says
        // where it started from as well as where it ended — with the colon that separates the verb from
        // the two points, which the forms that name a single place read better without.
        let message: String
        if let dragDestinationGlobalScreenPoint {
            message = "\(completionPhrase)：从\(startPoint) 到屏幕坐标 (\(Int(dragDestinationGlobalScreenPoint.x)), \(Int(dragDestinationGlobalScreenPoint.y)))。"
        } else {
            message = "\(completionPhrase)\(startPoint)。"
        }

        return .resolved(
            appKitScreenLocation: appKitScreenLocation,
            displayFrame: display.frame,
            dragDestinationAppKitScreenLocation: dragDestinationGlobalScreenPoint.map {
                ElementClicker.appKitScreenLocation(
                    fromAccessibilityScreenPoint: $0,
                    primaryScreenHeightInPoints: NSScreen.screens.first?.frame.maxY ?? 0
                )
            },
            message: message,
            hint: nil
        )
    }

    /// The point where the text the terminal named was found on screen.
    ///
    /// Screens are counted the way the model's own screenshots are numbered — the pointer's screen
    /// first, the rest behind it — so `-n` and `-s` and the `:screenN` a tag can carry all mean the
    /// same thing. Reading order within a screen is top to bottom, left to right, and the ordinal
    /// runs across the screens in that order.
    private func resolveActionTarget(
        namingText elementText: String,
        occurrenceNumber: Int,
        screenNumber: Int?,
        action: ElementActionOnArrival,
        dragDestinationGlobalScreenPoint: CGPoint?
    ) async -> ActionTargetResolution {
        let screenCaptures: [CompanionScreenCapture]
        do {
            screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            return .refused(reason: "看不到屏幕：\(error.localizedDescription)")
        }

        guard !screenCaptures.isEmpty else {
            return .refused(reason: "看不到屏幕。")
        }

        if let screenNumber, !(1...screenCaptures.count).contains(screenNumber) {
            return .refused(reason: "只有 \(screenCaptures.count) 块屏幕，没有第 \(screenNumber) 块。")
        }

        // One recognition per screen, started together: it is the whole cost of this path, and no
        // screen's reading depends on another's.
        let recognizedTextLinesTasks = screenCaptures.map { screenCapture in
            Task { await ScreenshotTextRecognizer.recognizedLines(in: screenCapture.imageData) }
        }

        var matches: [(screenIndex: Int, box: CGRect)] = []
        for screenIndex in screenCaptures.indices {
            guard screenNumber == nil || screenNumber == screenIndex + 1 else { continue }
            let recognizedTextLines = await recognizedTextLinesTasks[screenIndex].value
            let matchingBoxes = ScreenshotTextElementMatcher.elementBoxesInReadingOrder(
                matchingElementLabel: elementText,
                amongRecognizedLines: recognizedTextLines
            )
            matches.append(contentsOf: matchingBoxes.map { (screenIndex: screenIndex, box: $0) })
        }

        guard !matches.isEmpty else {
            let onThatScreen = screenNumber.map { "第 \($0) 块屏幕上" } ?? "屏幕上"
            return .refused(reason: "\(onThatScreen)没有「\(elementText)」。")
        }

        guard occurrenceNumber >= 1, occurrenceNumber <= matches.count else {
            return .refused(reason: "「\(elementText)」只有 \(matches.count) 个，没有第 \(occurrenceNumber) 个。")
        }

        let match = matches[occurrenceNumber - 1]
        let screenCapture = screenCaptures[match.screenIndex]
        let resolvedLocation = CompanionManager.screenLocation(
            forScreenshotCoordinate: CGPoint(x: match.box.midX, y: match.box.midY),
            on: screenCapture
        )

        let completionPhrase = Self.completionPhraseForTheAction(action)

        // Said after the element and in the order the drag moves: the thing named first, then the point
        // it is taken to. Nothing at all for an action that stays where it is.
        let dragDestinationClause = dragDestinationGlobalScreenPoint.map {
            "到屏幕坐标 (\(Int($0.x)), \(Int($0.y)))"
        } ?? ""

        let message = screenCaptures.count > 1
            ? "\(completionPhrase)「\(elementText)」（第 \(occurrenceNumber) 个，第 \(match.screenIndex + 1)/\(screenCaptures.count) 块屏幕）\(dragDestinationClause)。"
            : "\(completionPhrase)「\(elementText)」（第 \(occurrenceNumber) 个）\(dragDestinationClause)。"

        // Said only when the whole screen set was searched: with `-s` the terminal has already named
        // the screen it meant, and a count of the others is not a correction to anything.
        var hint: String?
        if screenNumber == nil, screenCaptures.count > 1 {
            let otherScreensWithAMatch = Set(matches.map(\.screenIndex)).subtracting([match.screenIndex])
            if !otherScreensWithAMatch.isEmpty {
                hint = "另外 \(otherScreensWithAMatch.count) 块屏幕上也有「\(elementText)」，只想要那一块的话加 -s。"
            }
        }

        return .resolved(
            appKitScreenLocation: resolvedLocation.screenLocation,
            displayFrame: resolvedLocation.displayFrame,
            dragDestinationAppKitScreenLocation: dragDestinationGlobalScreenPoint.map {
                ElementClicker.appKitScreenLocation(
                    fromAccessibilityScreenPoint: $0,
                    primaryScreenHeightInPoints: NSScreen.screens.first?.frame.maxY ?? 0
                )
            },
            message: message,
            hint: hint
        )
    }

    // MARK: - Resting In The Menu Bar Icon

    /// Starts the cursor's one-way flight into the menu bar icon it was left resting on.
    ///
    /// Called the instant the wait runs out, which is also the instant Kiki goes quiet — the flight
    /// cannot be called off, so a cursor already on its way to the icon must not be handed a job it
    /// would have to abandon halfway.
    func beginStatusItemIconMerge(iconScreenFrame: CGRect) {
        guard statusItemIconPhase == .notInTheIcon else { return }
        statusItemIconPhase = .cursorFlyingToIcon(iconScreenFrame: iconScreenFrame)
    }

    /// The cursor has arrived at the icon and disappeared into it.
    func cursorDidLandOnStatusItemIcon() {
        guard case .cursorFlyingToIcon = statusItemIconPhase else { return }
        statusItemIconPhase = .cursorRestingInIcon
    }

    /// Starts the cursor's flight back out of the icon, to the standing position beside the pointer.
    ///
    /// Kiki is still not taking input while this runs — the cursor is in the air, and there is
    /// nothing at the pointer to hand a job to until it lands.
    func beginWakingFromTheStatusItemIcon() {
        guard statusItemIconPhase == .cursorRestingInIcon else { return }
        statusItemIconPhase = .cursorWakingFromIcon
    }

    /// The cursor is back beside the pointer and following it again. Kiki takes input from here.
    func cursorDidFinishWakingFromTheStatusItemIcon() {
        guard statusItemIconPhase == .cursorWakingFromIcon else { return }
        statusItemIconPhase = .notInTheIcon
    }

    /// Ends the visit, for the two cases where it must not outlive the cursor it swallowed: the
    /// overlay going away, and a display change rebuilding every view that hosted it.
    ///
    /// Both leave a view that is following the pointer again, and an icon still wearing the cursor's
    /// colour beside it would be a lie about where the cursor is. Nothing else may call this: a
    /// visit that could be ended from outside would be a cursor that vanished mid-flight.
    func endTheStatusItemIconVisit() {
        guard isNotTakingInputBecauseOfTheStatusItemIcon else { return }
        statusItemIconPhase = .notInTheIcon
    }

    /// Restarts the overlay so the welcome animation and intro video play. Only reached
    /// through `playIntroDemoIfNeeded()`.
    func triggerOnboarding() {

        NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)

        KikiAnalytics.trackOnboardingStarted()

        startOnboardingMusic()

        // The first appearance is what triggers the welcome animation and onboarding video.
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding from the footer link, with the overlay already visible.
    func replayOnboarding() {
        // The intro is a demonstration of the cursor, and a Kiki whose cursor is in the menu bar icon
        // has none to demonstrate with — it would play as a video whose subject never appears.
        guard !isNotTakingInputBecauseOfTheStatusItemIcon else { return }

        NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)
        KikiAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()

        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Kiki: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Kiki: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    /// Rebuilds the cursor overlay whenever the set of connected displays changes.
    ///
    /// The overlay is built from `NSScreen.screens` at the moment it is shown, so a monitor plugged
    /// in afterwards has no window of its own — and the damaging part is the missing view for a
    /// pointing target: `pointingTarget` would stay set forever, and while it is set
    /// the buddy hides itself on every screen.
    private func startObservingDisplayConfigurationChanges() {
        displayConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayConfigurationChange()
        }
    }

    /// Rebuilds the overlay for the new display configuration. macOS posts this after
    /// `NSScreen.screens` has been updated and posts it more than once for a single plug-in; the
    /// rebuild is idempotent, so every pass is safe.
    private func handleDisplayConfigurationChange() {
        // Before the guard: the rebuild constructs every cursor view afresh, and a fresh view
        // follows the pointer and has no way to learn about a visit that is already under way. Left
        // alone, the icon would keep the cursor's colour while the cursor itself was back out
        // following the mouse.
        endTheStatusItemIconVisit()

        guard isOverlayVisible else { return }

        overlayWindowManager.refreshOverlaysForDisplayConfigurationChange(
            onScreens: NSScreen.screens,
            companionManager: self
        )

        // A display unplugged mid-flight takes the pending target with it, and no view will
        // ever consume that location — so clear it rather than leave the buddy hidden forever.
        if let pendingTargetDisplayFrame = pointingTarget?.displayFrame,
           !NSScreen.screens.contains(where: { $0.frame == pendingTargetDisplayFrame }) {
            clearDetectedElementLocation()
        }
    }

    func clearDetectedElementLocation() {
        // Cleared before the tour, so the overlay sees a target withdrawn rather than one that
        // changed its mind about being pressed while the cursor is standing on it. Nothing here
        // goes through `endPointingTour`'s withdrawal — the whole target is gone.
        pointingTarget = nil
        endPointingTour()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        userActionRecorder.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        replayStepTask?.cancel()
        replayStepTask = nil
        shortcutTransitionCancellable?.cancel()
        recordedActionsShortcutCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        if let observer = displayConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            displayConfigurationChangeObserver = nil
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadSpeechRecognition = hasSpeechRecognitionPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
            userActionRecorder.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            userActionRecorder.stop()
            // Neither half of recording survives the permission going away: the shortcut needs the
            // tap that hears it and a replay needs the permission to press anything. Ended here
            // rather than left standing, because the state would otherwise be one only a restart
            // could clear — the tap that ends it is the tap that has just been torn down.
            stopRecordingOrReplayingAndForgetIt()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        hasSpeechRecognitionPermission = SFSpeechRecognizer.authorizationStatus() == .authorized


        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadSpeechRecognition != hasSpeechRecognitionPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), speech: \(hasSpeechRecognitionPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            KikiAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            KikiAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            KikiAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadSpeechRecognition && hasSpeechRecognitionPermission {
            KikiAnalytics.trackPermissionGranted(permission: "speech_recognition")
        }
        // Screen content permission is persisted — once the SCShareableContent picker has been
        // approved there is nothing to re-check.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            KikiAnalytics.trackAllPermissionsGranted()

            // Covers the user who pasted their key first and granted permissions second.
            playIntroDemoIfNeeded()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy screenshot
    /// capture, and persists the grant so the user is never asked again.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // A 0x0 or empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    KikiAnalytics.trackPermissionGranted(permission: "screen_content")


                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isKikiCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    /// Asks for Speech Recognition from the settings panel, so the dialog does not interrupt the
    /// user's first push-to-talk press. macOS shows it exactly once, so a second press opens System
    /// Settings — the only way back once it has been answered either way.
    func requestSpeechRecognitionPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] authorizationStatus in
            // The callback arrives on an arbitrary queue, so hop back before touching
            // published state.
            Task { @MainActor [weak self] in
                self?.hasSpeechRecognitionPermission = authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions so the UI updates live after the user grants them. Screen
    /// Recording is the exception — macOS requires an app restart for that one.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }

                self.settleVoiceState()

                // Nothing to do while the microphone side is still in one of its phases; the state
                // this observer exists for is the one it settles on the way out of them. Pressing
                // and releasing the hotkey without saying anything runs no response task, so the
                // transient hide is scheduled here or the overlay never goes away.
                guard self.dictationPhase == .nothing else { return }
                self.scheduleTransientHideIfNeeded()
            }
    }

    /// Settles `voiceState` onto the facts it depicts. The only place it is written, apart from the
    /// credits fallback, which has no facts to derive from.
    ///
    /// It has two sources — the microphone, and the reply being produced and spoken — and while each
    /// group wrote it directly, what kept the two from overwriting one another was a guard at every
    /// call site that had to know what the other side was doing. Derived, there is nothing left to
    /// arbitrate, and a state no fact supports is not reachable, so Kiki cannot be left showing one.
    private func settleVoiceState() {
        // The three facts settle several times per segment and most of those writes change nothing,
        // and an unchanged `@Published` write still invalidates every view reading it.
        let stateTheFactsSupport = voiceStateTheFactsSupport
        guard stateTheFactsSupport != voiceState else { return }
        voiceState = stateTheFactsSupport
    }

    /// What the facts say Kiki is doing, in the panel's own vocabulary.
    ///
    /// The microphone owns the state while it is doing anything at all: the user pressing the key is
    /// the newest thing that has happened, whatever else was running. The reply owns it from the
    /// transcript being taken to its voice being done, and `isProducingAReply` is what covers the
    /// gap in the middle — the transcript lands seconds before the model writes a word, and
    /// `isSpeakingReply` only becomes true when a segment is handed over.
    private var voiceStateTheFactsSupport: CompanionVoiceState {
        switch dictationPhase {
        case .finalizing, .preparing: return .processing
        case .recording: return .listening
        case .nothing: break
        }

        guard isProducingAReply else { return .idle }
        // Held until the reply is actually heard, because a segment may have been handed over and
        // still be waiting on its own synthesis. A turn that is not read aloud never hears anything,
        // so it leaves this state when a segment is reached instead.
        if isWaitingForTheFirstSoundOfTheReply { return .processing }
        return isSpeakingReply ? .responding : .processing
    }

    /// What the microphone side of Kiki is doing, if anything.
    private enum DictationPhase {
        case nothing
        case preparing
        case recording
        case finalizing
    }

    /// The ordering is the priority, not the sequence: finalising outranks a recording that has not
    /// been cleaned up yet, so a transcript being wrapped up still reads as 处理中.
    private var dictationPhase: DictationPhase {
        if buddyDictationManager.isFinalizingTranscript { return .finalizing }
        if buddyDictationManager.isRecordingFromKeyboardShortcut { return .recording }
        if buddyDictationManager.isPreparingToRecord { return .preparing }
        return .nothing
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Everything the last thing started, stopped: the reply being produced, the voice speaking it,
    /// the recording or replay the user's own hands were in the middle of, and the action some
    /// terminal is waiting on.
    ///
    /// One function because there are two things that begin by replacing what is running — a question,
    /// spoken or typed, and a recording — and a second copy would be a second answer to what "starting
    /// over" means. The pointing tour needs nothing of its own here: `clearDetectedElementLocation()`
    /// reaches `endPointingTour` on its own, and a replay is not a tour.
    ///
    /// `interruptedBy` is the sentence a terminal that asked for the action being called off is told,
    /// which is the only part of this the two callers say differently.
    private func stopEverythingTheLastThingStarted(interruptedBy reason: String) {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        ttsClient.discardPreparedSegments()
        writeTheCurrentTurnIntoHistory(interruption: .theUserStartedANewQuestion)
        abandonSpeakingReply()
        clearDetectedElementLocation()
        // Before the action below, so that a step of a replay dies with the replay rather than being
        // carried out to a screen that is no longer what the user is working on.
        stopRecordingOrReplayingAndForgetIt()
        // The same answer a new command from a terminal gets: Kiki has stopped being 等待中, and a
        // press placed now would land on a screen this turn is about to replace.
        callOffTheActionBeingWaitedOn(because: reason)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }
            // A Kiki whose cursor is in the menu bar icon hears nothing at all — resting, or on its
            // way back out. Only `.pressed` is refused: `.released` is the cleanup path for a start
            // that never happened, and swallowing it would be the one way to leave the waveform
            // stuck on screen.
            guard !isNotTakingInputBecauseOfTheStatusItemIcon else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isKikiCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)

            // Pressing the key *is* starting the next question, so this is the earliest instant the
            // previous reply can be called over.
            stopEverythingTheLastThingStarted(interruptedBy: "这次操作被打断了：Kiki 开始听你说话了。")

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            KikiAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        KikiAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // A release arriving before the async start began recording would otherwise be
            // dropped, leaving the waveform overlay stuck on screen.
            KikiAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Recording And Replaying The User's Own Actions

    /// Binds the shortcut that starts, ends and interrupts a recording.
    ///
    /// The recorder owns the chord rather than the push-to-talk monitor, because ending a recording is
    /// something only the recorder can do: it is the half that knows what the recording holds. The tap
    /// therefore listens for it at all times, which is what makes the same press able to end one.
    private func bindTheRecordingShortcut() {
        recordedActionsShortcutCancellable = userActionRecorder
            .shortcutWasTappedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleTheRecordingShortcutBeingTapped()
            }
    }

    /// One tap of shift+option, which is one of three things and never the same thing twice in a row:
    /// it starts a recording, it ends one and replays it, or it stops the replay and forgets it.
    ///
    /// A tap rather than a hold, which is what makes a recording worth anything: a held modifier is
    /// down during everything being recorded, so every click the user made would be made with
    /// shift+option still pressed and every shortcut they used would be eaten.
    private func handleTheRecordingShortcutBeingTapped() {
        switch recordedActionsPhase {
        case .neitherRecordingNorReplaying:
            startRecordingWhatTheUserIsDoing()
        case .recordingWhatTheUserIsDoing:
            endTheRecordingAndReplayIt()
        case .replayingWhatTheUserDid:
            stopRecordingOrReplayingAndForgetIt()
            // The step the loop had already started goes with it. A step spends its first half
            // reading the screen and its second half flying, so the tap lands inside one often
            // enough to be seen, and a replay that presses one more thing after being told to stop
            // says the opposite of what the tap said.
            callOffTheActionBeingWaitedOn(because: "这次重放停下来了。")
        }
    }

    /// Starts watching the user's hands, or says why Kiki will not.
    ///
    /// Nothing is recorded when it will not: a recording of work Kiki cannot do again is discovered to
    /// be worthless only at the end of it, and the moment to say so is before the user starts.
    private func startRecordingWhatTheUserIsDoing() {
        guard !showOnboardingVideo, !isNotTakingInputBecauseOfTheStatusItemIcon else { return }

        guard isAutomaticClickingEnabled else {
            speakTheSentenceThatSaysWhyNothingWillBeRecorded(
                "先打开「允许 Kiki 用鼠标操作」，Kiki 才能重放你的操作。"
            )
            return
        }
        guard hasAccessibilityPermission else {
            speakTheSentenceThatSaysWhyNothingWillBeRecorded(
                "没有辅助功能权限，Kiki 重放不了你的操作。在「系统设置 → 隐私与安全性 → 辅助功能」里给 Kiki 打开。"
            )
            return
        }

        // A recording replaces whatever is running, the way a question does: the reply stops, and so
        // does anything a terminal is waiting on, because the screen all of it was aimed at is the one
        // the user is about to work on.
        stopEverythingTheLastThingStarted(interruptedBy: "这次操作被打断了：Kiki 开始记录你的操作了。")

        indexOfTheNextRecordedActionToReplay = 0
        recordedUserActions = []
        recordedActionsPhase = .recordingWhatTheUserIsDoing
        userActionRecorder.startRecording()
        print("⏺ Companion is recording what the user does")
    }

    /// Ends the recording and starts replaying it — or gives up quietly when it holds nothing, because
    /// there is no gesture to make and no sentence that would help.
    private func endTheRecordingAndReplayIt() {
        let recordedUserActions = userActionRecorder.stopRecording()
        guard !recordedUserActions.isEmpty else {
            recordedActionsPhase = .neitherRecordingNorReplaying
            print("⏺ Companion: nothing was recorded")
            return
        }

        // Asked again here rather than only where the recording started. Both halves of it can be
        // turned off while the user is working, and a recording is minutes of their own work — so the
        // sentence names what is missing rather than the recording disappearing without a word.
        guard isAutomaticClickingEnabled else {
            recordedActionsPhase = .neitherRecordingNorReplaying
            speakTheSentenceThatSaysWhyNothingWillBeRecorded(
                "「允许 Kiki 用鼠标操作」关掉了，这次记录没法重放。"
            )
            return
        }
        guard hasAccessibilityPermission else {
            recordedActionsPhase = .neitherRecordingNorReplaying
            speakTheSentenceThatSaysWhyNothingWillBeRecorded(
                "辅助功能权限没有了，这次记录没法重放。"
            )
            return
        }

        self.recordedUserActions = recordedUserActions
        indexOfTheNextRecordedActionToReplay = 0
        recordedActionsPhase = .replayingWhatTheUserDid
        print("⏺ Companion is replaying \(recordedUserActions.count) recorded action(s)")
        // The same hop the arrival takes to reach the performance: a step reads the screen, and this
        // is a shortcut press that has to return before it can.
        Task { await takeTheNextStepOfTheReplay() }
    }

    /// Says, aloud, why a recording is not starting or not replaying.
    ///
    /// Through a synthesizer of its own, the way the low-credits sentence is: there is no reply being
    /// spoken and no turn for `voiceState` to depict. Nothing is written to `voiceState` here either,
    /// because this sentence is over in a second and a state entered for it would have nothing to end
    /// it.
    private func speakTheSentenceThatSaysWhyNothingWillBeRecorded(_ sentence: String) {
        NSSpeechSynthesizer().startSpeaking(sentence)
    }

    /// Ends the recording or the replay the user's hands were in the middle of, throws away what was
    /// recorded, and gives the user their pointer back.
    ///
    /// One function because the two endings are the same ending — the recording stops, the loop stops,
    /// the list goes, the phase goes back to neither — and because everything that takes Kiki over
    /// needs all of it: a question, spoken or typed, a new recording, and the permission going away
    /// underneath either. The recording is never kept for later, because in every one of those the user
    /// has moved on to something else.
    private func stopRecordingOrReplayingAndForgetIt() {
        guard recordedActionsPhase != .neitherRecordingNorReplaying else { return }

        recordedActionsPhase = .neitherRecordingNorReplaying
        replayStepTask?.cancel()
        replayStepTask = nil
        recordedUserActions = []
        indexOfTheNextRecordedActionToReplay = 0
        // Told even when only the replay was running: it is holding the press and the scroll of a
        // recording that has ended, and a stale one would settle into the next recording's first action.
        userActionRecorder.stopRecording()

        // The cursor is part of what a replay started, so it is part of what ending one restores, the
        // way `abandonSpeakingReply` restores it for a reply. Every replay step is a pointer-carrying
        // flight, so the user's pointer is normally in Kiki's hand at this moment — held for a whole
        // run and let go of only when the flight in the air lands. Left to that, the tap that stops a
        // replay would drag the pointer to an element nothing is going to press and then hold it
        // through the tour's three seconds before it came home, which is a mouse that stays locked
        // after the user has taken over.
        clearDetectedElementLocation()
        requestBuddyReturnHome()
    }

    /// One step of the replay.
    ///
    /// The action is made at its point exactly the way a terminal's is made at the point it asked for —
    /// same flight, same red cursor, same click sound, same event — which is the whole reason a
    /// recorded action is stored as the value the arrival performs rather than as a description of a
    /// mouse event.
    private func takeTheNextStepOfTheReplay() async {
        guard recordedActionsPhase == .replayingWhatTheUserDid else { return }
        guard isAutomaticClickingEnabled else {
            stopRecordingOrReplayingAndForgetIt()
            return
        }
        guard recordedUserActions.indices.contains(indexOfTheNextRecordedActionToReplay) else { return }

        let recordedUserAction = recordedUserActions[indexOfTheNextRecordedActionToReplay]
        // Advanced before the action is made rather than after it, so that a step interrupted half way
        // is not the one a restarted loop would come back to.
        indexOfTheNextRecordedActionToReplay =
            (indexOfTheNextRecordedActionToReplay + 1) % recordedUserActions.count

        // Named the way a terminal's action is named, because everything downstream asks this and
        // nothing else which action it is performing: that the one answer goes back into the loop
        // rather than to a terminal is the only difference between the two.
        let actionBeingWaitedOn = ActionBeingWaitedOn(
            actionIdentifier: UUID(),
            whoHearsTheAnswer: .theReplayOfTheUsersRecordedActions
        )
        self.actionBeingWaitedOn = actionBeingWaitedOn

        // The point is resolved the way a terminal's is, which brings the flip into the AppKit space,
        // the search for the display it is on, and the refusal for a point on none of them. A refused
        // point answers the action like any other, which is how a step whose window has gone away is
        // skipped rather than ending the replay.
        let resolution = await resolveActionTarget(
            atGlobalScreenPoint: recordedUserAction.globalScreenPoint,
            action: recordedUserAction.action,
            dragDestinationGlobalScreenPoint: recordedUserAction.dragDestinationGlobalScreenPoint
        )

        // Asked again after the await, for the reason the terminal's own path asks it: resolving reads
        // the screens, which is long enough for the user to have tapped the shortcut and ended this.
        guard recordedActionsPhase == .replayingWhatTheUserDid,
              isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }

        await carryOutTheResolvedAction(
            resolution,
            elementText: nil,
            action: recordedUserAction.action,
            actionBeingWaitedOn: actionBeingWaitedOn
        )
    }

    /// Waits out the gap between two replayed actions and takes the next one.
    ///
    /// The wait is what makes a replay watchable: the actions themselves are over in milliseconds, so
    /// back to back the cursor would cross the screen twice before the eye could follow either.
    private func scheduleTheNextStepOfTheReplay() {
        replayStepTask?.cancel()
        guard recordedActionsPhase == .replayingWhatTheUserDid else { return }

        replayStepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.secondsBetweenReplayedActions * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.takeTheNextStepOfTheReplay()
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're kiki, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    language: you always reply in chinese (简体中文), written as natural spoken mandarin that sounds right out loud — not english sentences translated word for word. keep terms people actually say in english as english (like "commit", "pull request", "bug"), the way a chinese developer would say them.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - casual, warm. no emojis. if you use an english word, keep it lowercase.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - when the screenshot is relevant to what they asked, reference specific things you see; when it isn't, just answer the question directly.
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - if you receive multiple screen images, the one labeled as where the cursor is matters most — prioritize it, but reference the others if they're relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, put the coordinate tag right where you mention the element — inside the sentence, tight against the words that name it — never at the end of the sentence and never at the start of the next one. the cursor sets off when your voice reaches the sentence the tag sits in, and it holds the narration there until it has arrived and stood on the element. a tag left at a sentence boundary is read as belonging to the sentence before it, so the cursor sets off on words that have nothing to do with the element and the pause lands in the wrong place. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is what the element is CALLED. when the element has text written on it, copy that text into the label character for character, exactly as it appears on screen — chinese, file paths, identifiers, product names, all of it — and do not translate or tidy it. the label is matched against the text actually on the screen to place the cursor exactly, so the closer it is to what is really written there, the more precisely you point, and your coordinate only needs to be in the right neighbourhood rather than perfect. when the element has no text of its own — an icon button, a toolbar, a colour swatch, a panel with nothing written in it — name it in 1-3 english words instead (like "search bar" or "save button"). the tag and the label inside it are parsed by code and never read aloud, so nothing about the label has to sound like speech — but that cuts both ways: the label is not how the user hears what you are pointing at, so the sentence around the tag still has to name the element out loud, in chinese. "最上面是 [POINT:400,213:新华网] 新华网" is heard as "最上面是新华网"; leave that last word out and the very same reply is heard as "最上面是，". this slips most easily when you tag several things in a row — a list of names is exactly where the names end up living in the tags alone, and the user then hears you point at nine things without saying what any of them are.

    write [CLICK:x,y:label] instead when the user wants that element actually operated — opened, pressed, switched on — and you are doing it for them. this tag is not just wording: once the cursor lands on the element, kiki clicks it, once. so write it only where you mean the thing to happen now, and never for anything the user cannot take back — deleting, clearing, uninstalling, formatting, resetting, quitting, shutting down, paying, sending — those stay [POINT:x,y:label] and the user makes that click themselves. keep [POINT:x,y:label] when you are only locating something for them, which is the usual case: someone who asked where a setting lives has not asked to click it. if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    write [DOUBLECLICK:x,y:label] when the element takes two clicks to do what was asked — opening a file, folder or icon on the desktop or in finder, selecting a word in a piece of text, dropping into a cell so it can be edited. a single click on any of those only selects it, so [CLICK:x,y:label] leaves the user looking at a file that never opened. everything above about [CLICK:x,y:label] holds here as well: kiki is doing it for the user, so write it only where you mean it to happen now, and never on anything the user cannot take back. but do not reach for it just because the element matters or because clicking it feels decisive — a button, a menu item, a toolbar control, a switch and a link all take exactly one click, and two on those is a different action than the one the user asked for, or nothing at all. when in doubt, [CLICK:x,y:label].

    write [TRIPLECLICK:x,y:label] when what the user wants is a whole paragraph selected — three clicks is the one thing macOS reserves for that, and a double click only takes the word under the pointer. everything above about [CLICK:x,y:label] holds here as well: kiki is doing it, so write it only where you mean it to happen now, and never on anything the user cannot take back. but of all the click tags this is the narrowest and the one that goes wrong most quietly: a button, a menu item, a toolbar control, a switch and a link take exactly one click, and three on any of them is that one action happening three times over, which is not what the user asked for. on prose and nothing else. when in doubt, [CLICK:x,y:label] or [DOUBLECLICK:x,y:label].

    write [RIGHTCLICK:x,y:label] when what the user needs is the element's context menu — the menu that opens on a right click. kiki presses the right button on the element once the cursor lands, so that menu really opens on their screen, with the pointer left sitting on it ready for them to pick from. this is the shape for "how do i compress this file", "how do i rename this folder", "what else can i do with this photo" — the item that does it is in that menu, and no left click gets them there. everything above about [CLICK:x,y:label] holds here as well: kiki is doing it, so write it only where you mean it to happen now, and never on anything the user cannot take back. but do not reach for it over an ordinary button, link, menu item or toolbar control — a right click on those opens a menu nobody asked for instead of the one press they wanted. when in doubt, [POINT:x,y:label].

    one thing to know about it: the menu your own right click opens is not in your screenshot, because you are looking at the screen as it was before your reply started. so never tag anything inside a menu you just opened — say in words what the menu will offer and let the user choose.

    write [SCROLLUP:x,y:label], [SCROLLDOWN:x,y:label], [SCROLLLEFT:x,y:label] or [SCROLLRIGHT:x,y:label] when what the user needs is past the edge of what is on screen — the rest of a long list, a page that continues below, a column cut off to the left. kiki scrolls at the element once the cursor lands, so point it at the thing that should move: the list, the text pane, the document. it rolls one screenful by default; for more, append :xN after the label and before any :screenN — [SCROLLDOWN:640,400:消息列表:x3] rolls that list down three screenfuls, and N runs from 1 to 20. always with the x: everything after the second colon is read as the element's name, so a bare 「:3」 is swallowed into the label and the scroll never happens.

    two things to know about scrolling. the first is the same one that applies to a menu your own right click opens: your screenshot is the screen as it was when your reply started, so whatever a scroll brings into view is not in front of you — say in words what is down there, and never tag anything you could only see by scrolling, because that coordinate is one you do not have. the second is order: a scroll moves everything the tags after it were reading, so a scroll tag goes at the very end of your reply, once every element you meant to point at has been pointed at.

    write [DRAG:x,y:label>X,Y] when what the user wants is something carried from one place to another — a file into a folder, an icon onto the desktop, a slider dragged to the other end, a window moved out of the way. this is the only tag with two points: x,y is the element, which is where the drag starts, and X,Y after the > is where it is let go. kiki presses on the element once the cursor lands, carries it across and releases it there, so the whole movement happens on their screen. tag the thing being moved, never the place it is going — the element is still what the label names and what your coordinate has to be in the neighbourhood of. the drop point is a point and nothing else: there is no text there for kiki to find it by, so unlike the element's coordinate it has to be measured properly rather than estimated. it is read off the same screenshot the element is, so both points are on one screen; if that screen is not the cursor's, the :screenN goes after the label and before the >, as in [DRAG:420,330:季度报告:screen2>1100,600]. the label must never contain a >, and nothing but the label goes before it: everything up to the > is read as the element's name and everything after it as the point, so a :screenN written on the wrong side of the > is swallowed into the label, finds nothing on screen, and leaves the drag with nowhere to go.

    you can tag up to fifteen elements in one reply, and the cursor visits them in the order you write them. write them in the order you talk about them, each one sitting in the sentence that names it — the narration waits on an element until the cursor has arrived and stood on it, so a tag written somewhere other than where you mention the element makes the pointing feel out of step. if you want to mention more than fifteen things, pick the fifteen that matter most.

    examples:
    - user asks how to color grade in final cut: "打开 [POINT:1100,42:color inspector] 调色检查器就行，在工具栏右上角那一块。点开之后色轮和曲线都在里面。"
    - user asks what a folder in their terminal is: "最后那一行的 [POINT:660,151:Build] Build 就是 xcode 放编译产物的地方。每次重新构建都往里面写东西，删掉不会有任何损失。"
    - user asks what html is: "html 是超文本标记语言，基本上就是每个网页的骨架。想不想知道它跟你正在看的 css 是怎么配合的？"
    - user asks how to commit in xcode: "我先把顶上那个 [CLICK:285,11:源代码管理] 源代码管理菜单给你打开，你在里面选提交就行，或者直接按 command option c。"
    - user asks how to save their work in an app: "按一下右上角那个 [CLICK:880,64:保存] 保存按钮就存上了，存过一次之后 command s 也能随时存。"
    - user asks you to open a file sitting on their desktop: "桌面上那个 [DOUBLECLICK:420,330:季度报告] 季度报告双击就打开了，单击它只是选中，不会打开。"
    - user asks to replace a whole paragraph of a document: "在第二段开头那行 [TRIPLECLICK:520,318:本项目自去年立项以来] 本项目自去年立项以来连点三下，整段就选中了，直接打新的就行。"
    - user asks how to compress a file sitting on their desktop: "在那个 [RIGHTCLICK:420,330:季度报告] 季度报告上点右键，菜单里选「压缩」就行。"
    - user asks where to start in an unfamiliar app, worth two tags: "先看左上角那个 [POINT:210,64:search field] 搜索框，想找什么直接敲就行。要是找不到，右下角还有个 [POINT:1180,690:filter button] 筛选按钮，点开能按类型和时间筛。"
    - user asks what's in a list, worth several tags — every name is said out loud, not just tagged: "带上「新闻」两个字的从上到下就这几条：最上面是 [POINT:400,213:新华网] 新华网，接着是 [POINT:400,246:央视新闻] 央视新闻，再往下是 [POINT:400,279:腾讯新闻] 腾讯新闻。"
    - the same list, but the user asks you to open them rather than tell them what's there — now it is [CLICK:x,y:label], and the names are still said out loud: "好，我挨个给你打开：先是 [CLICK:400,213:新华网] 新华网，接着是 [CLICK:400,246:央视新闻] 央视新闻，最后是 [CLICK:400,279:腾讯新闻] 腾讯新闻。"
    - element is on screen 2 (not where cursor is): "在你另一块屏幕上，看到那个 [POINT:400,300:terminal:screen2] 终端窗口了吗？"
    - user asks what else is in a list that runs off the bottom of the screen, worth two tags and the scroll last: "再往下还有两栏，先看 [POINT:400,279:腾讯新闻] 腾讯新闻。剩下那两栏我把 [SCROLLDOWN:640,420:侧边栏:x2] 侧边栏往下滚两屏，你接着看就行。"
    - user asks you to file a document away, worth one drag: "我把桌面那个 [DRAG:420,330:季度报告>1160,640] 季度报告拖到右边的项目文件夹里，你看它过去就行。"
    """

    /// Forgets the conversation when the user has been away long enough that this turn starts a new
    /// one, and records this turn as the one the next gap is measured from.
    ///
    /// Checked at the top of the turn rather than where the exchange is appended, because the request
    /// is built from the history and a later check would let the stale rounds go out once more.
    /// `Date()` rather than a monotonic clock on purpose: a laptop closed overnight should read as a
    /// long gap, while a monotonic clock stops counting while the machine sleeps.
    private func startNewConversationIfTheUserHasBeenAway() {
        let thisTurnStartDate = Date()

        if let lastUserTurnStartDate {
            let gapSinceTheLastTurnSeconds = thisTurnStartDate.timeIntervalSince(lastUserTurnStartDate)
            if gapSinceTheLastTurnSeconds > Self.maximumGapBetweenTurnsInTheSameConversationSeconds {
                print("🧠 New conversation — \(Int(gapSinceTheLastTurnSeconds))s since the last turn, "
                      + "dropping \(conversationHistory.count) exchange(s)")
                conversationHistory.removeAll()
            }
        }

        lastUserTurnStartDate = thisTurnStartDate
    }

    /// Captures a screenshot, sends it with the transcript to DeepSeek, and plays the response
    /// aloud. The cursor stays in the spinner state until audio is actually heard.
    ///
    /// `isReadingTheReplyAloud` is the whole of the difference between a turn someone spoke and one
    /// a terminal typed: nothing is synthesised, and the pointing is paced by the cursor instead of
    /// by the narration.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        isReadingTheReplyAloud: Bool = true
    ) {
        // Before anything else about this turn, decide whether it continues the last
        // conversation.
        startNewConversationIfTheUserHasBeenAway()

        self.isReadingTheReplyAloud = isReadingTheReplyAloud
        // A fact about the last turn's voice, which the fallback below sets and nothing else clears.
        hasTheNarrationGoneSilent = false

        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        // A segment of the old reply still being synthesised is a core producing audio nobody
        // will hear, and the interrupted reply's stops must not stay armed for its replacement.
        ttsClient.discardPreparedSegments()
        endPointingTour()

        // Everything above this line is synchronous, which is what makes this the one race-free
        // moment to capture the reply being replaced: `currentResponseTask` is cancelled but its
        // `catch` has not run yet, and by then the segmenter may belong to this turn.
        writeTheCurrentTurnIntoHistory(interruption: .theUserStartedANewQuestion)
        abandonSpeakingReply()

        // Deliberately after the line above: what that read is the *previous* turn's question.
        transcriptOfTheTurnBeingAnswered = transcript

        // Stamped synchronously, before the task below exists, so a chunk still on its way from
        // the reply being replaced is already recognisable as stale when it lands.
        let thisTurnIdentifier = UUID()
        turnIdentifierOfTheReplyBeingStreamed = thisTurnIdentifier

        // Nothing will ever be heard in a silent turn, so the flag that says a reply is in progress
        // and not yet audible would never be cleared by the sound it is waiting for.
        isWaitingForTheFirstSoundOfTheReply = isReadingTheReplyAloud
        isProducingAReply = true

        currentResponseTask = Task {
            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Read the text on every screenshot now rather than once the reply arrives:
                // recognition takes the better part of a second per screen, and starting it after
                // would add that whole second to every reply that points at anything.
                let recognizedTextLinesTasks = screenCaptures.map { screenCapture in
                    Task {
                        await ScreenshotTextRecognizer.recognizedLines(in: screenCapture.imageData)
                    }
                }

                // Each label states the pixel dimensions of the image it sits beside, so the
                // model's coordinate space matches the image it sees.
                let labeledImages = screenCaptures.map { capture in
                    (
                        data: capture.imageData,
                        label: capture.label
                            + " (image dimensions: \(capture.screenshotWidthInPixels)"
                            + "x\(capture.screenshotHeightInPixels) pixels)"
                    )
                }

                // Pass conversation history so the model remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // The reply's state has to be clear of the last one's before the first chunk.
                beginStreamingReply(
                    screenCaptures: screenCaptures,
                    recognizedTextLinesTasks: recognizedTextLinesTasks
                )

                let (fullResponseText, _) = try await deepSeekAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedRawText in
                        // Awaited rather than fired and forgotten: the segmenter has to know which
                        // sentence each new tag sits in before it can cut the reply around it, and
                        // awaiting also pauses this read until it has answered.
                        await self?.absorbStreamedReplyText(
                            accumulatedRawText,
                            fromTurnIdentifiedBy: thisTurnIdentifier
                        )
                    }
                )

                guard !Task.isCancelled else { return }

                await concludeStreamedReply(
                    fullRawText: fullResponseText,
                    fromTurnIdentifiedBy: thisTurnIdentifier
                )
            } catch {
                // A cancelled read raises either `CancellationError` or `URLError(.cancelled)`, and
                // `URLSession.AsyncBytes` promises neither, so the task is asked rather than the error
                // — falling through would read 「额度用完了」 to a user who merely asked again.
                //
                // Nothing is recorded here either: this `catch` can run after the next turn has begun.
                guard !Task.isCancelled else { return }

                // A reply cut off part-way has already been partly spoken and there is no taking that
                // back; what can be helped is the fallback being read over the top of it.
                ttsClient.stopPlayback()
                ttsClient.discardPreparedSegments()
                writeTheCurrentTurnIntoHistory(interruption: .theReplyFailedPartWayThrough)
                abandonSpeakingReply()
                KikiAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                // A terminal watching this turn is owed an ending rather than a wait it cannot
                // resolve — nothing else about this turn will reach it.
                commandSocketServer.send(.failed(message: "这一轮没能跑完：\(error.localizedDescription)", isRefusal: false))
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                // The `await` above returns in the middle of the narration, not after it: the
                // reply has finished arriving while its segments are still being spoken. The turn
                // is not over until the voice is, so the state is left to the last segment —
                // `finishSpeakingReply` settles it when that segment is done.
                guard !isSpeakingReply, !isWaitingForTheFirstSoundOfTheReply else { return }
                isProducingAReply = false
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// In transient cursor mode, waits for the reply and any pointing to finish, then fades
    /// the overlay out after a second. Cancelled when the user starts another interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isKikiCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Asks whether the *reply* is still being spoken rather than whether the voice is making
            // sound: the client's `isPlaying` goes false between segments, so polling that would hide
            // the overlay in the silence while the cursor is still waited on.
            while isSpeakingReply {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // The location is cleared when the buddy flies back to the cursor.
            while pointingTarget != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }


            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message when the API call fails, straight to
    /// `NSSpeechSynthesizer` so it still works if the TTS client is mid-utterance or stuck.
    private func speakCreditsErrorFallback() {
        let utterance = "额度用完了，去 DeepSeek 充值之后我就能继续帮你。"
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        // The one direct write left. This sentence goes out through a synthesizer of its own, which
        // reports nothing back — no first sound, no completion — so it is not one of the facts
        // `voiceState` is derived from and there is nothing for a derivation to see. It is written
        // here rather than added as a fourth fact because it is the only utterance in the app that
        // neither ends nor reports, and a flag for it would be read once.
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// How many elements one reply may point at. Every extra stop is another chance for the
    /// narration to sit waiting on a flight, so this is a sanity limit on a rambling reply.
    private static let maximumPointingTourStopCount = 15

    /// Where the cursor is in its trip into the menu bar icon it goes to rest in, and back out.
    ///
    /// Neither flight can be called off — the cursor has gone somewhere the pointer cannot follow
    /// it, so no amount of moving the mouse undoes either one, and the stored frame is what the
    /// icon's own appearance is keyed on.
    enum StatusItemIconPhase: Equatable {
        case notInTheIcon
        /// The wait is over. The cursor is on its way to this icon rectangle, in AppKit screen
        /// coordinates — the same space `NSEvent.mouseLocation` is in.
        case cursorFlyingToIcon(iconScreenFrame: CGRect)
        /// Landed: the icon wears the cursor's colour from here on, and the cursor is gone.
        case cursorRestingInIcon
        /// The pointer came back. The cursor is on its way out to the position beside it, where
        /// following resumes.
        case cursorWakingFromIcon
    }

    /// Whether Kiki has gone quiet because the cursor is in the menu bar icon's hands.
    ///
    /// True from the moment a wait runs out, not from the landing: the flight cannot be called off,
    /// so anything that would hand the cursor a job has to be refused from the instant it is
    /// committed. It stays true through the flight back out for the same reason — until the cursor
    /// has landed beside the pointer there is nothing there to hand a job to.
    var isNotTakingInputBecauseOfTheStatusItemIcon: Bool { statusItemIconPhase != .notInTheIcon }

    /// Resting: on the way into the icon, or already inside it.
    ///
    /// Read by the two wait-counting paths, one per gesture — the rest's own wait counts only while
    /// this is false, and the wake's only while it is true.
    var isRestingInTheStatusItemIcon: Bool {
        switch statusItemIconPhase {
        case .cursorFlyingToIcon, .cursorRestingInIcon: return true
        case .cursorWakingFromIcon, .notInTheIcon: return false
        }
    }

    /// Waking: the cursor is on its way back out to the pointer.
    var isWakingFromTheStatusItemIcon: Bool { statusItemIconPhase == .cursorWakingFromIcon }

    /// What Kiki is doing right now, from the three facts that decide it.
    ///
    /// The icon comes first because it is the one state that covers every way into the app: while
    /// the cursor is in its hands there is no cursor to send anywhere, and whatever the voice is
    /// doing is beside the point. The recording comes next, for a weaker version of the same reason:
    /// a recording and a reply cannot both be running — starting one stops the other — so the order
    /// between them is not a preference, and putting the recording first says what the user is
    /// looking at while it lasts.
    var whatKikiIsDoingRightNow: WhatKikiIsDoingRightNow {
        switch statusItemIconPhase {
        case .cursorFlyingToIcon, .cursorRestingInIcon: return .restingInTheStatusItemIcon
        case .cursorWakingFromIcon: return .wakingFromTheStatusItemIcon
        case .notInTheIcon: break
        }

        switch recordedActionsPhase {
        case .recordingWhatTheUserIsDoing: return .recordingWhatTheUserIsDoing
        case .replayingWhatTheUserDid: return .replayingWhatTheUserDid
        case .neitherRecordingNorReplaying: break
        }

        switch voiceState {
        case .idle: return .waiting
        case .listening: return .listeningToTheUser
        case .processing: return .processingTheLastTurn
        case .responding: return .replyingToTheLastTurn
        }
    }

    /// What the cursor is doing at the element it just pointed at, from the tag the model wrote:
    /// locating it, operating it with one press, two or three, opening its menu, or scrolling it.
    ///
    /// One case per gesture rather than one carrying a count and a button: a button takes one press,
    /// asking for two on it is asking for a different action, and a right click opens something
    /// neither of the others does.
    ///
    /// The scroll case is the one that carries anything, and it carries the distance because the
    /// distance is the tag's own: `:x3` belongs to the element it was written on, and has to travel
    /// with that stop to the flight, the bubble and the events that go out.
    enum PointingBubbleInvitation: Equatable {
        /// The model is only locating the element for the user.
        case lookAtElement
        /// The model is telling the user to click or operate the element.
        case clickElement
        /// The model is telling the user to open or select the element, which takes two clicks.
        case doubleClickElement
        /// The model is telling the user to select a whole paragraph of the element, which takes
        /// three clicks.
        case tripleClickElement
        /// The model is telling the user the answer is in the element's context menu, which the
        /// right button opens.
        case rightClickElement
        /// The model is telling the user the element is to be moved somewhere else. Carries no
        /// destination for the same reason `ElementActionOnArrival.drag` does not: it is the same
        /// drag either way, and where it lets go travels on the stop.
        case dragElement
        /// There is more to see past the edge of this element, and which way it lies, and how far.
        /// The distance is not always the model's: this is also the invitation a recorded scroll
        /// replays under, and that one was measured off the user's own hand.
        case scrollElement(ElementScrollDirection, distance: ElementScrollDistance)

        /// What the cursor should do on arrival, or nil when there is nothing to do but hover.
        var actionToPerformOnArrival: ElementActionOnArrival? {
            switch self {
            case .lookAtElement: return nil
            case .clickElement: return .press(.singleClick)
            case .doubleClickElement: return .press(.doubleClick)
            case .tripleClickElement: return .press(.tripleClick)
            case .rightClickElement: return .press(.rightClick)
            case .dragElement: return .drag
            case .scrollElement(let direction, let distance): return .scroll(direction, distance: distance)
            }
        }

        /// The invitation that describes a given gesture, for a caller that holds the gesture and
        /// needs the bubble and the phrase pool that go with it.
        ///
        /// The inverse of the property above, so the words over the cursor and the presses that go
        /// out cannot disagree — the gestures look identical on screen until they happen, and
        /// 「点这里！」 over a file about to open describes the wrong one.
        static func describing(_ clickKind: ElementClickKind) -> PointingBubbleInvitation {
            switch clickKind {
            case .singleClick: return .clickElement
            case .doubleClick: return .doubleClickElement
            case .tripleClick: return .tripleClickElement
            case .rightClick: return .rightClickElement
            }
        }

        /// The same inverse for the other gesture axis. Separate from the one above rather than
        /// sharing it, because a scroll has a direction and a distance that a press has no room for.
        static func describing(
            _ direction: ElementScrollDirection,
            distance: ElementScrollDistance
        ) -> PointingBubbleInvitation {
            return .scrollElement(direction, distance: distance)
        }

        /// The same inverse again for a caller that holds the whole arrival action and nothing
        /// narrower — which is every caller that got it from a terminal or from a recording rather
        /// than from a tag, where the gesture arrived as one value already.
        static func describing(_ action: ElementActionOnArrival) -> PointingBubbleInvitation {
            switch action {
            case .press(let clickKind): return .describing(clickKind)
            case .drag: return .dragElement
            case .scroll(let direction, let distance): return .describing(direction, distance: distance)
            }
        }

        /// The name of the case for the record file, written out so a log value is something to
        /// search the source for.
        var name: String {
            switch self {
            case .lookAtElement: return "lookAtElement"
            case .clickElement: return "clickElement"
            case .doubleClickElement: return "doubleClickElement"
            case .tripleClickElement: return "tripleClickElement"
            case .rightClickElement: return "rightClickElement"
            case .dragElement: return "dragElement"
            case .scrollElement(let direction, _): return "scrollElement \(direction)"
            }
        }
    }

    /// One flight of the cursor, whole: the point it is aimed at and everything it does on arrival.
    struct PointingTarget: Equatable {
        /// Where the element is, in global AppKit screen coordinates.
        let screenLocation: CGPoint
        /// The display frame (global AppKit coords) of the screen the element is on, so the overlay
        /// knows which of its windows should animate.
        let displayFrame: CGRect
        /// What the arrival bubble invites the user to do, taken from the tag the model wrote.
        let bubbleInvitation: PointingBubbleInvitation
        /// Custom bubble text for the pointing animation, in place of a random phrase. Only the
        /// onboarding demo sets it, which is why it is the one fact here with no default.
        let bubbleText: String?
        /// What the element gets on arrival — a press or a scroll — or nil when Kiki will not do
        /// anything to it at all. Filled from the same function that decides whether the action is
        /// posted, so the overlay's drawing of the answer cannot disagree with what goes out.
        ///
        /// Withdrawn, not merely unset, when the tour ends under the cursor: the cursor stays where
        /// it is and stops being an action.
        var actionToPerformOnArrival: ElementActionOnArrival?
    }

    /// Result of parsing a [POINT:...] tag from the model's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the model said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
        /// Every element the model tagged, in the order it described them, capped at
        /// `maximumPointingTourStopCount`. Empty when the model wrote [POINT:none] or no tag.
        let tourStops: [PointingTourStop]
    }

    /// One element on a pointing tour, with the point in the spoken text at which the cursor
    /// should already be on its way there.
    struct PointingTourStop {
        /// The coordinate the model read off the screenshot, in that image's own pixel space.
        /// It needs the same scaling and flipping as `PointingParseResult.coordinate`.
        let screenshotCoordinate: CGPoint
        /// Short label describing the element (e.g. "run button").
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
        /// Offset into `spokenText` of the sentence describing this element. The tour sends the
        /// cursor on its way here, so it flies while the model is still describing the element, and
        /// the end of the same sentence is where the segment carrying this stop ends.
        let sentenceStartOffsetInSpokenText: Int
        /// What this stop's arrival bubble should invite the user to do.
        let pointingBubbleInvitation: PointingBubbleInvitation
        /// Where a drag from this stop lets go, in the screenshot's own pixel space and on the same
        /// screenshot as `screenshotCoordinate`. Nil for every stop that is not a drag, and for a
        /// `[DRAG:...]` tag that named no destination — which is what the refusal is read from.
        ///
        /// The same screenshot even when the destination is near a display's edge, because
        /// `screenLocation(forScreenshotCoordinate:on:)` clamps into the image it is given: a
        /// destination scaled against another display's capture would be a different point entirely.
        let dragDestinationScreenshotCoordinate: CGPoint?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag out of the model's response, and the
    /// same shapes written as [CLICK:...], [DOUBLECLICK:...], [RIGHTCLICK:...], the four
    /// [SCROLL…:...] names, each of which may also carry a `:xN` distance, and [DRAG:...], which
    /// carries a second pair of coordinates after a `>`. Returns the spoken text with every tag
    /// stripped, plus the coordinate, label and screen number of the last one.
    ///
    /// The tag is looked for anywhere in the response and the last one wins rather than being required
    /// at the very end: anchoring it meant a model that tacked anything on after it — a trailing "。"
    /// is enough — disabled pointing silently.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // The tag name is matched case-insensitively while everything inside it stays exact, because
        // the prompt describes these tags in lowercase prose and a tag the pattern does not recognize
        // fails silently: the reply is spoken normally and the cursor never moves.
        //
        // The label stops at `]` and at nothing else, so it may contain colons — the prompt asks the
        // model to copy the element's on-screen text verbatim, and a screen is full of text containing
        // them ("今天 02:04"). `:screenN` is lazy for that reason.
        // The alternatives are anchored just after `[`, so CLICK cannot swallow a RIGHTCLICK: the
        // pattern would have nothing left to match at that position.
        //
        // The distance comes after the label and carries an `x` of its own. A bare `:3` would be
        // eaten by the label group — it is lazy, and everything up to the next colon is still
        // "the rest of the label" — so `[RIGHTCLICK:120,240:今天 02:04]` would come back with the
        // label 「今天 02」 and a distance of 4. `:screenN` answers the same problem with a word in
        // front of it, and the distance does the same. Written in this order, the label takes what
        // it can and leaves `:x3` and `:screen2` standing.
        //
        // A drag's destination is the one thing appended after everything else, and it is appended
        // rather than slotted in because the groups above it are read by number: `:x(\d+)` is group
        // 4 and `:screen(\d+)` is group 5, so inserting the destination before either of them would
        // have `screenfuls(fromTagMatch:)` reading a destination's y as a distance. It sits after
        // them and is read as groups 6 and 7, which nothing else looks at.
        let pattern = #"\[(?i:POINT|CLICK|DOUBLECLICK|TRIPLECLICK|RIGHTCLICK|SCROLLUP|SCROLLDOWN|SCROLLLEFT|SCROLLRIGHT|DRAG):(?:none|(\d+)\s*,\s*(\d+)(?::([^\]\s][^\]]*?))?(?::x(\d+))?(?::screen(\d+))?(?:\s*>\s*(\d+)\s*,\s*(\d+))?)\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil, tourStops: [])
        }
        let allTagMatches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))

        guard let lastTagMatch = allTagMatches.last else {
            // No tag at all — the opening stretch of most replies — and it goes through the same tidy
            // the tagged path does. It has to: this runs on every chunk and its answer is what the
            // segmenter cuts segments from, so a reply raw until its first tag and tidied afterwards
            // would have two coordinate spaces instead of one.
            let tidiedRawSpokenText = Self.tidiedSpokenText(responseText)
            return PointingParseResult(
                spokenText: tidiedRawSpokenText.trimmingCharacters(in: .whitespacesAndNewlines),
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil,
                tourStops: []
            )
        }

        // Strip every tag, not just the one being pointed at, and rejoin the pieces between them.
        // Matches arrive in ascending order, so the length of the text assembled so far as each tag is
        // passed is exactly that tag's offset — which is how a tour stop later finds the sentence it
        // describes. Those offsets are in this raw text and are mapped onto the tidied text at the end.
        var rawSpokenText = ""
        var pendingPointingTourStops: [(
            screenshotCoordinate: CGPoint,
            elementLabel: String?,
            screenNumber: Int?,
            rawSentenceStartOffset: Int,
            pointingBubbleInvitation: PointingBubbleInvitation,
            dragDestinationScreenshotCoordinate: CGPoint?
        )] = []
        var searchStartIndex = responseText.startIndex
        for tagMatch in allTagMatches {
            guard let tagRange = Range(tagMatch.range, in: responseText) else { continue }
            rawSpokenText += responseText[searchStartIndex..<tagRange.lowerBound]
            searchStartIndex = tagRange.upperBound

            guard pendingPointingTourStops.count < Self.maximumPointingTourStopCount else { continue }
            // A [POINT:none] tag, or one whose coordinates didn't parse, has nothing to fly to.
            guard let screenshotCoordinate = Self.screenshotCoordinate(fromTagMatch: tagMatch, in: responseText) else { continue }

            pendingPointingTourStops.append((
                screenshotCoordinate: screenshotCoordinate,
                elementLabel: Self.elementLabel(fromTagMatch: tagMatch, in: responseText),
                screenNumber: Self.screenNumber(fromTagMatch: tagMatch, in: responseText),
                rawSentenceStartOffset: Self.sentenceStartOffset(inSpokenText: rawSpokenText, atOrBefore: rawSpokenText.utf16.count),
                pointingBubbleInvitation: Self.pointingBubbleInvitation(fromTagMatch: tagMatch, in: responseText),
                dragDestinationScreenshotCoordinate: Self.dragDestinationScreenshotCoordinate(
                    fromTagMatch: tagMatch,
                    in: responseText
                )
            ))
        }
        rawSpokenText += responseText[searchStartIndex...]

        let tidiedRawSpokenText = Self.tidiedSpokenText(rawSpokenText)
        // Trimming only removes from the two ends, so every offset into the tidied text has to
        // drop however much came off the front.
        let leadingWhitespaceUTF16UnitCount = String(tidiedRawSpokenText.prefix { $0.isWhitespace }).utf16.count
        let spokenText = tidiedRawSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        let tourStops = pendingPointingTourStops.map { pendingStop in
            PointingTourStop(
                screenshotCoordinate: pendingStop.screenshotCoordinate,
                elementLabel: pendingStop.elementLabel,
                screenNumber: pendingStop.screenNumber,
                sentenceStartOffsetInSpokenText: Self.tidiedOffset(
                    forRawOffset: pendingStop.rawSentenceStartOffset,
                    inRawText: rawSpokenText,
                    leadingWhitespaceUTF16UnitCount: leadingWhitespaceUTF16UnitCount
                ),
                pointingBubbleInvitation: pendingStop.pointingBubbleInvitation,
                dragDestinationScreenshotCoordinate: pendingStop.dragDestinationScreenshotCoordinate
            )
        }


        guard let lastScreenshotCoordinate = Self.screenshotCoordinate(fromTagMatch: lastTagMatch, in: responseText) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil, tourStops: tourStops)
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: lastScreenshotCoordinate,
            elementLabel: Self.elementLabel(fromTagMatch: lastTagMatch, in: responseText),
            screenNumber: Self.screenNumber(fromTagMatch: lastTagMatch, in: responseText),
            tourStops: tourStops
        )
    }

    /// The coordinate inside a [POINT:...] tag, in the screenshot's own pixel space, or nil
    /// for a [POINT:none] tag.
    private static func screenshotCoordinate(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> CGPoint? {
        guard tagMatch.numberOfRanges >= 3,
              let xRange = Range(tagMatch.range(at: 1), in: responseText),
              let yRange = Range(tagMatch.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// The short English label inside a [POINT:...] tag, e.g. "save button".
    private static func elementLabel(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> String? {
        guard tagMatch.numberOfRanges >= 4,
              let labelRange = Range(tagMatch.range(at: 3), in: responseText) else {
            return nil
        }
        return String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
    }

    /// Where a [DRAG:...] tag lets go, in the screenshot's own pixel space, or nil when that tag
    /// named no destination.
    ///
    /// Read only for a drag tag, because the two groups it reads are present in every tag's match —
    /// there is one pattern and it has one shape — so a destination written after any other tag
    /// would otherwise be read as a real one. What a tag means is its name.
    private static func dragDestinationScreenshotCoordinate(
        fromTagMatch tagMatch: NSTextCheckingResult,
        in responseText: String
    ) -> CGPoint? {
        guard let tagRange = Range(tagMatch.range, in: responseText),
              responseText[tagRange].uppercased().hasPrefix("[DRAG:") else {
            return nil
        }
        guard tagMatch.numberOfRanges >= 8,
              let xRange = Range(tagMatch.range(at: 6), in: responseText),
              let yRange = Range(tagMatch.range(at: 7), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// What the arrival bubble should invite the user to do, read off the tag the model wrote:
    /// [CLICK:...] for a click, [DOUBLECLICK:...] for two, [TRIPLECLICK:...] for three,
    /// [RIGHTCLICK:...] for the element's menu, [DRAG:...] for a drag, [SCROLLUP:...] and its three
    /// siblings for a scroll, [POINT:...] for locating it.
    ///
    /// Looking is the default: inviting someone to look is never wrong, while 「点这里」 reads as an
    /// instruction a user who only asked where a setting lives never asked for.
    ///
    /// A gesture's name has to be added here as well as to the pattern and to the prompt, and this
    /// is the silent one of the three: a tag the pattern knows but this does not still parses, still
    /// flies the cursor and still does the thing, and the bubble over it says 「看这里！」 about an
    /// action the user never asked for.
    private static func pointingBubbleInvitation(
        fromTagMatch tagMatch: NSTextCheckingResult,
        in responseText: String
    ) -> PointingBubbleInvitation {
        guard let tagRange = Range(tagMatch.range, in: responseText) else {
            return .lookAtElement
        }
        // Upper-cased before the comparison because the pattern accepts the tag name in any case. The
        // names are told apart by their whole prefix, so the order they are tested in cannot matter.
        let uppercasedTag = responseText[tagRange].uppercased()
        let screenfuls = Self.screenfuls(fromTagMatch: tagMatch, in: responseText)
        if uppercasedTag.hasPrefix("[DOUBLECLICK:") {
            return .doubleClickElement
        }
        if uppercasedTag.hasPrefix("[TRIPLECLICK:") {
            return .tripleClickElement
        }
        if uppercasedTag.hasPrefix("[RIGHTCLICK:") {
            return .rightClickElement
        }
        if uppercasedTag.hasPrefix("[CLICK:") {
            return .clickElement
        }
        if uppercasedTag.hasPrefix("[DRAG:") {
            return .dragElement
        }
        if uppercasedTag.hasPrefix("[SCROLLUP:") {
            return .describing(.up, distance: .screenfuls(screenfuls))
        }
        if uppercasedTag.hasPrefix("[SCROLLDOWN:") {
            return .describing(.down, distance: .screenfuls(screenfuls))
        }
        if uppercasedTag.hasPrefix("[SCROLLLEFT:") {
            return .describing(.left, distance: .screenfuls(screenfuls))
        }
        if uppercasedTag.hasPrefix("[SCROLLRIGHT:") {
            return .describing(.right, distance: .screenfuls(screenfuls))
        }
        return .lookAtElement
    }

    /// The 1-based screen number inside a tag, or nil when it named none — which means
    /// "wherever the cursor already is".
    private static func screenNumber(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> Int? {
        guard tagMatch.numberOfRanges >= 6,
              let screenRange = Range(tagMatch.range(at: 5), in: responseText) else {
            return nil
        }
        return Int(responseText[screenRange])
    }

    /// How many screenfuls a scroll tag asked for, clamped, defaulting to one for a tag that named
    /// no distance.
    ///
    /// Clamped here rather than where the events are built, because both ends of the range are
    /// meaningless rather than merely large: `:x0` is a tag that names a gesture doing nothing, and
    /// past the ceiling the count stops describing a distance anyone means. The prompt asks for one
    /// to three; this is what makes a model that writes `:x40` scroll rather than sit there.
    private static func screenfuls(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> Int {
        guard tagMatch.numberOfRanges >= 5,
              let screenfulsRange = Range(tagMatch.range(at: 4), in: responseText),
              let screenfuls = Int(responseText[screenfulsRange]) else {
            return 1
        }
        return min(max(screenfuls, 1), ElementScroller.mostScreenfulsInOneRequest)
    }

    /// Finds where the sentence that mentions the element begins, looking back from the tag.
    ///
    /// The tour sends the cursor on its way at that point rather than at the tag, because a tag follows
    /// the sentence describing its element: triggering on the tag would start the flight only once the
    /// model had finished talking about it. The scan steps over any run of sentence marks and spaces
    /// between the tag and the words before it, because the model usually writes the tag straight after
    /// the closing punctuation of its sentence — and without that step the scan would report where the
    /// *next* sentence begins.
    private static let sentenceEndingUTF16CodeUnits: Set<UInt16> = Set("。！？；，、\n!?,;".utf16)

    /// Everything that may sit between a sentence's end and the tag describing it: a sentence
    /// mark, any space around it, and a newline, which is already one of the marks.
    private static let sentenceTrailingUTF16CodeUnits: Set<UInt16> =
        CompanionManager.sentenceEndingUTF16CodeUnits.union(Set(" \t\r\u{3000}".utf16))

    /// The marks a sentence can end on and have itself be a finished thought.
    ///
    /// This is what lets a sentence that names no element still close a speech segment, so a preamble
    /// can be heard before the model has decided what to point at.
    ///
    /// The comma is deliberately not here even though `sentenceEndingUTF16CodeUnits` counts it: there
    /// it decides where a *stop's* sentence begins, a question about the cursor, while here it would
    /// decide where the voice may take a breath — and cutting a stop-less run of clauses at every comma
    /// spends the prosody on nobody's wait.
    private static let sentenceTerminatingUTF16CodeUnits: Set<UInt16> = Set("。！？；\n!?;".utf16)

    private static func sentenceStartOffset(inSpokenText spokenText: String, atOrBefore characterOffset: Int) -> Int {
        let spokenTextUTF16CodeUnits = Array(spokenText.utf16)
        var scanIndex = min(max(characterOffset, 0), spokenTextUTF16CodeUnits.count) - 1

        while scanIndex >= 0, Self.sentenceTrailingUTF16CodeUnits.contains(spokenTextUTF16CodeUnits[scanIndex]) {
            scanIndex -= 1
        }

        while scanIndex >= 0 {
            if Self.sentenceEndingUTF16CodeUnits.contains(spokenTextUTF16CodeUnits[scanIndex]) {
                return scanIndex + 1
            }
            scanIndex -= 1
        }
        return 0
    }

    /// Cuts the reply into sentences, as UTF-16 ranges that tile the whole of it. They are contiguous
    /// and lossless on purpose: a segment ends on a sentence boundary and the text either side is
    /// spoken by two different utterances, so a gap here would drop words and an overlap say them
    /// twice.
    private static func sentenceRanges(inSpokenText spokenText: String) -> [Range<Int>] {
        let spokenTextUTF16CodeUnits = Array(spokenText.utf16)
        guard !spokenTextUTF16CodeUnits.isEmpty else { return [] }

        var sentenceRanges: [Range<Int>] = []
        var sentenceStartOffset = 0
        for (codeUnitOffset, codeUnit) in spokenTextUTF16CodeUnits.enumerated() {
            guard Self.sentenceEndingUTF16CodeUnits.contains(codeUnit) else { continue }
            sentenceRanges.append(sentenceStartOffset..<(codeUnitOffset + 1))
            sentenceStartOffset = codeUnitOffset + 1
        }
        if sentenceStartOffset < spokenTextUTF16CodeUnits.count {
            sentenceRanges.append(sentenceStartOffset..<spokenTextUTF16CodeUnits.count)
        }
        return sentenceRanges
    }

    /// Which sentence a character offset falls in.
    ///
    /// An offset past the end of the last sentence reports the last sentence rather than nothing: a tag
    /// at the very end of a reply has its sentence start on the final character, and an offset resolving
    /// to no sentence would leave that stop with no segment to belong to.
    private static func sentenceIndex(containingOffset characterOffset: Int, among sentenceRanges: [Range<Int>]) -> Int {
        for (sentenceIndex, sentenceRange) in sentenceRanges.enumerated() {
            if sentenceRange.lowerBound > characterOffset {
                return max(0, sentenceIndex - 1)
            }
        }
        return sentenceRanges.count - 1
    }

    /// The slice of the reply's spoken text a UTF-16 range covers.
    private static func spokenTextSubstring(of spokenText: String, utf16Range: Range<Int>) -> String {
        let spokenTextUTF16View = spokenText.utf16
        let clampedLowerBound = min(max(utf16Range.lowerBound, 0), spokenTextUTF16View.count)
        let clampedUpperBound = min(max(utf16Range.upperBound, clampedLowerBound), spokenTextUTF16View.count)
        let sliceStartIndex = spokenTextUTF16View.index(spokenTextUTF16View.startIndex, offsetBy: clampedLowerBound)
        let sliceEndIndex = spokenTextUTF16View.index(spokenTextUTF16View.startIndex, offsetBy: clampedUpperBound)
        return String(decoding: spokenTextUTF16View[sliceStartIndex..<sliceEndIndex], as: UTF16.self)
    }

    /// Cuts the reply into the pieces the voice is handed one at a time.
    ///
    /// A sentence closes a segment for one of two reasons: it names a tour stop, in which case the next
    /// segment waits on the cursor getting through those stops, or it ends on a terminator and is not
    /// the last sentence, in which case nothing is waiting and holding the words gains nothing. The
    /// second is what lets a preamble be heard before the model has decided what to point at; a
    /// sentence that names nothing and does not end itself — the last sentence, and any run of clauses
    /// ending in a comma — is carried on to the next segment.
    ///
    /// The ranges tile the reply and index the *resolved* stops, since one whose screen is gone was
    /// dropped during resolution.
    private static func speechSegments(
        forSpokenText spokenText: String,
        resolvedPointingTourStops: [ResolvedPointingTourStop]
    ) -> [CompanionSpeechSegment] {
        let sentenceRanges = Self.sentenceRanges(inSpokenText: spokenText)
        guard !sentenceRanges.isEmpty else { return [] }
        let spokenTextUTF16CodeUnits = Array(spokenText.utf16)

        var speechSegments: [CompanionSpeechSegment] = []
        var speechSegmentStartOffset = 0
        var stopIndex = 0

        for (sentenceIndex, sentenceRange) in sentenceRanges.enumerated() {
            // Every stop this sentence names belongs to the segment it closes. They are
            // consecutive, because the model writes its tags in the order it talks about them.
            let firstStopIndexInThisSentence = stopIndex
            while stopIndex < resolvedPointingTourStops.count,
                  Self.sentenceIndex(
                      containingOffset: resolvedPointingTourStops[stopIndex].sentenceStartOffsetInSpokenText,
                      among: sentenceRanges
                  ) == sentenceIndex {
                stopIndex += 1
            }

            let doesThisSentenceNameStops = stopIndex > firstStopIndexInThisSentence
            // The last sentence is never cut on its own account, however it ends: the model may
            // still be writing it, so it is carried into the trailing segment.
            let isTheLastSentence = sentenceIndex == sentenceRanges.count - 1
            let doesThisSentenceEndItself = Self.sentenceTerminatingUTF16CodeUnits.contains(
                spokenTextUTF16CodeUnits[sentenceRange.upperBound - 1]
            )

            guard doesThisSentenceNameStops || (!isTheLastSentence && doesThisSentenceEndItself) else { continue }

            speechSegments.append(CompanionSpeechSegment(
                spokenText: Self.spokenTextSubstring(
                    of: spokenText,
                    utf16Range: speechSegmentStartOffset..<sentenceRange.upperBound
                ),
                startOffsetInSpokenText: speechSegmentStartOffset,
                stopIndexRange: firstStopIndexInThisSentence..<stopIndex
            ))
            speechSegmentStartOffset = sentenceRange.upperBound
        }

        // Whatever the model said after its last tag — a closing remark, a follow-up question —
        // is still part of the reply, and is the only part still being written.
        if speechSegmentStartOffset < spokenText.utf16.count {
            speechSegments.append(CompanionSpeechSegment(
                spokenText: Self.spokenTextSubstring(
                    of: spokenText,
                    utf16Range: speechSegmentStartOffset..<spokenText.utf16.count
                ),
                startOffsetInSpokenText: speechSegmentStartOffset,
                stopIndexRange: resolvedPointingTourStops.count..<resolvedPointingTourStops.count
            ))
        }

        return speechSegments
    }

    /// The tidy-up passes run over the assembled spoken text before it is spoken.
    ///
    /// What they take out is formatting rather than speech, and the synthesizer does not pass over it
    /// the way an eye does: it reads markdown marks out as words, and a blank line can make it cut a
    /// paragraph short while still reporting `didFinish`.
    ///
    /// Each pass has to be local — what it does at one character may only depend on the characters
    /// beside it — because `tidiedOffset(forRawOffset:…)` answers by tidying the raw text up to that
    /// offset and counting what is left; a pass whose match reaches past the offset reports a stop that
    /// silently never fires. That is also why a numbered list marker is left alone: a prefix cut between
    /// its two characters is a lone "1", equally a marker and a number.
    private static func tidiedSpokenText(_ text: String) -> String {
        text
            // Invisible and formatting-only characters, out wherever they sit. The markdown marks
            // among them are what the voice reads out as words. The price is a path losing its leading
            // tilde, which is a smaller thing to lose than a reply is to hear read aloud.
            .replacingOccurrences(
                of: "[\r\t\u{3000}\u{2028}\u{2029}\u{00A0}\u{200B}\u{FEFF}\u{00AD}\u{200E}\u{200F}*`#~>]",
                with: "",
                options: .regularExpression
            )
            // A paragraph break is a full stop to the ear, but only where the reply has not already
            // stopped: where it has, the mark that is there does the work.
            .replacingOccurrences(
                of: #"(?<=[。！？；，、!?,;.])\n+"#,
                with: "",
                options: .regularExpression
            )
            // Every other break, which is a paragraph of its own as far as the ear is concerned.
            .replacingOccurrences(
                of: #"(?<=[^\s])\n+"#,
                with: "。",
                options: .regularExpression
            )
            // Whatever is left of a break, which is one a reply opened with: a full stop before
            // the first word is not a pause the model asked for.
            .replacingOccurrences(of: #"\n+"#, with: "", options: .regularExpression)
            // Removing a tag leaves the spaces that used to sit either side of it facing.
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            // Deleting a tag written mid-sentence with the same mark on both sides of it makes the two
            // meet and read "。。", so an adjacent repeat of a mark never legitimately doubled is
            // collapsed. ！ and ？ are left alone because "！！" is deliberate.
            .replacingOccurrences(of: #"([。，、])\1"#, with: "$1", options: .regularExpression)
    }

    /// Maps an offset recorded while assembling the raw text onto the tidied text that actually gets
    /// spoken.
    ///
    /// The tidy passes delete characters, so an offset recorded before them drifts forward — and these
    /// offsets are the points where the narration pauses for the cursor, so one that has slipped past
    /// its sentence leaves the cursor flying only after the model has finished describing the element.
    /// Re-running the same tidy over the raw text preceding the offset keeps one copy of the rules.
    private static func tidiedOffset(forRawOffset rawOffset: Int, inRawText rawText: String, leadingWhitespaceUTF16UnitCount: Int) -> Int {
        let rawTextUTF16View = rawText.utf16
        let clampedRawOffset = min(max(rawOffset, 0), rawTextUTF16View.count)
        let rawPrefixEndIndex = rawTextUTF16View.index(rawTextUTF16View.startIndex, offsetBy: clampedRawOffset)
        let rawPrefix = String(decoding: rawTextUTF16View[..<rawPrefixEndIndex], as: UTF16.self)
        let tidiedPrefixUTF16UnitCount = Self.tidiedSpokenText(rawPrefix).utf16.count
        return max(0, tidiedPrefixUTF16UnitCount - leadingWhitespaceUTF16UnitCount)
    }

    /// Picks which of this turn's captures a point tag refers to: the screen the model named by number,
    /// or the screen the cursor is on when it named none — and also when it named one that is not
    /// connected any more.
    ///
    /// Returns a position rather than the capture because what comes back from the screen is keyed by
    /// that position.
    private static func screenIndex(forScreenNumber screenNumber: Int?, among screenCaptures: [CompanionScreenCapture]) -> Int? {
        if let screenNumber, screenNumber >= 1, screenNumber <= screenCaptures.count {
            return screenNumber - 1
        }
        return screenCaptures.firstIndex(where: { $0.isCursorScreen })
    }

    /// The coordinate to fly to for a stop — the centre of the on-screen text the model named, or the
    /// model's own coordinate when it named something with no text there — together with the rectangle
    /// that coordinate came from.
    ///
    /// The model's coordinate is a starting point rather than an answer: it reads a recognizable shape
    /// off an image essentially exactly, but a position it has to measure it estimates, and it estimates
    /// badly. What it can say reliably is what the thing is called, and the screen can say exactly where
    /// that is.
    private static func preciseScreenshotCoordinate(
        forModelScreenshotCoordinate modelScreenshotCoordinate: CGPoint,
        elementLabel: String?,
        amongRecognizedLines recognizedLines: [RecognizedTextLine],
        avoidingBoxesClaimedByEarlierStopsOnTheSameScreen claimedBoxes: [CGRect]
    ) -> (coordinate: CGPoint, matchedTextBox: CGRect?) {
        guard let matchedTextElementBox = ScreenshotTextElementMatcher.elementBox(
            matchingElementLabel: elementLabel,
            nearScreenshotCoordinate: modelScreenshotCoordinate,
            amongRecognizedLines: recognizedLines,
            avoidingBoxesClaimedByEarlierStopsOnTheSameScreen: claimedBoxes
        ) else {
            return (coordinate: modelScreenshotCoordinate, matchedTextBox: nil)
        }
        return (
            coordinate: CGPoint(x: matchedTextElementBox.midX, y: matchedTextElementBox.midY),
            matchedTextBox: matchedTextElementBox
        )
    }

    /// Converts a coordinate the model read off a screenshot into the global screen location the
    /// cursor overlay flies to, along with the display frame it is on.
    private static func screenLocation(
        forScreenshotCoordinate screenshotCoordinate: CGPoint,
        on screenCapture: CompanionScreenCapture
    ) -> (screenLocation: CGPoint, displayFrame: CGRect) {
        // The screen's pixel space (top-left origin, e.g. 1280x800), then scale to the display's point
        // space (e.g. 1440x900), then convert to AppKit global coords.
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame


        let clampedX = max(0, min(screenshotCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(screenshotCoordinate.y, screenshotHeight))


        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY


        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        return (screenLocation: globalLocation, displayFrame: displayFrame)
    }

    /// Clears the last reply out of the way and gets ready to receive a new one.
    ///
    /// Called before the request goes out, not after it returns, because the reply is spoken while it is
    /// still arriving — the first chunk carrying a finished clause is handed to the voice from inside the
    /// streaming callback, so there is no single moment afterwards at which the whole reply could be set
    /// up at once. The narration still paces the tour rather than the other way round.
    ///
    /// The panel keeps showing the spinner across this, which is what the user is owed for a wait on
    /// the model: the new turn's facts are already armed by the caller, so the state they derive is
    /// the one that was showing a moment ago.
    private func beginStreamingReply(
        screenCaptures: [CompanionScreenCapture],
        recognizedTextLinesTasks: [Task<[RecognizedTextLine], Never>]
    ) {
        endPointingTour()
        // `false` because this runs inside the new turn, not at the end of the old one: the
        // caller has already armed this turn's facts.
        abandonSpeakingReply(settlingTheVoiceState: false)

        streamingReplySegmenter = StreamingReplySegmenter(
            screenCaptures: screenCaptures,
            recognizedTextLinesTasks: recognizedTextLinesTasks
        )
        isReplyStreamComplete = false
        finalizedSpeechSegmentCount = 0
        isPointingTourActive = false
        // The turn that just ended has been written into the history by whoever ended it; this
        // is where the next turn's own record starts.
        hasWrittenTheCurrentTurnIntoHistory = false

        // A length from the last turn is not this turn's, and two replies of the same length would
        // otherwise leave the terminal with the first chunk of this one missing.
        rawReplyUTF16CountLastSentToTerminal = -1
    }

    /// Feeds the reply as far as it has been written to the segmenter, and acts on what that settled.
    ///
    /// Awaited from inside the streaming callback, which puts it on the critical path of reading the
    /// response — so the one thing it can wait on is screen text recognition, which is started before
    /// the request goes out for exactly that reason.
    private func absorbStreamedReplyText(
        _ accumulatedRawText: String,
        fromTurnIdentifiedBy turnIdentifier: UUID
    ) async {
        // Cancelling a task stops it delivering, but not instantly and not as a promise: the read can be
        // suspended in its `await` and resume with one more chunk after the next turn has begun, and the
        // turn's identity is the only thing that tells the two apart.
        guard turnIdentifier == turnIdentifierOfTheReplyBeingStreamed else { return }
        guard let streamingReplySegmenter else { return }

        let ingest = await streamingReplySegmenter.absorb(accumulatedRawText: accumulatedRawText)

        // Asked of the segmenter rather than read off the ingest, because the early-out means most
        // chunks produce none — and `absorb` records what arrived before it decides, so this is the
        // reply as it stands either way. Gated on a terminal actually watching: the answer costs a
        // full parse of the whole reply, which is the very thing the early-out exists to skip.
        if commandSocketServer.hasATerminalWatchingTheReply {
            sendTheReplyAsItStandsToTheTerminal(accumulatedRawText: accumulatedRawText)
        }

        // A skipped pass applies nothing: everything `applyStreamedReplyIngest` does is a
        // function of what a full pass changes, and here nothing changed.
        guard let ingest else { return }

        applyStreamedReplyIngest(ingest)
    }

    /// The reply has stopped arriving; everything still held is released.
    ///
    /// Until it runs the last segment is withheld, so a reply whose finalised segments have all been
    /// spoken is still waiting here rather than finishing.
    private func concludeStreamedReply(fullRawText: String, fromTurnIdentifiedBy turnIdentifier: UUID) async {
        // The same identity check as `absorbStreamedReplyText`, and it matters more: a stale turn
        // reaching this line would declare the *new* reply complete and release its last segment early.
        guard turnIdentifier == turnIdentifierOfTheReplyBeingStreamed else { return }
        guard let streamingReplySegmenter else { return }

        isReplyStreamComplete = true
        applyStreamedReplyIngest(await streamingReplySegmenter.conclude(accumulatedRawText: fullRawText))

        // Cannot be left to the teardown that runs when the next question arrives: that teardown reads
        // the history before the reply it replaces could have been added, so every reply would reach the
        // model one turn late.
        writeTheCurrentTurnIntoHistory(interruption: nil)

        // After the history write, so the terminal is told the turn is over at the same moment the
        // record of it becomes complete. `conclude` has already recorded the full text, so this is
        // the finished reply and not one chunk short of it.
        commandSocketServer.send(.done(spokenText: streamingReplySegmenter.spokenTextAsItStands()))
    }

    /// Hands a terminal watching the reply the text as it stands, so far.
    ///
    /// Skipped while the raw text has not moved, which is most chunks: the answer costs a whole
    /// re-parse of the reply, and the total arrives only ever growing, so an unchanged length
    /// means an unchanged answer.
    private func sendTheReplyAsItStandsToTheTerminal(accumulatedRawText: String) {
        let accumulatedRawTextUTF16Count = accumulatedRawText.utf16.count
        guard accumulatedRawTextUTF16Count != rawReplyUTF16CountLastSentToTerminal else { return }
        rawReplyUTF16CountLastSentToTerminal = accumulatedRawTextUTF16Count

        guard let streamingReplySegmenter else { return }
        commandSocketServer.send(.text(spokenTextSoFar: streamingReplySegmenter.spokenTextAsItStands()))
    }

    /// Takes what the segmenter made of the reply so far.
    private func applyStreamedReplyIngest(_ ingest: StreamedReplyIngest) {
        speechSegments = ingest.speechSegments
        finalizedSpeechSegmentCount = ingest.finalizedSpeechSegmentCount

        // Handed to the synthesizer whether or not they can be spoken yet: synthesis is what the
        // streaming design moved into the generation window, so the audio is in hand when it is asked for.
        // Skipped for a reply nobody will hear, where the synthesis would be waited for and never played.
        if isReadingTheReplyAloud {
            for settledSegment in ingest.segmentsToSynthesise {
                ttsClient.prepareSpeechSegment(
                    spokenText: settledSegment.spokenText,
                    segmentIndex: settledSegment.segmentIndex
                )
            }
        }

        if !ingest.newlyResolvedPointingTourStops.isEmpty {
            resolvedPointingTourStops = ingest.allResolvedPointingTourStops

            // The first tag is what makes this a tour.
            //
            // Deliberately not a state change: a tag resolving is not a sound. The segment the tag sits in
            // has not been cut yet, let alone synthesised, so `.idle` here would put the triangle on screen
            // over a reply with nothing to hear — and `.processing` means "no sound yet", which only the
            // sound itself may end.
            if !isPointingTourActive {
                isPointingTourActive = true
                schedulePointingTourStallWatchdog()
            }

            for newlyResolvedStop in ingest.newlyResolvedPointingTourStops {
                print("🎯 Element pointing: (\(Int(newlyResolvedStop.screenshotCoordinate.x)), \(Int(newlyResolvedStop.screenshotCoordinate.y))) → \"\(newlyResolvedStop.elementLabel ?? "element")\"")
            }
        }

        // Asked on every ingest that ran, because the two events are not the same one: a segment that
        // became final after the one before it was spoken through has no word and no arrival left to come
        // back for it, so every event that changes the answer has a call site of its own.
        if isSpeakingReply {
            continuePointingTourIfPossible()
        } else {
            speakCurrentSpeechSegment()
        }
    }

    /// What one pass over the reply so far settled.
    ///
    /// The segments are handed back whole rather than as a delta because they are recomputed from the
    /// text on every chunk, and a delta would be a second description that could disagree with the first.
    private struct StreamedReplyIngest {
        /// Every segment the reply holds so far, recomputed from the text just ingested.
        let speechSegments: [CompanionSpeechSegment]
        /// How many of those the model can no longer change; see `StreamingReplySegmenter.ingest`.
        let finalizedSpeechSegmentCount: Int
        /// The segments that have just become final, with the index each will be spoken under.
        let segmentsToSynthesise: [(segmentIndex: Int, spokenText: String)]
        /// The stops whose tags have just closed and whose screen locations have just been
        /// worked out, in the order they must be flown to.
        let newlyResolvedPointingTourStops: [ResolvedPointingTourStop]
        /// Every stop resolved so far, in the same order, for the caller's own copy.
        let allResolvedPointingTourStops: [ResolvedPointingTourStop]
    }

    /// Cuts the reply into speech segments while it is still being written.
    ///
    /// Each chunk is folded into a growing document that is re-parsed from the top — deliberately,
    /// because the tag parsing, the tidy passes and the sentence scan are one implementation each, and
    /// this way there is no second, incremental copy of them to drift.
    ///
    /// Redoing the work is only sound because every pass between the raw text and the segments is
    /// prefix-stable: tidying a prefix gives the same characters as tidying the whole and cutting, and so
    /// does the sentence scan, so a segment cut from an earlier, shorter document is the same segment in
    /// the longer one. The one approximation is that the tail is provisional, so the cut decisions are
    /// monotone and the last segment is held back until the text moves past it.
    private final class StreamingReplySegmenter {
        private let screenCaptures: [CompanionScreenCapture]
        private let recognizedTextLinesTasks: [Task<[RecognizedTextLine], Never>]

        /// The raw reply as it stands, with any half-written tag dropped off the end.
        private var accumulatedRawText = ""

        /// The reply as the voice will read it, tidied and with every tag stripped. Read after the
        /// stream ends so the diagnostic record can carry it beside the raw text.
        private(set) var spokenText = ""

        /// Every tag the model has closed so far, in the order it wrote them. Kept because the diagnostic
        /// record wants the coordinates before any of this app's arithmetic touched them.
        private(set) var parsedTourStops: [CompanionManager.PointingTourStop] = []

        private(set) var resolvedPointingTourStops: [CompanionManager.ResolvedPointingTourStop] = []

        /// How many of `parsedTourStops` have been through resolution. Stops are only ever appended, so a
        /// tag seen on an earlier chunk is never resolved twice.
        private var resolvedTourStopCount = 0

        /// The pieces of on-screen text earlier stops have already been given, one list per screen: a stop
        /// resolves against the recognition of its own display, so two stops on two displays naming the
        /// same thing do not compete for one piece of text.
        private var claimedTextBoxesPerScreen: [[CGRect]]

        /// How many segments have been handed to the synthesizer; never more than
        /// `finalizedSpeechSegmentCount`, which only ever grows.
        private var handedOverSpeechSegmentCount = 0

        /// The raw reply exactly as the last chunk delivered it, half-written tag and all.
        ///
        /// Kept beside `accumulatedRawText` because the early-out means most chunks are not folded in, so
        /// the reply as it stands has to be askable for without a pass having run over it — and the history
        /// is what asks, at the moment a question replaces the reply.
        private var rawTextAsReceived = ""

        /// The raw text as of the last pass that ran the whole pipeline. What arrived since is
        /// the part the early-out scans.
        private var rawTextAsOfTheLastFullIngest = ""

        /// Whether one more character arriving on its own could make a finished sentence out of what the
        /// reply already ends on.
        ///
        /// The third of the three things that can change what a pass answers, and the one a scan of the
        /// arriving characters cannot see: `finalizedSpeechSegmentCount` wants a segment's end *strictly*
        /// inside the text, so "你好。" has nothing final in it and any next character pushes that end
        /// inside and hands the sentence to the voice.
        private var couldOneMoreCharacterCloseASentence = true

        init(
            screenCaptures: [CompanionScreenCapture],
            recognizedTextLinesTasks: [Task<[RecognizedTextLine], Never>]
        ) {
            self.screenCaptures = screenCaptures
            self.recognizedTextLinesTasks = recognizedTextLinesTasks
            self.claimedTextBoxesPerScreen = Array(repeating: [], count: screenCaptures.count)
        }

        /// Folds in the reply as far as it has been written. The tail stays provisional.
        ///
        /// `nil` means what arrived cannot have changed anything the last pass settled. The early-out lives
        /// here rather than inside `ingest` so that `conclude`, which must never take it, cannot reach it.
        func absorb(accumulatedRawText: String) async -> StreamedReplyIngest? {
            rawTextAsReceived = accumulatedRawText

            guard couldTheIngestAnswerHaveChanged(withIncomingRawText: accumulatedRawText) else { return nil }

            return await ingest(accumulatedRawText: accumulatedRawText, isReplyComplete: false)
        }

        /// Folds in the finished reply. Nothing is held back any more.
        func conclude(accumulatedRawText: String) async -> StreamedReplyIngest {
            rawTextAsReceived = accumulatedRawText
            return await ingest(accumulatedRawText: accumulatedRawText, isReplyComplete: true)
        }

        /// Whether the text that has arrived since the last full pass could change what another one would
        /// answer.
        ///
        /// Three things can, and only three. A `]` closes a tag, and a tag is both a stop and a cut. A
        /// sentence mark moves a sentence boundary, and a comma counts even though it closes no segment —
        /// it does end a sentence, and one landing after the tail's last word takes the trailing segment
        /// away. And a reply already sitting on a finished sentence has a segment half-finalised, which is
        /// the state `couldOneMoreCharacterCloseASentence` needs and the reason this cannot be a pure scan
        /// of the new characters.
        ///
        /// The set scanned for is the wider `sentenceEndingUTF16CodeUnits` rather than the
        /// `sentenceTerminating` one the cut decisions use, because the question here is whether a boundary
        /// moved, which a comma does, and the tidy can invent a full stop out of newlines.
        private func couldTheIngestAnswerHaveChanged(withIncomingRawText incomingRawText: String) -> Bool {
            guard !couldOneMoreCharacterCloseASentence else { return true }

            let rawTextAsOfTheLastFullIngestUTF16Count = rawTextAsOfTheLastFullIngest.utf16.count
            guard incomingRawText.utf16.count >= rawTextAsOfTheLastFullIngestUTF16Count else { return true }

            let arrivedSinceUTF16View = incomingRawText.utf16.dropFirst(rawTextAsOfTheLastFullIngestUTF16Count)
            return arrivedSinceUTF16View.contains { codeUnit in
                codeUnit == UInt16(UInt8(ascii: "]"))
                    || CompanionManager.sentenceEndingUTF16CodeUnits.contains(codeUnit)
            }
        }

        /// The reply as the voice would read it, worked out from the raw text as it stands rather than read
        /// off the last full pass.
        ///
        /// `spokenText` is only as fresh as that pass and the early-out means most chunks do not run one, so
        /// anything that has to hold *everything* that arrived has to ask afresh. The history is the one
        /// thing that does.
        func spokenTextAsItStands() -> String {
            CompanionManager.parsePointingCoordinates(
                from: Self.droppingAHalfWrittenTag(from: rawTextAsReceived)
            ).spokenText
        }

        private func ingest(accumulatedRawText incomingRawText: String, isReplyComplete: Bool) async -> StreamedReplyIngest {
            accumulatedRawText = Self.droppingAHalfWrittenTag(from: incomingRawText)

            // `parsePointingCoordinates` is the whole of the post-processing a reply gets, and calling it
            // rather than reimplementing it is the point: it strips every tag, computes each stop's
            // sentence offset, and tidies the result — all of them prefix-stable.
            let parseResult = CompanionManager.parsePointingCoordinates(from: accumulatedRawText)
            spokenText = parseResult.spokenText
            parsedTourStops = parseResult.tourStops

            await resolveNewTourStops(startingAt: resolvedTourStopCount)
            let newlyResolvedStops = resolvedPointingTourStops.suffix(resolvedPointingTourStops.count - resolvedTourStopCount)
            resolvedTourStopCount = resolvedPointingTourStops.count

            let speechSegments = CompanionManager.speechSegments(
                forSpokenText: spokenText,
                resolvedPointingTourStops: resolvedPointingTourStops
            )
            let finalizedSpeechSegmentCount = Self.finalizedSpeechSegmentCount(
                in: speechSegments,
                spokenTextUTF16UnitCount: spokenText.utf16.count,
                isReplyComplete: isReplyComplete
            )

            let segmentsToSynthesise = speechSegments[handedOverSpeechSegmentCount..<finalizedSpeechSegmentCount]
                .enumerated()
                .map { offset, speechSegment in
                    (segmentIndex: handedOverSpeechSegmentCount + offset, spokenText: speechSegment.spokenText)
                }
            handedOverSpeechSegmentCount = finalizedSpeechSegmentCount

            // The raw text is recorded whole, half-written tag and all, because it is the next
            // pass's own input that the arriving part is measured against.
            rawTextAsOfTheLastFullIngest = incomingRawText
            couldOneMoreCharacterCloseASentence =
                spokenText.utf16.last.map { CompanionManager.sentenceTerminatingUTF16CodeUnits.contains($0) } ?? true

            return StreamedReplyIngest(
                speechSegments: speechSegments,
                finalizedSpeechSegmentCount: finalizedSpeechSegmentCount,
                segmentsToSynthesise: segmentsToSynthesise,
                newlyResolvedPointingTourStops: Array(newlyResolvedStops),
                allResolvedPointingTourStops: resolvedPointingTourStops
            )
        }

        /// Turns the tags that have closed since the last pass into screen locations.
        ///
        /// The one thing on this path that can take a moment is screen text recognition, and it was started
        /// before the request went out, so it has almost always finished by the time a tag is written.
        private func resolveNewTourStops(startingAt firstUnresolvedStopIndex: Int) async {
            guard firstUnresolvedStopIndex < parsedTourStops.count else { return }

            for parsedStopIndex in firstUnresolvedStopIndex..<parsedTourStops.count {
                let tourStop = parsedTourStops[parsedStopIndex]
                guard let screenIndex = CompanionManager.screenIndex(
                    forScreenNumber: tourStop.screenNumber,
                    among: screenCaptures
                ) else { continue }
                let screenCapture = screenCaptures[screenIndex]
                let recognizedTextLines = await recognizedTextLinesTasks[screenIndex].value

                let precisePosition = CompanionManager.preciseScreenshotCoordinate(
                    forModelScreenshotCoordinate: tourStop.screenshotCoordinate,
                    elementLabel: tourStop.elementLabel,
                    amongRecognizedLines: recognizedTextLines,
                    avoidingBoxesClaimedByEarlierStopsOnTheSameScreen: claimedTextBoxesPerScreen[screenIndex]
                )
                let screenshotCoordinate = precisePosition.coordinate
                // Only a stop that resolved against the screen has text to claim; one that fell
                // back to the model's own coordinate matched nothing.
                if let matchedTextBox = precisePosition.matchedTextBox {
                    claimedTextBoxesPerScreen[screenIndex].append(matchedTextBox)
                }

                let resolvedLocation = CompanionManager.screenLocation(
                    forScreenshotCoordinate: screenshotCoordinate,
                    on: screenCapture
                )
                // A drag's destination is converted against the same capture the starting point was
                // — `screenCapture`, the one the stop's own `:screenN` picked — so the two ends of
                // one movement cannot land on two different displays.
                let dragDestinationScreenLocation = tourStop.dragDestinationScreenshotCoordinate.map {
                    CompanionManager.screenLocation(forScreenshotCoordinate: $0, on: screenCapture).screenLocation
                }

                resolvedPointingTourStops.append(CompanionManager.ResolvedPointingTourStop(
                    screenshotCoordinate: screenshotCoordinate,
                    screenLocation: resolvedLocation.screenLocation,
                    displayFrame: resolvedLocation.displayFrame,
                    elementLabel: tourStop.elementLabel,
                    sentenceStartOffsetInSpokenText: tourStop.sentenceStartOffsetInSpokenText,
                    pointingBubbleInvitation: tourStop.pointingBubbleInvitation,
                    dragDestinationScreenLocation: dragDestinationScreenLocation
                ))
            }
        }

        /// How many of the segments the model can no longer change.
        ///
        /// The segments tile the text in order, so that is every segment but the last one, if the last one
        /// is where the text stops. It is a count rather than a flag because the caller needs the ones that
        /// have just crossed the line, not those handed over earlier.
        ///
        /// Only the sentence the tail belongs to can be rewritten by a later chunk, which is what makes
        /// this safe: a segment ending before the text does cannot be extended, merged with the next, or
        /// lose its place to a tag not yet written.
        private static func finalizedSpeechSegmentCount(
            in speechSegments: [CompanionSpeechSegment],
            spokenTextUTF16UnitCount: Int,
            isReplyComplete: Bool
        ) -> Int {
            guard !isReplyComplete else { return speechSegments.count }
            return speechSegments.prefix { speechSegment in
                speechSegment.startOffsetInSpokenText + speechSegment.spokenText.utf16.count < spokenTextUTF16UnitCount
            }.count
        }

        /// Drops a tag the model is part-way through writing.
        ///
        /// A tag that has not closed is not a tag to the parser — it is ordinary characters, and the
        /// punctuation inside it is read as punctuation the model wrote, so a chunk ending in
        /// `[POINT:322,192:已发表。` would cut a segment at that full stop and have the voice read the
        /// half-written tag out.
        ///
        /// The cut is at the *first* bracket that is never closed, not the last, which is what makes this
        /// safe on every chunk of a growing document: text that only grows can only close brackets, so the
        /// set of never-closed ones only shrinks and its smallest element only moves forward. Cutting at
        /// the last one would let the truncation point move backwards the moment a second `[` was written.
        private static func droppingAHalfWrittenTag(from accumulatedRawText: String) -> String {
            let codeUnits = Array(accumulatedRawText.utf16)

            // A bracket is unclosed exactly when it sits after the last closing bracket there is,
            // so the search needs no bracket-matching of its own.
            let lastClosingBracketOffset = codeUnits.lastIndex(of: UInt16(UInt8(ascii: "]"))) ?? -1
            guard let unclosedBracketOffset = codeUnits[(lastClosingBracketOffset + 1)...]
                .firstIndex(of: UInt16(UInt8(ascii: "["))) else {
                return accumulatedRawText
            }
            return String(decoding: codeUnits[..<unclosedBracketOffset], as: UTF16.self)
        }
    }

    /// Drops any tour in progress.
    ///
    /// Speech is deliberately left alone: a tour ending says the cursor is finished pointing, not that the
    /// reply is finished being spoken.
    private func endPointingTour() {
        pointingTourNarrationResumeTimeoutTask?.cancel()
        pointingTourNarrationResumeTimeoutTask = nil
        pointingTourNarrationFallbackTask?.cancel()
        pointingTourNarrationFallbackTask = nil
        pointingTourDwellCompletionTask?.cancel()
        pointingTourDwellCompletionTask = nil
        pointingTourReturnHomeTimeoutTask?.cancel()
        pointingTourReturnHomeTimeoutTask = nil
        pointingTourStallWatchdogTask?.cancel()
        pointingTourStallWatchdogTask = nil
        resolvedPointingTourStops = []
        nextPointingTourStopIndex = 0
        isFlyingToPointingTourStop = false
        isPointingTourActive = false
        hasNarrationReportedAnyWords = false
        lastNarrationProgressDate = nil
        lastPointingTourStopArrivalDate = nil
        shouldReturnBuddyToCursorAfterPointing = false
        // No stop is left to be pressed, so the press is withdrawn from the target the cursor is
        // standing on. Only that field: the cursor is left where it is until the tour's return-home
        // timeout takes it back, and clearing the target outright would read as a flight to nil.
        pointingTarget?.actionToPerformOnArrival = nil
    }

    /// The stop the tour is on, or nil once every stop has been visited.
    private var nextPointingTourStop: ResolvedPointingTourStop? {
        guard nextPointingTourStopIndex < resolvedPointingTourStops.count else { return nil }
        return resolvedPointingTourStops[nextPointingTourStopIndex]
    }

    // MARK: - Speaking The Reply One Segment At A Time

    /// The stops the segment being spoken names, as a range into `resolvedPointingTourStops`.
    /// Empty once every segment has been spoken.
    private var currentSpeechSegmentStopIndexRange: Range<Int> {
        guard currentSpeechSegmentIndex < speechSegments.count else {
            return resolvedPointingTourStops.count..<resolvedPointingTourStops.count
        }
        return speechSegments[currentSpeechSegmentIndex].stopIndexRange
    }

    /// Where in the reply's spoken text the segment being spoken starts, which is what converts
    /// the voice's own offsets back into positions in the reply.
    private var currentSpeechSegmentStartOffsetInSpokenText: Int {
        guard currentSpeechSegmentIndex < speechSegments.count else { return 0 }
        return speechSegments[currentSpeechSegmentIndex].startOffsetInSpokenText
    }

    /// How much longer the cursor has to stay on the stop it landed on before it may leave.
    /// Zero once the minimum dwell has been served, and zero when it has not landed on anything.
    private var remainingPointingTourStopDwellSeconds: Double {
        guard let lastPointingTourStopArrivalDate else { return 0 }
        return minimumPointingTourStopDwellSeconds - Date().timeIntervalSince(lastPointingTourStopArrivalDate)
    }

    /// Moves the reply forward as far as it can go right now.
    ///
    /// Everything that could change the answer runs through here — a word spoken, a segment spoken through,
    /// the cursor landing, a dwell running out — because the two halves of the coordination are one
    /// question asked in a fixed order: the cursor has first refusal on every word, and only once it is
    /// finished with the current segment is the next one handed over.
    private func continuePointingTourIfPossible() {
        if let pointingTourStopTheNarrationHasReached = stopTheNarrationHasReachedInCurrentSpeechSegment() {
            startFlightToPointingTourStop(pointingTourStopTheNarrationHasReached)
            return
        }
        advanceSpeechIfPossible()
    }

    /// The stop the narration has got as far as naming in the segment being spoken, or nil when it names
    /// none the cursor has not already been sent to.
    ///
    /// Every stop a segment names sits in its last sentence, which is what lets one test cover them all,
    /// and the comparison is one-sided: a stop whose trigger went by while a flight was in the air is
    /// picked up by the next word rather than skipped.
    ///
    /// A segment spoken through counts as having reached its stops whether or not a word callback said so,
    /// because being spoken through means it was heard and the synthesizer genuinely skips reporting those
    /// words. So does a narration that has gone silent, where no word is coming at all.
    private func stopTheNarrationHasReachedInCurrentSpeechSegment() -> ResolvedPointingTourStop? {
        guard isPointingTourActive,
              !isFlyingToPointingTourStop,
              !shouldReturnBuddyToCursorAfterPointing,
              remainingPointingTourStopDwellSeconds <= 0,
              nextPointingTourStopIndex < currentSpeechSegmentStopIndexRange.upperBound,
              let pointingTourStop = nextPointingTourStop else { return nil }

        let narrationHasReachedTheStop = lastNarrationWordEndOffsetInSpokenText > pointingTourStop.sentenceStartOffsetInSpokenText
        let speechSegmentHasBeenSpokenThrough = hasCurrentSpeechSegmentFinishedSpeaking
        guard narrationHasReachedTheStop || speechSegmentHasBeenSpokenThrough || hasTheNarrationGoneSilent else {
            return nil
        }
        return pointingTourStop
    }

    /// Speaks the next segment if both sides are ready for it.
    ///
    /// The words are the first half: a segment not spoken through has nothing to release. The cursor is the
    /// second, and it is the one that makes the reply wait — until it has stood on the element for its
    /// minimum dwell, the next segment is simply never handed to the voice.
    ///
    /// A silent narration is waited out here rather than short-circuited, because the report this needs is
    /// not the one it stopped sending: the voice that reports no words still reports the segment finished,
    /// audio or none, and releasing on the words alone would cut a segment off mid-sentence.
    private func advanceSpeechIfPossible() {
        guard isSpeakingReply, hasCurrentSpeechSegmentFinishedSpeaking else { return }
        guard hasPointerFinishedWithCurrentSpeechSegment() else { return }

        currentSpeechSegmentIndex += 1
        speakCurrentSpeechSegment()
    }

    /// Whether the cursor has nothing left to do about the segment being spoken.
    private func hasPointerFinishedWithCurrentSpeechSegment() -> Bool {
        // Nothing to point at, or the pointing is over: what is left to say has nothing to wait for.
        guard isPointingTourActive, !shouldReturnBuddyToCursorAfterPointing else { return true }
        guard !isFlyingToPointingTourStop else { return false }
        guard nextPointingTourStopIndex >= currentSpeechSegmentStopIndexRange.upperBound else { return false }

        // Every stop this segment names has been reached, so all that is left is the last dwell.
        return remainingPointingTourStopDwellSeconds <= 0
    }

    /// Hands the current segment to the voice, or ends the reply when there are none left.
    ///
    /// Returning immediately is deliberate: this is reached from inside the voice's own callbacks, and
    /// waiting there for the next segment to be spoken through would block the callback that would have
    /// said it had been.
    ///
    /// Two waits meet here: `finalizedSpeechSegmentCount`, so a segment the model may still be writing is
    /// never handed over, and the one inside the TTS client for a segment whose synthesis has not finished.
    private func speakCurrentSpeechSegment() {
        guard currentSpeechSegmentIndex < speechSegments.count else {
            // Reaching the end of the segments is not the end of the reply while more may still
            // be written — it is an empty waiting room.
            guard isReplyStreamComplete else { return }
            finishSpeakingReply()
            return
        }
        guard currentSpeechSegmentIndex < finalizedSpeechSegmentCount else { return }

        let speechSegmentIndex = currentSpeechSegmentIndex

        hasCurrentSpeechSegmentFinishedSpeaking = false
        lastSpokenWordEndOffsetInCurrentSpeechSegment = 0
        isSpeakingReply = true
        // `voiceState` follows from that write alone: a segment handed over is not yet a sound, so a
        // reply still waiting for its first one stays `.processing` — see `voiceStateTheFactsSupport`.

        guard isReadingTheReplyAloud else {
            // Nothing was handed to a voice, so no callback will ever report this segment spoken
            // through and the tour would wait on a word that is not coming. The cursor paces the
            // reply instead: the segment counts as spoken through the moment it is reached, and the
            // stops it names are visited one at a time, each held for its dwell.
            //
            // Not wrapped in a `Task` like the branch below: there is nothing to await here, and a
            // hop would make this and the `continuePointingTourIfPossible()` at the end of
            // `applyStreamedReplyIngest` land in an unpredictable order.
            markCurrentSpeechSegmentAsSpokenThrough()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.ttsClient.speakPreparedSegment(segmentIndex: speechSegmentIndex)
            // The index is re-checked because a reply that arrived in the meantime has taken the
            // voice, and this segment is no longer part of what is being said.
            guard self.isSpeakingReply, self.currentSpeechSegmentIndex == speechSegmentIndex else { return }
            // Armed once, on the first segment: it asks whether this voice has said anything at
            // all, and by the end of the first segment the answer is in.
            if speechSegmentIndex == 0 {
                self.schedulePointingTourFallbackIfNarrationIsSilent()
            }
        }
    }

    /// Marks the reply as spoken through. Nothing is left for the cursor to wait on, so it takes the same
    /// route home a single point does.
    ///
    /// The turn ends here rather than where the response task's `await` returns, because the reply has
    /// finished arriving while its segments are still being spoken. Clearing the three facts is what
    /// returns the panel to 等待中, and it has to happen here: the reply's own arrival is long past, so
    /// nothing else is left that would.
    private func finishSpeakingReply() {
        isSpeakingReply = false
        isWaitingForTheFirstSoundOfTheReply = false
        isProducingAReply = false
        if isPointingTourActive {
            shouldReturnBuddyToCursorAfterPointing = true
        }
        requestBuddyReturnHome()
    }

    /// Tells the cursor to come home and resume following, on every screen.
    ///
    /// Raised wherever the reply the cursor was pointing for is over, whether it finished, was cut off or
    /// failed: in all three the cursor has nothing left to stand on, and the state it is in suspends cursor
    /// tracking entirely.
    private func requestBuddyReturnHome() {
        buddyReturnHomeRequestCount += 1
    }

    /// What cut a reply short, and therefore what the history entry says about it.
    ///
    /// The two are kept apart because they tell the model different things: one says the user did not want
    /// to hear the rest, the other says Kiki never finished writing it.
    private enum ReplyInterruption {
        case theUserStartedANewQuestion
        case theReplyFailedPartWayThrough

        /// Appended to the assistant's half of the entry, in Chinese like the reply the model
        /// reads back, and on its own paragraph so it cannot be read as part of the sentence before.
        var markerAppendedToTheHistoryEntry: String {
            switch self {
            case .theUserStartedANewQuestion:
                return "\n\n（这条回复被用户打断了，没有说完）"
            case .theReplyFailedPartWayThrough:
                return "\n\n（这条回复出错了，没有说完）"
            }
        }
    }

    /// Writes the turn that is ending into the history the next request is built from.
    ///
    /// Called from three places, because a reply can end in three ways that are not the same call stack:
    /// the reply finishing, the teardown for one the next question cut off, and the `catch` for one that
    /// failed. `hasWrittenTheCurrentTurnIntoHistory` keeps it to one entry per turn.
    ///
    /// What is written is the *spoken* text, with every tag stripped: the raw text carries coordinates read
    /// off a screenshot that is already gone, and a history full of those teaches the model to point at
    /// last turn's screen.
    private func writeTheCurrentTurnIntoHistory(interruption: ReplyInterruption?) {
        guard !hasWrittenTheCurrentTurnIntoHistory else { return }

        // An interrupted reply is recorded as far as it got, and for one cut off before its first word that
        // is nowhere: an empty assistant message would teach the model that answering with nothing works.
        let replyAsItStands = streamingReplySegmenter?.spokenTextAsItStands() ?? ""
        guard !replyAsItStands.isEmpty else { return }

        hasWrittenTheCurrentTurnIntoHistory = true
        conversationHistory.append((
            userTranscript: transcriptOfTheTurnBeingAnswered,
            assistantResponse: replyAsItStands
                + (interruption?.markerAppendedToTheHistoryEntry ?? "")
        ))

        // Where the history is actually bounded by `maximumExchangeCountCarriedInHistory`.
        if conversationHistory.count > Self.maximumExchangeCountCarriedInHistory {
            conversationHistory.removeFirst(
                conversationHistory.count - Self.maximumExchangeCountCarriedInHistory
            )
        }

        print("🧠 History \(conversationHistory.count) exchange(s) — 问 "
              + "\(transcriptOfTheTurnBeingAnswered.count) 字 / 答 \(replyAsItStands.count) 字"
              + (interruption == nil ? "" : "（中断）"))
    }

    /// Writes off the reply being spoken. For a reply that was replaced, or one the app is done with — the
    /// voice itself is stopped by the caller.
    ///
    /// The tour is left alone, since it can outlive the reply while the cursor flies home, but the
    /// segmenter is dropped: a reply written off has nothing further to ingest, and its accumulated text is
    /// the one thing here that grows without bound. The cursor *is* sent home from here, because a reply
    /// that failed or was replaced reaches only this path.
    ///
    /// - Parameter settlingTheVoiceState: Whether writing the reply off also ends the turn the panel shows.
    ///   False only for `beginStreamingReply`, which runs inside the new turn, where the caller has already
    ///   armed this turn's facts; clearing them here would put the spinner out for the whole reply.
    private func abandonSpeakingReply(settlingTheVoiceState: Bool = true) {
        isSpeakingReply = false
        // Except when a new reply is being armed, where the writes below belong to that reply.
        if settlingTheVoiceState {
            // The other half of "this reply is still the app's business": a reply written off will
            // never report a first sound, and nothing else would ever clear a wait that no sound can.
            isWaitingForTheFirstSoundOfTheReply = false
            isProducingAReply = false
        }
        speechSegments = []
        currentSpeechSegmentIndex = 0
        hasCurrentSpeechSegmentFinishedSpeaking = false
        lastNarrationWordEndOffsetInSpokenText = 0
        lastSpokenWordEndOffsetInCurrentSpeechSegment = 0
        streamingReplySegmenter = nil
        finalizedSpeechSegmentCount = 0
        isReplyStreamComplete = false
        // The cursor is part of what this reply started, so it is part of what writing the reply off
        // restores. `shouldReturnBuddyToCursorAfterPointing` is left alone — the next teardown clears it.
        requestBuddyReturnHome()
    }

    /// Called by the TTS client as each word is about to be spoken. The narration's position is what drives
    /// the tour: a word reaching the sentence that names an element sends the cursor.
    ///
    /// Nothing is held here — the words of a segment are free to run ahead of the cursor, and the wait, when
    /// there is one, happens at the segment boundary.
    private func handleSpokenCharacterRange(_ spokenCharacterRange: NSRange) {
        // Recorded before any of the guards below: a word arriving at all is proof this voice
        // reports what it is saying, whether or not it is the word that sends the cursor off.
        hasNarrationReportedAnyWords = true
        lastNarrationProgressDate = Date()

        lastSpokenWordEndOffsetInCurrentSpeechSegment = spokenCharacterRange.location + spokenCharacterRange.length
        // The voice reports offsets within the segment it was handed, so this converts them into the reply's
        // own space. Deliberately not clamped to the segment's end: the voice can only report words it was
        // given.
        lastNarrationWordEndOffsetInSpokenText = currentSpeechSegmentStartOffsetInSpokenText
            + lastSpokenWordEndOffsetInCurrentSpeechSegment

        continuePointingTourIfPossible()
    }

    /// Called when the segment the voice was handed has been spoken through — what releases the next one,
    /// and the only thing that does.
    ///
    /// A cancelled segment reports nothing and so releases nothing: it was cut off, and how much of it was
    /// heard is not something the voice can say.
    private func handlePlaybackFinished() {
        guard isSpeakingReply, currentSpeechSegmentIndex < speechSegments.count else { return }
        markCurrentSpeechSegmentAsSpokenThrough()
    }

    /// Records the segment being narrated as spoken through, and moves the reply forward on it.
    ///
    /// Shared with the path that reads nothing aloud, where the segment is spoken through the moment
    /// it is reached because no callback will ever say so.
    private func markCurrentSpeechSegmentAsSpokenThrough() {
        hasCurrentSpeechSegmentFinishedSpeaking = true
        // A segment the voice was heard to finish is proof the narration is still moving, and it counts for
        // as much as a reported word: the synthesizer reports no word marks at all for a short segment, so a
        // list reply runs through several without a single word reaching the watchdog.
        lastNarrationProgressDate = Date()
        continuePointingTourIfPossible()
    }

    /// Sends the cursor to a tour stop.
    ///
    /// The narration is deliberately not held here and the cursor not delayed: the words run on over the
    /// flight, and the wait for the cursor happens at the sentence boundary instead, by not handing over the
    /// next segment.
    private func startFlightToPointingTourStop(_ pointingTourStop: ResolvedPointingTourStop) {
        beginFlightOfTheCursor(
            to: pointingTourStop.screenLocation,
            on: pointingTourStop.displayFrame,
            with: pointingTourStop.pointingBubbleInvitation,
            // Asked here rather than when the action goes out, because the overlay has to know before the
            // flight starts: a stop that will be pressed is flown to by carrying the user's pointer there,
            // and one that will not is flown to the way it always was.
            performing: actionThatWillActuallyBePerformed(at: pointingTourStop)
        )

        KikiAnalytics.trackElementPointed(elementLabel: pointingTourStop.elementLabel)
        print("🎯 Pointing tour: flying to (\(Int(pointingTourStop.screenshotCoordinate.x)), \(Int(pointingTourStop.screenshotCoordinate.y))) → \"\(pointingTourStop.elementLabel ?? "element")\"")

        schedulePointingTourArrivalTimeout()
    }

    /// Starts the cursor flying to one point, with whatever it says and does when it gets there.
    ///
    /// The single trigger for a flight, whether the destination came from a reply or from a terminal:
    /// setting the location is what makes an overlay fly, and screens other than the target's stand
    /// their own cursor down when it changes, so there is only ever one buddy on screen.
    private func beginFlightOfTheCursor(
        to screenLocation: CGPoint,
        on displayFrame: CGRect,
        with pointingBubbleInvitation: PointingBubbleInvitation,
        saying bubbleText: String? = nil,
        performing actionToPerformOnArrival: ElementActionOnArrival?
    ) {
        // The cursor is about to leave the stop it is on, so the dwell it owed that one is settled.
        pointingTourDwellCompletionTask?.cancel()
        pointingTourDwellCompletionTask = nil
        isFlyingToPointingTourStop = true
        pointingTourNarrationFallbackTask?.cancel()
        pointingTourNarrationFallbackTask = nil

        // Last, and in one write: the overlay flies on this changing, so a target assembled field by
        // field would be readable in a state the flight it describes was never in.
        pointingTarget = PointingTarget(
            screenLocation: screenLocation,
            displayFrame: displayFrame,
            bubbleInvitation: pointingBubbleInvitation,
            bubbleText: bubbleText,
            actionToPerformOnArrival: actionToPerformOnArrival
        )
    }

    /// Called by the cursor overlay once it has arrived at a tour stop, or at a point a terminal asked
    /// for an action at.
    func buddyDidArriveAtPointingTarget() {
        // The arrival timeout may have already written this flight off, and counting the arrival
        // a second time would skip the next stop.
        guard isFlyingToPointingTourStop else { return }

        // Whether this arrival begins a drag, which is the one action that outlives it: a press and a
        // scroll are over the moment the cursor is standing on the element, while a drag still has
        // the button down and half a second of movement to go. Closing the flight out here would
        // send the cursor on to the next stop mid-drag, letting go of what it was carrying.
        //
        // Asked of `requestedActionForArrival` rather than of the action that will actually happen,
        // because a refused drag is performed too — it performs nothing and says so — and it is the
        // performing task, not the refusal, that closes the flight afterwards.
        let isStartingADrag = nextPointingTourStop.flatMap { requestedActionForArrival(at: $0) } == ElementActionOnArrival.drag
            || actionInFlight?.action == ElementActionOnArrival.drag

        if isStartingADrag {
            // Nothing is flying any more, so the watchdog for a flight that never reports back has
            // nothing left to watch. Left armed it would fire part way through the drag and move the
            // tour on with the button still down — through the other door from the one above.
            pointingTourNarrationResumeTimeoutTask?.cancel()
            pointingTourNarrationResumeTimeoutTask = nil
        }

        // Read before the flight is closed out, because closing it out moves the tour past it.
        if let pointingTourStop = nextPointingTourStop {
            performTheActionTheModelAskedForItIfAny(
                at: pointingTourStop,
                isClosingTheArrivalFlightAfterwards: isStartingADrag
            )
        }

        // Written off before the flight is closed out, so the teardown below does not read an action
        // answered here as one whose cursor never arrived and fail it on the way past.
        if let actionThatJustArrived = actionInFlight {
            actionInFlight = nil
            Task {
                await performTheActionInFlight(
                    actionThatJustArrived,
                    isClosingTheArrivalFlightAfterwards: isStartingADrag
                )
            }
        }

        guard !isStartingADrag else { return }
        finishCurrentPointingTourFlight()
    }

    /// The action the cursor just landed on, when the model asked for the element to be operated or
    /// scrolled rather than only located — whichever gesture the tag it wrote named — or nil when it
    /// asked for nothing, or when the user has automatic acting switched off.
    ///
    /// Reached from the cursor *arriving* and from nowhere else: the other way a flight ends, the arrival
    /// timeout, means no cursor view accepted the target, so the cursor is not on the element.
    private func requestedActionForArrival(at pointingTourStop: ResolvedPointingTourStop) -> ElementActionOnArrival? {
        guard isAutomaticClickingEnabled,
              let action = pointingTourStop.pointingBubbleInvitation.actionToPerformOnArrival
        else { return nil }

        return action
    }

    /// The action this stop will actually get — nil when it asks for none *or* when the action would be
    /// refused, which makes nil the honest answer to "will Kiki do this".
    ///
    /// The overlay draws this answer, so it is built on the question above rather than restating it: the
    /// cursor turning red for a press that never follows is a loud, untrue claim.
    ///
    /// The two halves of the question are the two gesture axes, and each is asked of the thing that owns
    /// it: a press is refused by the words on the element, a scroll by the grant alone, a drag by where
    /// its destination is, and none of them answers for another.
    private func actionThatWillActuallyBePerformed(at pointingTourStop: ResolvedPointingTourStop) -> ElementActionOnArrival? {
        guard let requestedAction = requestedActionForArrival(at: pointingTourStop) else { return nil }
        switch requestedAction {
        case .press:
            guard ElementClicker.refusalOfClick(matchingElementLabel: pointingTourStop.elementLabel, origin: .theModelsTag) == nil else { return nil }
        case .scroll:
            guard ElementScroller.refusalOfScroll() == nil else { return nil }
        case .drag:
            guard ElementDragger.refusalOfDrag(
                toAppKitScreenLocation: pointingTourStop.dragDestinationScreenLocation
            ) == nil else { return nil }
        }
        return requestedAction
    }

    /// `isClosingTheArrivalFlightAfterwards` is true only for a drag, which is still running when the
    /// cursor lands and so is the one action whose flight the arrival leaves open for it to close.
    private func performTheActionTheModelAskedForItIfAny(
        at pointingTourStop: ResolvedPointingTourStop,
        isClosingTheArrivalFlightAfterwards: Bool
    ) {
        // One guard for every gesture, because the switch from pointing to acting is the same either way:
        // a stop the model only asked to locate has nothing to do here, and neither has any stop while the
        // user has automatic acting switched off.
        //
        // A refused action deliberately gets past this and is reported by the action itself.
        guard let action = requestedActionForArrival(at: pointingTourStop) else { return }

        let stopIndex = nextPointingTourStopIndex
        let elementLabel = pointingTourStop.elementLabel
        let screenLocation = pointingTourStop.screenLocation
        let displayFrame = pointingTourStop.displayFrame
        // Read here rather than inside the clicker, which stays self-contained and touches no AppKit.
        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0
        // Where a drag lets go, already on the display the starting point is on: it is converted from
        // the same screenshot the starting point was, which clamps it to that screen's bounds.
        let dragDestinationScreenLocation = pointingTourStop.dragDestinationScreenLocation

        Task {
            switch action {
            case .press(let clickKind):
                // Played before the click, and only for a click that will actually go out: asking the refusal
                // first keeps the sound from announcing a click that was declined, and playing it here makes the
                // sound land with the events.
                if ElementClicker.refusalOfClick(matchingElementLabel: elementLabel, origin: .theModelsTag) == nil {
                    elementClickSoundPlayer.playClickSound()
                }

                let clickOutcome = await ElementClicker.clickElement(
                    atAppKitScreenLocation: screenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                    matchingElementLabel: elementLabel,
                    kind: clickKind,
                    origin: .theModelsTag
                )

                print("🖱 \(clickKind) at stop \(stopIndex): \(clickOutcome)")

            case .scroll(let direction, let distance):
                // Nothing is played: the click's sound is feedback for a press, and a scroll presses
                // nothing. The content moving is the feedback.
                let scrollOutcome = await ElementScroller.scrollElement(
                    atAppKitScreenLocation: screenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                    direction: direction,
                    distance: distance,
                    displayFrame: displayFrame
                )

                print("🖱 \(direction) \(distance) at stop \(stopIndex): \(scrollOutcome)")

            case .drag:
                // Nothing is played, for the scroll's reason: what moves is its own feedback.
                let dragOutcome = await dragForTheUser(
                    fromAppKitScreenLocation: screenLocation,
                    toAppKitScreenLocation: dragDestinationScreenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints
                )

                print("🖱 drag at stop \(stopIndex): \(dragOutcome)")

                // The one place a model-asked-for drag ends, and the only action that ends after the
                // arrival rather than at it: the flight the arrival deliberately left open is closed
                // here, with the button up and the cursor standing where the drag put it.
                if isClosingTheArrivalFlightAfterwards, isFlyingToPointingTourStop {
                    finishCurrentPointingTourFlight()
                }
            }
        }
    }

    /// Drags from one point to another for the user, with the cursor drawn following it.
    ///
    /// The one place a drag runs, reached by both the model's tag and the terminal's request: the two
    /// differ in where the points come from and in what is said about it afterwards, and not at all in
    /// what is done to the machine or in what the user sees while it happens.
    ///
    /// The cursor follows because the overlay reads `screenLocationOfTheDragInFlight` — a drag posts its
    /// events from here, and nothing about the flight the cursor arrived on is still running to draw it.
    private func dragForTheUser(
        fromAppKitScreenLocation startAppKitScreenLocation: CGPoint,
        toAppKitScreenLocation destinationAppKitScreenLocation: CGPoint?,
        primaryScreenHeightInPoints: CGFloat
    ) async -> ElementDragOutcome {
        // Cleared however the drag ends, so a drag that was refused does not leave the cursor drawn
        // somewhere no movement is happening.
        defer { screenLocationOfTheDragInFlight = nil }

        return await ElementDragger.dragElement(
            fromAppKitScreenLocation: startAppKitScreenLocation,
            toAppKitScreenLocation: destinationAppKitScreenLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints,
            onEachStep: { [weak self] appKitScreenLocation in
                self?.screenLocationOfTheDragInFlight = appKitScreenLocation
            }
        )
    }

    /// Closes out the flight in progress: the next stop becomes eligible to be sent to, and the reply is
    /// told the cursor has moved on.
    ///
    /// Reached by both ways a flight can end — the cursor arriving, and the arrival timeout — so it is the
    /// single place the tour learns that it is standing still again.
    private func finishCurrentPointingTourFlight() {
        // An action being waited on was performed on arrival, where it is written off before this
        // runs, so one still here is a flight that never landed: nothing was done, and whoever asked
        // is told so — or, for a replay, the loop simply moves on — rather than left waiting on a
        // cursor that is not coming.
        if let actionThatNeverLanded = actionInFlight {
            endTheActionBeingWaitedOn(actionThatNeverLanded.beingWaitedOn, with: .failed(message: "光标没飞到那个点，这次操作没做成。", isRefusal: false))
        }

        pointingTourNarrationResumeTimeoutTask?.cancel()
        pointingTourNarrationResumeTimeoutTask = nil
        isFlyingToPointingTourStop = false
        // The clock the next stop's minimum dwell is measured against. A flight that timed out
        // counts too: the cursor has been parked on that element either way.
        lastPointingTourStopArrivalDate = Date()
        nextPointingTourStopIndex += 1

        if nextPointingTourStop == nil {
            // Nothing left to point at, so the only thing keeping the cursor out here is the narration still
            // talking. It comes home on the same three seconds the overlay gives a single point.
            schedulePointingTourReturnHomeTimeout()
        }

        // The dwell the cursor owes the element it is on is the only thing left before the reply may carry
        // on, and nothing else will notice when it runs out.
        schedulePointingTourDwellCompletion()
        continuePointingTourIfPossible()
    }

    /// Pokes the tour once the cursor has spent its minimum time on the stop it landed on.
    ///
    /// In the case this exists for nothing else does: the narration has already been spoken through, so no
    /// further word is coming to re-run the coordination.
    private func schedulePointingTourDwellCompletion() {
        pointingTourDwellCompletionTask?.cancel()
        pointingTourDwellCompletionTask = nil

        let remainingDwellSeconds = remainingPointingTourStopDwellSeconds
        guard remainingDwellSeconds > 0 else { return }

        pointingTourDwellCompletionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remainingDwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.continuePointingTourIfPossible()
        }
    }

    /// Sends the cursor home if the narration is still going three seconds after the cursor landed
    /// on the last element it will point at.
    private func schedulePointingTourReturnHomeTimeout() {
        pointingTourReturnHomeTimeoutTask?.cancel()
        pointingTourReturnHomeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourStopMaximumDwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isPointingTourActive,
                  !self.isFlyingToPointingTourStop,
                  !self.shouldReturnBuddyToCursorAfterPointing else { return }
            self.shouldReturnBuddyToCursorAfterPointing = true
            self.requestBuddyReturnHome()
        }
    }

    /// Writes off a flight that never reports back.
    ///
    /// Every path that never reaches a cursor view funnels through it — the screen holding the element was
    /// unplugged between the screenshot and the flight, or the welcome animation is running, which makes
    /// the view ignore targets — and it degrades them to one missed stop.
    private func schedulePointingTourArrivalTimeout() {
        pointingTourNarrationResumeTimeoutTask?.cancel()
        pointingTourNarrationResumeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourArrivalTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isFlyingToPointingTourStop else { return }
            print("🎯 Pointing tour: no arrival after \(Self.pointingTourArrivalTimeoutSeconds)s, writing the flight off")
            self.finishCurrentPointingTourFlight()
        }
    }

    /// Hands the tour over to the cursor if the narration never gets going.
    ///
    /// The tour is triggered by the words being spoken, so a voice that never reports what it is saying
    /// would leave the cursor parked where it was for every reply. Pointing at the first tagged element and
    /// ending the tour there was the old answer, and it dropped every element after the first.
    private func schedulePointingTourFallbackIfNarrationIsSilent() {
        pointingTourNarrationFallbackTask?.cancel()
        pointingTourNarrationFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourSilentNarrationFallbackSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only a voice that has said nothing at all is silent. Asking whether a flight had started
            // would be a different question, with a wrong answer for any reply that talks about something
            // else before its first tagged element.
            guard !self.hasNarrationReportedAnyWords else { return }
            print("🎯 Pointing tour: narration reported no words, the cursor paces the tour from here")
            self.hasTheNarrationGoneSilent = true
            self.continuePointingTourIfPossible()
        }
    }

    /// Unsticks a reply whose narration has gone quiet partway through.
    ///
    /// The reply is driven by the words being spoken, so a voice that stops reporting them leaves it
    /// stranded: nothing sends the cursor to the next stop and nothing ends the tour either. The
    /// silent-narration fallback does not cover this, because it asks whether the voice has said anything
    /// *at all* and answers once, which a voice that has already reported words passed.
    ///
    /// The tour is ended rather than advanced, the words being what pace it and there being none left; the
    /// cursor is parked on the stop it was waiting to serve. The segment in progress is written off with
    /// it, because a voice that has stopped producing audio will never report it.
    private func schedulePointingTourStallWatchdog() {
        pointingTourStallWatchdogTask?.cancel()
        pointingTourStallWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourStallTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard self.isPointingTourActive else { return }

                // A voice that never reported a word is the silent-narration case, which has its
                // own fallback. This watchdog is for a voice that was reporting and then stopped.
                guard self.hasNarrationReportedAnyWords else { continue }

                guard let lastNarrationProgressDate = self.lastNarrationProgressDate,
                      Date().timeIntervalSince(lastNarrationProgressDate) >= Self.pointingTourStallTimeoutSeconds else {

                    continue
                }

                print("🎯 Pointing tour: neither a word nor a finished segment for \(Self.pointingTourStallTimeoutSeconds)s, the narration has stopped")

                // Read before the tour is ended, which clears both of them.
                let stopToParkOn = self.nextPointingTourStop ?? self.resolvedPointingTourStops.last
                self.endPointingTour()
                // Put back for the stop the cursor was waiting to serve, which `endPointingTour` has
                // just cleared along with the rest of the tour. Doing nothing is the point: the tour
                // that asked for the action is over, and the cursor is only being left standing where
                // it got to.
                if let stopToParkOn {
                    self.pointingTarget = PointingTarget(
                        screenLocation: stopToParkOn.screenLocation,
                        displayFrame: stopToParkOn.displayFrame,
                        bubbleInvitation: stopToParkOn.pointingBubbleInvitation,
                        bubbleText: nil,
                        actionToPerformOnArrival: nil
                    )
                }

                self.hasCurrentSpeechSegmentFinishedSpeaking = true
                self.continuePointingTourIfPossible()
                return
            }
        }
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules the demo interactions.
    /// Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        // Bundled rather than streamed: fetching the intro put the first thing a new user ever sees behind
        // a network round trip, and its failure was silent.
        guard let videoURL = Bundle.main.url(forResource: "kiki-intro", withExtension: "mp4") else {
            print("⚠️ Onboarding video: kiki-intro.mp4 is missing from the bundle")
            return
        }

        // A replay starts the demos over: the second run's first demo would otherwise be told to
        // avoid everything the first run pointed at, on a screen that has nothing to do with them.
        onboardingDemoTargetsAlreadyPointedAt.removeAll()

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        // Full volume from the first sample, rather than ramping up from silence: the ramp cost the clip
        // its opening words, so the first thing the user heard was the middle of a sentence.
        player.volume = 1.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // The picture fades in first and playback starts after it: a paused `AVPlayerLayer` draws the item's
        // frame at time zero, so what fades in is the clip's opening image rather than an empty box. The two
        // delays time the fade against the playback, so moving either changes when the narration is heard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Waits for SwiftUI to mount the view; the .animation modifier handles the fade.
            self.onboardingVideoOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            player.play()
        }

        // Two demos, ten seconds apart: Kiki flies to something interesting on screen and comments on it,
        // then does the same somewhere else. Both are silent — the only output is one sentence in the
        // pointing bubble — so they play alongside the narration.
        //
        // Both times have to land inside the clip, and the failure is silent: a boundary time past the end
        // is never reached, while the end observer tears the whole observer down regardless. These two
        // numbers move with the clip.
        let demoTriggerTimes = [5, 15].map {
            CMTime(seconds: Double($0), preferredTimescale: 600)
        }
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: demoTriggerTimes.map { NSValue(time: $0) },
            queue: .main
        ) { [weak self] in
            KikiAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            KikiAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait out the fade-out before tearing down, matching the opacity animation's own
            // duration in `OverlayWindow`, or the clip disappears in one frame instead of fading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "按住 control + option 然后介绍你自己"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're kiki, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. write it in chinese (简体中文), the way you'd say it out loud. no emojis ever. the observation is the one part that must not repeat what's written on screen — react to the thing, don't read it back. keep it to 12 chinese characters max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST pick something near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width, and your y coordinate between 20%-80% of the image height — nothing near any edge, which rules out menu bar items, dock icons and sidebar items. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. your comment is in chinese. if the thing you picked has text written on it, copy that text into the label character for character exactly as it appears on screen — chinese is fine there, the label is code and is never read aloud — otherwise name it in english.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot, asks the model to find something interesting to point at, and
    /// triggers the flight. Used during onboarding to demo pointing while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only the cursor screen, so the model can't pick something on a monitor we can't
                // point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                // The demo picks something with a name on screen, so it gets the same exact positioning the
                // pointing tour uses. Started before the request so the recognition runs while the model
                // writes.
                let recognizedTextLinesTask = Task {
                    await ScreenshotTextRecognizer.recognizedLines(in: cursorScreenCapture.imageData)
                }

                let labeledImages = [(
                    data: cursorScreenCapture.imageData,
                    label: cursorScreenCapture.label
                        + " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)"
                        + "x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                )]

                // What an earlier demo already pointed at on this same display. Each demo is a fresh request
                // carrying no history, so left alone the model picks the same thing again. Two levers, and
                // both are needed: this tells the model what to avoid, and the claimed box below takes the
                // ground away if it names the same element anyway.
                let earlierDemoTargetsOnThisScreen = onboardingDemoTargetsAlreadyPointedAt
                    .filter { $0.displayFrame == cursorScreenCapture.displayFrame }

                let userPrompt = earlierDemoTargetsOnThisScreen.isEmpty
                    ? "look around my screen and find something interesting to point at"
                    : "look around my screen and find something interesting to point at."
                        + " you have already pointed at \(earlierDemoTargetsOnThisScreen.map(\.elementLabel).joined(separator: "、"))"
                        + " — pick something else this time, somewhere well away from it."

                let (fullResponseText, _) = try await deepSeekAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: userPrompt,
                    // Empty on purpose, unlike the voice path: the demo says nothing out loud, its
                    // whole output being one sentence written into the pointing bubble.
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let modelPointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                // The boxes an earlier demo resolved to are passed as claimed, the same mechanism the
                // pointing tour uses. A label that would land on covered ground falls back to the model's own
                // coordinate, so the second demo still points somewhere.
                let precisePosition = Self.preciseScreenshotCoordinate(
                    forModelScreenshotCoordinate: modelPointCoordinate,
                    elementLabel: parseResult.elementLabel,
                    amongRecognizedLines: await recognizedTextLinesTask.value,
                    avoidingBoxesClaimedByEarlierStopsOnTheSameScreen: earlierDemoTargetsOnThisScreen
                        .compactMap(\.matchedTextBox)
                )

                let resolvedLocation = Self.screenLocation(
                    forScreenshotCoordinate: precisePosition.coordinate,
                    on: cursorScreenCapture
                )

                // Recorded whether or not the flight goes anywhere, so the next demo is told about
                // it either way. A target with no label carries nothing forward.
                if let elementLabel = parseResult.elementLabel, !elementLabel.isEmpty {
                    onboardingDemoTargetsAlreadyPointedAt.append(
                        OnboardingDemoTarget(
                            elementLabel: elementLabel,
                            matchedTextBox: precisePosition.matchedTextBox,
                            displayFrame: cursorScreenCapture.displayFrame
                        )
                    )
                }

                // One target, and its invitation is a look: the demo points something out rather than
                // offering to operate it. The overlay reads that to decide whether the flight carries
                // the user's mouse, so anything else here would have the welcome animation take hold of
                // the pointer mid-demo.
                pointingTarget = PointingTarget(
                    screenLocation: resolvedLocation.screenLocation,
                    displayFrame: resolvedLocation.displayFrame,
                    bubbleInvitation: .lookAtElement,
                    // The model's comment, in place of a random phrase.
                    bubbleText: parseResult.spokenText,
                    actionToPerformOnArrival: nil
                )
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
