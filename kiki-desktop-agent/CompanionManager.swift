//
//  CompanionManager.swift
//  kiki-desktop-agent
//
//  Central state manager: the push-to-talk pipeline and the observable voice state the panel reads.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI

enum CompanionVoiceState: Equatable {
    case idle
    case listening
    case processing
    case responding
}

/// One answer, combined with `StatusItemIconPhase` at every way into the app, so a state added
/// later is a compile error rather than a silent pass.
enum WhatKikiIsDoingRightNow {
    case waiting
    case restingInTheStatusItemIcon
    case wakingFromTheStatusItemIcon
    case recordingWhatTheUserIsDoing
    case replayingWhatTheUserDid
    case listeningToTheUser
    case processingTheLastTurn
    case replyingToTheLastTurn
}

/// One fact rather than two flags, which would admit a state where Kiki is doing both.
enum RecordedActionsPhase: Equatable {
    case neitherRecordingNorReplaying
    case recordingWhatTheUserIsDoing
    case replayingWhatTheUserDid
}

/// One value: separate properties would let the panel mix two moments as it re-draws per chunk.
struct TaskProgress: Equatable {
    let roundCount: Int
    /// A round that never acted on the screen is one step.
    let stepCount: Int
    let isRunning: Bool
    let stepInTheRoundInProgress: Int
    /// Valued by the same estimate the compression trigger reads.
    let estimatedTokenCountOfTheContext: Int
    let tokenCountThatStartsCompression: Int
    /// A moment rather than a countdown, which the panel computes as it draws.
    let dateTheNextQuestionStartsANewConversation: Date?

    var hasATask: Bool {
        roundCount > 0 || isRunning
    }

    /// Negative once past.
    func secondsBeforeTheNextQuestionStartsANewConversation(from now: Date) -> TimeInterval? {
        dateTheNextQuestionStartsANewConversation.map { $0.timeIntervalSince(now) }
    }

    /// Measured against the trigger and clamped, because the estimate can read past it mid-step.
    var fractionOfTheRoomBeforeCompressionUsed: Double {
        guard tokenCountThatStartsCompression > 0 else { return 0 }
        return min(1, Double(estimatedTokenCountOfTheContext) / Double(tokenCountThatStartsCompression))
    }
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
    /// Speech Recognition is a TCC service of its own, asked for the first time the Speech framework runs.
    @Published private(set) var hasSpeechRecognitionPermission = false

    /// One value: a flight that picked up the last flight's bubble text or click kind would point
    /// at the right place for the wrong reason.
    @Published var pointingTarget: PointingTarget?

    /// What the overlay flies on. Never the target's location: two stops can name one point — a
    /// `[TYPE:…]` and the `[KEY:…:return]` after it — and a flight keyed on location misses the second.
    @Published private(set) var pointingFlightRequestCount = 0

    /// In global AppKit coordinates, written step by step by `ElementDragger` so the cursor is drawn
    /// travelling with it.
    @Published var screenLocationOfTheDragInFlight: CGPoint?

    @Published private(set) var statusItemIconPhase: StatusItemIconPhase = .notInTheIcon

    /// The turn's list, not a step's: a step appends its own segments, offset by
    /// `speechSegmentCountBeforeTheStepNowStreaming`, so a step boundary is not a seam.
    private var speechSegmentsOfTheTurnBeingSpoken: [CompanionSpeechSegment] = []
    /// How many are beyond revision; the last one is the segment the model may still be writing,
    /// held back because the voice cannot take words back.
    private var finalizedSpeechSegmentCount = 0
    /// Turns a step's from-zero index into a position in the turn's list.
    private var speechSegmentCountBeforeTheStepNowStreaming = 0
    /// Reaching the end of the finalised segments is not the end: the next may not be written yet.
    private var isReplyStreamComplete = false
    /// Nil outside a streamed reply — the onboarding demo has none.
    private var streamingReplySegmenter: StreamingReplySegmenter?
    /// Index into the turn's numbering — never reset at a step boundary.
    private var currentSpeechSegmentIndex = 0
    private var hasCurrentSpeechSegmentFinishedSpeaking = false
    /// Distinct from the TTS client's own `isPlaying`, which goes false between segments.
    private var isSpeakingReply = false { didSet { settleVoiceState() } }
    /// A terminal-raised turn is not, unless it asked to be: with nothing to listen to, the cursor paces.
    private var isReadingTheReplyAloud = true
    /// No word is coming to release a stop, so the cursor paces the tour from there on.
    private var hasTheNarrationGoneSilent = false
    /// What the cursor's spinner depicts; it ends at the first sound, reported from playback position.
    private var isWaitingForTheFirstSoundOfTheReply = false { didSet { settleVoiceState() } }
    /// Wider than `isWaitingForTheFirstSoundOfTheReply`, which is about what has been *heard*: a
    /// silent turn would otherwise read as 等待中 throughout, with a terminal click let through.
    private var isProducingAReply = false { didSet { settleVoiceState() } }
    /// The voice reports offsets within the segment it was handed; this is where they become the reply's.
    private var lastNarrationWordEndOffsetInSpokenText = 0
    /// Compared against the segment's own length to tell spoken-through from abandoned.
    private var lastSpokenWordEndOffsetInCurrentSpeechSegment = 0

    /// A run of the reply handed to the synthesizer as one utterance.
    private struct CompanionSpeechSegment {
        let spokenText: String
        let startOffsetInSpokenText: Int
        /// Emptied when the step it was cut for ends, because `resolvedPointingTourStops` is
        /// replaced per step — an old range would name elements of a reply it is not about.
        var stopIndexRange: Range<Int>
    }

    // MARK: - Pointing Tour State

    private var resolvedPointingTourStops: [ResolvedPointingTourStop] = []
    private var nextPointingTourStopIndex = 0
    /// What decides who receives the arrival.
    @Published var isPointingTourActive = false
    /// Set when the narration has finished and the cursor should come home from the last stop.
    @Published var shouldReturnBuddyToCursorAfterPointing = false
    /// A counter rather than a flag: coming home is driven by a `.onChange`, so a flag written
    /// `false` alongside would take the request away.
    @Published private(set) var buddyReturnHomeRequestCount = 0
    private var isFlyingToPointingTourStop = false
    /// Writes off a flight that never reports back, so it cannot hold the tour for good.
    private var pointingTourNarrationResumeTimeoutTask: Task<Void, Never>?
    /// Waits to see whether the narration reports any words at all.
    private var pointingTourNarrationFallbackTask: Task<Void, Never>?
    /// Pokes the tour once the cursor has spent its minimum time on the stop it is on.
    private var pointingTourDwellCompletionTask: Task<Void, Never>?
    /// Brings the cursor home if the narration outlasts the last stop's dwell.
    private var pointingTourReturnHomeTimeoutTask: Task<Void, Never>?
    /// Direct evidence that the voice reports at all, where "no flight has started yet" is not.
    private var hasNarrationReportedAnyWords = false
    /// When the narration last proved it was still moving: a word, or a stop on a new sentence.
    private var lastNarrationProgressDate: Date?
    /// Unsticks a tour whose narration has fallen silent partway through.
    private var pointingTourStallWatchdogTask: Task<Void, Never>?
    /// When the cursor last landed on a tour stop. The minimum dwell is measured from here.
    private var lastPointingTourStopArrivalDate: Date?

    /// Comfortably longer than the slowest flight, so it only fires when nothing picked it up.
    private static let pointingTourArrivalTimeoutSeconds: Double = 3.0

    /// How long the cursor stays on a stop before it may leave: the bubble it writes there has to be
    /// readable, and the narration's next tagged sentence often is not.
    private static let minimumSpokenPointingTourStopDwellSeconds: Double = 1.0

    /// The same hold where nothing reads aloud, so no sentence paces the bubble.
    private static let minimumSilentPointingTourStopDwellSeconds: Double = 0.4

    private var minimumPointingTourStopDwellSeconds: Double {
        isReadingTheReplyAloud
            ? Self.minimumSpokenPointingTourStopDwellSeconds
            : Self.minimumSilentPointingTourStopDwellSeconds
    }

    /// How long the cursor waits on the last stop before flying home; the overlay holds a point as long.
    private static let pointingTourStopMaximumDwellSeconds: Double = 3.0

    /// How long to wait for the first word before concluding this voice never reports what it says.
    private static let pointingTourSilentNarrationFallbackSeconds: Double = 2.5

    /// The longest legitimate silence — a spoken dwell plus an arrival timeout — plus a second's margin.
    private static let pointingTourStallTimeoutSeconds: Double =
        pointingTourArrivalTimeoutSeconds + minimumSpokenPointingTourStopDwellSeconds + 1.0

    /// A tour stop with its screenshot coordinate already converted into a screen location.
    private struct ResolvedPointingTourStop {
        /// The centre of the text box the label matched, or the model's estimate when it matched nothing.
        let screenshotCoordinate: CGPoint
        /// The coordinate the model itself wrote, kept for the pointing log: a label occurring more
        /// than once throws the two numbers apart, the only way to see a match on the wrong occurrence.
        let modelScreenshotCoordinate: CGPoint
        /// Whether the label was found on screen: a label that is not verbatim matches nothing and the
        /// coordinate falls back to the estimate silently, so a wrong click reads like a right one here.
        let didTheLabelMatchTextOnScreen: Bool
        let screenLocation: CGPoint
        let displayFrame: CGRect
        let elementLabel: String?
        /// A word reaching it sends the cursor, and it decides which speech segment owns this stop.
        let sentenceStartOffsetInSpokenText: Int
        let pointingBubbleInvitation: PointingBubbleInvitation
        /// Where a drag from this stop lets go, in the same global AppKit coordinates — beside the point rather
        /// than inside a type that knows nothing about coordinates. Nil for a non-drag or a named no destination.
        let dragDestinationScreenLocation: CGPoint?
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    /// Asks the player where it is, every step of the narration, so the glow reads the level there.
    private var onboardingNarrationLoudnessObserver: Any?

    /// Each demo is a fresh request with no history, so the model would pick the same element again:
    /// the next demo is told what the last picked, and that label's rectangle is claimed ground.
    struct OnboardingDemoTarget {
        /// The label the model wrote, verbatim — what the next demo is told to avoid.
        let elementLabel: String
        /// The text rectangle the label resolved to, or nil when it matched nothing.
        let matchedTextBox: CGRect?
        /// The display it was found on — a rectangle is in its own screenshot's pixel space.
        let displayFrame: CGRect
    }

    private var onboardingDemoTargetsAlreadyPointedAt: [OnboardingDemoTarget] = []

    // MARK: - Onboarding Prompt Bubble

    /// Streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// What the cursor's glow widens and narrows by, whoever is speaking for Kiki.
    let voiceLoudnessMeter = VoiceLoudnessMeter()

    /// Watches the mouse for a run of the user's own actions, and owns the shift+option tap for one.
    let userActionRecorder = UserActionRecorder()


    /// Where the user's DeepSeek API key lives, written by the panel and read by the client.
    let deepSeekAPIKeyStore = DeepSeekAPIKeyStore()

    /// Whether a DeepSeek API key has been saved, so the panel need not read the store itself.
    @Published private(set) var hasDeepSeekAPIKey: Bool = false

    /// Sends chat requests straight to DeepSeek: no proxy, the pasted key the only credential, and
    /// nothing baked into the binary.
    private lazy var deepSeekAPI: DeepSeekAPI = {
        return DeepSeekAPI(apiKeyStore: deepSeekAPIKeyStore, model: selectedModel)
    }()

    /// Speaks the companion's responses, on-device and with no API key.
    private lazy var ttsClient = AppleTTSClient()

    /// Its accept loop and I/O run on a queue of its own so nothing lands on the main actor.
    /// `lazy` because its closures capture the manager.
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
        screenshotHandler: { [weak self] screenshotRequest, terminalIdentifier in
            self?.captureScreenshotForTerminal(screenshotRequest, fromTheTerminalWith: terminalIdentifier)
        },
        locateHandler: { [weak self] locateRequest, terminalIdentifier in
            self?.locateTextForTerminal(locateRequest, fromTheTerminalWith: terminalIdentifier)
        },
        readinessProvider: { [weak self] in
            self?.commandReadiness()
                ?? KikiCommandReadiness(
                    canRunCommands: false,
                    problems: ["Kiki 正在关闭。"],
                    understandsScrolling: true,
                    understandsTripleClick: true,
                    understandsDragging: true,
                    understandsFractionalScreenfuls: true,
                    understandsTyping: true,
                    understandsPressingKeys: true,
                    understandsScreenshots: true,
                    understandsLocatingText: true
                )
        }
    )

    /// Carries the turn each entry belongs to: trimming on count alone would let a long search push
    /// out the question it is searching for.
    private var conversationHistory: [(turnIdentifier: UUID,
                                       userTranscript: String,
                                       assistantResponse: String)] = []

    /// One fact, written together, counted from the front: the context is the summary followed by the
    /// history from that index on, never a second copy of the conversation that can drift.
    private var summaryOfTheStepsCompressedOutOfTheContext: String?
    private var numberOfHistoryEntriesTheSummaryStandsInFor = 0

    /// Held, because the history is written from three call stacks that are not the same one.
    private var transcriptOfTheTurnBeingAnswered = ""

    /// So trimming drops whole turns rather than the tail of one; stamped where a turn begins,
    /// never per step.
    private var turnIdentifierOfTheTurnBeingAnswered = UUID()

    /// Every path that writes it can run more than once for the same turn.
    private var hasWrittenTheCurrentTurnIntoHistory = false

    /// Refreshed where an answer changes, never computed where it is read: the estimate walks every
    /// character of the history, and the panel re-draws on every chunk.
    @Published private(set) var taskProgress = TaskProgress(
        roundCount: 0,
        stepCount: 0,
        isRunning: false,
        stepInTheRoundInProgress: 0,
        estimatedTokenCountOfTheContext: 0,
        tokenCountThatStartsCompression: CompanionManager.tokenCountThatStartsCompression,
        dateTheNextQuestionStartsANewConversation: nil
    )

    // MARK: - The Turn As A Run Of Steps

    /// One step of the turn: the reply the model wrote and what its actions then did. Counted, not
    /// flagged: the tour running out of stops and the last press reporting back finish at different times.
    private struct StepOfTheTurnBeingAnswered {
        var numberOfActionsAskedFor = 0
        var numberOfActionsThatHaveReportedBack = 0
        /// What each action did, in the order asked, as the sentences the next step is told.
        var sentencesSayingWhatTheActionDid: [String] = []
        /// All refused means the screen is exactly as the screenshot the model is already looking at.
        var didAnyActionReachTheScreen = false
        /// So the several things that can finish a step do not report it more than once.
        var hasBeenClosedOut = false
    }

    private var stepInProgress = StepOfTheTurnBeingAnswered()

    /// Counting the one in progress. One for a turn that never acts, which is most of them.
    private var numberOfStepsStartedInTheTurnBeingAnswered = 0

    /// Without a ceiling, a model answering every look with another `[LOOK]` would hold the turn open
    /// indefinitely; a folder costs two steps to look inside, and the prompt reads this constant.
    private static let maximumStepsInTheTurnBeingAnswered = 20

    /// The `[LOOK]` marker, which is what makes this a loop rather than one reply.
    private var hasTheModelAskedToLookAgain = false

    /// The terminal gets absolute snapshots, not deltas, so without this the reply would appear to
    /// shrink at every step boundary.
    private var spokenTextOfTheStepsBeforeTheOneInProgress = ""

    private var hasClosedOutTheTurnBeingAnswered = false

    /// A cancelled read is not a promise of silence: it can resume with one more chunk after the next
    /// turn has begun, and by then that chunk is legitimately the new turn's.
    private var turnIdentifierOfTheReplyBeingStreamed = UUID()

    /// Which action is outstanding, so work that reads the screen for it can tell after each `await` whether it
    /// is still the action Kiki will perform. One value rather than two optionals: written and cleared together, a stray write would answer a terminal that never asked.
    private var actionBeingWaitedOn: ActionBeingWaitedOn?

    private struct ActionBeingWaitedOn {
        let actionIdentifier: UUID
        let whoHearsTheAnswer: WhoHearsTheAnswer
    }

    /// Where the one answer to an action goes, carried here so all three askers reach one performance.
    private enum WhoHearsTheAnswer {
        case theTerminalThatAsked(CommandTerminalIdentifier)
        /// Nobody asked in words: the answer's only work is to start the next step.
        case theReplayOfTheUsersRecordedActions
        /// The guide reads the outcome off the permission fact instead.
        case theOnboardingGuideItself
    }

    /// Cleared together with the identifier above, so an answered action is never performed on arrival.
    private var actionInFlight: ActionInFlight?

    /// A fact of its own rather than a flag on the recorder: it decides what every input path does,
    /// and the panel and the cursor both draw it.
    @Published private(set) var recordedActionsPhase: RecordedActionsPhase = .neitherRecordingNorReplaying

    /// Emptied when the replay is forgotten: a list with no replay running is a recording nobody asked for.
    private var recordedUserActions: [RecordedUserAction] = []

    /// Advanced before each step is performed, so an interrupted step is not the one the loop resumes.
    private var indexOfTheNextRecordedActionToReplay = 0

    private var replayStepTask: Task<Void, Never>?

    /// The actions are over in milliseconds, so without a wait the cursor would cross the screen twice before the
    /// eye could follow either. Must stay under `pointingTourStopMaximumDwellSeconds`, or the cursor flies home between two steps.
    private static let secondsBetweenReplayedActions: Double = 0.6

    private var recordedActionsShortcutCancellable: AnyCancellable?

    /// So an unchanged chunk skips the parse that would work out the same answer.
    private var rawReplyUTF16CountLastSentToTerminal = -1

    /// When the conversation last moved — the user speaking or Kiki working. Advanced by every step, not only
    /// every turn: from the question alone, the follow-up asked the moment a quarter-hour search ends would drop the history that search built.
    private var dateOfTheLastActivityInTheConversation: Date?

    /// A soft bound: the turn in progress is never trimmed, so a turn of more steps keeps all of them.
    /// What a request carries is bounded separately, by the summary the oldest steps compress into.
    private static let maximumExchangeCountCarriedInHistory = 5000

    private static let contextTokenCountOfTheModel = 1_000_000

    /// Well under half, because the trigger is checked before the screenshot is taken: what the
    /// compression leaves has to hold a capture of every display, the prompt, and the reply to come.
    private static let fractionOfTheContextThatStartsCompression = 0.45

    /// The one place those two numbers are combined, so the trigger the compression fires on and
    /// the trigger the panel counts down to are the same figure rather than two roundings of it.
    private static let tokenCountThatStartsCompression = Int(
        Double(contextTokenCountOfTheModel) * fractionOfTheContextThatStartsCompression)

    /// The ones the question just asked actually refers to.
    private static let numberOfNewestStepsAlwaysCarriedWhole = 5

    /// Vision input is counted by the image rather than its bytes; no tokenizer in the process to ask.
    private static let estimatedTokenCountOfOneScreenshot = 5_000

    private static let maximumGapBetweenTurnsInTheSameConversationSeconds: TimeInterval = 10 * 60

    init() {
        // The panel renders the key's saved/empty state before any request is made, so seed it here.
        hasDeepSeekAPIKey = deepSeekAPIKeyStore.hasAPIKey

        // A recovered key was typed into an older build, so its step is already done: left unset, a
        // machine with every other fact satisfied would have no segment left and no way to the video.
        if deepSeekAPIKeyStore.didRecoverTheKeyFromTheLegacyKeychain {
            hasCompletedOnboarding = true
        }

        // The first reports how far into the segment the words have got, sending the cursor off; the
        // second that it has been spoken through, releasing the next segment.
        ttsClient.onSpokenCharacterRange = { [weak self] spokenCharacterRange in
            self?.handleSpokenCharacterRange(spokenCharacterRange)
        }
        ttsClient.onPlaybackFinished = { [weak self] in
            self?.handlePlaybackFinished()
        }
        // The spinner is held until this arrives, so clearing the wait ends the reply's `.processing`
        // state. Idempotent: a late report settles onto whatever the facts say.
        ttsClient.onFirstSoundHeard = { [weak self] in
            self?.isWaitingForTheFirstSoundOfTheReply = false
        }
        // The voice's own level, which drives the glow; the onboarding video reports to the same meter.
        ttsClient.onVoiceLoudness = { [weak self] voiceLoudness in
            self?.voiceLoudnessMeter.report(voiceLoudness)
        }
    }

    /// The running response task, cancelled when the user speaks again.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// So the overlay keeps one window per connected screen.
    private var displayConfigurationChangeObserver: NSObjectProtocol?
    private var transientHideTask: Task<Void, Never>?

    /// Every permission has to be in the set: the panel renders its rows only while this is false,
    /// so one left out would become un-grantable the moment the others were in place.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission
            && hasScreenContentPermission && hasRequiredSpeechRecognitionPermission
    }

    /// Only required when the *resolved* transcription backend is Apple's — the factory falls back to
    /// Apple Speech with no key — and not private: the guide's microphone segment waits on this fact.
    var hasRequiredSpeechRecognitionPermission: Bool {
        !buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission
            || hasSpeechRecognitionPermission
    }

    @Published private(set) var isOverlayVisible: Bool = false

    /// Persisted under a key of its own, so a model saved by an older build falls back to the default.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedDeepSeekModel") ?? DeepSeekAPI.defaultModel

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedDeepSeekModel")
        deepSeekAPI.model = model
    }

    /// Saves the DeepSeek API key the user typed into the panel; returns whether it was stored.
    @discardableResult
    func saveDeepSeekAPIKey(_ apiKey: String) -> Bool {
        let didSaveAPIKey = deepSeekAPIKeyStore.saveAPIKey(apiKey)
        hasDeepSeekAPIKey = deepSeekAPIKeyStore.hasAPIKey

        // Saving a key is the setup step, so completing it also lets the post-onboarding panel appear.
        if didSaveAPIKey && hasDeepSeekAPIKey {
            hasCompletedOnboarding = true
            playIntroDemoIfNeeded()
        }

        return didSaveAPIKey
    }

    /// When off, the overlay is hidden and push-to-talk is disabled.
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
    /// irreversible is refused either way, and off means every tag only points.
    @Published var isAutomaticClickingEnabled: Bool = UserDefaults.standard.object(forKey: "isAutomaticClickingEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isAutomaticClickingEnabled")

    func setAutomaticClickingEnabled(_ enabled: Bool) {
        isAutomaticClickingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutomaticClickingEnabled")
    }

    /// Whether Kiki may type into or press keys on the element the model asked it to operate; off means a keyboard
    /// tag only points. Its own switch rather than sharing the one above: typing into a field and pressing its button are different amounts of trust.
    @Published var isAutomaticKeyboardEnabled: Bool = UserDefaults.standard.object(forKey: "isAutomaticKeyboardEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isAutomaticKeyboardEnabled")

    func setAutomaticKeyboardEnabled(_ enabled: Bool) {
        isAutomaticKeyboardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutomaticKeyboardEnabled")
    }

    /// Built once at launch, because where they are needed is inside a stop's one-second dwell.
    private let elementActionSoundPlayer = ElementActionSoundPlayer()

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Separate from `hasCompletedOnboarding` because the two come apart: setup finishes the instant
    /// a key is saved, while the demo needs every permission it uses.
    @Published var hasPlayedIntroDemo: Bool = UserDefaults.standard.bool(forKey: "hasPlayedIntroDemo")

    /// Plays the welcome animation and intro video, once. Called from the key-save path and the
    /// permission refresh both, so the demo is not lost to ordering.
    func playIntroDemoIfNeeded() {
        guard !hasPlayedIntroDemo else { return }

        // A skip and not a latch: the guide plays the intro itself the moment its last script ends,
        // so latching here would lose the welcome and the video to a closing line still being spoken.
        guard !onboardingGuide.isPlayingASegmentScript else { return }
        guard hasCompletedOnboarding && allPermissionsGranted else { return }

        hasPlayedIntroDemo = true
        UserDefaults.standard.set(true, forKey: "hasPlayedIntroDemo")

        triggerOnboarding()
    }

    func start() {
        refreshAllPermissions()
        print("Kiki start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), speech: \(hasSpeechRecognitionPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        startObservingDisplayConfigurationChanges()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindTheRecordingShortcut()
        startCommandSocketServer()
        // Eagerly touch the API so its TLS warmup handshake completes before the demo fires.
        _ = deepSeekAPI

        // If permissions were revoked, the cursor stays hidden and the panel shows its rows instead.
        if hasCompletedOnboarding && allPermissionsGranted && isKikiCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Last, so every fact the guide reads has been refreshed and the overlay decision made.
        onboardingGuide.beginFollowingTheOnboardingFacts()
    }

    // MARK: - The Command Line Tool

    /// Read off the filesystem rather than remembered: the link can be made or broken outside the
    /// app — by the README's own `ln -s`, or by `Kiki.app` being moved. Refreshed at every open of
    /// the panel, the only place it is drawn.
    @Published private(set) var commandLineToolIsInstalled = false

    @Published private(set) var isInstallingTheCommandLineTool = false

    func refreshCommandLineToolInstallation() {
        commandLineToolIsInstalled = KikiCommandLineInstaller.isInstalled
    }

    /// Puts the command into PATH, behind the one system authorisation prompt that writing to
    /// `/usr/local/bin` costs. The link on disk is the report, not the installer's own answer.
    func installTheCommandLineTool() async {
        guard !isInstallingTheCommandLineTool else { return }

        // The row can be showing 安装 over a link that is already ours, and re-making it would ask
        // for an authorisation there is nothing to authorise.
        refreshCommandLineToolInstallation()
        guard !commandLineToolIsInstalled else { return }

        isInstallingTheCommandLineTool = true
        await KikiCommandLineInstaller.install()
        refreshCommandLineToolInstallation()
        isInstallingTheCommandLineTool = false
    }

    private func startCommandSocketServer() {
        commandSocketServer.start()
    }

    /// Answered before the command is sent, so a terminal that cannot be served is told why instead of watching
    /// a turn fail. Accessibility is deliberately not asked: without it Kiki still sees, answers and points.
    private func commandReadiness() -> KikiCommandReadiness {
        var problems: [String] = []

        if let refusalReason = whyCommandsCannotRunRightNow {
            problems.append(refusalReason)
        }
        if !deepSeekAPIKeyStore.hasAPIKey {
            problems.append("还没有填 DeepSeek API Key。在菜单栏图标里打开设置填一个。")
        }
        if !hasScreenRecordingPermission {
            problems.append(Self.sentenceForTheMissingScreenRecordingGrant)
        }

        // A gesture a build did not have is answered by the build, not the moment: a request to an app that
        // predates it is refused with a sentence instead of arriving as some other gesture.
        return KikiCommandReadiness(
            canRunCommands: problems.isEmpty,
            problems: problems,
            understandsScrolling: true,
            understandsTripleClick: true,
            understandsDragging: true,
            understandsFractionalScreenfuls: true,
            understandsTyping: true,
            understandsPressingKeys: true,
            understandsScreenshots: true,
            understandsLocatingText: true
        )
    }

    /// Why a command cannot be run right now, or nil. A terminal is turned away down two paths — the readiness
    /// report at connect, the failure event sent to one already attached — so the answer lives in one place.
    private var whyCommandsCannotRunRightNow: String? {
        switch whatKikiIsDoingRightNow {
        // A command arrives to *be* the next turn: it replaces a reply in flight, and a replay is one more thing a
        // new question replaces. The icon stops it, and so does a recording — the command would run while the user is still deciding what to record.
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

    /// A command runs exactly as a spoken one does — same teardown, capture, reply and pointing —
    /// except for the voice, which a terminal only gets by asking. The dictation callback's twin.
    private func runCommandFromTerminal(_ commandText: String, speakReply: Bool) {
        // A terminal already attached when Kiki went quiet never saw the readiness answer that would have turned
        // it away. A CLI that held its connection open lands here, and running the command is exactly what resting must not do.
        if let refusalReason = whyCommandsCannotRunRightNow {
            commandSocketServer.send(.failed(message: refusalReason, isRefusal: true))
            return
        }

        // A command takes Kiki over the way talking to it does. The click being called off is not deferred behind
        // the turn — a new question replaces the screen it was read off — and a replay ends the same way.
        stopRecordingOrReplayingAndForgetIt()
        callOffTheActionBeingWaitedOn(because: "这次操作被打断了：另一个终端发了新命令。")

        lastTranscript = commandText
        print("Companion received command: \(commandText)")

        // Before the capture, not after: a terminal that cannot tell a started turn from one that never
        // began is worse than a terminal that is merely quiet.
        commandSocketServer.send(.accepted(message: Self.sentenceForReadingTheScreen))
        sendTranscriptToClaudeWithScreenshot(transcript: commandText, isReadingTheReplyAloud: speakReply)
    }

    /// Stops the turn a terminal is watching — the teardown a key press does, minus the new question.
    private func cancelCommandFromTerminal() {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        ttsClient.discardPreparedSegments()
        writeTheCurrentTurnIntoHistory(interruption: .theUserStartedANewQuestion)
        abandonSpeakingReply()
        clearDetectedElementLocation()
    }

    // MARK: - Reading The Screen For A Terminal

    /// Sends a terminal a picture of one screen — the one request answered with bytes rather than a sentence.
    /// Refused on the grant and a missing screen and nothing else, not even a turn in flight.
    private func captureScreenshotForTerminal(
        _ screenshotRequest: KikiScreenshotRequest,
        fromTheTerminalWith terminalIdentifier: CommandTerminalIdentifier
    ) {
        guard hasScreenRecordingPermission else {
            commandSocketServer.send(
                .failed(message: Self.sentenceForTheMissingScreenRecordingGrant, isRefusal: true),
                toTheTerminalWith: terminalIdentifier
            )
            return
        }

        // No sentence: a capture is a fraction of a second, where `locate` spends seconds reading it.
        commandSocketServer.send(.accepted(message: nil), toTheTerminalWith: terminalIdentifier)

        // The cursor's screen when none was named: it comes first in capture order.
        let screenNumber = screenshotRequest.screenNumber ?? 1

        Task {
            guard let screenCaptures = await captureScreensForTerminal(terminalIdentifier) else { return }

            guard let screenIndex = Self.checkedScreenIndex(forScreenNumber: screenNumber, among: screenCaptures) else {
                commandSocketServer.send(
                    .failed(message: Self.sentenceForTheMissingScreen(screenNumber: screenNumber, among: screenCaptures), isRefusal: true),
                    toTheTerminalWith: terminalIdentifier
                )
                return
            }

            let screenCapture = screenCaptures[screenIndex]
            commandSocketServer.send(
                .captured(
                    message: "已截取第 \(screenIndex + 1) 块屏幕（共 \(screenCaptures.count) 块），"
                        + "\(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) 像素。",
                    screenshotJPEGBase64: screenCapture.imageData.base64EncodedString(),
                    screenNumber: screenIndex + 1
                ),
                toTheTerminalWith: terminalIdentifier
            )
        }
    }

    /// Every place a piece of text is on screen, one point each, in reading order, in the global screen space a
    /// posted event lands in — what lets a script hand one straight back as `kiki click -x -y`. Reading, not acting, so allowed mid-turn.
    private func locateTextForTerminal(
        _ locateRequest: KikiLocateRequest,
        fromTheTerminalWith terminalIdentifier: CommandTerminalIdentifier
    ) {
        let textToFind = locateRequest.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToFind.isEmpty else {
            commandSocketServer.send(.failed(message: "要找的文字是空的。", isRefusal: true), toTheTerminalWith: terminalIdentifier)
            return
        }

        guard hasScreenRecordingPermission else {
            commandSocketServer.send(
                .failed(message: Self.sentenceForTheMissingScreenRecordingGrant, isRefusal: true),
                toTheTerminalWith: terminalIdentifier
            )
            return
        }

        // The seconds of this path — capture and recognition — are both still ahead.
        commandSocketServer.send(.accepted(message: Self.sentenceForReadingTheScreen), toTheTerminalWith: terminalIdentifier)

        Task {
            guard let screenCaptures = await captureScreensForTerminal(terminalIdentifier) else { return }

            if let screenNumber = locateRequest.screenNumber, Self.checkedScreenIndex(forScreenNumber: screenNumber, among: screenCaptures) == nil {
                commandSocketServer.send(
                    .failed(message: Self.sentenceForTheMissingScreen(screenNumber: screenNumber, among: screenCaptures), isRefusal: true),
                    toTheTerminalWith: terminalIdentifier
                )
                return
            }

            let matches = await Self.boxesOfTextOnScreens(
                matchingText: textToFind,
                among: screenCaptures,
                onScreenNumber: locateRequest.screenNumber
            )

            guard !matches.isEmpty else {
                commandSocketServer.send(
                    .failed(
                        message: Self.sentenceForTheMissingText(textToFind, onScreenNumber: locateRequest.screenNumber),
                        isRefusal: true
                    ),
                    toTheTerminalWith: terminalIdentifier
                )
                return
            }

            let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0
            let locatedPoints = matches.map { match -> KikiLocatedPoint in
                let screenLocation = CompanionManager.screenLocation(
                    forScreenshotCoordinate: CGPoint(x: match.box.midX, y: match.box.midY),
                    on: screenCaptures[match.screenIndex]
                ).screenLocation

                let globalScreenPoint = ElementClicker.accessibilityPoint(
                    fromAppKitScreenLocation: screenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints
                )

                return KikiLocatedPoint(
                    globalScreenX: globalScreenPoint.x,
                    globalScreenY: globalScreenPoint.y,
                    screenNumber: match.screenIndex + 1
                )
            }

            let onThatScreen = locateRequest.screenNumber.map { "第 \($0) 块屏幕上" } ?? "屏幕上"
            commandSocketServer.send(
                .located(
                    message: "\(onThatScreen)有 \(locatedPoints.count) 处「\(textToFind)」。",
                    locatedPoints: locatedPoints
                ),
                toTheTerminalWith: terminalIdentifier
            )
        }
    }

    /// The pictures both reading commands are made of, or the one sentence for why there are none.
    private func captureScreensForTerminal(_ terminalIdentifier: CommandTerminalIdentifier) async -> [CompanionScreenCapture]? {
        do {
            return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            commandSocketServer.send(
                .failed(message: "看不到屏幕：\(error.localizedDescription)", isRefusal: true),
                toTheTerminalWith: terminalIdentifier
            )
            return nil
        }
    }

    // MARK: - Doing What A Terminal Asked

    /// Where the action a terminal asked for is aimed, and what to tell the terminal about it.
    private enum ActionTargetResolution {
        /// `dragDestinationAppKitScreenLocation` is where a drag lets go, nil otherwise — beside the
        /// starting point rather than inside the action, a drag being the one gesture whose *where*
        /// is two places.
        case resolved(
            appKitScreenLocation: CGPoint,
            displayFrame: CGRect,
            dragDestinationAppKitScreenLocation: CGPoint?,
            message: String,
            hint: String?
        )
        case refused(reason: String)
    }

    /// An action a terminal asked for while the cursor flies to it: what performing it needs once the cursor
    /// lands, the resolution long gone. The named text is kept because the refusals are asked again on arrival.
    private struct ActionInFlight {
        let beingWaitedOn: ActionBeingWaitedOn
        let appKitScreenLocation: CGPoint
        let displayFrame: CGRect
        /// The text the element was named by, or nil when the point is all there was.
        let elementText: String?
        /// Which button and how many times, or which way and how far. Carried by the flight rather than read off
        /// the request on arrival: the bubble and the terminal's sentence are both cut from it, and all three are one action.
        let action: ElementActionOnArrival
        /// Where a drag lets go, nil otherwise — read on arrival, by which time the request that
        /// named the destination is gone.
        let dragDestinationAppKitScreenLocation: CGPoint?
        /// Written for a replay too, which has no terminal to read it.
        let successMessage: String
    }

    /// Why an action asked for from the terminal cannot be made now, or nil when it can. Only states that mean
    /// Kiki is in the middle of something: the cursor flying home is deliberately not one — its reply has ended, and an event carries its own point.
    private var whyAnActionFromTheTerminalCannotBeMadeRightNow: String? {
        switch whatKikiIsDoingRightNow {
        // Unlike a command, an action takes over nothing: it is a conflict rather than a replacement.
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

    /// The action a terminal asked for, read in one place. A missing `gesture` is one click — what a tool older
    /// than the field sends; an unrecognised one is a refusal, never a click.
    private static func actionAskedForByTheTerminal(_ clickRequest: KikiClickRequest) -> ElementActionOnArrival? {
        switch clickRequest.gesture {
        case nil, KikiCommandProtocol.Gesture.singleClick: return .press(.singleClick)
        case KikiCommandProtocol.Gesture.doubleClick: return .press(.doubleClick)
        case KikiCommandProtocol.Gesture.tripleClick: return .press(.tripleClick)
        case KikiCommandProtocol.Gesture.rightClick: return .press(.rightClick)
        case KikiCommandProtocol.Gesture.scrollUp:
            return .scroll(.up, distance: .screenfuls(CGFloat(clickRequest.screenfuls ?? 1)))
        case KikiCommandProtocol.Gesture.scrollDown:
            return .scroll(.down, distance: .screenfuls(CGFloat(clickRequest.screenfuls ?? 1)))
        case KikiCommandProtocol.Gesture.scrollLeft:
            return .scroll(.left, distance: .screenfuls(CGFloat(clickRequest.screenfuls ?? 1)))
        case KikiCommandProtocol.Gesture.scrollRight:
            return .scroll(.right, distance: .screenfuls(CGFloat(clickRequest.screenfuls ?? 1)))
        case KikiCommandProtocol.Gesture.drag: return .drag
        // A known gesture whose payload is missing reads as unknown: there is no action to build. The
        // tool refuses such a request before sending it.
        case KikiCommandProtocol.Gesture.typeText:
            guard let typedText = clickRequest.typedText else { return nil }
            return .keyboard(.text(typedText))
        case KikiCommandProtocol.Gesture.pressKey:
            guard let keyCombination = clickRequest.keyCombination else { return nil }
            return .keyboard(.combination(name: keyCombination))
        default: return nil
        }
    }

    /// Performs where a terminal asked, and nothing else: no model, no reply, no voice, nothing remembered.
    /// Never interrupts — one arriving mid-turn is refused — and every answer goes to `terminalIdentifier`.
    private func runActionFromTerminal(_ clickRequest: KikiClickRequest, fromTheTerminalWith terminalIdentifier: CommandTerminalIdentifier) {
        // First of the refusals: the rest are all questions about an action, and here there is none.
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

        // By kind, not one gate: the mouse's gestures share a panel row, the keyboard its own.
        switch action {
        case .press, .scroll, .drag:
            guard isAutomaticClickingEnabled else {
                commandSocketServer.send(.failed(message: Self.sentenceForTheSwitchThatIsOff(action), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        case .keyboard:
            guard isAutomaticKeyboardEnabled else {
                commandSocketServer.send(.failed(message: Self.sentenceForTheSwitchThatIsOff(action), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        }

        // Asked before the capture, so seconds of screenshots and recognition are not spent on a conclusion already
        // in hand. A scroll is refused for the grant alone — it can be scrolled back — a drag for the grant and a missing destination.
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
            // Decided here rather than after the screens are read: the one request answerable without
            // looking.
            if let refusal = ElementDragger.refusalOfDrag(
                toAppKitScreenLocation: Self.dragDestinationAppKitScreenLocation(in: clickRequest)
            ) {
                commandSocketServer.send(.failed(message: Self.sentenceForAnActionOutcome(refusal.outcome), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        case .keyboard(.text(let typedText)):
            if let refusal = ElementKeyboard.refusalOfTyping(
                typedText,
                matchingElementLabel: clickRequest.elementText,
                origin: .theUsersOwnCommand
            ) {
                commandSocketServer.send(.failed(message: Self.sentenceForAnActionOutcome(refusal.outcome), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        case .keyboard(.combination(let keyCombination)):
            // No dangerous table in the tool: a table in two places is two answers. The refusal
            // arrives as the exit code the tool would have got anyway.
            if let refusal = ElementKeyboard.refusalOfCombination(named: keyCombination) {
                commandSocketServer.send(.failed(message: Self.sentenceForAnActionOutcome(refusal.outcome), isRefusal: true), toTheTerminalWith: terminalIdentifier)
                return
            }
        }

        // A second action is refused, not queued, and last — never part of
        // `whyAnActionFromTheTerminalCannotBeMadeRightNow`, asked again after the capture, where the action being waited on is this one and it would refuse itself.
        guard actionBeingWaitedOn == nil else {
            commandSocketServer.send(.failed(message: "Kiki 正在做上一个，等它做完。", isRefusal: true), toTheTerminalWith: terminalIdentifier)
            return
        }

        // Stamped before the task exists: an answer bearing an identifier no longer waited on has
        // been answered already and answers nothing.
        let actionBeingWaitedOn = ActionBeingWaitedOn(
            actionIdentifier: UUID(),
            whoHearsTheAnswer: .theTerminalThatAsked(terminalIdentifier)
        )
        self.actionBeingWaitedOn = actionBeingWaitedOn

        // Sent once every refusal above is passed, which is what makes it readable as "the screens are about to
        // be read": by text it faces seconds of capture and recognition, by coordinate it does not — and that one carries no sentence.
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

    /// Calls off the action being waited on, if there is one, and tells whoever asked: it is not made rather
    /// than landing at a point read off a screen the new turn is about to replace.
    private func callOffTheActionBeingWaitedOn(because reason: String) {
        guard let actionBeingWaitedOn else { return }
        endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: reason, isRefusal: true))
    }

    /// Asked after each `await` in the action path — a turn or a command can begin while the screens
    /// are read — and on arrival.
    private func isStillTheActionBeingWaitedOn(_ actionBeingWaitedOn: ActionBeingWaitedOn) -> Bool {
        self.actionBeingWaitedOn?.actionIdentifier == actionBeingWaitedOn.actionIdentifier
    }

    /// Delivered by whoever reaches it first; it cannot be delivered twice, and afterwards nothing is
    /// outstanding — the flight is written off with it, so a late arrival performs nothing.
    private func endTheActionBeingWaitedOn(_ actionBeingWaitedOn: ActionBeingWaitedOn, with event: KikiCommandEvent) {
        guard isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }
        self.actionBeingWaitedOn = nil
        actionInFlight = nil

        switch actionBeingWaitedOn.whoHearsTheAnswer {
        case .theTerminalThatAsked(let terminalIdentifier):
            // Addressed to the terminal that asked: by now the reply watcher may be another terminal,
            // or nobody.
            commandSocketServer.send(event, toTheTerminalWith: terminalIdentifier)
        case .theReplayOfTheUsersRecordedActions:
            scheduleTheNextStepOfTheReplay()
        case .theOnboardingGuideItself:
            // Nothing to do: the guide waits on the permission fact, not on an answer to the click.
            break
        }
    }

    /// Resolves the point a terminal named, performs the action there, and reports what happened.
    private func carryOutTheActionTheTerminalAskedFor(
        _ clickRequest: KikiClickRequest,
        action: ElementActionOnArrival,
        actionBeingWaitedOn: ActionBeingWaitedOn
    ) async {
        let resolution = await resolveActionTarget(for: clickRequest, action: action)

        // Reading the screen takes the better part of a second per screen, and a turn or a command can begin
        // inside that. Being taken over is answered as being taken over, not as whatever a screen from the last turn said on its way out.
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

    /// Everything from a resolved point onwards — where a terminal and a replay meet. The answers that
    /// belong to the *request* are settled here; whether it may start is not, and each source asks that itself.
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

        // The one place both ends of a drag are in hand: a movement between two displays would be posted as a
        // press on one and a release over the other — not a drag to any app that receives it. Held against the start's frame, where the cursor goes.
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

        // With the cursor switched off there is no overlay to make the flight, and the action is performed where
        // it stands: neither a press nor a scroll needs a cursor on screen. Whether the flight carries the user's pointer is the action's own answer.
        guard isOverlayVisible else {
            await performTheActionInFlight(actionInFlight, isClosingTheArrivalFlightAfterwards: false)
            return
        }

        self.actionInFlight = actionInFlight
        flyTheCursorToTheActionBeingWaitedOn(actionInFlight)
    }

    /// Sends the cursor to the point an action is aimed at, so it lands at the end of a flight the user reads
    /// as "Kiki is about to do this". Flown as a tour with no stops left, so the arrival is handed straight back.
    private func flyTheCursorToTheActionBeingWaitedOn(_ actionInFlight: ActionInFlight) {
        // An action aimed at the point the cursor stands on has nowhere to fly: the overlay flies when the
        // published location *changes*, and the cursor is still on that spot, still red, still holding the mouse.
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

        print("Action: flying to (\(Int(actionInFlight.appKitScreenLocation.x)), \(Int(actionInFlight.appKitScreenLocation.y)))")
        schedulePointingTourArrivalTimeout()
    }

    /// Performs the action where it was aimed and delivers the one answer. `isClosingTheArrivalFlightAfterwards`
    /// is true only for a drag begun at the arrival: the tour is left open, closed here after the button is up.
    private func performTheActionInFlight(
        _ actionInFlight: ActionInFlight,
        isClosingTheArrivalFlightAfterwards: Bool
    ) async {
        // Read off the flight rather than the action being waited on now: a flight already sent out
        // does nothing once its action has been answered — by a turn, a command or the timeout.
        let actionBeingWaitedOn = actionInFlight.beingWaitedOn

        // However this returns, the flight a drag opened is closed: the arrival that would have closed it is this
        // call. The guard inside asks the tour's own state, so a flight a new turn already tore down is not closed twice.
        defer {
            if isClosingTheArrivalFlightAfterwards, isFlyingToPointingTourStop {
                finishCurrentPointingTourFlight()
            }
        }

        guard isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }

        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0

        switch actionInFlight.action {
        case .press(let clickKind):
            // Asked again here, as the tour does: this is the last moment before the press, and the
            // sound says "I am about to press this" — which a click that will not go out must not say.
            if ElementClicker.refusalOfClick(
                matchingElementLabel: actionInFlight.elementText,
                origin: .theUsersOwnCommand
            ) == nil {
                elementActionSoundPlayer.playClickSound()
            }

            let clickOutcome = await ElementClicker.clickElement(
                atAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                matchingElementLabel: actionInFlight.elementText,
                kind: clickKind,
                origin: .theUsersOwnCommand
            )
            print("Action: \(clickOutcome)")

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
            // No sound: a scroll presses nothing — the content moving is its own feedback.
            let scrollOutcome = await ElementScroller.scrollElement(
                atAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                direction: direction,
                distance: distance,
                displayFrame: actionInFlight.displayFrame
            )
            print("Action: \(direction) \(distance): \(scrollOutcome)")

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
            // No sound, for the scroll's reason: a drag is not a press — what moves is its own feedback.
            let dragOutcome = await dragForTheUser(
                fromAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                toAppKitScreenLocation: actionInFlight.dragDestinationAppKitScreenLocation,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
            print("Action: \(dragOutcome)")

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

        case .keyboard(let keyboardInput):
            let keyboardOutcome: ElementKeyboardOutcome
            switch keyboardInput {
            case .text(let typedText):
                // Asked again as the click's is, and it is the focus click's sound, because a focus
                // click is what typing begins with: text that will not begin with one must not make it.
                if ElementKeyboard.refusalOfTyping(
                    typedText,
                    matchingElementLabel: actionInFlight.elementText,
                    origin: .theUsersOwnCommand
                ) == nil {
                    elementActionSoundPlayer.playClickSound()
                }

                keyboardOutcome = await ElementKeyboard.typeText(
                    typedText,
                    atAppKitScreenLocation: actionInFlight.appKitScreenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                    matchingElementLabel: actionInFlight.elementText,
                    origin: .theUsersOwnCommand
                )
            case .combination(let keyCombination):
                // The key-press sound and not the click's — a combination presses no mouse button —
                // asked first for the click's reason: one that will be refused must not make it.
                if ElementKeyboard.refusalOfCombination(named: keyCombination) == nil {
                    elementActionSoundPlayer.playKeyPressSound()
                }

                keyboardOutcome = ElementKeyboard.pressCombination(named: keyCombination)
            }
            print("Action: \(keyboardOutcome)")

            switch keyboardOutcome {
            case .postedTheKeystrokes:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .clicked(message: actionInFlight.successMessage))
            case .failedToPostTheKeystrokes:
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(keyboardOutcome), isRefusal: false))
            case .refusedBecauseTheElementCannotBeClicked,
                 .refusedBecauseTheCombinationIsADangerousOne,
                 .refusedBecauseTheCombinationIsNotOneKikiKnows,
                 .refusedBecauseTheTextIsLongerThanKikiWillType,
                 .refusedBecauseAccessibilityIsNotEnabled:
                // Only reachable if the grant went away between the question above and the keys.
                endTheActionBeingWaitedOn(actionBeingWaitedOn, with: .failed(message: Self.sentenceForAnActionOutcome(keyboardOutcome), isRefusal: true))
            }
        }
    }

    /// What the terminal is told while the screens are being read; written here rather than in the
    /// tool because it is a sentence of Kiki's, and the tool prints what it is sent.
    private static let sentenceForReadingTheScreen = "Kiki 正在看屏幕…"

    /// What is missing when the screen cannot be read at all, said once for every path that reads it: a capture
    /// without the grant is the wallpaper rather than an error, so going ahead answers with a screen nobody sees.
    private static let sentenceForTheMissingScreenRecordingGrant =
        "没有屏幕录制权限。在「系统设置 → 隐私与安全性 → 屏幕录制」里给 Kiki 打开。"

    /// Which switch is off, in the terms of the row the user would go and turn back on. A `switch`
    /// over every case, so a fourth kind of action has to be given its row, not inherit the mouse's.
    private static func sentenceForTheSwitchThatIsOff(_ action: ElementActionOnArrival) -> String {
        switch action {
        case .press, .scroll, .drag:
            return "「允许 Kiki 用鼠标操作」没打开，Kiki 现在动不了。"
        case .keyboard:
            return "「允许 Kiki 用键盘操作」没打开，Kiki 现在打不了字。"
        }
    }

    /// What to tell the terminal about a click: a refusal is Kiki saying it will not do this, a
    /// failure is one meant to go out and did not.
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

    /// The same for a scroll, whose one refusal of its own is the grant alone.
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

    /// The same for the keyboard, whose refusals are its own — except the first, which is the click's
    /// carried through, because typing puts the input focus in by clicking the landing point.
    private static func sentenceForAnActionOutcome(_ keyboardOutcome: ElementKeyboardOutcome) -> String {
        switch keyboardOutcome {
        case .postedTheKeystrokes:
            // Not reached: a success is answered with the action's own completion phrase, where
            // 「已输入」 and 「已按 ⌘S」 can differ. Here for the switch to be whole.
            return "键已发出。"
        case .failedToPostTheKeystrokes:
            return "按键没能发出去。"
        case .refusedBecauseTheElementCannotBeClicked(let clickRefusal):
            return sentenceForAnActionOutcome(clickRefusal.outcome)
        case .refusedBecauseTheCombinationIsADangerousOne(let matchedName):
            return "\(matchedName) 这类快捷键 Kiki 不按，你自己来吧。"
        case .refusedBecauseTheCombinationIsNotOneKikiKnows(let name):
            return "「\(name)」这个组合键 Kiki 不认识，没按。"
        case .refusedBecauseTheTextIsLongerThanKikiWillType(let characterCount):
            return "一次最多打 \(ElementKeyboard.maximumCharacterCountKikiWillType) 个字，这次有 \(characterCount) 个，没打。"
        case .refusedBecauseAccessibilityIsNotEnabled:
            return "没有辅助功能权限，Kiki 按不了键。在「系统设置 → 隐私与安全性 → 辅助功能」里给 Kiki 打开。"
        }
    }

    /// A drag that named no destination, said once because two paths reach it — the terminal's and
    /// the resolution path's — and the two must not explain the same refusal in two ways.
    private static let sentenceForADragThatNamedNoDestination = "这次拖拽没说要拖到哪儿（要给 --to-x 和 --to-y）。"

    /// A drag asked for between two displays: refused, never carried across the gap. The movement is events that
    /// each carry their own point, so a press on one display released over another is two unrelated events — and the thing being moved is left pressed.
    private static let sentenceForADragBetweenTwoScreens = "拖拽的起点和终点不在同一块屏幕上，这次没做。"

    /// A screen that was named and is not there, said once for the three things that can name one.
    private static func sentenceForTheMissingScreen(screenNumber: Int, among screenCaptures: [CompanionScreenCapture]) -> String {
        "只有 \(screenCaptures.count) 块屏幕，没有第 \(screenNumber) 块。"
    }

    /// A piece of text that was named and is not on the screen, said once for the two things that can
    /// name one — the click by word and `kiki locate` — so the tool has one sentence to match on.
    private static func sentenceForTheMissingText(_ textToFind: String, onScreenNumber screenNumber: Int?) -> String {
        let onThatScreen = screenNumber.map { "第 \($0) 块屏幕上" } ?? "屏幕上"
        return "\(onThatScreen)没有「\(textToFind)」。"
    }

    /// Where a drag lets go, as the terminal gave it: a point in the global screen space, or nil for the two cases
    /// that have none — a request that named none, and one that is not a drag. Both fields or neither: half a drag is a press held down.
    private static func dragDestinationGlobalScreenPoint(in clickRequest: KikiClickRequest) -> CGPoint? {
        guard let dragToGlobalScreenX = clickRequest.dragToGlobalScreenX,
              let dragToGlobalScreenY = clickRequest.dragToGlobalScreenY else {
            return nil
        }
        return CGPoint(x: dragToGlobalScreenX, y: dragToGlobalScreenY)
    }

    /// The same destination in AppKit coordinates, or nil when the request named none — read from the request,
    /// not the resolution, because it is asked before any screen is read and the refusal costs no capture.
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
        // Read here rather than inside the two ways of naming a start: a drag cannot be made without
        // it, and a request naming its start by text would otherwise spend seconds of screenshots on
        // a conclusion already in hand.
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

    /// The opening of the sentence the terminal is answered with — 「已点击」「已双击」「已三击」「已右键点击」
    /// 「已往下滚 3 屏：」「已拖动」「已输入「季度报告」到」「已按 ⌘S：」 — the part that depends on the action;
    /// named rather than inferred from the subcommand, because tool and app can disagree about a gesture. The
    /// scroll and combination forms end in a colon so the object reads the same either way.
    private static func completionPhraseForTheAction(_ action: ElementActionOnArrival) -> String {
        switch action {
        case .press(.singleClick): return "已点击"
        case .press(.doubleClick): return "已双击"
        case .press(.tripleClick): return "已三击"
        case .press(.rightClick): return "已右键点击"
        case .scroll(let direction, let distance): return "已\(Self.phraseForScrolling(direction, distance: distance))："
        case .drag: return "已拖动"
        case .keyboard(.text(let typedText)): return "已输入「\(typedText)」到"
        case .keyboard(.combination(let name)): return "已按 \(ElementKeyboard.phraseForPressingKey(name))："
        }
    }

    /// How a scroll is described in words — 「往下滚 3 屏」「往下滚 240 点」 — the same in the terminal's sentence
    /// and the bubble. A distance says itself in its own unit: a screenful is what a terminal asked for.
    private static func phraseForScrolling(_ direction: ElementScrollDirection, distance: ElementScrollDistance) -> String {
        let directionWord: String
        switch direction {
        case .up: directionWord = "上"
        case .down: directionWord = "下"
        case .left: directionWord = "左"
        case .right: directionWord = "右"
        }
        switch distance {
        case .screenfuls(let screenfuls):
            return "往\(directionWord)滚 \(ElementScrollDistance.screenfulsAsText(screenfuls)) 屏"
        case .points(let points): return "往\(directionWord)滚 \(Int(points.rounded())) 点"
        }
    }

    /// A point the terminal gave in the global screen space, turned into the AppKit location the rest of the app
    /// works in. A point on no display is refused: the event would land unseen, and reporting it done is a claim the terminal cannot check.
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

        // A drag's sentence describes a movement rather than a place, so it says both points, and the
        // colon separates the verb from them.
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

    /// Where a piece of text is on the screens: every appearance, screen by screen in reading order. One
    /// implementation for both lookers — a click by word wants one, `kiki locate` all — so the ordinal cannot disagree between them.
    private static func boxesOfTextOnScreens(
        matchingText textToFind: String,
        among screenCaptures: [CompanionScreenCapture],
        onScreenNumber screenNumber: Int?
    ) async -> [(screenIndex: Int, box: CGRect)] {
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
                matchingElementLabel: textToFind,
                amongRecognizedLines: recognizedTextLines
            )
            matches.append(contentsOf: matchingBoxes.map { (screenIndex: screenIndex, box: $0) })
        }
        return matches
    }

    /// The point where the text the terminal named was found. Screens are counted the way the model's are —
    /// pointer's screen first — so `-n`, `-s` and `:screenN` mean the same thing; reading order across screens.
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

        if let screenNumber, Self.checkedScreenIndex(forScreenNumber: screenNumber, among: screenCaptures) == nil {
            return .refused(reason: Self.sentenceForTheMissingScreen(screenNumber: screenNumber, among: screenCaptures))
        }

        let matches = await Self.boxesOfTextOnScreens(
            matchingText: elementText,
            among: screenCaptures,
            onScreenNumber: screenNumber
        )

        guard !matches.isEmpty else {
            return .refused(reason: Self.sentenceForTheMissingText(elementText, onScreenNumber: screenNumber))
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

        // In the order the drag moves: the thing named first, then the point it is taken to. Nothing
        // at all for an action that stays where it is.
        let dragDestinationClause = dragDestinationGlobalScreenPoint.map {
            "到屏幕坐标 (\(Int($0.x)), \(Int($0.y)))"
        } ?? ""

        let message = screenCaptures.count > 1
            ? "\(completionPhrase)「\(elementText)」（第 \(occurrenceNumber) 个，第 \(match.screenIndex + 1)/\(screenCaptures.count) 块屏幕）\(dragDestinationClause)。"
            : "\(completionPhrase)「\(elementText)」（第 \(occurrenceNumber) 个）\(dragDestinationClause)。"

        // Only when the whole screen set was searched: with `-s` the terminal has already named the
        // screen it meant, and a count of the others corrects nothing.
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

    /// Starts the cursor's one-way flight into the menu bar icon, the instant the wait runs out. The flight
    /// cannot be called off, so a cursor on its way must not be handed a job it would have to abandon.
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
    /// Kiki is still not taking input while this runs — there is nothing at the pointer to hand a
    /// job to until it lands.
    func beginWakingFromTheStatusItemIcon() {
        guard statusItemIconPhase == .cursorRestingInIcon else { return }
        statusItemIconPhase = .cursorWakingFromIcon
    }

    /// The cursor is back beside the pointer and following it again. Kiki takes input from here.
    func cursorDidFinishWakingFromTheStatusItemIcon() {
        guard statusItemIconPhase == .cursorWakingFromIcon else { return }
        statusItemIconPhase = .notInTheIcon
    }

    /// Ends the visit, for the two cases where it must not outlive the cursor it swallowed: the overlay going
    /// away, and a display change. Nothing else may call this — or a cursor would vanish mid-flight.
    func endTheStatusItemIconVisit() {
        guard isNotTakingInputBecauseOfTheStatusItemIcon else { return }
        statusItemIconPhase = .notInTheIcon
    }

    /// Set when the intro wants to start while a guide line is still being spoken: the last grant
    /// lands on the permission poll, which can fall mid-sentence, and the video would sound over the
    /// closing words.
    private var shouldTriggerOnboardingOnceTheGuideStopsSpeaking = false

    func triggerOnboarding() {
        // The guide keeps the voice until its line has been heard through; the video is let go from
        // the one place a line ends, `finishTheOnboardingGuideLineIfItIsStillBeingWaitedOn`.
        guard onboardingGuideLineFinishedSpeakingContinuation == nil else {
            shouldTriggerOnboardingOnceTheGuideStopsSpeaking = true
            return
        }

        NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)

        startOnboardingMusic()

        // The first appearance is what triggers the welcome animation and intro video; the guide's
        // own bring-up consumed it so the welcome would not play at segment 1 — handed back here.
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding from the footer link, with the overlay already visible.
    func replayOnboarding() {
        // The intro demonstrates the cursor, and a Kiki whose cursor is in the menu bar icon has none
        // — it would play as a video whose subject never appears.
        guard !isNotTakingInputBecauseOfTheStatusItemIcon else { return }

        NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)
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
            print("Kiki: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.5
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s.
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("Kiki: Failed to play onboarding music: \(error)")
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

    /// Rebuilds the overlay whenever the connected displays change. Built from `NSScreen.screens` when shown, a
    /// monitor plugged in later has no window — and a target with no view stays set forever, hiding the cursor on every screen.
    private func startObservingDisplayConfigurationChanges() {
        displayConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayConfigurationChange()
        }
    }

    /// Rebuilds the overlay for the new display configuration. macOS posts this more than once for a
    /// single plug-in; the rebuild is idempotent, so every pass is safe.
    private func handleDisplayConfigurationChange() {
        // Before the guard: the rebuild constructs every cursor view afresh, and a fresh view follows the pointer
        // with no way to learn about a visit already under way — the icon would keep the cursor's colour while the cursor was back out following the mouse.
        endTheStatusItemIconVisit()

        guard isOverlayVisible else { return }

        overlayWindowManager.refreshOverlaysForDisplayConfigurationChange(
            onScreens: NSScreen.screens,
            companionManager: self
        )

        // A display unplugged mid-flight takes the pending target with it, and no view will ever
        // consume that location — cleared rather than left to hide the cursor forever.
        if let pendingTargetDisplayFrame = pointingTarget?.displayFrame,
           !NSScreen.screens.contains(where: { $0.frame == pendingTargetDisplayFrame }) {
            clearDetectedElementLocation()
        }
    }

    func clearDetectedElementLocation() {
        // Cleared before the tour, so the overlay sees a target withdrawn rather than one that changed its mind
        // about being pressed under the cursor — the whole target is gone, so nothing goes through `endPointingTour`'s withdrawal.
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
            // Neither half of recording survives the permission going away: the shortcut needs the tap, a replay
            // the grant to press. Ended here, because the tap that would end it was just torn down.
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
            print("Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), speech: \(hasSpeechRecognitionPermission)")
        }

        // Persisted: once the picker has been approved there is nothing to re-check.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            // Covers the user who pasted their key first and granted permissions second.
            playIntroDemoIfNeeded()
        }
    }

    /// Triggers the macOS screen content picker with a dummy capture, and persists the grant.
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
                print("Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isKikiCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    /// Asked from the panel so the dialog does not interrupt the first push-to-talk press. macOS
    /// shows it once, so a second ask opens System Settings instead.
    func requestSpeechRecognitionPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] authorizationStatus in
            // The callback arrives on an arbitrary queue, so hop back before touching published state.
            Task { @MainActor [weak self] in
                self?.hasSpeechRecognitionPermission = authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    ///
    /// Not private because the onboarding guide asks it as segment 5's first beat — the guide has no
    /// panel row to press.
    func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions so the UI updates live. Screen Recording is the exception — macOS
    /// requires an app restart for that one.
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

                // Nothing to do while the microphone side is in a phase; what this observer exists for is the
                // state it settles on. Nothing said means no response task, so the transient hide is set here.
                guard self.dictationPhase == .nothing else { return }
                self.scheduleTransientHideIfNeeded()
            }
    }

    /// Settles `voiceState` onto the facts it depicts. The only place it is written, apart from the credits
    /// fallback, which has no facts. Derived rather than assigned, so there is nothing to arbitrate and a
    /// state no fact supports is not reachable.
    private func settleVoiceState() {
        // The three facts settle several times per segment and most writes change nothing — and an
        // unchanged `@Published` write still invalidates every view reading it.
        let stateTheFactsSupport = voiceStateTheFactsSupport
        guard stateTheFactsSupport != voiceState else { return }
        voiceState = stateTheFactsSupport
    }

    /// What the facts say Kiki is doing. The microphone owns the state while it does anything at all; the reply
    /// owns it from the transcript to the voice done, `isProducingAReply` covering the gap before the model writes.
    private var voiceStateTheFactsSupport: CompanionVoiceState {
        switch dictationPhase {
        case .finalizing, .preparing: return .processing
        case .recording: return .listening
        case .nothing: break
        }

        guard isProducingAReply else { return .idle }
        // Held until the reply is actually heard, because a segment may have been handed over and still be
        // waiting on its own synthesis. A silent turn never hears anything, so it leaves this state when a segment is reached instead.
        if isWaitingForTheFirstSoundOfTheReply { return .processing }
        // The same wait one step further on: at a step boundary the model has been asked for the next step and
        // has not written a word of it. Left to fall through, that wait is 回复中 over a still cursor with no sound around it.
        if isWaitingForTheFirstSegmentOfTheStepNowStreaming { return .processing }
        return isSpeakingReply ? .responding : .processing
    }

    /// Whether the voice has said everything it has been given and the step now streaming has not reached it yet:
    /// `isSpeakingReply` covers a whole turn, so it stays true over the wait between steps, where only the model still works.
    private var isWaitingForTheFirstSegmentOfTheStepNowStreaming: Bool {
        // The index only ever moves forward and this step's segments begin at the count the step
        // started with, so the last test is true only while the voice stands before this step's own
        // narration — only between two steps.
        isSpeakingReply
            && !isReplyStreamComplete
            && hasCurrentSpeechSegmentFinishedSpeaking
            && hasPointerFinishedWithCurrentSpeechSegment()
            && currentSpeechSegmentIndex < speechSegmentCountBeforeTheStepNowStreaming
    }

    /// What the microphone side of Kiki is doing, if anything.
    private enum DictationPhase {
        case nothing
        case preparing
        case recording
        case finalizing
    }

    /// The ordering is a priority, not a sequence: finalising outranks a recording not yet cleaned
    /// up, so a transcript being wrapped up still reads as 处理中.
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

    /// Everything the last thing started, stopped: the reply, the voice, the recording or replay, the action a
    /// terminal waits on. One function because two things begin by replacing what is running, and a second copy
    /// would be a second answer to "starting over"; `interruptedBy` is what the called-off action's terminal is told.
    private func stopEverythingTheLastThingStarted(interruptedBy reason: String) {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        ttsClient.discardPreparedSegments()
        // Stopped playback reports nothing, so the guide line's wait is released here by hand.
        finishTheOnboardingGuideLineIfItIsStillBeingWaitedOn()
        writeTheCurrentTurnIntoHistory(interruption: .theUserStartedANewQuestion)
        abandonSpeakingReply()
        clearDetectedElementLocation()
        // Before the action below, so a step of a replay dies with the replay.
        stopRecordingOrReplayingAndForgetIt()
        // A press placed now would land on a screen this turn is about to replace.
        callOffTheActionBeingWaitedOn(because: reason)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }
            // Only `.pressed` is refused: `.released` is the cleanup path for a start that never
            // happened, and swallowing it would leave the waveform stuck on screen.
            guard !isNotTakingInputBecauseOfTheStatusItemIcon else { return }

            transientHideTask?.cancel()
            transientHideTask = nil

            if !isKikiCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)

            // Pressing the key *is* starting the next question, so this is the earliest instant the
            // previous reply can be called over.
            stopEverythingTheLastThingStarted(interruptedBy: "这次操作被打断了：Kiki 开始听你说话了。")


            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // A release arriving before the async start began recording would leave the waveform stuck.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Recording And Replaying The User's Own Actions

    /// Binds the shortcut that starts, ends and interrupts a recording. The recorder owns the chord rather than
    /// the push-to-talk monitor, because ending a recording is something only the recorder can do, and the tap therefore listens for it at all times.
    private func bindTheRecordingShortcut() {
        recordedActionsShortcutCancellable = userActionRecorder
            .shortcutWasTappedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleTheRecordingShortcutBeingTapped()
            }
    }

    /// One tap of shift+option: it starts a recording, ends one and replays it, or stops the replay and forgets
    /// it. A tap rather than a hold: a held modifier would sit on every recorded click and eat every shortcut.
    private func handleTheRecordingShortcutBeingTapped() {
        switch recordedActionsPhase {
        case .neitherRecordingNorReplaying:
            startRecordingWhatTheUserIsDoing()
        case .recordingWhatTheUserIsDoing:
            endTheRecordingAndReplayIt()
        case .replayingWhatTheUserDid:
            stopRecordingOrReplayingAndForgetIt()
            // A replay that presses one more thing after being told to stop says the opposite of what
            // the tap said: a step spends its first half reading the screen, so the tap lands inside one.
            callOffTheActionBeingWaitedOn(because: "这次重放停下来了。")
        }
    }

    /// Starts watching the user's hands, or says why Kiki will not — a recording of work Kiki cannot
    /// do again is worthless, so the refusal is said before the user starts rather than after.
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

        // A recording replaces whatever is running, the way a question does: the screen all of it was
        // aimed at is the one the user is about to work on.
        stopEverythingTheLastThingStarted(interruptedBy: "这次操作被打断了：Kiki 开始记录你的操作了。")

        indexOfTheNextRecordedActionToReplay = 0
        recordedUserActions = []
        recordedActionsPhase = .recordingWhatTheUserIsDoing
        userActionRecorder.startRecording()
        print("Companion is recording what the user does")
    }

    /// Ends the recording and starts replaying it, or gives up quietly when it holds nothing.
    private func endTheRecordingAndReplayIt() {
        let recordedUserActions = userActionRecorder.stopRecording()
        guard !recordedUserActions.isEmpty else {
            recordedActionsPhase = .neitherRecordingNorReplaying
            print("Companion: nothing was recorded")
            return
        }

        // Asked again here: both halves can be turned off while the user works, and a recording is
        // minutes of their own work, so the sentence names what is missing rather than vanishing.
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
        print("Companion is replaying \(recordedUserActions.count) recorded action(s)")
        // The same hop the arrival takes: this is a shortcut press that has to return before a screen
        // can be read.
        Task { await takeTheNextStepOfTheReplay() }
    }

    /// Says, aloud, why a recording is not starting or not replaying — through a synthesizer of its
    /// own, the way the low-credits sentence is: a state entered for a sentence over in a second would
    /// have nothing to end it.
    private func speakTheSentenceThatSaysWhyNothingWillBeRecorded(_ sentence: String) {
        NSSpeechSynthesizer().startSpeaking(sentence)
    }

    /// Ends the recording or replay the user's hands were in the middle of, throws away what was recorded, and
    /// gives the user their pointer back. One function because the two endings are the same ending, and every
    /// thing that takes Kiki over needs all of it; the recording is never kept for later.
    private func stopRecordingOrReplayingAndForgetIt() {
        guard recordedActionsPhase != .neitherRecordingNorReplaying else { return }

        recordedActionsPhase = .neitherRecordingNorReplaying
        replayStepTask?.cancel()
        replayStepTask = nil
        recordedUserActions = []
        indexOfTheNextRecordedActionToReplay = 0
        // Told even when only the replay was running: it holds a recording that has ended, and a stale
        // one would settle into the next recording's first action.
        userActionRecorder.stopRecording()

        // Every replay step is a pointer-carrying flight, so the user's pointer is normally in Kiki's hand here.
        // Left to the landing, the tap that stops a replay would drag the pointer to an element nothing will press and hold it through the tour's three seconds.
        clearDetectedElementLocation()
        requestBuddyReturnHome()
    }

    /// One step of the replay: the action is made exactly the way a terminal's is — same flight, same red cursor,
    /// same click sound, same event — which is why a recorded action is stored as the value the arrival performs.
    private func takeTheNextStepOfTheReplay() async {
        guard recordedActionsPhase == .replayingWhatTheUserDid else { return }
        guard isAutomaticClickingEnabled else {
            stopRecordingOrReplayingAndForgetIt()
            return
        }
        guard recordedUserActions.indices.contains(indexOfTheNextRecordedActionToReplay) else { return }

        let recordedUserAction = recordedUserActions[indexOfTheNextRecordedActionToReplay]
        // Advanced before the action is made, so a step interrupted half way is not the one a restarted
        // loop returns to.
        indexOfTheNextRecordedActionToReplay =
            (indexOfTheNextRecordedActionToReplay + 1) % recordedUserActions.count

        // Named the way a terminal's action is named — everything downstream asks this and nothing else
        // which action it is performing; only who hears the answer differs.
        let actionBeingWaitedOn = ActionBeingWaitedOn(
            actionIdentifier: UUID(),
            whoHearsTheAnswer: .theReplayOfTheUsersRecordedActions
        )
        self.actionBeingWaitedOn = actionBeingWaitedOn

        // Resolved the way a terminal's point is, refusals included: a refused point answers the action
        // like any other, which is how a step whose window has gone away is skipped rather than ending
        // the replay.
        let resolution = await resolveActionTarget(
            atGlobalScreenPoint: recordedUserAction.globalScreenPoint,
            action: recordedUserAction.action,
            dragDestinationGlobalScreenPoint: recordedUserAction.dragDestinationGlobalScreenPoint
        )

        // Asked again after the await: resolving reads the screens, long enough for the user to have
        // tapped the shortcut and ended this.
        guard recordedActionsPhase == .replayingWhatTheUserDid,
              isStillTheActionBeingWaitedOn(actionBeingWaitedOn) else { return }

        await carryOutTheResolvedAction(
            resolution,
            elementText: nil,
            action: recordedUserAction.action,
            actionBeingWaitedOn: actionBeingWaitedOn
        )
    }

    /// Waits out the gap between two replayed actions and takes the next one — the actions are over in
    /// milliseconds, so back to back the cursor would cross the screen twice before the eye could
    /// follow either.
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
    you're kiki, a friendly always-on companion that lives in the user's menu bar. the user just asked you for something — spoken through push-to-talk, or typed into their terminal — and you can see their screen(s). your reply is spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

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
    you have a small purple triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, put the coordinate tag right where you mention the element — inside the sentence, tight against the words that name it — never at the end of the sentence and never at the start of the next one. the cursor sets off when your voice reaches the sentence the tag sits in, and it holds the narration there until it has arrived and stood on the element. a tag left at a sentence boundary is read as belonging to the sentence before it, so the cursor sets off on words that have nothing to do with the element and the pause lands in the wrong place. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is what the element is CALLED. when the element has text written on it, copy that text into the label character for character, exactly as it appears on screen — chinese, file paths, identifiers, product names, all of it — and do not translate or tidy it. the label is matched against the text actually on the screen to place the cursor exactly, so the closer it is to what is really written there, the more precisely you point, and your coordinate only needs to be in the right neighbourhood rather than perfect — as long as the label does match. when nothing is written on the element and you are naming it yourself, there is no text to find, so your coordinate is the only thing placing the cursor and it has to be measured properly rather than estimated. when the element has no text of its own — an icon button, a toolbar, a colour swatch, a panel with nothing written in it — name it in 1-3 english words instead (like "search bar" or "save button"). the tag and the label inside it are parsed by code and never read aloud, so nothing about the label has to sound like speech — but that cuts both ways: the label is not how the user hears what you are pointing at, so the sentence around the tag still has to name the element out loud, in chinese. "最上面是 [POINT:400,213:新华网] 新华网" is heard as "最上面是新华网"; leave that last word out and the very same reply is heard as "最上面是，". this slips most easily when you tag several things in a row — a list of names is exactly where the names end up living in the tags alone, and the user then hears you point at nine things without saying what any of them are.

    write [CLICK:x,y:label] instead when the user wants that element actually operated — opened, pressed, switched on — and you are doing it for them. this tag is not just wording: once the cursor lands on the element, kiki clicks it, once. so write it only where you mean the thing to happen now, and never for anything the user cannot take back — deleting, clearing, uninstalling, formatting, resetting, restoring, restarting, logging out, quitting, shutting down, paying, sending — those stay [POINT:x,y:label] and the user makes that click themselves. keep [POINT:x,y:label] when you are only locating something for them, which is the usual case: someone who asked where a setting lives has not asked to click it. if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    write [DOUBLECLICK:x,y:label] when the element takes two clicks to do what was asked — opening a file, folder or icon on the desktop or in finder, selecting a word in a piece of text, dropping into a cell so it can be edited. a single click on any of those only selects it, so [CLICK:x,y:label] leaves the user looking at a file that never opened. everything above about [CLICK:x,y:label] holds here as well: kiki is doing it for the user, so write it only where you mean it to happen now, and never on anything the user cannot take back. but do not reach for it just because the element matters or because clicking it feels decisive — a button, a menu item, a toolbar control, a switch, a link and a favourite tile on a browser's start page all take exactly one click, and two on those is a different action than the one the user asked for, or nothing at all. when in doubt, [CLICK:x,y:label].

    write [TRIPLECLICK:x,y:label] when what the user wants is a whole paragraph selected — three clicks is the one thing macOS reserves for that, and a double click only takes the word under the pointer. everything above about [CLICK:x,y:label] holds here as well: kiki is doing it, so write it only where you mean it to happen now, and never on anything the user cannot take back. but of all the click tags this is the narrowest and the one that goes wrong most quietly: a button, a menu item, a toolbar control, a switch and a link take exactly one click, and three on any of them is that one action happening three times over, which is not what the user asked for. on prose and nothing else. when in doubt, [CLICK:x,y:label] or [DOUBLECLICK:x,y:label].

    write [RIGHTCLICK:x,y:label] when what the user needs is the element's context menu — the menu that opens on a right click. kiki presses the right button on the element once the cursor lands, so that menu really opens on their screen, with the pointer left sitting on it ready for them to pick from. this is the shape for "how do i compress this file", "how do i rename this folder", "what else can i do with this photo" — the item that does it is in that menu, and no left click gets them there. everything above about [CLICK:x,y:label] holds here as well: kiki is doing it, so write it only where you mean it to happen now, and never on anything the user cannot take back. but do not reach for it over an ordinary button, link, menu item or toolbar control — a right click on those opens a menu nobody asked for instead of the one press they wanted. when in doubt, [POINT:x,y:label].

    one thing to know about it: the menu your own right click opens is not in your screenshot, because you are looking at the screen as it was before your reply started. so never tag anything inside a menu you just opened — say in words what the menu will offer and let the user choose. what you can do instead is write [LOOK] at the end of the reply, which brings you back for a second look at the menu that is now really open.

    write [SCROLLUP:x,y:label], [SCROLLDOWN:x,y:label], [SCROLLLEFT:x,y:label] or [SCROLLRIGHT:x,y:label] when what the user needs is past the edge of what is on screen — the rest of a long list, a page that continues below, a column cut off to the left. kiki scrolls at the element once the cursor lands, so point it at the thing that should move: the list, the text pane, the document. it rolls one screenful by default; append :xN after the label and before any :screenN to say how far — [SCROLLDOWN:640,400:消息列表:x3] rolls that list down three screenfuls, [SCROLLDOWN:640,400:消息列表:x0.5] rolls it half a screen, and N runs from 0.5 to 20 — half a screen is the shortest scroll kiki will make, and whole or half screens are what read best. prefer half a screen when you are scrolling in order to read — following a list, hunting for one entry — because a whole screen carries the lines the user was on off the display, and what they were looking for is as likely to be in the part that just went past as in the part that arrived; save a whole screen or more for when you mean to travel. always with the x: everything after the second colon is read as the element's name, so a bare 「:3」 is swallowed into the label and the scroll never happens.

    two things to know about scrolling. the first is the same one that applies to a menu your own right click opens: your screenshot is the screen as it was when your reply started, so whatever a scroll brings into view is not in front of you — say in words what is down there, and never tag anything you could only see by scrolling, because that coordinate is one you do not have. if what the scroll turns up is something you need to work with, write [LOOK] after it and you will be asked again with the list scrolled. the second is order: a scroll moves everything the tags after it were reading, so a scroll tag goes at the very end of your reply, once every element you meant to point at has been pointed at.

    write [DRAG:x,y:label>X,Y] when what the user wants is something carried from one place to another — a file into a folder, an icon onto the desktop, a slider dragged to the other end, a window moved out of the way. this is the only tag with two points: x,y is the element, which is where the drag starts, and X,Y after the > is where it is let go. kiki presses on the element once the cursor lands, carries it across and releases it there, so the whole movement happens on their screen. tag the thing being moved, never the place it is going — the element is still what the label names and what your coordinate has to be in the neighbourhood of. the drop point is a point and nothing else: there is no text there for kiki to find it by, so unlike the element's coordinate it has to be measured properly rather than estimated. it is read off the same screenshot the element is, so both points are on one screen; if that screen is not the cursor's, the :screenN goes after the label and before the >, as in [DRAG:420,330:季度报告:screen2>1100,600]. the label must never contain a >, and nothing but the label goes before it: everything up to the > is read as the element's name and everything after it as the point, so a :screenN written on the wrong side of the > is swallowed into the label, finds nothing on screen, and leaves the drag with nowhere to go.

    write [TYPE:x,y:label:text] when what the user asked for is words put into something — a search box, a message field, a filename, a cell. kiki clicks the element once the cursor lands, which is what puts the typing into it, and then types the text a character at a time; the characters go in as keystrokes, so chinese works, no input method is involved and nothing touches the clipboard. the label is the element typed into and the text is what goes in it, and both are required: [TYPE:420,330:搜索框:季度报告] types 季度报告 into the search box. the text is the last thing before any :screenN, so it may not contain a colon itself — [TYPE:400,300:搜索框:季度报告:screen2] is that same search box on the second screen. there is a ceiling on it, \(ElementKeyboard.maximumCharacterCountKikiWillType) characters, because every one of them is a key kiki presses and a longer run would be a paste — which kiki does not do. a paragraph of prose is not this tag's work. everything else you know about [CLICK:x,y:label] holds here: kiki is doing it, so only where the user asked for those words to go in, and never into anything the user cannot take back — a field whose name reads like 删除, 格式化 or 卸载 stays a [POINT:x,y:label] and the user types in it themselves. typing gives way to nothing, so it is also worth saying out loud what you are putting there, because the user watches it go in one character at a time.

    write [KEY:x,y:label:combination] when what the user needs is a keyboard shortcut pressed — a menu command with no button to press, or one that is quicker typed than clicked. kiki presses the combination once the cursor lands and clicks nothing: a click moves the insertion point, and no shortcut wants the caret somewhere else. write the combination with + between the parts, names and symbols both read — [KEY:640,420:季度报告.txt:cmd+s] and [KEY:640,420:季度报告.txt:⌘S] press the same keys, and so do cmd+shift+t and command+shift+t. one key with any of cmd, shift, option and control around it, one plain key at most: cmd+s, cmd+shift+t and ⌃⌘Q are combinations, cmd+shift is not one and neither is a bare letter. the element you tag is the one the shortcut acts on, so the user can see where it is going — but the keys land at whatever has the focus, which is not something you can see from a screenshot, so reach for this when the user named the shortcut or when what it does is plain from the words around it. kiki refuses the combinations that take the screen away or throw work out — clearing the trash, logging out, restarting, forcing an app to quit, locking the screen — so never write those.

    write [LOOK] on its own, at the very end of your reply, when you need to see the screen again after doing what you tagged. everything you tagged happens first, in the order you wrote it, and only then does kiki take a fresh screenshot and ask you again with the result — so [LOOK] is how you find out what your own actions actually did, and how you keep looking when the user has sent you searching for something. it is the one tag that names no element; it is never read aloud and never left in what the user hears.

    reach for it where you would otherwise be guessing: a menu you just right-clicked open, a dialog a click brought up, a page that has to load, a folder you just opened, a list a scroll moved. say what you are doing, write [LOOK], and your next reply can read what is really on screen and name the item to press. all of this is written the same way as any other reply — it is still spoken to the user, so talk to them and not to this machinery.

    an action you tagged is a press and not a result. what comes back to you afterwards names the element kiki pressed and says nothing about what the screen did with it, so a click having landed is not the thing happening: a page you were asked to open is open when your next screenshot shows it open, not when you have clicked the link. open it, write [LOOK], and read what is really there — if the page came up, say what is on it; if it did not, say what you see instead and what you are trying next. never tell the user something is done on the strength of having asked for it.

    when the user has sent you looking for something — a file, a folder, a setting, a page — and you cannot see it on screen, looking again is how you search, and the closed folders in front of you are the first place to look. open one, read what is inside it, and if it is not there, come back out and open the next; keep going until you find it or you have been through all of them, and then say plainly that it is in none of them. "it is not in these folders" reached by reading their names is not an answer to what they asked, only a guess at it. and the first step has to act: a reply that only points at the folders moves nothing on screen, so the turn ends there with nothing opened and nothing found.

    a reply that means to press something has to carry the tag that presses it. the sentence saying you will open a menu opens nothing — the tag is the pressing — and a [LOOK] at the end of a reply that tagged no action asks to look again at a screen nothing has touched, so the turn simply ends there and the user is left holding a promise nothing followed. write the gesture on the element you mean and [LOOK] after it; and if there is nothing left to press, say what you found and stop.

    do not write it when the screen will look the same either way. if you have answered the question and there is nothing left to look for, say what you have to say and stop, and the same goes for a reply that only located something with [POINT:x,y:label] — but that is the end of an errand, not of a search, so while you are still looking, having only pointed so far is not your answer: open the next thing in the same reply, and [LOOK] after it. and never write it after an action that was refused or failed, because nothing moved: you would be shown the same picture and reach the same reply. one turn may look again at most \(CompanionManager.maximumStepsInTheTurnBeingAnswered - 1) times.

    you can tag up to fifteen elements in one reply, and the cursor visits them in the order you write them. write them in the order you talk about them, each one sitting in the sentence that names it — the narration waits on an element until the cursor has arrived and stood on it, so a tag written somewhere other than where you mention the element makes the pointing feel out of step. if you want to mention more than fifteen things, pick the fifteen that matter most.

    examples:
    - user asks how to color grade in final cut: "打开 [POINT:1100,42:color inspector] 调色检查器就行，在工具栏右上角那一块。点开之后色轮和曲线都在里面。"
    - user asks what a folder in their terminal is: "最后那一行的 [POINT:660,151:Build] Build 就是 xcode 放编译产物的地方。每次重新构建都往里面写东西，删掉不会有任何损失。"
    - user asks what html is: "html 是超文本标记语言，基本上就是每个网页的骨架。你现在看的这个页面就是它搭的，css 只管往上刷颜色和排版。"
    - user asks how to commit in xcode: "我先把顶上那个 [CLICK:285,11:源代码管理] 源代码管理菜单给你打开，你在里面选提交就行，或者直接按 command option c。"
    - user asks how to save their work in an app: "按一下右上角那个 [CLICK:880,64:保存] 保存按钮就存上了，存过一次之后 command s 也能随时存。"
    - user asks you to open a file sitting on their desktop: "桌面上那个 [DOUBLECLICK:420,330:季度报告] 季度报告双击就打开了，单击它只是选中，不会打开。"
    - user asks to replace a whole paragraph of a document: "在第二段开头那行 [TRIPLECLICK:520,318:本项目自去年立项以来] 本项目自去年立项以来连点三下，整段就选中了，直接打新的就行。"
    - user asks how to compress a file sitting on their desktop: "在那个 [RIGHTCLICK:420,330:季度报告] 季度报告上点右键，菜单里选「压缩」就行。"
    - the same request, but the user asks you to do it rather than show them — the menu is not in your screenshot, so the first reply opens it and looks: "我先在 [RIGHTCLICK:420,330:季度报告] 季度报告上点右键。 [LOOK]"
      and then, with the menu really open in front of you: "菜单出来了，我点 [CLICK:470,395:压缩] 压缩，压缩包会生成在旁边。"
    - user asks you to make a new folder on their desktop, and where that lives is inside a menu you cannot see into: "好，我先在 [CLICK:512,11:文件] 文件菜单里找新建文件夹。 [LOOK]" and then "在菜单第三项，[CLICK:556,120:新建文件夹] 新建文件夹，你在弹出的框里打个名字就行。"
    - user asks you to open a page or a site for them, and what you say about it has to be what is really on screen: "我点开 [CLICK:400,213:新华网] 新华网。 [LOOK]" and then, with the page in front of you: "开了，头条是……" — and if it did not open: "点了没反应，还停在原来那页。我再点一次 [CLICK:400,213:新华网] 新华网。 [LOOK]"
    - user asks which of the folders on their desktop holds last quarter's reports, and no folder name says — so you open them and look, one at a time: "我挨个翻，先开 [DOUBLECLICK:420,330:归档] 归档。 [LOOK]" and then "这个里面只有去年的周报，不是。我退回去看下一个，[CLICK:96,52:back button] 返回。 [LOOK]" and then, from the folder list again, the next one: "[DOUBLECLICK:420,362:项目] 项目我再看一眼。 [LOOK]" — and when they run out: "六个都翻过了，没有放季度报告的那个。它是放在别的地方，还是名字跟这些不一样？"
    - user asks where to start in an unfamiliar app, worth two tags: "先看左上角那个 [POINT:210,64:search field] 搜索框，想找什么直接敲就行。要是找不到，右下角还有个 [POINT:1180,690:filter button] 筛选按钮，点开能按类型和时间筛。"
    - user asks what's in a list, worth several tags — every name is said out loud, not just tagged: "带上「新闻」两个字的从上到下就这几条：最上面是 [POINT:400,213:新华网] 新华网，接着是 [POINT:400,246:央视新闻] 央视新闻，再往下是 [POINT:400,279:腾讯新闻] 腾讯新闻。"
    - the same list, but the user asks you to open them rather than tell them what's there — now it is [CLICK:x,y:label], and the names are still said out loud: "好，我挨个给你打开：先是 [CLICK:400,213:新华网] 新华网，接着是 [CLICK:400,246:央视新闻] 央视新闻，最后是 [CLICK:400,279:腾讯新闻] 腾讯新闻。"
    - element is on screen 2 (not where cursor is): "在你另一块屏幕上，看到那个 [POINT:400,300:terminal:screen2] 终端窗口了吗？"
    - user asks what else is in a list that runs off the bottom of the screen, worth two tags and the scroll last: "再往下还有两栏，先看 [POINT:400,279:腾讯新闻] 腾讯新闻。剩下那两栏我把 [SCROLLDOWN:640,420:侧边栏:x2] 侧边栏往下滚两屏，你接着看就行。"
    - user asks you to file a document away, worth one drag: "我把桌面那个 [DRAG:420,330:季度报告>1160,640] 季度报告拖到右边的项目文件夹里，你看它过去就行。"
    - user asks you to look something up in an app, which takes words and then a key — two tags, the typing first, because the return would otherwise be pressed before the text is in: "我在 [TYPE:420,330:搜索框:季度报告] 搜索框里打上「季度报告」，再按一下 [KEY:420,330:搜索框:return] 回车。 [LOOK]"
    - user asks how to save their work, and would rather have it done than told: "在 [KEY:640,420:季度报告.txt:cmd+s] 这个文档上按一下 command s，就存上了。"
    """

    /// Forgets the conversation when the user has been away long enough that this turn starts a new one, and
    /// records this turn as the one the next gap is measured from — checked at the top of the turn, because a
    /// later check would let the stale rounds go out once more. `Date()`, not a monotonic clock: a laptop closed
    /// overnight should read as a long gap.
    private func startNewConversationIfTheUserHasBeenAway() {
        if let dateOfTheLastActivityInTheConversation {
            let gapSinceTheLastActivitySeconds = Date().timeIntervalSince(dateOfTheLastActivityInTheConversation)
            if gapSinceTheLastActivitySeconds > Self.maximumGapBetweenTurnsInTheSameConversationSeconds {
                print("New conversation — \(Int(gapSinceTheLastActivitySeconds))s since the last "
                      + "activity, dropping \(conversationHistory.count) exchange(s)")
                // Emptied together with the history: a summary left behind would be read as the record
                // of a task the user has walked away from.
                conversationHistory.removeAll()
                summaryOfTheStepsCompressedOutOfTheContext = nil
                numberOfHistoryEntriesTheSummaryStandsInFor = 0
                // The task both histories were the two faces of is over, so the panel says so.
                refreshTaskProgress(includingThePrompt: "")
            }
        }

        dateOfTheLastActivityInTheConversation = Date()
    }

    /// The exchanges the next request carries as they were written, which are the ones the summary
    /// does not stand in for.
    private func historyToSendWithTheNextRequest() -> [(userPlaceholder: String, assistantResponse: String)] {
        conversationHistory
            .dropFirst(numberOfHistoryEntriesTheSummaryStandsInFor)
            .map { (userPlaceholder: $0.userTranscript, assistantResponse: $0.assistantResponse) }
    }

    /// The system prompt, with the summary of the steps the context no longer carries whole appended when there
    /// is one. Appended rather than sent as a message of its own — standing among the turns it would put two
    /// messages of the same role side by side or start on an assistant turn, and the API may refuse either.
    private func systemPromptForThisStep() -> String {
        guard let summaryOfTheStepsCompressedOutOfTheContext,
              !summaryOfTheStepsCompressedOutOfTheContext.isEmpty else {
            return Self.companionVoiceResponseSystemPrompt
        }

        return Self.companionVoiceResponseSystemPrompt + """


        The steps of this task from before the ones you can see have been compressed, because the \
        conversation outgrew the room there is for it. This is what they held. It is a record of \
        your own work rather than anything the user has just said, and the parts of it that record \
        an error, a refusal or a dead end are there so that you do not walk into them again:

        \(summaryOfTheStepsCompressedOutOfTheContext)
        """
    }

    /// What a stretch of the conversation is taken to cost, in tokens — an estimate that errs high on purpose,
    /// since an over-estimate compresses a step early and an under-estimate sends a request the model rejects.
    /// There is no tokenizer in the process; a Chinese character is about a token, a Latin one about a quarter.
    private static func estimatedTokenCount(of text: String) -> Int {
        var estimatedTokenCount = 0.0
        for scalar in text.unicodeScalars {
            estimatedTokenCount += scalar.properties.isIdeographic ? 1.0 : 0.3
        }
        return Int(estimatedTokenCount)
    }

    /// What the next request would cost, as it stands. Screenshots are counted at the estimate per display rather
    /// than left out: they are why compression triggers below half, and a trigger blind to them would spend exactly the room they need.
    private func estimatedTokenCountOfTheContextAsItStands(includingThePrompt prompt: String) -> Int {
        var tokenCount = Self.estimatedTokenCount(of: Self.companionVoiceResponseSystemPrompt)
            + Self.estimatedTokenCount(of: summaryOfTheStepsCompressedOutOfTheContext ?? "")

        for entry in conversationHistory.dropFirst(numberOfHistoryEntriesTheSummaryStandsInFor) {
            tokenCount += Self.estimatedTokenCount(of: entry.userTranscript)
                + Self.estimatedTokenCount(of: entry.assistantResponse)
        }

        return tokenCount
            + Self.estimatedTokenCount(of: prompt)
            + NSScreen.screens.count * Self.estimatedTokenCountOfOneScreenshot
    }

    /// What the settings panel shows about the task, read off the history as it stands — the step being
    /// asked about counted apart from the ones on the record, because its prompt is not in the history
    /// yet.
    private func taskProgressAsItStands(includingThePrompt prompt: String) -> TaskProgress {
        let isRunningARound = numberOfStepsStartedInTheTurnBeingAnswered > 0 && !hasClosedOutTheTurnBeingAnswered

        // A round enters the history once per step, so its steps are consecutive entries sharing one identifier
        // and the rounds are the run changes. The running round's steps are counted in the same pass, both questions being asked of one array.
        var roundCount = 0
        var numberOfStepsOfTheRunningRoundAlreadyOnTheRecord = 0
        var previousRoundIdentifier: UUID?
        for entry in conversationHistory {
            if entry.turnIdentifier != previousRoundIdentifier {
                roundCount += 1
                previousRoundIdentifier = entry.turnIdentifier
            }
            if isRunningARound, entry.turnIdentifier == turnIdentifierOfTheTurnBeingAnswered {
                numberOfStepsOfTheRunningRoundAlreadyOnTheRecord += 1
            }
        }

        // The running round joins the count only while its own first step has not been written yet:
        // from that write on the walk above has counted it.
        if isRunningARound, numberOfStepsOfTheRunningRoundAlreadyOnTheRecord == 0 {
            roundCount += 1
        }

        // The steps before the one in progress are on the record, so what the count is short by is
        // exactly the difference between what has been started and what has been written.
        let numberOfStepsOfTheRunningRoundNotYetOnTheRecord = isRunningARound
            ? max(0, numberOfStepsStartedInTheTurnBeingAnswered - numberOfStepsOfTheRunningRoundAlreadyOnTheRecord)
            : 0

        return TaskProgress(
            roundCount: roundCount,
            stepCount: conversationHistory.count + numberOfStepsOfTheRunningRoundNotYetOnTheRecord,
            isRunning: isRunningARound,
            stepInTheRoundInProgress: isRunningARound ? numberOfStepsStartedInTheTurnBeingAnswered : 0,
            estimatedTokenCountOfTheContext: estimatedTokenCountOfTheContextAsItStands(includingThePrompt: prompt),
            tokenCountThatStartsCompression: Self.tokenCountThatStartsCompression,
            // Cut from the same constant the reset fires on, so the two cannot disagree.
            dateTheNextQuestionStartsANewConversation: dateOfTheLastActivityInTheConversation.map {
                $0.addingTimeInterval(Self.maximumGapBetweenTurnsInTheSameConversationSeconds)
            }
        )
    }

    /// Takes the panel's reading of the task again, for the four callers that have just changed one of its
    /// answers: a step starting, a compression landing, a round closing, the idle gap emptying both histories. Guarded like `settleVoiceState`.
    private func refreshTaskProgress(includingThePrompt prompt: String) {
        let progress = taskProgressAsItStands(includingThePrompt: prompt)
        guard progress != taskProgress else { return }
        taskProgress = progress
    }

    /// Where the context stops carrying the history whole: before this index goes into the summary, from it on
    /// goes out as written; nil when nothing is left to compress. Walked back to a turn's first step — a step
    /// that is not the first opens with a report of the previous step's actions, so a context beginning at one
    /// would open with a result whose call was cut away (the tool_call/tool_result pairing rule).
    private func indexWhereTheContextWouldStartCarryingTheHistoryWhole() -> Int? {
        guard conversationHistory.count > Self.numberOfNewestStepsAlwaysCarriedWhole else { return nil }

        var indexTheContextWouldStartAt = conversationHistory.count
            - Self.numberOfNewestStepsAlwaysCarriedWhole

        while indexTheContextWouldStartAt > numberOfHistoryEntriesTheSummaryStandsInFor,
              conversationHistory[indexTheContextWouldStartAt].turnIdentifier
                == conversationHistory[indexTheContextWouldStartAt - 1].turnIdentifier {
            indexTheContextWouldStartAt -= 1
        }

        // Backing up this far means every step the context could drop is already in the summary, so the
        // compression would spend a call writing down what it already says.
        guard indexTheContextWouldStartAt > numberOfHistoryEntriesTheSummaryStandsInFor else { return nil }
        return indexTheContextWouldStartAt
    }

    /// Compresses the steps the context has outgrown into the summary. Run before the request is built rather
    /// than after one is rejected, which would have already paid for a capture and a round trip; one that fails
    /// is not fatal — the request goes out as it would have anyway, and the next step tries again.
    private func compressTheContextIfItHasOutgrownItsRoom(includingThePrompt prompt: String) async {
        let tokenCountOfTheContextAsItStands = estimatedTokenCountOfTheContextAsItStands(includingThePrompt: prompt)
        guard tokenCountOfTheContextAsItStands > Self.tokenCountThatStartsCompression else { return }

        guard let indexWhereTheContextWouldStartAt = indexWhereTheContextWouldStartCarryingTheHistoryWhole()
        else { return }

        // Copied out before the await: the encoding and the request both suspend, and the history
        // is written on the main actor by the steps that are still arriving.
        let stepsToCompress = Array(conversationHistory[numberOfHistoryEntriesTheSummaryStandsInFor
                                                         ..< indexWhereTheContextWouldStartAt])
        let recordOfTheStepsToCompress = stepsToCompress
            .map { "用户：\($0.userTranscript)\n助手：\($0.assistantResponse)" }
            .joined(separator: "\n\n")

        print("Context at \(tokenCountOfTheContextAsItStands) tokens — compressing "
              + "\(stepsToCompress.count) step(s)")

        do {
            let summary = try await deepSeekAPI.summarizeConversation(
                compressing: recordOfTheStepsToCompress,
                foldingIn: summaryOfTheStepsCompressedOutOfTheContext
            )

            // The summary belongs to the conversation that asked for it: one that came back after the
            // question was replaced would be filed against a history that may be shorter, or about
            // something else entirely.
            guard !Task.isCancelled else { return }

            summaryOfTheStepsCompressedOutOfTheContext = summary
            numberOfHistoryEntriesTheSummaryStandsInFor = indexWhereTheContextWouldStartAt
            print("Compressed into \(summary.count) 字, steps 0..<\(indexWhereTheContextWouldStartAt) now "
                  + "stand on the summary")

            // The panel has been counting down to this moment, and the count has just gone back up.
            refreshTaskProgress(includingThePrompt: prompt)
        } catch {
            // Not fatal: the request goes out over its own budget, and the next step tries again with
            // more of the conversation behind it.
            print("Context compression failed: \(error)")
        }
    }

    /// Captures a screenshot, sends it with the transcript to DeepSeek, and plays the response aloud.
    /// `isReadingTheReplyAloud` is the whole difference between a spoken turn and a typed one: nothing is synthesised, and the cursor paces the tour instead.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        isReadingTheReplyAloud: Bool = true
    ) {
        // Before anything else about this turn, decide whether it continues the last conversation.
        startNewConversationIfTheUserHasBeenAway()

        self.isReadingTheReplyAloud = isReadingTheReplyAloud
        // A fact about the last turn's voice, which the fallback below sets and nothing else clears.
        hasTheNarrationGoneSilent = false

        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        // A segment of the old reply still being synthesised is audio nobody will hear, and its stops
        // must not stay armed for its replacement.
        ttsClient.discardPreparedSegments()
        endPointingTour()

        // Everything above is synchronous, so this is the one race-free moment to capture the reply
        // being replaced: `currentResponseTask` is cancelled but its `catch` has not run yet.
        writeTheCurrentTurnIntoHistory(interruption: .theUserStartedANewQuestion)
        abandonSpeakingReply()

        // A fresh turn: no step behind it, and nothing left over from the last turn's loop for the
        // terminal to be handed twice. After the history write above, which reads the previous prompt.
        numberOfStepsStartedInTheTurnBeingAnswered = 0
        spokenTextOfTheStepsBeforeTheOneInProgress = ""
        hasClosedOutTheTurnBeingAnswered = false
        // After the history write above, which files the previous reply under the identifier of the
        // turn it belonged to.
        turnIdentifierOfTheTurnBeingAnswered = UUID()

        askTheModelForTheNextStepOfTheTurn(prompt: transcript)
    }

    /// Asks the model for one step of the turn: a look at the screen as it is now, and the reply that follows. A turn
    /// is one call of this or several, and the several are what makes it a loop — a reply that acts on the screen and
    /// ends with `[LOOK]` changes the screen out from under itself, so the next step is the same question asked of a
    /// picture nothing else has seen yet.
    ///
    /// - Parameter prompt: The user's transcript for the first step, and the sentence describing what its last actions did for every step after it.
    private func askTheModelForTheNextStepOfTheTurn(prompt: String) {
        transcriptOfTheTurnBeingAnswered = prompt
        // A step is the conversation still going, so it counts as activity against the idle gap.
        dateOfTheLastActivityInTheConversation = Date()
        // Read before the count moves: the first step is the one asked for out of the user's own
        // speech, so the last thing to touch the screen was the user.
        let isTheFirstStepOfTheTurn = numberOfStepsStartedInTheTurnBeingAnswered == 0
        numberOfStepsStartedInTheTurnBeingAnswered += 1
        stepInProgress = StepOfTheTurnBeingAnswered()
        hasTheModelAskedToLookAgain = false

        // The step's prompt is not in the history yet, so the prompt is what is counted beside it.
        refreshTaskProgress(includingThePrompt: prompt)

        // Stamped synchronously, before the task below exists, so a chunk still on its way from the
        // reply being replaced is already recognisable as stale when it lands.
        let thisTurnIdentifier = UUID()
        turnIdentifierOfTheReplyBeingStreamed = thisTurnIdentifier

        // Cleared here and not where the request goes out — the compression and capture below take time: left at
        // the last step's `true`, the previous step's final segment would read the turn as finished and end the narration under the user's ear.
        isReplyStreamComplete = false
        // A silent turn will never hear anything, so the flag would never be cleared by the sound it
        // waits for. Nor is it armed over a step still being spoken: that sound is the one it waits for.
        if !isSpeakingReply {
            isWaitingForTheFirstSoundOfTheReply = isReadingTheReplyAloud
        }
        isProducingAReply = true

        currentResponseTask = Task {
            do {
                // Before the capture, not after it: a step that compressed afterwards would have already
                // spent the round trip and the capture it was meant to save.
                await compressTheContextIfItHasOutgrownItsRoom(includingThePrompt: prompt)

                guard !Task.isCancelled else { return }

                // All connected screens, once the screen has stopped reacting to whatever the step before did. A
                // turn's first step waits for nothing: the last thing to touch the screen was the user, at the one moment a wait would be felt.
                let screenCaptures: [CompanionScreenCapture]
                if isTheFirstStepOfTheTurn {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                } else {
                    screenCaptures = try await CompanionScreenCaptureUtility
                        .captureAllScreensAsJPEGOnceTheScreenHasSettled()
                }

                guard !Task.isCancelled else { return }

                // Read for text now rather than once the reply arrives: recognition takes the better part
                // of a second per screen, and starting it after would add that to every reply that points.
                let recognizedTextLinesTasks = screenCaptures.map { screenCapture in
                    Task {
                        await ScreenshotTextRecognizer.recognizedLines(in: screenCapture.imageData)
                    }
                }

                // Each label states the pixel dimensions of the image it sits beside, so the model's
                // coordinate space matches the image it sees.
                let labeledImages = screenCaptures.map { capture in
                    (
                        data: capture.imageData,
                        label: capture.label
                            + " (image dimensions: \(capture.screenshotWidthInPixels)"
                            + "x\(capture.screenshotHeightInPixels) pixels)"
                    )
                }

                // Pass conversation history so the model remembers prior exchanges
                let historyForAPI = historyToSendWithTheNextRequest()

                // The reply's state has to be clear of the last one's before the first chunk.
                beginStreamingReply(
                    screenCaptures: screenCaptures,
                    recognizedTextLinesTasks: recognizedTextLinesTasks
                )

                let (fullResponseText, _) = try await deepSeekAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptForThisStep(),
                    conversationHistory: historyForAPI,
                    userPrompt: prompt,
                    onTextChunk: { [weak self] accumulatedRawText in
                        // Awaited rather than fired and forgotten: the segmenter has to know which
                        // sentence each new tag sits in before it can cut the reply around it.
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
                // `URLSession.AsyncBytes` promises neither, so the task is asked rather than the error — falling
                // through would read 「额度用完了」 to a user who merely asked again. Nothing is recorded here
                // either: this `catch` can run after the next turn has begun.
                guard !Task.isCancelled else { return }

                // Part of the reply has already been spoken and cannot be taken back; what can be helped
                // is the fallback being read over the top of it.
                ttsClient.stopPlayback()
                ttsClient.discardPreparedSegments()
                writeTheCurrentTurnIntoHistory(interruption: .theReplyFailedPartWayThrough)
                abandonSpeakingReply()
                print("Companion response error: \(error)")
                // A terminal watching this turn is owed an ending rather than a wait it cannot resolve
                // — nothing else about this turn will reach it.
                commandSocketServer.send(.failed(message: "这一轮没能跑完：\(error.localizedDescription)", isRefusal: false))
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                // A step already followed by another one is not the owner of the state below: clearing it
                // here would put the spinner out in the pause between two steps of one turn.
                guard thisTurnIdentifier == turnIdentifierOfTheReplyBeingStreamed else { return }

                // The `await` above returns in the middle of the narration: the turn is not over until
                // the voice is, so the state is left to the last segment.
                guard !isSpeakingReply, !isWaitingForTheFirstSoundOfTheReply else { return }
                isProducingAReply = false
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// In transient cursor mode, waits for the reply and any pointing to finish, then fades the
    /// overlay out after a second. Cancelled when the user starts another interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isKikiCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Asks whether the *reply* is still being spoken, not whether the voice is making sound: the client's
            // `isPlaying` goes false between segments, so polling that would hide the overlay in a silence the cursor is still waiting through.
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

    /// Speaks a hardcoded error message when the API call fails, straight to `NSSpeechSynthesizer` so
    /// it still works if the TTS client is mid-utterance or stuck.
    private func speakCreditsErrorFallback() {
        let utterance = "额度用完了，去 DeepSeek 充值之后我就能继续帮你。"
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        // The one direct write left: this sentence goes out through a synthesizer of its own, which reports
        // nothing back — no first sound, no completion — so there is nothing for the derivation to see. A flag just for it would be read once.
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// How many elements one reply may point at. Every extra stop is another chance for the narration
    /// to sit waiting on a flight, so this is a sanity limit on a rambling reply.
    private static let maximumPointingTourStopCount = 15

    /// Where the cursor is in its trip into the menu bar icon it goes to rest in, and back out.
    ///
    /// Neither flight can be called off, and the stored frame is what the icon's own appearance is
    /// keyed on.
    enum StatusItemIconPhase: Equatable {
        case notInTheIcon
        /// The wait is over: on the way to this icon rectangle, in AppKit screen coordinates — the same
        /// space `NSEvent.mouseLocation` is in.
        case cursorFlyingToIcon(iconScreenFrame: CGRect)
        /// Landed: the icon wears the cursor's colour from here on, and the cursor is gone.
        case cursorRestingInIcon
        /// The pointer came back: on the way out to the position beside it, where following resumes.
        case cursorWakingFromIcon
    }

    /// Whether Kiki has gone quiet because the cursor is in the menu bar icon's hands. True from the moment a
    /// wait runs out, not from the landing, and through the flight back out: that flight cannot be called off,
    /// so until the cursor lands there is nothing to hand a job to.
    var isNotTakingInputBecauseOfTheStatusItemIcon: Bool { statusItemIconPhase != .notInTheIcon }

    /// Resting: on the way into the icon, or already inside it. Read by the two wait-counting paths,
    /// one per gesture — the rest's wait counts only while this is false, the wake's only while true.
    var isRestingInTheStatusItemIcon: Bool {
        switch statusItemIconPhase {
        case .cursorFlyingToIcon, .cursorRestingInIcon: return true
        case .cursorWakingFromIcon, .notInTheIcon: return false
        }
    }

    /// Waking: the cursor is on its way back out to the pointer.
    var isWakingFromTheStatusItemIcon: Bool { statusItemIconPhase == .cursorWakingFromIcon }

    /// What Kiki is doing right now, from the three facts that decide it: the icon first, because while the
    /// cursor is in its hands there is no cursor to send anywhere, then the recording, because a recording and a reply cannot both run.
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

    /// What the cursor does at the element it just pointed at, from the tag the model wrote: locate, press once or
    /// twice or three times, open a menu, scroll, type. One case per gesture rather than one carrying a count and a
    /// button — two presses is a different action from one, and a right click opens what neither does. Two cases carry
    /// a payload because it is the tag's own: a scroll's distance, and a keyboard action's input, since ⌘S and ⌘T are different actions and the bubble must name the right one.
    enum PointingBubbleInvitation: Equatable {
        /// Only locating the element for the user.
        case lookAtElement
        /// Telling the user to click or operate the element.
        case clickElement
        /// Opening or selecting the element, which takes two clicks.
        case doubleClickElement
        /// Selecting a whole paragraph, which takes three clicks.
        case tripleClickElement
        /// The answer is in the element's context menu, which the right button opens.
        case rightClickElement
        /// The element is to be moved. Carries no destination: it is the same drag either way, and
        /// where it lets go travels on the stop.
        case dragElement
        /// There is more to see past the edge of this element, which way and how far. The distance is
        /// not always the model's: a recorded scroll replays under this invitation, measured off the
        /// user's own hand.
        case scrollElement(ElementScrollDirection, distance: ElementScrollDistance)
        /// Words to type into the element, or a combination to press with the element as the thing
        /// being pointed at.
        case keyboardElement(ElementKeyboardInput)

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
            case .keyboardElement(let keyboardInput): return .keyboard(keyboardInput)
            }
        }

        /// The inverse of the property above, for a caller holding a gesture: the words over the cursor
        /// and the presses that go out cannot disagree — the gestures look identical until they happen.
        static func describing(_ clickKind: ElementClickKind) -> PointingBubbleInvitation {
            switch clickKind {
            case .singleClick: return .clickElement
            case .doubleClick: return .doubleClickElement
            case .tripleClick: return .tripleClickElement
            case .rightClick: return .rightClickElement
            }
        }

        /// The same inverse for the other gesture axis — a scroll has a direction and a distance that a
        /// press has no room for.
        static func describing(
            _ direction: ElementScrollDirection,
            distance: ElementScrollDistance
        ) -> PointingBubbleInvitation {
            return .scrollElement(direction, distance: distance)
        }

        /// The same inverse again for a caller holding the whole arrival action — one that got it from
        /// a terminal or a recording rather than a tag.
        static func describing(_ action: ElementActionOnArrival) -> PointingBubbleInvitation {
            switch action {
            case .press(let clickKind): return .describing(clickKind)
            case .drag: return .dragElement
            case .scroll(let direction, let distance): return .describing(direction, distance: distance)
            case .keyboard(let keyboardInput): return .keyboardElement(keyboardInput)
            }
        }

        /// The name of the case for the record file, written out so a log value is something to search
        /// for in the source.
        var name: String {
            switch self {
            case .lookAtElement: return "lookAtElement"
            case .clickElement: return "clickElement"
            case .doubleClickElement: return "doubleClickElement"
            case .tripleClickElement: return "tripleClickElement"
            case .rightClickElement: return "rightClickElement"
            case .dragElement: return "dragElement"
            case .scrollElement(let direction, _): return "scrollElement \(direction)"
            case .keyboardElement(.text): return "keyboardElement text"
            case .keyboardElement(.combination(let name)): return "keyboardElement combination \(name)"
            }
        }
    }

    /// One flight of the cursor, whole: the point it is aimed at and everything it does on arrival.
    struct PointingTarget: Equatable {
        /// Where the element is, in global AppKit screen coordinates.
        let screenLocation: CGPoint
        /// The display frame of the screen the element is on, so the overlay knows which of its windows
        /// should animate.
        let displayFrame: CGRect
        /// What the arrival bubble invites the user to do, taken from the tag the model wrote.
        let bubbleInvitation: PointingBubbleInvitation
        /// Custom bubble text in place of a random phrase; only the onboarding demo sets it, which is
        /// why it is the one fact here with no default.
        let bubbleText: String?
        /// What the element gets on arrival, or nil when Kiki will do nothing to it. Filled from the function that
        /// decides whether the action posts, so drawing and event cannot disagree; withdrawn, not merely unset, when the tour ends under the cursor.
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
        /// Whether the reply carried the [LOOK] marker, which asks to see the screen again once everything it
        /// tagged has been acted on. Stripped from `spokenText` like every other tag, so the voice never says it and history never holds it.
        let hasAskedToLookAgain: Bool
    }

    /// One element on a pointing tour, with the point in the spoken text at which the cursor should
    /// already be on its way there.
    struct PointingTourStop {
        /// The coordinate the model read off the screenshot, in that image's own pixel space — needing
        /// the same scaling and flipping as `PointingParseResult.coordinate`.
        let screenshotCoordinate: CGPoint
        /// Short label describing the element (e.g. "run button").
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
        /// Offset into `spokenText` of the sentence describing this element: the cursor flies while the
        /// model is still describing it, and the same sentence's end is where the segment ends.
        let sentenceStartOffsetInSpokenText: Int
        /// What this stop's arrival bubble should invite the user to do.
        let pointingBubbleInvitation: PointingBubbleInvitation
        /// Where a drag from this stop lets go, in the screenshot's own pixel space and on `screenshotCoordinate`'s
        /// own image — the point is clamped into the image it is scaled against. Nil for a non-drag and for a
        /// `[DRAG:…]` that named no destination, which is what the refusal is read from.
        let dragDestinationScreenshotCoordinate: CGPoint?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag and the same shapes as [CLICK:…], [DOUBLECLICK:…],
    /// [TRIPLECLICK:…], [RIGHTCLICK:…], the four [SCROLL…] with an optional `:xN`, [DRAG:…] with a destination after
    /// `>`, [TYPE:…] and [KEY:…] — returning the spoken text with every tag stripped plus the last tag's coordinate,
    /// label and screen. Looked for anywhere and the last wins: anchored at the end, a trailing "。" after it disabled pointing silently.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Case-insensitive, exact inside; an unrecognized tag fails silently — the reply is spoken and the cursor
        // never moves. The label stops at `]` only, so it may contain colons and `:screenN` must stay lazy for it;
        // the alternatives anchor just after `[` so CLICK cannot swallow RIGHTCLICK. A distance carries its own
        // `x`, a bare `:3` being eaten by that lazy label. A drag's destination is appended last because the
        // groups are read by number (`:x` is 4, `:screen` 5) and one slotted before them would have
        // `screenfuls(fromTagMatch:)` read its y as a distance; its fraction stays non-capturing and `LOOK`
        // captures nothing. `TYPE`/`KEY` must stay alternatives of their own: a payload on the shared body would
        // be read as every tag's *label*, which the lazy label prefers to capture empty, so sharpening would fail
        // silently. Their groups come last, and the payload is required.
        let pattern = #"\[(?i:POINT|CLICK|DOUBLECLICK|TRIPLECLICK|RIGHTCLICK|SCROLLUP|SCROLLDOWN|SCROLLLEFT|SCROLLRIGHT|DRAG):(?:none|(\d+)\s*,\s*(\d+)(?::([^\]\s][^\]]*?))?(?::x(\d+(?:\.\d+)?))?(?::screen(\d+))?(?:\s*>\s*(\d+)\s*,\s*(\d+))?)\]|\[(?i:LOOK)\]|\[(?i:TYPE):(\d+)\s*,\s*(\d+):([^\]\s][^\]]*?):(.+?)(?::screen(\d+))?\]|\[(?i:KEY):(\d+)\s*,\s*(\d+):([^\]\s][^\]]*?):(.+?)(?::screen(\d+))?\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil, tourStops: [], hasAskedToLookAgain: false)
        }
        let allTagMatches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
        let hasAskedToLookAgain = allTagMatches.contains { Self.isTheLookMarker($0, in: responseText) }

        guard let lastTagMatch = allTagMatches.last else {
            // No tag at all, and it goes through the same tidy the tagged path does: this runs on every chunk and
            // its answer is what the segmenter cuts from, so a reply raw until its first tag would have two coordinate spaces.
            let tidiedRawSpokenText = Self.tidiedSpokenText(responseText)
            return PointingParseResult(
                spokenText: tidiedRawSpokenText.trimmingCharacters(in: .whitespacesAndNewlines),
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil,
                tourStops: [],
                hasAskedToLookAgain: hasAskedToLookAgain
            )
        }

        // Strip every tag and rejoin the pieces between them: matches arrive in ascending order, so the length of
        // the text assembled so far is the tag's offset, how a stop later finds its sentence. Offsets are in the raw text, mapped onto the tidied one at the end.
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
        // Trimming only removes from the ends, so every offset drops however much came off the front.
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
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil, tourStops: tourStops, hasAskedToLookAgain: hasAskedToLookAgain)
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: lastScreenshotCoordinate,
            elementLabel: Self.elementLabel(fromTagMatch: lastTagMatch, in: responseText),
            screenNumber: Self.screenNumber(fromTagMatch: lastTagMatch, in: responseText),
            tourStops: tourStops,
            hasAskedToLookAgain: hasAskedToLookAgain
        )
    }

    /// Whether one match is the [LOOK] marker rather than a tag naming an element — read off the
    /// matched text because the marker captures nothing, which is what keeps the group numbers every
    /// other tag is read by where they were.
    private static func isTheLookMarker(_ tagMatch: NSTextCheckingResult, in responseText: String) -> Bool {
        guard let tagRange = Range(tagMatch.range, in: responseText) else { return false }
        return responseText[tagRange].uppercased() == "[LOOK]"
    }

    /// The coordinate inside a tag, in the screenshot's own pixel space, or nil for [POINT:none]. A TYPE or KEY
    /// tag keeps its coordinate in groups of its own: the shared groups are asked first, and a tag whose own
    /// groups captured is answered by them — never both, one match being one alternative.
    private static func screenshotCoordinate(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> CGPoint? {
        for (xGroupNumber, yGroupNumber) in [(1, 2), (8, 9), (13, 14)] where tagMatch.numberOfRanges > yGroupNumber {
            guard let xRange = Range(tagMatch.range(at: xGroupNumber), in: responseText),
                  let yRange = Range(tagMatch.range(at: yGroupNumber), in: responseText),
                  let x = Double(responseText[xRange]),
                  let y = Double(responseText[yRange]) else { continue }
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    /// The element's own text inside a tag, e.g. "保存" — the label the app looks for on the picture,
    /// which is why the prompt asks for it verbatim. Read from the tag's own groups, like the
    /// coordinate.
    private static func elementLabel(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> String? {
        for labelGroupNumber in [3, 10, 15] where tagMatch.numberOfRanges > labelGroupNumber {
            guard let labelRange = Range(tagMatch.range(at: labelGroupNumber), in: responseText) else { continue }
            return String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// What a [TYPE:...] or [KEY:...] tag is to do with its element — the text to type, or the combination to
    /// press — or nil for every other tag. Read off the tag's own name, not by trying both groups: the other one's payload group is empty.
    private static func keyboardInput(
        fromTagMatch tagMatch: NSTextCheckingResult,
        in responseText: String
    ) -> ElementKeyboardInput? {
        guard let tagRange = Range(tagMatch.range, in: responseText) else { return nil }
        let uppercasedTag = responseText[tagRange].uppercased()

        let payloadGroupNumber: Int
        if uppercasedTag.hasPrefix("[TYPE:") {
            payloadGroupNumber = 11
        } else if uppercasedTag.hasPrefix("[KEY:") {
            payloadGroupNumber = 16
        } else {
            return nil
        }

        guard tagMatch.numberOfRanges > payloadGroupNumber,
              let payloadRange = Range(tagMatch.range(at: payloadGroupNumber), in: responseText) else {
            return nil
        }

        let payload = String(responseText[payloadRange])
        // A combination travels as the name the model wrote, not as a decoded value: a name nothing
        // recognizes has to reach the refusal that says so, which a decoded one could not.
        return uppercasedTag.hasPrefix("[TYPE:") ? .text(payload) : .combination(name: payload)
    }

    /// Where a [DRAG:...] tag lets go, in the screenshot's own pixel space, or nil when it named no destination.
    /// Read only for a drag: those groups are in every tag's match, so any other tag's trailing numbers would read as a real one.
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

    /// What the arrival bubble should invite the user to do, read off the tag the model wrote: a click, a scroll, a
    /// drag, the keyboard's two, or looking — the default, since inviting a look is never wrong where 「点这里」 is an
    /// instruction a user who only asked where a setting lives never asked for. A gesture's name has to be added here
    /// as well as to the pattern and the prompt, and this is the silent one of the three: the tag still parses, still flies and still does the thing, and the bubble over it says 「看这里！」 about an action never asked for.
    private static func pointingBubbleInvitation(
        fromTagMatch tagMatch: NSTextCheckingResult,
        in responseText: String
    ) -> PointingBubbleInvitation {
        guard let tagRange = Range(tagMatch.range, in: responseText) else {
            return .lookAtElement
        }
        // Upper-cased because the pattern accepts any case; the whole-prefix tests cannot overlap.
        let uppercasedTag = responseText[tagRange].uppercased()

        // Asked first and separately: the keyboard tags carry a payload, and a payload is not a prefix.
        if let keyboardInput = Self.keyboardInput(fromTagMatch: tagMatch, in: responseText) {
            return .keyboardElement(keyboardInput)
        }

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

    /// The 1-based screen number inside a tag, or nil when it named none — "wherever the cursor already
    /// is". Read from the tag's own groups, for the reason the coordinate is.
    private static func screenNumber(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> Int? {
        for screenGroupNumber in [5, 12, 17] where tagMatch.numberOfRanges > screenGroupNumber {
            guard let screenRange = Range(tagMatch.range(at: screenGroupNumber), in: responseText) else { continue }
            return Int(responseText[screenRange])
        }
        return nil
    }

    /// How many screenfuls a scroll tag asked for, clamped, defaulting to one. Clamped because both ends of the
    /// range are meaningless rather than merely large: `:x0` is a gesture doing nothing, and past the ceiling the count describes no real distance.
    private static func screenfuls(fromTagMatch tagMatch: NSTextCheckingResult, in responseText: String) -> CGFloat {
        guard tagMatch.numberOfRanges >= 5,
              let screenfulsRange = Range(tagMatch.range(at: 4), in: responseText),
              let screenfuls = Double(responseText[screenfulsRange]) else {
            return 1
        }
        return min(max(CGFloat(screenfuls), ElementScroller.smallestScreenfulsInOneRequest),
                   CGFloat(ElementScroller.mostScreenfulsInOneRequest))
    }

    /// Finds where the sentence that mentions the element begins, looking back from the tag: the tour flies from
    /// there, because triggering on the tag would start the flight only once the model had finished talking about
    /// the element. The scan steps over the run of sentence marks and spaces the model writes between tag and
    /// sentence, and without that step it would report where the *next* sentence begins.
    private static let sentenceEndingUTF16CodeUnits: Set<UInt16> = Set("。！？；，、\n!?,;".utf16)

    /// Everything that may sit between a sentence's end and the tag describing it.
    private static let sentenceTrailingUTF16CodeUnits: Set<UInt16> =
        CompanionManager.sentenceEndingUTF16CodeUnits.union(Set(" \t\r\u{3000}".utf16))

    /// The marks a sentence can end on and have itself be a finished thought: this is what lets a sentence naming
    /// no element still close a segment, so a preamble can be heard before the model has decided what to point
    /// at. The comma is not here although `sentenceEndingUTF16CodeUnits` counts it.
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

    /// Cuts the reply into sentences, as UTF-16 ranges that tile the whole of it: a segment ends on a sentence
    /// boundary and either side is spoken by a different utterance, so a gap here would drop words and an overlap say them twice.
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

    /// Which sentence a character offset falls in. An offset past the end reports the last one: a tag at the very
    /// end of a reply has its sentence start on the final character, and no sentence would leave that stop unattached.
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

    /// Cuts the reply into the pieces the voice is handed one at a time. A sentence closes a segment for one of two
    /// reasons: it names a tour stop, so the next segment waits on the cursor getting through those stops, or it ends
    /// on a terminator and is not the last sentence, so nothing is waiting. A sentence that names nothing and does not
    /// end itself — the last sentence, and a run of clauses ending in a comma — is carried on to the next segment. The ranges tile the reply and index the *resolved* stops, one whose screen is gone having been dropped during resolution.
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
            // The last sentence is never cut on its own account, however it ends: the model may still be
            // writing it, so it is carried into the trailing segment.
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

        // Whatever the model said after its last tag — a closing remark, a follow-up question — is still
        // part of the reply, and is the only part still being written.
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

    /// The tidy-up passes run over the assembled spoken text before it is spoken: what they take out is formatting
    /// rather than speech, and the synthesizer reads markdown marks as words and can cut a paragraph short on a blank
    /// line while reporting `didFinish`. Each pass has to be local, because `tidiedOffset(forRawOffset:…)` answers by
    /// tidying the raw text up to that offset — a match reaching past it reports a stop that silently never fires. A numbered list marker is left alone for the same reason.
    private static func tidiedSpokenText(_ text: String) -> String {
        text
            // Invisible and formatting-only characters, out wherever they sit; the markdown marks among them are
            // what the voice reads out as words. The price is a path losing its leading tilde — smaller than a reply heard read aloud.
            .replacingOccurrences(
                of: "[\r\t\u{3000}\u{2028}\u{2029}\u{00A0}\u{200B}\u{FEFF}\u{00AD}\u{200E}\u{200F}*`#~>]",
                with: "",
                options: .regularExpression
            )
            // A paragraph break is a full stop to the ear, unless the reply already stopped there.
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
            // Whatever is left of a break, which is one a reply opened with: a full stop before the first
            // word is not a pause the model asked for.
            .replacingOccurrences(of: #"\n+"#, with: "", options: .regularExpression)
            // Removing a tag leaves the spaces that used to sit either side of it facing.
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            // A tag deleted from between two identical marks makes them meet and read "。。", so an
            // adjacent repeat never legitimately doubled is collapsed. ！ and ？ are left alone.
            .replacingOccurrences(of: #"([。，、])\1"#, with: "$1", options: .regularExpression)
    }

    /// Maps an offset recorded while assembling the raw text onto the tidied text that is spoken. The tidy passes
    /// delete characters, so a recorded offset drifts forward, and one that slipped past its sentence would delay the cursor past the model's description.
    private static func tidiedOffset(forRawOffset rawOffset: Int, inRawText rawText: String, leadingWhitespaceUTF16UnitCount: Int) -> Int {
        let rawTextUTF16View = rawText.utf16
        let clampedRawOffset = min(max(rawOffset, 0), rawTextUTF16View.count)
        let rawPrefixEndIndex = rawTextUTF16View.index(rawTextUTF16View.startIndex, offsetBy: clampedRawOffset)
        let rawPrefix = String(decoding: rawTextUTF16View[..<rawPrefixEndIndex], as: UTF16.self)
        let tidiedPrefixUTF16UnitCount = Self.tidiedSpokenText(rawPrefix).utf16.count
        return max(0, tidiedPrefixUTF16UnitCount - leadingWhitespaceUTF16UnitCount)
    }

    /// Picks which of this turn's captures a point tag refers to: the screen the model named by number, the
    /// cursor's screen when it named none or named one no longer connected. A position, because the answer is keyed by it.
    private static func screenIndex(forScreenNumber screenNumber: Int?, among screenCaptures: [CompanionScreenCapture]) -> Int? {
        if let screenNumber, screenNumber >= 1, screenNumber <= screenCaptures.count {
            return screenNumber - 1
        }
        return screenCaptures.firstIndex(where: { $0.isCursorScreen })
    }

    /// The position of the screen somebody else named, or nil when there is no such screen. A refusal rather than
    /// a fallback — the difference from the function above: answering about a different screen without saying so is the alternative.
    private static func checkedScreenIndex(forScreenNumber screenNumber: Int, among screenCaptures: [CompanionScreenCapture]) -> Int? {
        guard screenNumber >= 1, screenNumber <= screenCaptures.count else { return nil }
        return screenNumber - 1
    }

    /// The coordinate to fly to for a stop — the centre of the on-screen text the model named, or the model's own
    /// coordinate when none is there — with the rectangle it came from. That coordinate is a hint, not an answer: the model reads shapes exactly but estimates positions badly.
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

    /// Converts a coordinate the model read off a screenshot into the global screen location the cursor
    /// overlay flies to, along with the display frame it is on.
    private static func screenLocation(
        forScreenshotCoordinate screenshotCoordinate: CGPoint,
        on screenCapture: CompanionScreenCapture
    ) -> (screenLocation: CGPoint, displayFrame: CGRect) {
        // The screenshot's pixel space, scaled to the display's point space, then AppKit's global coords.
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

    /// Clears the last reply out of the way before the request goes out — a reply is spoken while it is still
    /// arriving, so there is no moment afterwards at which it could be set up. The panel keeps showing the
    /// spinner across this: the caller has already armed the new turn's facts.
    private func beginStreamingReply(
        screenCaptures: [CompanionScreenCapture],
        recognizedTextLinesTasks: [Task<[RecognizedTextLine], Never>]
    ) {
        endPointingTour()

        // The step before this one may still be being spoken: a step whose screen work is done is handed to the
        // model at once, and its audio queues behind what is still playing. So the narration is written off only when nothing is left of it.
        if !isSpeakingReply, !isWaitingForTheFirstSoundOfTheReply {
            // `false` because this runs inside the new turn: the caller has already armed its facts.
            abandonSpeakingReply(settlingTheVoiceState: false)
        }

        // Said up to here belongs to the steps before this one: where this step's indices start.
        speechSegmentCountBeforeTheStepNowStreaming = speechSegmentsOfTheTurnBeingSpoken.count

        streamingReplySegmenter = StreamingReplySegmenter(
            screenCaptures: screenCaptures,
            recognizedTextLinesTasks: recognizedTextLinesTasks
        )
        isPointingTourActive = false
        // The last turn was written into the history by whoever ended it; the next turn starts here.
        hasWrittenTheCurrentTurnIntoHistory = false

        // A length from the last turn is not this turn's, and two replies of the same length would
        // otherwise leave the terminal with this one's first chunk missing.
        rawReplyUTF16CountLastSentToTerminal = -1
    }

    /// Feeds the reply as far as it has been written to the segmenter, and acts on what that settled. Awaited
    /// from inside the streaming callback, so it is on the critical path of reading the response; the one thing
    /// it may wait on is recognition, started before the request for exactly that reason.
    private func absorbStreamedReplyText(
        _ accumulatedRawText: String,
        fromTurnIdentifiedBy turnIdentifier: UUID
    ) async {
        // Cancelling a task stops it delivering, but not instantly: the read can be suspended in its `await` and
        // resume with one more chunk after the next turn has begun, and the turn's identity is the only thing that tells the two apart.
        guard turnIdentifier == turnIdentifierOfTheReplyBeingStreamed else { return }
        guard let streamingReplySegmenter else { return }

        let ingest = await streamingReplySegmenter.absorb(accumulatedRawText: accumulatedRawText)

        // Gated on a terminal actually watching: the answer costs a full parse of the whole reply, which
        // is the very thing the early-out exists to skip.
        if commandSocketServer.hasATerminalWatchingTheReply {
            sendTheReplyAsItStandsToTheTerminal(accumulatedRawText: accumulatedRawText)
        }

        // A skipped pass applies nothing: everything `applyStreamedReplyIngest` does is a function of what
        // a full pass changes, and none of it changed.
        guard let ingest else { return }

        applyStreamedReplyIngest(ingest)
    }

    /// The reply has stopped arriving; everything still held is released. Until it runs the last segment
    /// is withheld, so a reply whose finalised segments have all been spoken still waits here.
    private func concludeStreamedReply(fullRawText: String, fromTurnIdentifiedBy turnIdentifier: UUID) async {
        // The same identity check as `absorbStreamedReplyText`, and it matters more: a stale turn reaching
        // this line would declare the *new* reply complete and release its last segment early.
        guard turnIdentifier == turnIdentifierOfTheReplyBeingStreamed else { return }
        guard let streamingReplySegmenter else { return }

        isReplyStreamComplete = true
        let ingest = await streamingReplySegmenter.conclude(accumulatedRawText: fullRawText)

        // Cannot be left to the teardown a new question performs — that reads the history before the reply it
        // replaces could have been added, so every reply arrives a turn late — and must precede the ingest, which can end the step.
        writeTheCurrentTurnIntoHistory(interruption: nil)

        applyStreamedReplyIngest(ingest)

        // The end of the stream is one of the things that can finish a step, and for a reply that asked
        // for nothing it is the only one: no action will report back and no tour runs out of stops.
        finishTheStepIfEverythingItAskedForIsDone()
    }

    /// The whole of what one step asked for is done, so the turn either takes another step or ends. Its three finishers
    /// finish at different times — the reply stops arriving, the cursor runs out of stops to visit, the last action
    /// reports — so any of the three can be last and all three call this. The voice is not one of them: a step that
    /// waited for it would sit idle through its last sentence before asking the model anything. A step with no actions satisfies the count trivially, the common case.
    private func finishTheStepIfEverythingItAskedForIsDone() {
        guard !stepInProgress.hasBeenClosedOut else { return }
        guard isReplyStreamComplete,
              nextPointingTourStop == nil,
              stepInProgress.numberOfActionsAskedFor == stepInProgress.numberOfActionsThatHaveReportedBack
        else { return }

        guard shouldTheTurnTakeAnotherStep else {
            stepInProgress.hasBeenClosedOut = true
            closeOutTheTurnBeingAnswered()
            return
        }

        // The next step is asked for even while the step before it is still being spoken, so the two runs
        // of narration are one: this step's segments are appended to the turn's list, never replacing it.
        if isSpeakingReply, !isWaitingForTheFirstSoundOfTheReply {
            print("Step \(numberOfStepsStartedInTheTurnBeingAnswered) starts with \(speechSegmentsOfTheTurnBeingSpoken.count - currentSpeechSegmentIndex) segment(s) of narration still owed")
        }

        stepInProgress.hasBeenClosedOut = true

        // A blank line between two steps: the terminal renders what it is sent as it arrives, so a step's last
        // sentence and the next step's first would otherwise run together. It rides on the step that ended, so the turn's last step carries no trailing gap.
        let spokenTextOfTheStepThatJustEnded = spokenTextOfTheStepInProgress
        if !spokenTextOfTheStepThatJustEnded.isEmpty {
            spokenTextOfTheStepsBeforeTheOneInProgress += spokenTextOfTheStepThatJustEnded + "\n\n"
        }

        askTheModelForTheNextStepOfTheTurn(
            prompt: Self.promptForTheStepAfterTheModelsOwnActions(
                sentencesSayingWhatTheyDid: stepInProgress.sentencesSayingWhatTheActionDid
            )
        )
    }

    /// Read freshly rather than off a stored copy: the passes the early-out skipped are exactly the chunks
    /// `spokenText` is behind by.
    private var spokenTextOfTheStepInProgress: String {
        streamingReplySegmenter?.spokenTextAsItStands() ?? ""
    }

    /// Whether the model asked for another look and there is something new for it to see.
    private var shouldTheTurnTakeAnotherStep: Bool {
        guard hasTheModelAskedToLookAgain else { return false }

        // A step whose every action was refused or failed left the screen as the screenshot its reply was
        // written against, so another look earns the same reply — a loop with nothing moving in it.
        guard stepInProgress.didAnyActionReachTheScreen else {
            print("Step asked to look again but nothing on the screen changed — the turn ends here.")
            return false
        }

        guard numberOfStepsStartedInTheTurnBeingAnswered < Self.maximumStepsInTheTurnBeingAnswered else {
            print("Turn stopped after \(numberOfStepsStartedInTheTurnBeingAnswered) steps.")
            return false
        }

        return true
    }

    /// Ends the turn as far as the watching terminal is concerned. Deferred rather than sent when the stream stops: the
    /// turn is over when the cursor finishes acting, not when the model stops writing. The snapshot is the whole turn, so what it read only grows.
    private func closeOutTheTurnBeingAnswered() {
        guard !hasClosedOutTheTurnBeingAnswered else { return }
        hasClosedOutTheTurnBeingAnswered = true

        // The round stops running here, and its last step is already on the record — so the prompt is
        // nothing, there being no longer a request this reading is taken ahead of.
        refreshTaskProgress(includingThePrompt: "")

        let spokenTextOfTheWholeTurn = spokenTextOfTheStepsBeforeTheOneInProgress + spokenTextOfTheStepInProgress

        print("Turn closed out after \(numberOfStepsStartedInTheTurnBeingAnswered) step(s), "
              + "\(spokenTextOfTheWholeTurn.count) 字")

        commandSocketServer.send(.done(spokenText: spokenTextOfTheWholeTurn))
    }

    /// Hands a terminal watching the reply the text as it stands, so far. Skipped while the raw text has not moved,
    /// which is most chunks: the answer costs a whole re-parse, and an unchanged length means an unchanged answer.
    /// Each snapshot is the whole turn, not the current step — the terminal is promised an absolute snapshot rather
    /// than a delta, and a step's alone would *shrink* at every step boundary.
    private func sendTheReplyAsItStandsToTheTerminal(accumulatedRawText: String) {
        let accumulatedRawTextUTF16Count = accumulatedRawText.utf16.count
        guard accumulatedRawTextUTF16Count != rawReplyUTF16CountLastSentToTerminal else { return }
        rawReplyUTF16CountLastSentToTerminal = accumulatedRawTextUTF16Count

        // No segmenter is no reply in progress, and an empty snapshot is worse than none: it would take
        // the steps the terminal has already read back off its screen.
        guard streamingReplySegmenter != nil else { return }

        commandSocketServer.send(.text(spokenTextSoFar:
            spokenTextOfTheStepsBeforeTheOneInProgress + spokenTextOfTheStepInProgress
        ))
    }

    /// Takes what the segmenter made of the reply so far.
    private func applyStreamedReplyIngest(_ ingest: StreamedReplyIngest) {
        // The ingest speaks about one step, numbering its segments from zero, so they are hung on the end
        // of the turn's list at the offset the step began at: only this step's tail is recomputed.
        var segmentsOfTheWholeTurn = Array(
            speechSegmentsOfTheTurnBeingSpoken.prefix(speechSegmentCountBeforeTheStepNowStreaming)
        )
        // A segment cut by the step before carries a range into that step's `resolvedPointingTourStops`, which this
        // step's first tag has just replaced. Left as it was, a range fitting the new tour reads as reached and sends the cursor ahead of the voice.
        for index in segmentsOfTheWholeTurn.indices {
            segmentsOfTheWholeTurn[index].stopIndexRange = 0..<0
        }

        speechSegmentsOfTheTurnBeingSpoken = segmentsOfTheWholeTurn + ingest.speechSegments
        finalizedSpeechSegmentCount = speechSegmentCountBeforeTheStepNowStreaming
            + ingest.finalizedSpeechSegmentCount
        // The marker only ever appears once its `]` has arrived, so a `[LOOK]` cut short by the end of a
        // step reads as no marker rather than as half of one.
        hasTheModelAskedToLookAgain = ingest.hasAskedToLookAgain

        // Handed over whether or not they can be spoken yet: synthesis is what the streaming design moved
        // into the generation window. Skipped for a reply nobody will hear.
        if isReadingTheReplyAloud {
            for settledSegment in ingest.segmentsToSynthesise {
                ttsClient.prepareSpeechSegment(
                    spokenText: settledSegment.spokenText,
                    // The turn's numbering, not the step's: the whole turn's audio is one queue and
                    // `speakPreparedSegment(segmentIndex:)` looks a segment up by this number alone.
                    segmentIndex: speechSegmentCountBeforeTheStepNowStreaming + settledSegment.segmentIndex
                )
            }
        }

        if !ingest.newlyResolvedPointingTourStops.isEmpty {
            resolvedPointingTourStops = ingest.allResolvedPointingTourStops

            // The first tag is what makes this a tour, and it is not a state change — a tag resolving is no sound.
            // Its segment is not cut yet, let alone synthesised, so `.idle` would show the triangle over a reply with nothing to hear.
            if !isPointingTourActive {
                isPointingTourActive = true
                schedulePointingTourStallWatchdog()
            }

            for newlyResolvedStop in ingest.newlyResolvedPointingTourStops {
                print("Element pointing: (\(Int(newlyResolvedStop.screenshotCoordinate.x)), \(Int(newlyResolvedStop.screenshotCoordinate.y))) → \"\(newlyResolvedStop.elementLabel ?? "element")\""
                      + " · model said (\(Int(newlyResolvedStop.modelScreenshotCoordinate.x)), \(Int(newlyResolvedStop.modelScreenshotCoordinate.y)))"
                      + (newlyResolvedStop.didTheLabelMatchTextOnScreen
                         ? " · label matched screen text"
                         : " · label matched nothing on screen, the model's own estimate was used"))
            }
        }

        // Asked on every ingest that ran, because the two events are not the same one: a segment that
        // became final after the one before it was spoken through has no word left to come back for it.
        if isSpeakingReply {
            continuePointingTourIfPossible()
        } else {
            speakCurrentSpeechSegment()
        }
    }

    /// What one pass over the reply so far settled. The segments come back whole rather than as a delta:
    /// they are recomputed every chunk, and a delta could disagree with the first description.
    private struct StreamedReplyIngest {
        /// Every segment the reply holds so far, recomputed from the text just ingested.
        let speechSegments: [CompanionSpeechSegment]
        /// How many of those the model can no longer change; see `StreamingReplySegmenter.ingest`.
        let finalizedSpeechSegmentCount: Int
        /// The segments that have just become final, with the index each will be spoken under.
        let segmentsToSynthesise: [(segmentIndex: Int, spokenText: String)]
        /// The stops whose tags have just closed and been resolved, in the order they must be flown to.
        let newlyResolvedPointingTourStops: [ResolvedPointingTourStop]
        /// Every stop resolved so far, in the same order, for the caller's own copy.
        let allResolvedPointingTourStops: [ResolvedPointingTourStop]
        /// Whether the reply as it stands carries the [LOOK] marker.
        let hasAskedToLookAgain: Bool
    }

    /// Cuts the reply into speech segments while it is still being written: each chunk re-parses the growing document
    /// from the top, one implementation each of the tag parse, the tidy passes and the sentence scan, with no second
    /// incremental copy to drift. That is only sound because every pass between the raw text and the segments is
    /// prefix-stable — a segment cut from a shorter document is the same segment in the longer one. The one approximation is the provisional tail, held back until the text moves past it.
    private final class StreamingReplySegmenter {
        private let screenCaptures: [CompanionScreenCapture]
        private let recognizedTextLinesTasks: [Task<[RecognizedTextLine], Never>]

        /// The raw reply as it stands, half-written tag dropped off the end.
        private var accumulatedRawText = ""

        /// The reply as the voice will read it, tidied and with every tag stripped.
        private(set) var spokenText = ""

        /// Every tag the model has closed so far, in the order it wrote them.
        private(set) var parsedTourStops: [CompanionManager.PointingTourStop] = []

        private(set) var resolvedPointingTourStops: [CompanionManager.ResolvedPointingTourStop] = []

        /// How many of `parsedTourStops` have been through resolution; stops are only appended, so none is
        /// resolved twice.
        private var resolvedTourStopCount = 0

        /// One list per screen, so two stops on two displays naming the same thing do not compete for one
        /// piece of text.
        private var claimedTextBoxesPerScreen: [[CGRect]]

        /// How many segments have been handed to the synthesizer, never more than
        /// `finalizedSpeechSegmentCount`.
        private var handedOverSpeechSegmentCount = 0

        /// The raw reply exactly as the last chunk delivered it, half-written tag and all. Kept beside
        /// `accumulatedRawText` because the early-out means most chunks are not folded in, and history has to ask for the reply as it stands.
        private var rawTextAsReceived = ""

        /// The raw text as of the last pass that ran the whole pipeline; what arrived since is the part the
        /// early-out scans.
        private var rawTextAsOfTheLastFullIngest = ""

        /// Whether one more character could make a finished sentence out of what the reply already ends on:
        /// `finalizedSpeechSegmentCount` wants a segment's end *strictly* inside the text, so "你好。" holds nothing final until one arrives.
        private var couldOneMoreCharacterCloseASentence = true

        init(
            screenCaptures: [CompanionScreenCapture],
            recognizedTextLinesTasks: [Task<[RecognizedTextLine], Never>]
        ) {
            self.screenCaptures = screenCaptures
            self.recognizedTextLinesTasks = recognizedTextLinesTasks
            self.claimedTextBoxesPerScreen = Array(repeating: [], count: screenCaptures.count)
        }

        /// Folds in the reply as far as it has been written; the tail stays provisional. `nil` means what arrived
        /// cannot have changed anything the last pass settled. The early-out lives here rather than inside `ingest`, which `conclude` must never reach.
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

        /// Whether the text that has arrived since the last full pass could change what another one would answer.
        /// Exactly three things can: a `]` closes a tag, which is both a stop and a cut; a sentence mark moves a boundary,
        /// and a comma counts although it closes no segment; and a reply already sitting on a finished sentence has a
        /// segment half-finalised, which is why this cannot be a pure scan. The set scanned for is the wider
        /// `sentenceEndingUTF16CodeUnits` — the tidy can invent a full stop out of newlines.
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

        /// The reply as the voice would read it, worked out from the raw text as it stands: `spokenText` is
        /// only as fresh as the last full pass, and most chunks do not run one — the history asks afresh.
        func spokenTextAsItStands() -> String {
            CompanionManager.parsePointingCoordinates(
                from: Self.droppingAHalfWrittenTag(from: rawTextAsReceived)
            ).spokenText
        }

        /// The reply as the model wrote it, tags and all. A tag the parser did not recognise is the one way
        /// a step can ask to look again and read as having stopped, and it is invisible in the spoken text.
        func rawTextAsItStands() -> String { rawTextAsReceived }

        private func ingest(accumulatedRawText incomingRawText: String, isReplyComplete: Bool) async -> StreamedReplyIngest {
            accumulatedRawText = Self.droppingAHalfWrittenTag(from: incomingRawText)

            // `parsePointingCoordinates` is the whole of the post-processing a reply gets: it strips every tag,
            // computes each stop's sentence offset, and tidies the result — all of them prefix-stable.
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

            // The raw text is recorded whole, half-written tag and all, because it is the next pass's own
            // input that the arriving part is measured against.
            rawTextAsOfTheLastFullIngest = incomingRawText
            couldOneMoreCharacterCloseASentence =
                spokenText.utf16.last.map { CompanionManager.sentenceTerminatingUTF16CodeUnits.contains($0) } ?? true

            return StreamedReplyIngest(
                speechSegments: speechSegments,
                finalizedSpeechSegmentCount: finalizedSpeechSegmentCount,
                segmentsToSynthesise: segmentsToSynthesise,
                newlyResolvedPointingTourStops: Array(newlyResolvedStops),
                allResolvedPointingTourStops: resolvedPointingTourStops,
                hasAskedToLookAgain: parseResult.hasAskedToLookAgain
            )
        }

        /// Turns the tags that have closed since the last pass into screen locations. The one slow thing is
        /// screen text recognition, started before the request went out, so it is almost always finished.
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
                // Only a stop that resolved against the screen has text to claim; one that fell back to the
                // model's own coordinate matched nothing.
                if let matchedTextBox = precisePosition.matchedTextBox {
                    claimedTextBoxesPerScreen[screenIndex].append(matchedTextBox)
                }

                let resolvedLocation = CompanionManager.screenLocation(
                    forScreenshotCoordinate: screenshotCoordinate,
                    on: screenCapture
                )
                // A drag's destination is converted against the same capture the starting point was, so the
                // two ends of one movement cannot land on two different displays.
                let dragDestinationScreenLocation = tourStop.dragDestinationScreenshotCoordinate.map {
                    CompanionManager.screenLocation(forScreenshotCoordinate: $0, on: screenCapture).screenLocation
                }

                resolvedPointingTourStops.append(CompanionManager.ResolvedPointingTourStop(
                    screenshotCoordinate: screenshotCoordinate,
                    modelScreenshotCoordinate: tourStop.screenshotCoordinate,
                    didTheLabelMatchTextOnScreen: precisePosition.matchedTextBox != nil,
                    screenLocation: resolvedLocation.screenLocation,
                    displayFrame: resolvedLocation.displayFrame,
                    elementLabel: tourStop.elementLabel,
                    sentenceStartOffsetInSpokenText: tourStop.sentenceStartOffsetInSpokenText,
                    pointingBubbleInvitation: tourStop.pointingBubbleInvitation,
                    dragDestinationScreenLocation: dragDestinationScreenLocation
                ))
            }
        }

        /// How many of the segments the model can no longer change: every one but the last, if the last is where
        /// the text stops. A count, not a flag: the caller needs the ones that have just crossed the line.
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

        /// Drops a tag the model is part-way through writing: an unclosed tag is ordinary characters to the parser, so a
        /// chunk ending in `[POINT:322,192:已发表。` would cut a segment at that full stop and have the voice read the
        /// half-written tag out. Cut at the *first* never-closed bracket, not the last: text that only grows can only close brackets, so the last would let the truncation point move backwards on a second `[`.
        private static func droppingAHalfWrittenTag(from accumulatedRawText: String) -> String {
            let codeUnits = Array(accumulatedRawText.utf16)

            // A bracket is unclosed exactly when it sits after the last closing bracket there is.
            let lastClosingBracketOffset = codeUnits.lastIndex(of: UInt16(UInt8(ascii: "]"))) ?? -1
            guard let unclosedBracketOffset = codeUnits[(lastClosingBracketOffset + 1)...]
                .firstIndex(of: UInt16(UInt8(ascii: "["))) else {
                return accumulatedRawText
            }
            return String(decoding: codeUnits[..<unclosedBracketOffset], as: UTF16.self)
        }
    }

    /// Drops any tour in progress, and sends the cursor home with it. Speech is left alone: a tour ending
    /// says the cursor is finished pointing, not that the reply is finished being spoken.
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
        // The tour going away is one of the ways the cursor stops having anything left to do about the
        // segment being spoken, and the wait the panel shows on the step now streaming is settled by it.
        settleVoiceState()
        // No stop is left to be pressed, so the press is withdrawn from the target the cursor is standing
        // on. Only that field: clearing the target outright would read as a flight to nil.
        pointingTarget?.actionToPerformOnArrival = nil

        // The tour was the only thing holding the cursor out there, and the return-home timeout is cancelled
        // above: a cursor left on the last stop still holds the user's pointer, so the visit ends with the tour. Reached mid-run, not only at a tour's end.
        if pointingTarget != nil {
            requestBuddyReturnHome()
        }
    }

    /// The stop the tour is on, or nil once every stop has been visited.
    private var nextPointingTourStop: ResolvedPointingTourStop? {
        guard nextPointingTourStopIndex < resolvedPointingTourStops.count else { return nil }
        return resolvedPointingTourStops[nextPointingTourStopIndex]
    }

    // MARK: - Speaking The Reply One Segment At A Time

    /// The stops the segment being spoken names, as a range into `resolvedPointingTourStops`. Empty once
    /// every segment has been spoken.
    private var currentSpeechSegmentStopIndexRange: Range<Int> {
        guard currentSpeechSegmentIndex < speechSegmentsOfTheTurnBeingSpoken.count else {
            return resolvedPointingTourStops.count..<resolvedPointingTourStops.count
        }
        return speechSegmentsOfTheTurnBeingSpoken[currentSpeechSegmentIndex].stopIndexRange
    }

    /// Where in the reply's spoken text the segment being spoken starts, which is what converts the voice's
    /// own offsets back into positions in the reply.
    private var currentSpeechSegmentStartOffsetInSpokenText: Int {
        guard currentSpeechSegmentIndex < speechSegmentsOfTheTurnBeingSpoken.count else { return 0 }
        return speechSegmentsOfTheTurnBeingSpoken[currentSpeechSegmentIndex].startOffsetInSpokenText
    }

    /// How much longer the cursor has to stay on the stop it landed on before it may leave. Zero once the
    /// minimum dwell has been served, and zero when it has not landed on anything.
    private var remainingPointingTourStopDwellSeconds: Double {
        guard let lastPointingTourStopArrivalDate else { return 0 }
        return minimumPointingTourStopDwellSeconds - Date().timeIntervalSince(lastPointingTourStopArrivalDate)
    }

    /// Moves the reply forward as far as it can go right now. Everything that could change the answer runs through
    /// here — a word, a segment spoken through, the cursor landing, a dwell running out — one question in a fixed
    /// order: the cursor has first refusal on every word, and only once it is done is the next segment handed over.
    private func continuePointingTourIfPossible() {
        // Settled here because the cursor's half of the question is not only answered by writes: a stop's
        // dwell runs out on its own, and this call is the only thing that hears about it.
        settleVoiceState()
        if let pointingTourStopTheNarrationHasReached = stopTheNarrationHasReachedInCurrentSpeechSegment() {
            startFlightToPointingTourStop(pointingTourStopTheNarrationHasReached)
            return
        }
        advanceSpeechIfPossible()
    }

    /// The stop the narration has got as far as naming in the segment being spoken, or nil when it names none the
    /// cursor has not already been sent to. A segment spoken through has reached its stops whether or not a word callback said so.
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

    /// Speaks the next segment if both sides are ready for it: the words, which a segment not spoken through has nothing
    /// to release, and the cursor, which is the half that makes the reply wait — the next segment is never handed to the
    /// voice before the dwell on the element has been served. A silent narration is waited out rather than short-circuited: a voice reporting no words still reports the segment finished, and releasing on the words alone would cut a segment off mid-sentence.
    private func advanceSpeechIfPossible() {
        guard isSpeakingReply, hasCurrentSpeechSegmentFinishedSpeaking else { return }
        guard hasPointerFinishedWithCurrentSpeechSegment() else { return }

        // The index may only move onto a segment already cut, never onto one the model is still writing:
        // `speakCurrentSpeechSegment` returns without clearing the flag for that one, the next chunk reads the stale
        // flag as "said" and steps over it too, and the index tracks the tip of the list — the rest of the step is never spoken.
        let indexAfterTheCurrentSegment = currentSpeechSegmentIndex + 1
        let isThereACutSegmentToMoveOnTo = indexAfterTheCurrentSegment < finalizedSpeechSegmentCount
        // The one move that is not onto a segment is the ending, and only once the model has stopped
        // writing this step: the end of a step's segments is an empty waiting room for a step after it.
        let isTheStreamDoneAndThisWasTheLastSegment =
            isReplyStreamComplete && indexAfterTheCurrentSegment >= speechSegmentsOfTheTurnBeingSpoken.count
        guard isThereACutSegmentToMoveOnTo || isTheStreamDoneAndThisWasTheLastSegment else { return }

        currentSpeechSegmentIndex = indexAfterTheCurrentSegment
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

    /// Hands the current segment to the voice, or ends the reply when there are none left. Returning immediately
    /// is deliberate: this is reached from inside the voice's own callbacks, and waiting would block the callback that says the segment is through.
    private func speakCurrentSpeechSegment() {
        guard currentSpeechSegmentIndex < speechSegmentsOfTheTurnBeingSpoken.count else {
            // The end of the segments is not the end of the turn while a step after this one may still be
            // writing them — it is an empty waiting room.
            guard isReplyStreamComplete else { return }
            finishSpeakingReply()
            return
        }
        guard currentSpeechSegmentIndex < finalizedSpeechSegmentCount else { return }

        let speechSegmentIndex = currentSpeechSegmentIndex

        hasCurrentSpeechSegmentFinishedSpeaking = false
        lastSpokenWordEndOffsetInCurrentSpeechSegment = 0
        // The narration's position counts the text of the step it belongs to, so it is comparable only inside one
        // step: this step's first segment is the one place it can still be the step before's, and not a near miss — a stop would read as reached.
        if speechSegmentIndex == speechSegmentCountBeforeTheStepNowStreaming {
            lastNarrationWordEndOffsetInSpokenText = 0
        }
        isSpeakingReply = true
        // `voiceState` follows from that write alone: a segment handed over is not yet a sound, so a reply
        // still waiting for its first one stays `.processing` — see `voiceStateTheFactsSupport`.

        guard isReadingTheReplyAloud else {
            // Nothing was handed to a voice, so no callback will ever report this segment spoken through and the tour would
            // wait on a word that is not coming. It counts as spoken through the moment it is reached, and the cursor becomes
            // the only thing pacing the tour. Not wrapped in a `Task`: there is nothing to await, and a hop would put this and
            // the `continuePointingTour…` call at the end of `applyStreamedReplyIngest` in an unpredictable order.
            markCurrentSpeechSegmentAsSpokenThrough()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.ttsClient.speakPreparedSegment(segmentIndex: speechSegmentIndex)
            // Re-checked because a reply that arrived in the meantime has taken the voice, and this
            // segment is no longer part of what is being said.
            guard self.isSpeakingReply, self.currentSpeechSegmentIndex == speechSegmentIndex else { return }
            // Per step and not per turn: the count it reads, `hasNarrationReportedAnyWords`, is cleared
            // where a step's tour is armed.
            if speechSegmentIndex == self.speechSegmentCountBeforeTheStepNowStreaming {
                self.schedulePointingTourFallbackIfNarrationIsSilent()
            }
        }
    }

    /// Marks the reply as spoken through: nothing is left for the cursor to wait on, so it takes the same route
    /// home a single point does. The facts are cleared here, not where the response task's `await` returns — nothing else would return the panel to 等待中.
    private func finishSpeakingReply() {
        isSpeakingReply = false
        isWaitingForTheFirstSoundOfTheReply = false
        isProducingAReply = false
        if isPointingTourActive {
            shouldReturnBuddyToCursorAfterPointing = true
        }
        requestBuddyReturnHome()

        // The step that has just become spoken through is one of the three things the join waits on and
        // has to say so — though not one of them holds the next request back.
        finishTheStepIfEverythingItAskedForIsDone()
    }

    /// Tells the cursor to come home and resume following, on every screen. Raised wherever the reply the cursor
    /// was pointing for is over — finished, cut off or failed — because all three suspend cursor tracking entirely.
    private func requestBuddyReturnHome() {
        buddyReturnHomeRequestCount += 1
    }

    /// What cut a reply short, and therefore what the history entry says about it. Kept apart because they tell
    /// the model different things: one says the user did not want the rest, the other that Kiki never finished writing it.
    private enum ReplyInterruption {
        case theUserStartedANewQuestion
        case theReplyFailedPartWayThrough

        /// Appended to the assistant's half of the entry, in Chinese like the reply the model reads back,
        /// and on its own paragraph so it cannot be read as part of the sentence before.
        var markerAppendedToTheHistoryEntry: String {
            switch self {
            case .theUserStartedANewQuestion:
                return "\n\n（这条回复被用户打断了，没有说完）"
            case .theReplyFailedPartWayThrough:
                return "\n\n（这条回复出错了，没有说完）"
            }
        }
    }

    /// Writes the turn that is ending into the history the next request is built from. Three callers, because a
    /// reply ends three ways that are not one call stack, with `hasWrittenTheCurrentTurnIntoHistory` keeping it to
    /// one entry per turn. What is written is the *spoken* text, tags stripped: the raw text's coordinates came off
    /// a screenshot already gone and would teach the model to point at last turn's screen.
    private func writeTheCurrentTurnIntoHistory(interruption: ReplyInterruption?) {
        guard !hasWrittenTheCurrentTurnIntoHistory else { return }

        // An interrupted reply is recorded as far as it got — nowhere, for one cut off before its first
        // word: an empty assistant message would teach the model that answering with nothing works.
        let replyAsItStands = streamingReplySegmenter?.spokenTextAsItStands() ?? ""
        guard !replyAsItStands.isEmpty else { return }
        let replyAsTheModelWroteIt = streamingReplySegmenter?.rawTextAsItStands() ?? ""

        hasWrittenTheCurrentTurnIntoHistory = true
        dateOfTheLastActivityInTheConversation = Date()
        conversationHistory.append((
            turnIdentifier: turnIdentifierOfTheTurnBeingAnswered,
            userTranscript: transcriptOfTheTurnBeingAnswered,
            assistantResponse: replyAsItStands
                + (interruption?.markerAppendedToTheHistoryEntry ?? "")
        ))

        // Where `maximumExchangeCountCarriedInHistory` bites. Dropped one at a time and never past the turn in
        // progress, so a turn's steps leave together: cutting at the count alone would evict the question answered fifteen steps into a search.
        while conversationHistory.count > Self.maximumExchangeCountCarriedInHistory,
              conversationHistory.first?.turnIdentifier != turnIdentifierOfTheTurnBeingAnswered {
            conversationHistory.removeFirst()
        }

        print("History \(conversationHistory.count) exchange(s) — 问 "
              + "\(transcriptOfTheTurnBeingAnswered.count) 字 / 答 \(replyAsItStands.count) 字"
              + (interruption == nil ? "" : "（中断）"))

        // Tags and all: a tag the parser did not recognise is invisible in the spoken text history keeps,
        // and is the one way a step can ask to look again and read as having stopped.
        print("Step reply as the model wrote it: \(replyAsTheModelWroteIt)")
    }

    /// Writes off the reply being spoken — one replaced, or one the app is done with; the voice itself is stopped
    /// by the caller. The tour is left alone, since it can outlive the reply while the cursor flies home, but the
    /// segmenter is dropped: a written-off reply has nothing further to ingest and its text grows without bound.
    /// The cursor *is* sent home, because a reply that failed or was replaced reaches only this path. This writes
    /// off the whole turn's narration, not one step's — a step boundary must not cut a sentence still being spoken,
    /// which is why `beginStreamingReply` reaches it only when the voice has already fallen silent.
    ///
    /// - Parameter settlingTheVoiceState: False for `beginStreamingReply`; its caller already armed the turn's facts, and clearing them here would put the spinner out.
    private func abandonSpeakingReply(settlingTheVoiceState: Bool = true) {
        isSpeakingReply = false
        // Except when a new reply is being armed, where the writes below belong to that reply.
        if settlingTheVoiceState {
            // A reply written off will never report a first sound, and nothing else would ever clear a
            // wait that no sound can.
            isWaitingForTheFirstSoundOfTheReply = false
            isProducingAReply = false
        }
        speechSegmentsOfTheTurnBeingSpoken = []
        currentSpeechSegmentIndex = 0
        hasCurrentSpeechSegmentFinishedSpeaking = false
        lastNarrationWordEndOffsetInSpokenText = 0
        lastSpokenWordEndOffsetInCurrentSpeechSegment = 0
        streamingReplySegmenter = nil
        finalizedSpeechSegmentCount = 0
        isReplyStreamComplete = false
        // The cursor is part of what this reply started, so it is part of what writing it off restores.
        // `shouldReturnBuddyToCursorAfterPointing` is left alone — the next teardown clears it.
        requestBuddyReturnHome()
    }

    /// Called by the TTS client as each word is about to be spoken. The narration's position is what drives the
    /// tour: a word reaching the sentence that names an element sends the cursor. Nothing is held here — words
    /// run ahead, and the wait, when there is one, happens at the segment boundary.
    private func handleSpokenCharacterRange(_ spokenCharacterRange: NSRange) {
        // Recorded before any of the guards below: a word arriving at all is proof this voice
        // reports what it is saying, whether or not it is the word that sends the cursor off.
        hasNarrationReportedAnyWords = true
        lastNarrationProgressDate = Date()

        lastSpokenWordEndOffsetInCurrentSpeechSegment = spokenCharacterRange.location + spokenCharacterRange.length
        // The voice reports offsets within the segment it was handed; this converts them into the reply's
        // own space. Not clamped to the segment's end: the voice can only report words it was given.
        lastNarrationWordEndOffsetInSpokenText = currentSpeechSegmentStartOffsetInSpokenText
            + lastSpokenWordEndOffsetInCurrentSpeechSegment

        continuePointingTourIfPossible()
    }

    /// Called when the segment the voice was handed has been spoken through — what releases the next one, and
    /// the only thing that does. A cancelled segment reports nothing and releases nothing: how much of it was heard is not something the voice can say.
    private func handlePlaybackFinished() {
        // The end of a guide line, which is the one thing that releases the guide's next beat. Guarded on
        // `isSpeakingReply` so a reply's segment boundary can never be read as a guide line's end.
        if !isSpeakingReply {
            finishTheOnboardingGuideLineIfItIsStillBeingWaitedOn()
        }

        guard isSpeakingReply,
              currentSpeechSegmentIndex < speechSegmentsOfTheTurnBeingSpoken.count
        else { return }
        markCurrentSpeechSegmentAsSpokenThrough()
    }

    /// Records the segment being narrated as spoken through, and moves the reply forward on it. Shared with the
    /// path that reads nothing aloud, where a segment is spoken through on being reached, no callback ever saying so.
    private func markCurrentSpeechSegmentAsSpokenThrough() {
        hasCurrentSpeechSegmentFinishedSpeaking = true
        // A finished segment counts for as much as a reported word: the synthesizer reports no word marks at
        // all for a short segment, so a list reply runs through several without a word reaching the watchdog.
        lastNarrationProgressDate = Date()
        continuePointingTourIfPossible()
    }

    /// Sends the cursor to a tour stop. The narration is not held here: the words run on over the flight, and
    /// the wait for the cursor happens at the sentence boundary instead, by not handing over the next segment.
    private func startFlightToPointingTourStop(_ pointingTourStop: ResolvedPointingTourStop) {
        beginFlightOfTheCursor(
            to: pointingTourStop.screenLocation,
            on: pointingTourStop.displayFrame,
            with: pointingTourStop.pointingBubbleInvitation,
            // Asked before the flight starts, because the overlay has to know by then: a stop that will be
            // pressed is flown to by carrying the user's pointer, and one that will not is flown to the way
            // it always was.
            performing: actionThatWillActuallyBePerformed(at: pointingTourStop)
        )

        print("Pointing tour: flying to (\(Int(pointingTourStop.screenshotCoordinate.x)), \(Int(pointingTourStop.screenshotCoordinate.y))) → \"\(pointingTourStop.elementLabel ?? "element")\"")

        schedulePointingTourArrivalTimeout()
    }

    /// Starts the cursor flying to one point, with whatever it says and does when it gets there. The single trigger
    /// for a flight, whether from a reply or a terminal: setting the location is what makes an overlay fly.
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

        // In one write: the overlay flies on this changing, so a target assembled field by field would be
        // readable in a state its flight was never in.
        pointingTarget = PointingTarget(
            screenLocation: screenLocation,
            displayFrame: displayFrame,
            bubbleInvitation: pointingBubbleInvitation,
            bubbleText: bubbleText,
            actionToPerformOnArrival: actionToPerformOnArrival
        )

        // And the flight itself, after the target: the overlay reads the target when the count changes, so
        // a bump ahead of the write would fly it to the one before.
        pointingFlightRequestCount += 1
    }

    /// Called by the cursor overlay once it has arrived at a tour stop, or at a point a terminal asked for an action
    /// at. The arrival timeout may already have written this flight off, and counting the arrival twice would skip the next stop.
    func buddyDidArriveAtPointingTarget() {
        guard isFlyingToPointingTourStop else { return }

        // Whether this arrival begins something still running when the cursor lands: a drag, and a run of typed characters
        // — closing the flight out here would move the tour on mid-gesture, letting go of what a drag was carrying or
        // pressing a second element before the first has been typed into. Asked of `requestedActionForArrival`, not of the
        // action that will actually happen: a refused drag or run is performed too (it performs nothing and says so), and the performing task closes the flight afterwards.
        let isStartingAnActionThatOutlivesTheArrival = doesTheActionOutliveTheArrival(
            nextPointingTourStop.flatMap { requestedActionForArrival(at: $0) }
        ) || doesTheActionOutliveTheArrival(actionInFlight?.action)

        if isStartingAnActionThatOutlivesTheArrival {
            // Nothing is flying any more, so the watchdog for a flight that never reports back has nothing
            // to watch. Left armed it would fire part way through the drag and move the tour on with the
            // button still down.
            pointingTourNarrationResumeTimeoutTask?.cancel()
            pointingTourNarrationResumeTimeoutTask = nil
        }

        // Read before the flight is closed out, because closing it out moves the tour past it.
        if let pointingTourStop = nextPointingTourStop {
            performTheActionTheModelAskedForItIfAny(
                at: pointingTourStop,
                isClosingTheArrivalFlightAfterwards: isStartingAnActionThatOutlivesTheArrival
            )
        }

        // Written off before the flight is closed out, so the teardown below does not read an action
        // answered here as one whose cursor never arrived and fail it on the way past.
        if let actionThatJustArrived = actionInFlight {
            actionInFlight = nil
            Task {
                await performTheActionInFlight(
                    actionThatJustArrived,
                    isClosingTheArrivalFlightAfterwards: isStartingAnActionThatOutlivesTheArrival
                )
            }
        }

        guard !isStartingAnActionThatOutlivesTheArrival else { return }
        finishCurrentPointingTourFlight()
    }

    /// Whether an action is still going when the cursor has landed: a drag is moving to a second point, and a run
    /// of text is a landing click and then a character at a time. A combination is not one of them — a press and a
    /// release microseconds apart. A `switch` over every case, so an action added later fails to build instead of
    /// being quietly treated as over on arrival.
    private func doesTheActionOutliveTheArrival(_ action: ElementActionOnArrival?) -> Bool {
        switch action {
        case .drag, .keyboard(.text): return true
        case .keyboard(.combination), .press, .scroll, .none: return false
        }
    }

    /// The action the cursor just landed on, whichever gesture the tag named, or nil when it asked for nothing or
    /// acting is off. Reached from the cursor *arriving* and nowhere else: the arrival timeout means no view accepted the target.
    private func requestedActionForArrival(at pointingTourStop: ResolvedPointingTourStop) -> ElementActionOnArrival? {
        guard let action = pointingTourStop.pointingBubbleInvitation.actionToPerformOnArrival else { return nil }

        // Asked by the kind of action rather than as one gate: the three mouse gestures share the panel's row and
        // the keyboard has one of its own, and a `switch` over every case makes a fourth family be given its row here rather than inherit the mouse's.
        switch action {
        case .press, .scroll, .drag:
            guard isAutomaticClickingEnabled else { return nil }
        case .keyboard:
            guard isAutomaticKeyboardEnabled else { return nil }
        }

        return action
    }

    /// The action this stop will actually get — nil when it asks for none *or* when it would be refused, which makes
    /// nil the honest answer to "will Kiki do this". The overlay draws this answer, so it is built on the question above
    /// rather than restating it: the cursor turning red for a press that never follows is a loud, untrue claim. Each refusal is asked of the thing that owns it, and none answers for another.
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
        case .keyboard(.text(let typedText)):
            // Typing is refused for the focus click's reasons as well as its own — the click is how the
            // words get somewhere to land.
            guard ElementKeyboard.refusalOfTyping(
                typedText,
                matchingElementLabel: pointingTourStop.elementLabel,
                origin: .theModelsTag
            ) == nil else { return nil }
        case .keyboard(.combination(let keyCombination)):
            guard ElementKeyboard.refusalOfCombination(named: keyCombination) == nil else { return nil }
        }
        return requestedAction
    }

    /// `isClosingTheArrivalFlightAfterwards` is true only for a drag, which is still running when the
    /// cursor lands and so is the one action whose flight the arrival leaves open for it to close.
    private func performTheActionTheModelAskedForItIfAny(
        at pointingTourStop: ResolvedPointingTourStop,
        isClosingTheArrivalFlightAfterwards: Bool
    ) {
        // One guard for every gesture: a stop the model only asked to locate has nothing to do here, and neither
        // has any stop while automatic acting is off. A refused action gets past this and is reported by the action itself.
        guard let action = requestedActionForArrival(at: pointingTourStop) else { return }

        let stopIndex = nextPointingTourStopIndex
        let elementLabel = pointingTourStop.elementLabel
        let screenLocation = pointingTourStop.screenLocation
        let displayFrame = pointingTourStop.displayFrame
        // Read here rather than inside the clicker, which stays self-contained and touches no AppKit.
        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0
        // Where a drag lets go, already on the display the starting point is on: converted from the same
        // screenshot, which clamps it to that screen's bounds.
        let dragDestinationScreenLocation = pointingTourStop.dragDestinationScreenLocation

        // Counted here rather than where the task reports back: the two ends of that count are written by
        // different code.
        stepInProgress.numberOfActionsAskedFor += 1
        let thisStepIdentifier = turnIdentifierOfTheReplyBeingStreamed

        Task {
            // Every arm below ends by reporting what it did, whether it reached the screen or not: the
            // report is what the step is waiting for.
            switch action {
            case .press(let clickKind):
                // Only for a click that will actually go out: asking the refusal first keeps the sound from
                // announcing a click that was declined, and playing it here lands it with the events.
                if ElementClicker.refusalOfClick(matchingElementLabel: elementLabel, origin: .theModelsTag) == nil {
                    elementActionSoundPlayer.playClickSound()
                }

                let clickOutcome = await ElementClicker.clickElement(
                    atAppKitScreenLocation: screenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                    matchingElementLabel: elementLabel,
                    kind: clickKind,
                    origin: .theModelsTag
                )

                print("\(clickKind) at stop \(stopIndex): \(clickOutcome)")
                recordWhatAnActionOfTheStepDid(
                    clickOutcome,
                    action: action,
                    elementLabel: elementLabel,
                    identifiedBy: thisStepIdentifier
                )

            case .scroll(let direction, let distance):
                // Nothing is played: the click's sound is feedback for a press, and the content moving is a
                // scroll's own feedback.
                let scrollOutcome = await ElementScroller.scrollElement(
                    atAppKitScreenLocation: screenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                    direction: direction,
                    distance: distance,
                    displayFrame: displayFrame
                )

                print("\(direction) \(distance) at stop \(stopIndex): \(scrollOutcome)")
                recordWhatAnActionOfTheStepDid(
                    scrollOutcome,
                    action: action,
                    elementLabel: elementLabel,
                    identifiedBy: thisStepIdentifier
                )

            case .drag:
                // Nothing is played, for the scroll's reason: what moves is its own feedback.
                let dragOutcome = await dragForTheUser(
                    fromAppKitScreenLocation: screenLocation,
                    toAppKitScreenLocation: dragDestinationScreenLocation,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints
                )

                print("Drag at stop \(stopIndex): \(dragOutcome)")
                recordWhatAnActionOfTheStepDid(
                    dragOutcome,
                    action: action,
                    elementLabel: elementLabel,
                    identifiedBy: thisStepIdentifier
                )

                // The one place a model-asked-for drag ends: the flight the arrival left open is closed
                // here, with the button up and the cursor standing where the drag put it.
                if isClosingTheArrivalFlightAfterwards, isFlyingToPointingTourStop {
                    finishCurrentPointingTourFlight()
                }

            case .keyboard(let keyboardInput):
                let keyboardOutcome: ElementKeyboardOutcome
                switch keyboardInput {
                case .text(let typedText):
                    // Played for the focus click, which goes out before the first character — the same question the
                    // click's own branch asks, because a run of text that will not begin with one must not make its sound.
                    if ElementKeyboard.refusalOfTyping(
                        typedText,
                        matchingElementLabel: elementLabel,
                        origin: .theModelsTag
                    ) == nil {
                        elementActionSoundPlayer.playClickSound()
                    }

                    keyboardOutcome = await ElementKeyboard.typeText(
                        typedText,
                        atAppKitScreenLocation: screenLocation,
                        primaryScreenHeightInPoints: primaryScreenHeightInPoints,
                        matchingElementLabel: elementLabel,
                        origin: .theModelsTag
                    )
                case .combination(let keyCombination):
                    // The key-press sound and not the click's, asked first for the reason above: a
                    // combination that will be refused must not be announced as one about to happen.
                    if ElementKeyboard.refusalOfCombination(named: keyCombination) == nil {
                        elementActionSoundPlayer.playKeyPressSound()
                    }

                    keyboardOutcome = ElementKeyboard.pressCombination(named: keyCombination)
                }

                print("\(keyboardInput) at stop \(stopIndex): \(keyboardOutcome)")
                recordWhatAnActionOfTheStepDid(
                    keyboardOutcome,
                    action: action,
                    elementLabel: elementLabel,
                    identifiedBy: thisStepIdentifier
                )

                // A typed run is the other action that outlives the arrival — the flight stays open across however
                // many seconds the words take — and closing it belongs here, once the last character is in. A combination is over at the arrival, which the flag is false for.
                if isClosingTheArrivalFlightAfterwards, isFlyingToPointingTourStop {
                    finishCurrentPointingTourFlight()
                }
            }
        }
    }

    /// Notes what one action of the step in progress did, in the order the model asked for them. The report is a sentence
    /// the model reads rather than the outcome the terminal is answered with, because the model is told about the element
    /// it named, the only thing it can look for on the next picture. Dropped for a step that is no longer the one in
    /// progress: a click takes as long as it takes, and a tour called off in the air would otherwise file its report under whatever step is running when it lands.
    private func recordWhatAnActionOfTheStepDid(
        _ outcome: ElementClickOutcome,
        action: ElementActionOnArrival,
        elementLabel: String?,
        identifiedBy stepIdentifier: UUID
    ) {
        recordWhatAnActionOfTheStepDid(
            sentence: sentenceTellingTheModelWhatItsActionDid(action, toElementLabel: elementLabel, orTheFailure: outcome.isASuccess ? nil : Self.sentenceForAnActionOutcome(outcome)),
            didItReachTheScreen: outcome.isASuccess,
            identifiedBy: stepIdentifier
        )
    }

    private func recordWhatAnActionOfTheStepDid(
        _ outcome: ElementScrollOutcome,
        action: ElementActionOnArrival,
        elementLabel: String?,
        identifiedBy stepIdentifier: UUID
    ) {
        recordWhatAnActionOfTheStepDid(
            sentence: sentenceTellingTheModelWhatItsActionDid(action, toElementLabel: elementLabel, orTheFailure: outcome.isASuccess ? nil : Self.sentenceForAnActionOutcome(outcome)),
            didItReachTheScreen: outcome.isASuccess,
            identifiedBy: stepIdentifier
        )
    }

    private func recordWhatAnActionOfTheStepDid(
        _ outcome: ElementDragOutcome,
        action: ElementActionOnArrival,
        elementLabel: String?,
        identifiedBy stepIdentifier: UUID
    ) {
        recordWhatAnActionOfTheStepDid(
            sentence: sentenceTellingTheModelWhatItsActionDid(action, toElementLabel: elementLabel, orTheFailure: outcome.isASuccess ? nil : Self.sentenceForAnActionOutcome(outcome)),
            didItReachTheScreen: outcome.isASuccess,
            identifiedBy: stepIdentifier
        )
    }

    private func recordWhatAnActionOfTheStepDid(
        _ outcome: ElementKeyboardOutcome,
        action: ElementActionOnArrival,
        elementLabel: String?,
        identifiedBy stepIdentifier: UUID
    ) {
        recordWhatAnActionOfTheStepDid(
            sentence: sentenceTellingTheModelWhatItsActionDid(action, toElementLabel: elementLabel, orTheFailure: outcome.isASuccess ? nil : Self.sentenceForAnActionOutcome(outcome)),
            didItReachTheScreen: outcome.isASuccess,
            identifiedBy: stepIdentifier
        )
    }

    private func recordWhatAnActionOfTheStepDid(
        sentence: String,
        didItReachTheScreen: Bool,
        identifiedBy stepIdentifier: UUID
    ) {
        guard isStillTheStepIdentifiedBy(stepIdentifier) else {
            print("An action reported back after its step was over: \(sentence)")
            return
        }

        stepInProgress.numberOfActionsThatHaveReportedBack += 1
        stepInProgress.sentencesSayingWhatTheActionDid.append(sentence)
        stepInProgress.didAnyActionReachTheScreen = stepInProgress.didAnyActionReachTheScreen || didItReachTheScreen

        // The last of them, and the tour may have run out of stops long ago: an action outliving the
        // arrival can be the only thing still running.
        finishTheStepIfEverythingItAskedForIsDone()
    }

    /// Whether the step being reported on is still the step in progress. The turn identifier is what the streaming
    /// reply already uses for a stale chunk, and a step is a turn's worth of work, so one identifier answers both — it moves with the next step and a new question.
    private func isStillTheStepIdentifiedBy(_ stepIdentifier: UUID) -> Bool {
        stepIdentifier == turnIdentifierOfTheReplyBeingStreamed
    }

    /// What the model is told its own action did. Built on the same completion phrase the terminal is answered with
    /// rather than a second pool, because that pool is the one place a gesture's name is decided: two pools would let
    /// a gesture added later be named for one audience and approximated for the other. Only the object differs, and it
    /// must — a terminal may be a script looking for which occurrence was pressed, while the model is told about the element it named. An action with no label is called 那个元素.
    private func sentenceTellingTheModelWhatItsActionDid(
        _ action: ElementActionOnArrival,
        toElementLabel elementLabel: String?,
        orTheFailure failureSentence: String?
    ) -> String {
        let elementName = elementLabel.map { "「\($0)」" } ?? "那个元素"
        guard let failureSentence else {
            return Self.completionPhraseForTheAction(action) + elementName + "。"
        }
        return elementName + "没做成：" + failureSentence
    }

    /// The prompt for a step that follows the model's own actions. Written as a report rather than a question,
    /// because the user asked once and everything after the first step is Kiki telling the model what happened.
    /// It names the picture as the one taken after the actions, without which a model seeing a changed screen has no way to know why.
    private static func promptForTheStepAfterTheModelsOwnActions(
        sentencesSayingWhatTheyDid: [String]
    ) -> String {
        var prompt = "（你上一步的动作结果："
        prompt += sentencesSayingWhatTheyDid.isEmpty
            ? "没有一步操作成功。"
            : sentencesSayingWhatTheyDid.joined()
        prompt += " 截图是这些动作之后的画面。接着说给用户听，别回应这条说明。）"
        return prompt
    }

    /// Drags from one point to another for the user, with the cursor drawn following it. The one place a drag
    /// runs, reached by both the model's tag and the terminal's request: the two differ in where the points come
    /// from and in what is said afterwards, never in what is done to the machine. The cursor follows because the
    /// overlay reads `screenLocationOfTheDragInFlight`.
    private func dragForTheUser(
        fromAppKitScreenLocation startAppKitScreenLocation: CGPoint,
        toAppKitScreenLocation destinationAppKitScreenLocation: CGPoint?,
        primaryScreenHeightInPoints: CGFloat
    ) async -> ElementDragOutcome {
        // Cleared however the drag ends, so a refused drag does not leave the cursor drawn somewhere no
        // movement is happening.
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

    /// Closes out the flight in progress: the next stop becomes eligible, and the reply is told the cursor has
    /// moved on. Reached by both ends a flight has — arrival and timeout — it is where the tour learns it is standing still.
    private func finishCurrentPointingTourFlight() {
        // An action being waited on is written off on arrival, so one still here is a flight that never landed:
        // nothing was done, and whoever asked is told so — for a replay, the loop merely moves on — rather than left waiting on a cursor that is not coming.
        if let actionThatNeverLanded = actionInFlight {
            endTheActionBeingWaitedOn(actionThatNeverLanded.beingWaitedOn, with: .failed(message: "光标没飞到那个点，这次操作没做成。", isRefusal: false))
        }

        pointingTourNarrationResumeTimeoutTask?.cancel()
        pointingTourNarrationResumeTimeoutTask = nil
        isFlyingToPointingTourStop = false
        // The clock the next stop's minimum dwell is measured against. A flight that timed out counts
        // too: the cursor has been parked on that element either way.
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

        // The tour running out of stops is one of the things that can finish a step, and in a silent turn it is
        // the last: with no voice to wait on, the segment walk runs out long before the cursor has visited everything the reply named.
        finishTheStepIfEverythingItAskedForIsDone()
    }

    /// Pokes the tour once the cursor has spent its minimum time on the stop it landed on — the case this
    /// exists for being the one where nothing else does, the narration having already been spoken through.
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

    /// Sends the cursor home if the narration is still going three seconds after the cursor landed on the
    /// last element it will point at.
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

    /// Writes off a flight that never reports back — the screen unplugged between screenshot and flight, the
    /// welcome animation, which makes the view ignore targets. Every such path degrades to one missed stop.
    private func schedulePointingTourArrivalTimeout() {
        pointingTourNarrationResumeTimeoutTask?.cancel()
        pointingTourNarrationResumeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourArrivalTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isFlyingToPointingTourStop else { return }
            print("Pointing tour: no arrival after \(Self.pointingTourArrivalTimeoutSeconds)s, writing the flight off")
            self.finishCurrentPointingTourFlight()
        }
    }

    /// Hands the tour over to the cursor if the narration never gets going: the tour is triggered by the
    /// words being spoken, so a voice that never reports what it is saying would leave the cursor parked.
    private func schedulePointingTourFallbackIfNarrationIsSilent() {
        pointingTourNarrationFallbackTask?.cancel()
        pointingTourNarrationFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourSilentNarrationFallbackSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only a voice that has said nothing at all is silent; asking whether a flight had started is a
            // different question, wrong for a reply that talks about something else before its first tag.
            guard !self.hasNarrationReportedAnyWords else { return }
            print("Pointing tour: narration reported no words, the cursor paces the tour from here")
            self.hasTheNarrationGoneSilent = true
            self.continuePointingTourIfPossible()
        }
    }

    /// Unsticks a reply whose narration has gone quiet partway through: the reply is driven by the words being spoken, so
    /// a voice that stops reporting them leaves nothing to send the cursor to the next stop and nothing to end the tour.
    /// The silent-narration fallback does not cover this — it answers once, on a voice that said nothing at all. The tour is ended rather than advanced, and the segment in progress written off with it.
    private func schedulePointingTourStallWatchdog() {
        pointingTourStallWatchdogTask?.cancel()
        pointingTourStallWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pointingTourStallTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard self.isPointingTourActive else { return }

                // A voice that never reported a word is the silent-narration case, which has its own
                // fallback. This watchdog is for a voice that was reporting and then stopped.
                guard self.hasNarrationReportedAnyWords else { continue }

                guard let lastNarrationProgressDate = self.lastNarrationProgressDate,
                      Date().timeIntervalSince(lastNarrationProgressDate) >= Self.pointingTourStallTimeoutSeconds else {

                    continue
                }

                print("Pointing tour: neither a word nor a finished segment for \(Self.pointingTourStallTimeoutSeconds)s, the narration has stopped")

                // Read before the tour is ended, which clears both of them.
                let stopToParkOn = self.nextPointingTourStop ?? self.resolvedPointingTourStops.last
                self.endPointingTour()
                // Put back for the stop the cursor was waiting to serve, which `endPointingTour` has just cleared
                // with the rest of the tour. No action goes with it: that tour is over, the cursor merely left standing where it got to.
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
    /// Called by CursorView when onboarding starts.
    func setupOnboardingVideo() {
        // Bundled rather than streamed: fetching the intro put the first thing a new user ever sees behind
        // a network round trip, and its failure was silent.
        guard let videoURL = Bundle.main.url(forResource: "kiki-intro", withExtension: "mp4") else {
            print("Onboarding video: kiki-intro.mp4 is missing from the bundle")
            return
        }

        // A replay starts the demos over: the second run's first demo would otherwise be told to avoid
        // everything the first run pointed at, on a screen that has nothing to do with them.
        onboardingDemoTargetsAlreadyPointedAt.removeAll()

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        // Full volume from the first sample: ramping up from silence cost the clip its opening words, so
        // the first thing the user heard was the middle of a sentence.
        player.volume = 1.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // The picture fades in first and playback starts after it: a paused `AVPlayerLayer` draws the item's
        // frame at time zero, so what fades in is the clip's opening image. Both delays time the fade against
        // the playback, so moving either changes what is heard when.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            player.play()
        }

        // Two demos, ten seconds apart: Kiki flies to something interesting on screen and comments on it, then does the
        // same somewhere else. Both are silent — their only output is one sentence in the pointing bubble — so they play
        // alongside the narration. Both boundary times must land inside the clip, and the failure is silent: a time past
        // the end is never reached, while the end observer tears the whole observer down regardless. These two numbers move with the clip.
        let demoTriggerTimes = [5, 15].map {
            CMTime(seconds: Double($0), preferredTimescale: 600)
        }
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: demoTriggerTimes.map { NSValue(time: $0) },
            queue: .main
        ) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }

        listenForTheOnboardingNarrationLoudness(of: player, videoAt: videoURL)

        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingVideoOpacity = 0.0
            // Wait out the fade-out before tearing down, matching the opacity animation's own duration in
            // `OverlayWindow`, or the clip disappears in one frame instead of fading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.tearDownOnboardingVideo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    /// Measures the clip's own narration once, then follows it by where the player has got to. `AVPlayer` publishes
    /// no level, so the track is decoded off the main actor — what the decode would otherwise hold up is the
    /// video's own fade-in. The music under the intro goes through an `AVAudioPlayer` the meter never sees.
    private func listenForTheOnboardingNarrationLoudness(of player: AVPlayer, videoAt videoURL: URL) {
        Task { [weak self] in
            let envelope = await Task.detached(priority: .userInitiated) {
                OnboardingNarrationLoudnessEnvelope.measuring(videoAt: videoURL)
            }.value

            // The video may have been torn down or replayed while that was being measured, and a report
            // from the run before this one would drive the glow of the run now.
            guard let self, let envelope, self.onboardingVideoPlayer === player else { return }

            self.onboardingNarrationLoudnessObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: OnboardingNarrationLoudnessEnvelope.secondsPerStep, preferredTimescale: 600),
                queue: .main
            ) { [weak self] playbackTime in
                guard let self else { return }
                self.voiceLoudnessMeter.report(envelope.loudness(atSeconds: playbackTime.seconds))
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        if let loudnessObserver = onboardingNarrationLoudnessObserver {
            onboardingVideoPlayer?.removeTimeObserver(loudnessObserver)
            onboardingNarrationLoudnessObserver = nil
        }
        // The clip is the only thing that was speaking, and nothing else would report over what it left
        // the glow at.
        voiceLoudnessMeter.report(0)
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
    you're kiki, a small purple cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. write it in chinese (简体中文), the way you'd say it out loud. no emojis ever. the observation is the one part that must not repeat what's written on screen — react to the thing, don't read it back. keep it to 12 chinese characters max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST pick something near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width, and your y coordinate between 20%-80% of the image height — nothing near any edge, which rules out menu bar items, dock icons and sidebar items. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. your comment is in chinese. if the thing you picked has text written on it, copy that text into the label character for character exactly as it appears on screen — chinese is fine there, the label is code and is never read aloud — otherwise name it in english.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot, asks the model to find something interesting to point at, and triggers the
    /// flight. Used during onboarding to demo pointing while the intro video plays.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only the cursor screen, so the model cannot pick something on a monitor Kiki cannot
                // point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("Onboarding demo: no cursor screen found")
                    return
                }

                // The demo picks something with a name on screen, so it gets the same exact positioning the
                // pointing tour uses. Started before the request so it runs while the model writes.
                let recognizedTextLinesTask = Task {
                    await ScreenshotTextRecognizer.recognizedLines(in: cursorScreenCapture.imageData)
                }

                let labeledImages = [(
                    data: cursorScreenCapture.imageData,
                    label: cursorScreenCapture.label
                        + " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)"
                        + "x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                )]

                // What an earlier demo already pointed at on this same display. Each demo is a fresh request with
                // no history, so the model would pick the same thing again; the claimed box below takes that ground away.
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
                    // Empty on purpose: the demo says nothing out loud, its whole output being one
                    // sentence written into the pointing bubble.
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let modelPointCoordinate = parseResult.coordinate else {
                    print("Onboarding demo: no element to point at")
                    return
                }

                // Passed as claimed, as the pointing tour does: a label that would land on covered ground
                // falls back to the model's own coordinate, so the second demo still points somewhere.
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

                // Recorded whether or not the flight goes anywhere, so the next demo is told about it either
                // way. A target with no label carries nothing forward.
                if let elementLabel = parseResult.elementLabel, !elementLabel.isEmpty {
                    onboardingDemoTargetsAlreadyPointedAt.append(
                        OnboardingDemoTarget(
                            elementLabel: elementLabel,
                            matchedTextBox: precisePosition.matchedTextBox,
                            displayFrame: cursorScreenCapture.displayFrame
                        )
                    )
                }

                // Its invitation is a look, not an offer to operate: the overlay reads that to decide whether
                // the flight carries the user's mouse, so anything else would take hold of the pointer mid-demo.
                pointingTarget = PointingTarget(
                    screenLocation: resolvedLocation.screenLocation,
                    displayFrame: resolvedLocation.displayFrame,
                    bubbleInvitation: .lookAtElement,
                    // The model's comment, in place of a random phrase.
                    bubbleText: parseResult.spokenText,
                    actionToPerformOnArrival: nil
                )
                // Built here rather than through `beginFlightOfTheCursor`, which takes the tour's bookkeeping with
                // it — so this is the second of the two places a flight is asked for, and it bumps the count itself.
                pointingFlightRequestCount += 1
                print("Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("Onboarding demo error: \(error)")
            }
        }
    }

    // MARK: - The First-Run Onboarding Guide

    /// One place on the settings panel the guide can point at. Named rather than measured: the panel is a SwiftUI
    /// view whose rows move as the setup section fills and empties, so the only code that knows where a row stands is the row itself.
    enum KikiSettingsPanelAnchor: Hashable {
        case deepSeekAPIKeyField
        case screenRecordingPermissionRow
        case screenContentPermissionRow
    }

    /// Where each anchored element of the settings panel stands on screen, in AppKit global coordinates.
    /// Reported by the panel, read by the guide.
    @Published private(set) var settingsPanelAnchorScreenFrames: [KikiSettingsPanelAnchor: CGRect] = [:]

    /// Records where one anchored element stands, or forgets it when it leaves the screen. Guarded like
    /// `settleVoiceState`, for the same reason: the panel re-reports on every layout pass, and an unchanged
    /// dictionary written anyway would invalidate every view reading it.
    func setSettingsPanelAnchorScreenFrame(_ screenFrame: CGRect?, for anchor: KikiSettingsPanelAnchor) {
        var updatedScreenFrames = settingsPanelAnchorScreenFrames
        if let screenFrame {
            updatedScreenFrames[anchor] = screenFrame
        } else {
            updatedScreenFrames.removeValue(forKey: anchor)
        }

        guard updatedScreenFrames != settingsPanelAnchorScreenFrames else { return }
        settingsPanelAnchorScreenFrames = updatedScreenFrames
    }

    /// Whether the settings panel is on screen right now. Its flights point at a thing only the panel shows, and
    /// the user leaves it constantly: a cursor flying at a row nobody can see reads as a fault, not as guidance —
    /// so the flights are gated on this, and the guide's wait is woken by it.
    @Published private(set) var isTheSettingsPanelVisible = false

    /// The panel is on screen. Called by `MenuBarPanelManager` where the panel is ordered in and out.
    func theSettingsPanelCameOnScreen() {
        guard !isTheSettingsPanelVisible else { return }
        isTheSettingsPanelVisible = true
    }

    func theSettingsPanelWentOffScreen() {
        guard isTheSettingsPanelVisible else { return }
        isTheSettingsPanelVisible = false
    }

    /// Whether a reply is being had right now, in any of its three phases. Asked by the guide before it speaks,
    /// points or presses: a turn owns the voice, cursor and keyboard, and a new question's teardown stops whatever the guide was doing.
    var isATurnUnderwayRightNow: Bool {
        isProducingAReply || isSpeakingReply || buddyDictationManager.isDictationInProgress
    }

    /// Whether an action is still in the air — what the guide's press asks on its own, because a refusal *while
    /// one is in flight* is not "Kiki may not press": it is the ordinary state of a press this beat just sent, not yet landed.
    var isAnActionBeingWaitedOn: Bool { actionBeingWaitedOn != nil }

    /// The first-run guide — the segments themselves live in `KikiOnboardingGuide`.
    private(set) lazy var onboardingGuide = KikiOnboardingGuide(companionManager: self)

    /// Shows the overlay for the guide on a launch where `start()` deliberately left it hidden — it raises the cursor
    /// only when setup is complete, so on a fresh install the guide would have nowhere to fly from. Does nothing when the overlay is up or the cursor is switched off.
    func showTheOverlayForTheFirstRunOnboardingGuide() {
        guard !isOverlayVisible, isKikiCursorEnabled else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// The guide line being spoken, and what releases the script that spoke it: `speakPreparedSegment` returns the
    /// moment the audio starts, so a line's *end* arrives through `handlePlaybackFinished` — and a stopped playback
    /// reports nothing at all, which is why a new question's teardown and a watchdog of its own also release it.
    private var onboardingGuideLineFinishedSpeakingContinuation: CheckedContinuation<Void, Never>?
    private var onboardingGuideLineWriteOffTask: Task<Void, Never>?

    /// How long one guide line may be waited on before the wait is written off: longer than any line the guide
    /// says, short enough that a quiet synthesizer does not stall the segment — which no later launch repairs.
    private static let secondsBeforeAnOnboardingGuideLineIsWrittenOff: TimeInterval = 15

    /// Speaks one line the onboarding guide says, and returns once it has been heard or written off. Not the
    /// reply path: nothing is queued behind a reply's segments, the guide waits for a turn to end, and
    /// `isSpeakingReply` stays false throughout — which is what lets `handlePlaybackFinished` tell the two apart.
    func speakAnOnboardingGuideLine(_ lineToSpeak: String) async {
        // The video is the guide's ending, and its narration owns the voice from the moment it starts —
        // a line spoken now would talk over it.
        guard !showOnboardingVideo else { return }

        // Any wait left armed by an earlier line belongs to a script that has already moved on.
        finishTheOnboardingGuideLineIfItIsStillBeingWaitedOn()

        ttsClient.discardPreparedSegments()
        ttsClient.prepareSpeechSegment(spokenText: lineToSpeak, segmentIndex: 0)

        // The continuation is armed before the speaking task exists: a segment the synthesizer yields no audio for
        // reports its end synchronously from inside `speakPreparedSegment`, and a continuation armed after that would never be resumed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onboardingGuideLineFinishedSpeakingContinuation = continuation

            onboardingGuideLineWriteOffTask?.cancel()
            onboardingGuideLineWriteOffTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.secondsBeforeAnOnboardingGuideLineIsWrittenOff * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishTheOnboardingGuideLineIfItIsStillBeingWaitedOn()
            }

            Task { [weak self] in
                await self?.ttsClient.speakPreparedSegment(segmentIndex: 0)
            }
        }

        ttsClient.discardPreparedSegments()
    }

    /// Releases the wait on the guide line being spoken, if one is waiting, and lets go of a video that asked to start
    /// while the line was still sounding. The one resumer, called from the three ways a line ends — heard through
    /// (`handlePlaybackFinished`), the watchdog running out, the teardown a new question performs — and the guard also serves the fourth caller, the cleanup a new line performs before arming its own wait.
    func finishTheOnboardingGuideLineIfItIsStillBeingWaitedOn() {
        onboardingGuideLineWriteOffTask?.cancel()
        onboardingGuideLineWriteOffTask = nil

        // Guarded rather than optional-chained, because the deferred video below belongs to the end of a
        // line and must not start a beat before the next one.
        guard let continuation = onboardingGuideLineFinishedSpeakingContinuation else { return }
        onboardingGuideLineFinishedSpeakingContinuation = nil
        continuation.resume()

        if shouldTriggerOnboardingOnceTheGuideStopsSpeaking {
            shouldTriggerOnboardingOnceTheGuideStopsSpeaking = false
            triggerOnboarding()
        }
    }

    /// The screen an AppKit global point falls on, or nil when it falls on none — a point left over from a
    /// display that has since been unplugged.
    func screenContaining(appKitScreenLocation: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(appKitScreenLocation) }
    }

    /// Sends the cursor to a point on screen with one thing written beside it and nothing done on arrival. Built the way
    /// `performOnboardingDemoInteraction` builds its target rather than through `beginFlightOfTheCursor`, which takes the
    /// pointing tour's bookkeeping with it: the guide has a single look that ends by itself.
    ///
    /// - Returns: whether a flight was asked for — false when the overlay is not up or the point is on no connected screen, ordinary states rather than failures.
    @discardableResult
    func pointTheCursorAtAppKitScreenLocation(_ screenLocation: CGPoint, saying bubbleText: String) -> Bool {
        guard isOverlayVisible, let containingScreen = screenContaining(appKitScreenLocation: screenLocation) else {
            return false
        }

        pointingTarget = PointingTarget(
            screenLocation: screenLocation,
            displayFrame: containingScreen.frame,
            bubbleInvitation: .lookAtElement,
            bubbleText: bubbleText,
            actionToPerformOnArrival: nil
        )
        // Bumped after the target is written: the overlay reads the target when the count changes.
        pointingFlightRequestCount += 1
        return true
    }

    /// Points at an anchored element of the settings panel, waiting for the panel to report where it stands: it is up
    /// but still laying out for the first moments of a segment, and its rows move as the setup section fills in, so
    /// the frame is waited for rather than read once. It also has to be *on screen* — a hidden panel's rows keep
    /// reporting frames, and flying to one is the cursor flashing at nothing.
    ///
    /// - Returns: whether the cursor was sent; false when the frame never arrived, the panel is hidden, or the cursor is hidden.
    @discardableResult
    func pointTheCursorAtSettingsPanelAnchor(
        _ anchor: KikiSettingsPanelAnchor,
        saying bubbleText: String,
        waitingUpToSeconds: TimeInterval
    ) async -> Bool {
        let momentToGiveUpWaiting = Date().addingTimeInterval(waitingUpToSeconds)
        while Date() < momentToGiveUpWaiting {
            if isTheSettingsPanelVisible, let anchorScreenFrame = settingsPanelAnchorScreenFrames[anchor] {
                return pointTheCursorAtAppKitScreenLocation(
                    CGPoint(x: anchorScreenFrame.midX, y: anchorScreenFrame.midY),
                    saying: bubbleText
                )
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    /// The smallest and largest a dialog is taken to be, in points. Distinguishes a dialog from the rest of the
    /// window list: menu bar extras and the status item are short, a browser is larger; the settings pane measures
    /// inside the range on some displays, so it is dropped by frame instead.
    private static let smallestDialogWindowSizeInPoints = CGSize(width: 120, height: 80)
    private static let largestDialogWindowSizeInPoints = CGSize(width: 1000, height: 750)

    /// The two layers a dialog window stands at: `.normal`, and `.modalPanel` for `NSAlert` and the consent
    /// prompts macOS 26 presents through UserNotificationCenter — kept apart from the menu bar, the Dock and this app's overlay above them.
    private static let layersADialogWindowStandsAt: Set<Int> = [
        Int(NSWindow.Level.normal.rawValue),
        Int(NSWindow.Level.modalPanel.rawValue)
    ]

    /// The system processes that raise the prompts the first-run guide waits on, and the button each one's alert
    /// asks the user to press. Raw values are bundle identifiers: the window server reports an owner name in the
    /// user's own language (系统设置), so an owner name is not a name to switch on. The button is read off the
    /// host rather than the alert, because nothing at this point in the guide can read the alert.
    enum SystemAlertHost: String {
        case universalAccessAuthWarn = "com.apple.accessibility.universalAccessAuthWarn"
        case loginwindow = "com.apple.loginwindow"
        case systemSettings = "com.apple.systempreferences"
        case userNotificationCenter = "com.apple.UserNotificationCenter"

        /// The name on the fingerprint check's sheet. The check stands as loginwindow's own window on some machines
        /// and as a sheet of System Settings on others, so it is not one host's name — where it is System Settings', the sheet's size is what reaches this name, never the host.
        static let fingerprintCheckButtonName = "允许此操作"

        /// The name on the alert's own button, for the hosts whose alerts say one thing apiece. System Settings
        /// owns both the quit-and-reopen prompt and the fingerprint check, and only the sheet's size tells the two apart.
        var buttonNameItAsksFor: String {
            switch self {
            case .universalAccessAuthWarn: "打开系统设置"
            case .loginwindow: Self.fingerprintCheckButtonName
            case .systemSettings: "退出并重新打开"
            case .userNotificationCenter: "允许"
            }
        }
    }

    /// One of those processes' windows, standing on screen: where it is in the space the guide points in,
    /// and which host raised it.
    struct SystemAlertWindow {
        let frame: CGRect
        let host: SystemAlertHost
    }

    /// Every system alert standing on screen, front to back. Read off the window server rather than the accessibility
    /// tree, because the grant the guide needs these for is one the app does not hold yet. This app's own windows are
    /// left out — the settings panel carries 「允许 Kiki 用鼠标操作」, and a search for 「允许」 narrowed only by
    /// "inside some window" would find that row. Three filters stand between the window list and an alert: the two
    /// layers a dialog stands at, the size range, and the host, which keeps a stranger's panel from having a button named over it; the System Settings pane is dropped by frame, because on some displays it measures inside the size range.
    func systemAlertWindowsInFrontToBackOrder() -> [SystemAlertWindow] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0
        // Found once, outside the walk: finding it is a walk of the window list in its own right.
        let systemSettingsPaneFrame = frameOfTheSystemSettingsWindow()

        var systemAlertWindows: [SystemAlertWindow] = []
        for windowInfo in windowInfoList {
            guard let ownerProcessIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessIdentifier != ownProcessIdentifier,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  Self.layersADialogWindowStandsAt.contains(windowLayer),
                  let windowAlpha = windowInfo[kCGWindowAlpha as String] as? Double,
                  windowAlpha > 0.05,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let accessibilityScreenFrame = CGRect(dictionaryRepresentation: boundsDictionary)
            else { continue }

            let screenFrame = Self.appKitScreenFrame(
                fromAccessibilityScreenFrame: accessibilityScreenFrame,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
            guard screenFrame.width >= Self.smallestDialogWindowSizeInPoints.width,
                  screenFrame.height >= Self.smallestDialogWindowSizeInPoints.height,
                  screenFrame.width <= Self.largestDialogWindowSizeInPoints.width,
                  screenFrame.height <= Self.largestDialogWindowSizeInPoints.height
            else { continue }

            guard screenFrame != systemSettingsPaneFrame else { continue }

            let alertHost = Self.systemAlertHost(
                ownedByProcessIdentifier: ownerProcessIdentifier,
                named: windowInfo[kCGWindowOwnerName as String] as? String
            )
            guard let alertHost else { continue }

            systemAlertWindows.append(SystemAlertWindow(frame: screenFrame, host: alertHost))
        }
        return systemAlertWindows
    }

    /// The one place a window's owner becomes one of the hosts, or nil for one that raises no system prompt. The
    /// owner name is only a fallback, for the host NSWorkspace may not list: a daemon's process name is not localized, unlike an app's.
    private static func systemAlertHost(
        ownedByProcessIdentifier ownerProcessIdentifier: pid_t,
        named ownerName: String?
    ) -> SystemAlertHost? {
        if let bundleIdentifier = NSRunningApplication(processIdentifier: ownerProcessIdentifier)?.bundleIdentifier,
           let alertHost = SystemAlertHost(rawValue: bundleIdentifier) {
            return alertHost
        }
        return ownerName == "universalAccessAuthWarn" ? .universalAccessAuthWarn : nil
    }

    /// The frame of the System Settings window, or nil when it is not on screen: found by owning process, not by
    /// size, because on some displays the pane measures inside the dialog range. The guide points here for grants only the user's hand can make.
    func frameOfTheSystemSettingsWindow() -> CGRect? {
        let systemSettingsProcessIdentifiers = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .map(\.processIdentifier)
        guard !systemSettingsProcessIdentifiers.isEmpty else { return nil }

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.maxY ?? 0

        var largestScreenFrame: CGRect?
        for windowInfo in windowInfoList {
            guard let ownerProcessIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  systemSettingsProcessIdentifiers.contains(ownerProcessIdentifier),
                  let windowAlpha = windowInfo[kCGWindowAlpha as String] as? Double,
                  windowAlpha > 0.05,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let accessibilityScreenFrame = CGRect(dictionaryRepresentation: boundsDictionary)
            else { continue }

            let screenFrame = Self.appKitScreenFrame(
                fromAccessibilityScreenFrame: accessibilityScreenFrame,
                primaryScreenHeightInPoints: primaryScreenHeightInPoints
            )
            // The largest window is the pane. System Settings owns smaller ones too — its own alerts, and
            // on some versions a toolbar shelf — and the pane is what is being pointed at.
            if let currentLargest = largestScreenFrame,
               currentLargest.width * currentLargest.height >= screenFrame.width * screenFrame.height {
                continue
            }
            largestScreenFrame = screenFrame
        }
        return largestScreenFrame
    }

    /// Converts a window-server frame into AppKit global coordinates, through the one copy of the flip rather than
    /// a second subtraction: `CGWindowListCopyWindowInfo` reports in the Accessibility space, the space `resolveActionTarget` converts from — top-left origin on the primary display.
    private static func appKitScreenFrame(
        fromAccessibilityScreenFrame accessibilityScreenFrame: CGRect,
        primaryScreenHeightInPoints: CGFloat
    ) -> CGRect {
        let topLeftInAppKit = ElementClicker.appKitScreenLocation(
            fromAccessibilityScreenPoint: accessibilityScreenFrame.origin,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
        let bottomRightInAppKit = ElementClicker.appKitScreenLocation(
            fromAccessibilityScreenPoint: CGPoint(
                x: accessibilityScreenFrame.maxX,
                y: accessibilityScreenFrame.maxY
            ),
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )

        return CGRect(
            x: topLeftInAppKit.x,
            y: bottomRightInAppKit.y,
            width: bottomRightInAppKit.x - topLeftInAppKit.x,
            height: topLeftInAppKit.y - bottomRightInAppKit.y
        )
    }

    /// The middle of the one piece of on-screen text standing alone as this label, in AppKit global coordinates, searched
    /// for only inside the given windows — frontmost first, reading order within a window. Standing alone as a whole word
    /// is what keeps 「允许」 from being found inside 「不允许」, the two sitting one character apart on the very alerts this aims a press at.
    ///
    /// - Returns: the point and the capture it was converted from — nil when the screen cannot be read or the label is nowhere.
    func locationStandingAloneAsLabel(
        _ label: String,
        insideOneOf containingWindowFrames: [CGRect]
    ) async -> (screenLocation: CGPoint, displayFrame: CGRect)? {
        let capturedScreens: [CompanionScreenCapture]
        do {
            capturedScreens = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            print("Onboarding guide: cannot read the screen to find 「\(label)」 — \(error)")
            return nil
        }

        var recognizedLinesByScreen: [[RecognizedTextLine]] = []
        for capturedScreen in capturedScreens {
            recognizedLinesByScreen.append(
                await ScreenshotTextRecognizer.recognizedLines(in: capturedScreen.imageData)
            )
        }

        for containingWindowFrame in containingWindowFrames {
            for (screenIndex, capturedScreen) in capturedScreens.enumerated() {
                let boxesStandingAlone = ScreenshotTextElementMatcher.elementBoxesStandingAlone(
                    matchingElementLabel: label,
                    amongRecognizedLines: recognizedLinesByScreen[screenIndex]
                )
                for boxStandingAlone in boxesStandingAlone {
                    let resolvedLocation = Self.screenLocation(
                        forScreenshotCoordinate: CGPoint(x: boxStandingAlone.midX, y: boxStandingAlone.midY),
                        on: capturedScreen
                    )
                    if containingWindowFrame.contains(resolvedLocation.screenLocation) {
                        return resolvedLocation
                    }
                }
            }
        }
        return nil
    }

    /// Presses the button carrying this label in the system's own permission alerts, frontmost first. It reaches the
    /// machine the way every other action does — the same `carryOutTheResolvedAction`, red carrying flight, sound and
    /// `CGEvent` — so a press the guide makes is not a second kind of press. The answer goes to nobody
    /// (`.theOnboardingGuideItself`), because the script waits on the permission fact its press was made for.
    ///
    /// - Returns: whether the press was sent; false is ordinary — nothing stands alone as this label inside a dialog, the screen cannot be read, or Kiki may not press right now — and the guide points instead.
    func pressTheSystemAlertButtonLabelled(_ buttonLabel: String) async -> Bool {
        guard isAutomaticClickingEnabled,
              hasAccessibilityPermission,
              isOverlayVisible,
              !isATurnUnderwayRightNow
        else {
            print("Onboarding guide: not pressing 「\(buttonLabel)」 — Kiki may not or cannot press right now")
            return false
        }

        // Its own guard, because this one is ordinary rather than a refusal: the beat is woken every second and
        // a half, and a press asked for a moment ago is still flying — `isAnActionBeingWaitedOn` tells the two apart.
        guard actionBeingWaitedOn == nil else {
            print("Onboarding guide: not pressing 「\(buttonLabel)」 — an action is still in the air")
            return false
        }

        let systemAlertWindowFrames = systemAlertWindowsInFrontToBackOrder().map(\.frame)
        guard !systemAlertWindowFrames.isEmpty,
              let pressTarget = await locationStandingAloneAsLabel(buttonLabel, insideOneOf: systemAlertWindowFrames)
        else {
            print("Onboarding guide: not pressing 「\(buttonLabel)」 — nothing standing alone inside an alert, or the screen could not be read")
            return false
        }

        // Asked again after the capture, which is a second wide: the user may have started a turn, or a
        // replayed action may have a press in flight by now.
        guard isAutomaticClickingEnabled,
              !isATurnUnderwayRightNow,
              actionBeingWaitedOn == nil
        else {
            print("Onboarding guide: not pressing 「\(buttonLabel)」 — a turn or another action began while the screen was being read")
            return false
        }

        let actionBeingWaitedOn = ActionBeingWaitedOn(
            actionIdentifier: UUID(),
            whoHearsTheAnswer: .theOnboardingGuideItself
        )
        self.actionBeingWaitedOn = actionBeingWaitedOn

        await carryOutTheResolvedAction(
            .resolved(
                appKitScreenLocation: pressTarget.screenLocation,
                displayFrame: pressTarget.displayFrame,
                dragDestinationAppKitScreenLocation: nil,
                message: "已点击「\(buttonLabel)」。",
                hint: nil
            ),
            // No label travels with the press. The label was this app's own way of finding the point, and
            // the point is the whole instruction — the same shape a click the user typed as a coordinate has.
            elementText: nil,
            action: .press(.singleClick),
            actionBeingWaitedOn: actionBeingWaitedOn
        )
        return true
    }
}
