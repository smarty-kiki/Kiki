//  AppleTTSClient.swift
//  kiki-desktop-agent
//
//  Text-to-speech backed by Apple's on-device AVSpeechSynthesizer. Runs entirely
//  locally: no API key, no network round trip, no per-character cost.

import AVFoundation
import Foundation

/// Speaks the reply one speech segment at a time, synthesising each segment while the model is
/// still writing the rest of it.
///
/// Synthesis and playback are separate calls: a segment's text is handed here the moment it can no
/// longer change, so the audio is produced inside the window the user is already spending on the
/// model, and only playback is left in front of the voice.
///
/// `write(_:toBufferCallback:)` is driven strictly serially — a second `write()` begun while the
/// first is running disowns the first one's callbacks, including the zero-length closing buffer that
/// is the only thing that would have marked it complete.
///
/// There is deliberately no pause API: `pauseSpeaking`/`continueSpeaking` leave the synthesizer
/// silent for the rest of the utterance while reporting `isPaused == false`. The pacing they were
/// used for lives in `CompanionManager`, which withholds the next segment instead.
@MainActor
final class AppleTTSClient {

    // MARK: - What the caller hears about

    /// Reports a word as it is reached, in UTF-16 offsets within the segment's own text.
    ///
    /// Taken from the playback position rather than the synthesizer, so they are accurate to the
    /// polling interval below. `CompanionManager` adds the segment's start offset.
    var onSpokenCharacterRange: (@MainActor (NSRange) -> Void)?

    /// Reports that the segment handed to `speakPreparedSegment` has been heard in full.
    ///
    /// This is what releases the rest of the reply: the next segment is withheld until it arrives, so
    /// a segment whose audio never ends strands everything after it.
    var onPlaybackFinished: (@MainActor () -> Void)?

    /// Reports that audio of the current reply has actually reached the output, once per reply.
    ///
    /// This is the difference between asking the voice to speak and hearing it: only the playback
    /// position knows the node has rendered.
    var onFirstSoundHeard: (@MainActor () -> Void)?

    /// Reports how loud the audio being rendered is, from 0 to 1, once per playback tick, and zero
    /// once the segment is over.
    ///
    /// The raw measurement rather than a smoothed one: how a glow rises and falls over a pause
    /// between two syllables is the glow's business, and the two things that ever speak for Kiki
    /// report here at rates of their own.
    var onVoiceLoudness: (@MainActor (CGFloat) -> Void)?

    /// Whether a segment is currently being played. False between segments, which is why
    /// `CompanionManager` schedules the transient cursor hide off its own `isSpeakingReply`.
    var isPlaying: Bool { currentlyPlayingSegment != nil }

    // MARK: - Configuration

    /// Optional Info.plist key naming an exact voice to speak with. When it is absent, or names a
    /// voice this machine doesn't have installed, we fall back to the best voice for the language
    /// the user actually speaks.
    private static let preferredVoiceIdentifierInfoPlistKey = "AppleTTSVoiceIdentifier"

    /// How often the playback position is read while a segment plays. The pointing tour is driven by
    /// the words this reports, so it is the resolution at which a tour trigger fires.
    private static let playbackPositionPollingIntervalSeconds: TimeInterval = 0.02

    /// How many consecutive nil readings of the playback position write a playback off.
    ///
    /// `playerTime(forNodeTime:)` returns nil only while the node is not playing, which after `play()`
    /// has been called means the audio fell over rather than that it finished. A segment nothing ever
    /// reports finished is a reply that never continues, so this turns it into a late end.
    private static let consecutiveMissingPlaybackReadingsBeforeGivingUp = 25

    // MARK: - Synthesis

    private let speechSegmentSynthesizer = SpeechSegmentSynthesizer()

    /// Every segment handed over for synthesis, in the order they were handed over, and kept after
    /// playback because `speakPreparedSegment(segmentIndex:)` finds one by its index.
    private var preparedSpeechSegments: [PreparedSpeechSegment] = []

    // MARK: - Playback

    private let playbackEngine = AVAudioEngine()
    private let playbackPlayerNode = AVAudioPlayerNode()
    private var isPlaybackEngineRunning = false

    /// Whether any audio of the current reply has reached the output.
    ///
    /// What makes `onFirstSoundHeard` once per reply. Both teardown calls clear it: clearing it early
    /// costs nothing — the next tick that sees the node render reports again — while clearing it too
    /// late costs the caller the report entirely.
    private var hasHeardTheFirstSoundOfTheCurrentReply = false

    /// The format the player node is connected to the mixer with: the voice's own output format,
    /// which is not knowable until the first buffer of audio exists.
    private var connectedPlaybackAudioFormat: AVAudioFormat?

    /// What the tap below most recently measured, read by the polling timer.
    ///
    /// The measurement itself happens on the render thread, and the poll is what carries it to the
    /// main actor — so the audio thread is written to and never written from.
    private let playbackLoudnessMeasurement = PlaybackLoudnessMeasurement()

    private var playbackHeadPollingTimer: Timer?
    private var currentlyPlayingSegment: PreparedSpeechSegment?
    private var wordMarksBeingPlayed: [(characterRange: NSRange, startFrame: Int)] = []
    private var totalFramesBeingPlayed = 0
    private var nextWordMarkIndexToReport = 0
    private var consecutiveMissingPlaybackReadings = 0

    init() {
        speechSegmentSynthesizer.voice = Self.resolveVoice()
        speechSegmentSynthesizer.onFirstAudioBufferProduced = { [weak self] audioFormat in
            Task { @MainActor in
                self?.startPlaybackEngineIfNeeded(withAudioFormat: audioFormat)
            }
        }
    }

    // MARK: - The public surface

    /// Hands one speech segment over to be synthesised, and returns immediately.
    ///
    /// The text is final by the time it arrives here, which is why it is never revisited.
    func prepareSpeechSegment(spokenText: String, segmentIndex: Int) {
        let preparedSegment = speechSegmentSynthesizer.beginSynthesizing(
            spokenText: spokenText,
            segmentIndex: segmentIndex
        )
        preparedSpeechSegments.append(preparedSegment)
    }

    /// Plays a segment that was handed over earlier, waiting for its synthesis if it has not
    /// finished. Synthesis runs at roughly six times real time, so every segment but the first is
    /// usually long finished before the cursor is ready to move on.
    func speakPreparedSegment(segmentIndex: Int) async {
        guard let speechSegment = preparedSpeechSegments.first(where: { $0.segmentIndex == segmentIndex }) else {
            return
        }

        while !speechSegment.isSynthesisComplete {
            // The reply may have been replaced while this was waiting, in which case the segment
            // is gone from the list and there is nothing left to play.
            guard preparedSpeechSegments.contains(where: { $0 === speechSegment }) else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard preparedSpeechSegments.contains(where: { $0 === speechSegment }) else { return }

        guard let synthesizedAudio = speechSegment.synthesizedAudio else {
            // Synthesis completed without producing any audio. Reporting the segment as finished
            // is the only safe direction: the reply is released on that report, so waiting
            // forever for audio that will never exist would strand everything after it.
            onPlaybackFinished?()
            return
        }

        startPlaybackEngineIfNeeded(withAudioFormat: synthesizedAudio.audioFormat)

        // Stopping the node is what keeps the next segment from being heard early: it drops
        // anything scheduled and resets the node's timeline, so the frame numbers the word marks
        // were measured in start at zero again for this segment.
        playbackPlayerNode.stop()
        // The previous segment's last reading outlives its audio, and the first tick of this one
        // would report it as though it were this segment's opening syllable.
        playbackLoudnessMeasurement.reset()
        for audioBuffer in synthesizedAudio.audioBuffers {
            // Written out in full rather than as `scheduleBuffer(_:)`, because that shorthand is
            // ambiguous inside an `async` function: AVFoundation also publishes a one-argument
            // `async` overload that suspends until the buffer has played, and the compiler picks
            // it — scheduling one buffer, waiting out its whole length, then scheduling the next.
            playbackPlayerNode.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: nil)
        }

        wordMarksBeingPlayed = synthesizedAudio.wordMarks
        totalFramesBeingPlayed = synthesizedAudio.totalFrames
        nextWordMarkIndexToReport = 0
        consecutiveMissingPlaybackReadings = 0
        currentlyPlayingSegment = speechSegment

        playbackPlayerNode.play()

        startPlaybackHeadPollingTimer()
    }

    /// Stops the audio immediately, without touching what has been prepared.
    ///
    /// A new reply and a new interaction both call it, and both follow it with
    /// `discardPreparedSegments()`.
    func stopPlayback() {
        stopPlaybackHeadPollingTimer()
        currentlyPlayingSegment = nil
        wordMarksBeingPlayed = []
        totalFramesBeingPlayed = 0
        nextWordMarkIndexToReport = 0
        consecutiveMissingPlaybackReadings = 0
        hasHeardTheFirstSoundOfTheCurrentReply = false
        playbackPlayerNode.stop()
        // The audio stops here without the timer that would have gone on reporting it.
        onVoiceLoudness?(0)
    }

    /// Drops every segment that has not been played, and abandons the one being synthesised.
    ///
    /// The synthesizer can still deliver buffers for a `write()` that has been stopped, so every
    /// callback checks the generation it was started under before touching a segment.
    func discardPreparedSegments() {
        preparedSpeechSegments = []
        hasHeardTheFirstSoundOfTheCurrentReply = false
        speechSegmentSynthesizer.cancelSynthesisInFlight()
        stopPlaybackEngine()
    }

    // MARK: - The playback engine

    /// Connects the player node and starts the engine, once per reply.
    ///
    /// Called as soon as the first buffer of audio exists, which is during the model's own
    /// generation window: the engine takes about 10 ms to start and starting it also opens the
    /// output device, so neither cost lands when the first word is due.
    private func startPlaybackEngineIfNeeded(withAudioFormat audioFormat: AVAudioFormat) {
        if let connectedPlaybackAudioFormat, connectedPlaybackAudioFormat != audioFormat {
            // The voice is pinned, so every segment of every reply comes out in the same format.
            // Reconnecting on a difference is the cheap answer to a case that should not arise,
            // and it beats scheduling buffers into a mismatched connection, which fails silently.
            disconnectThePlaybackGraph()
        }

        // An engine that has stopped is not something this object is told about in time: the output
        // device changing under it takes it down, and the notification that means that arrives after
        // the fact, if at all. So the flag is checked against the engine itself, here, where the next
        // thing to happen is a buffer going into it — scheduling into a stopped engine fails
        // silently, which would be the rest of the reply going quiet with no fault reported anywhere.
        if isPlaybackEngineRunning, !playbackEngine.isRunning {
            print("🔊 TTS: the playback engine had stopped, rebuilding it before this segment")
            disconnectThePlaybackGraph()
        }

        if connectedPlaybackAudioFormat == nil {
            if playbackPlayerNode.engine == nil {
                playbackEngine.attach(playbackPlayerNode)
            }
            playbackEngine.connect(playbackPlayerNode, to: playbackEngine.mainMixerNode, format: audioFormat)
            connectedPlaybackAudioFormat = audioFormat
            installPlaybackLoudnessTap()
        }

        // The connection outlives a stopped engine — `stop()` halts the render thread and leaves the
        // graph attached — so a remembered format says nothing about whether the engine is running,
        // and scheduling into a stopped one fails silently. Every reply begins by stopping the engine,
        // so this cannot be skipped on a matching format.
        guard !isPlaybackEngineRunning else { return }

        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
        } catch {
            // Reported rather than swallowed, but not fatal to the reply:
            // `handlePlaybackHeadTick` finds no playback position, runs out its missing readings
            // and ends the segment, which releases the rest of it.
            print("⚠️ TTS playback engine failed to start: \(error)")
        }
    }

    /// Takes the player node and the engine down to where they stand before the first segment of a
    /// reply, so that what happens next is the connect and the start rather than a schedule into a
    /// graph that has gone.
    ///
    /// A tap is installed by the connect below and goes with the connection it was made for, so one
    /// exists exactly while a format is remembered — which is what makes removing it safe at both
    /// call sites.
    private func disconnectThePlaybackGraph() {
        playbackPlayerNode.stop()
        playbackPlayerNode.removeTap(onBus: 0)
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        connectedPlaybackAudioFormat = nil
    }

    /// Puts a tap on the player node that measures the audio as it is rendered.
    ///
    /// Installed and removed with the connection it is installed on, so there is never more than
    /// one. The block runs on the render thread, and the only thing it touches is the measurement
    /// it was handed — which is what lets the value cross to the main actor without a lock on the
    /// side that reads it.
    private func installPlaybackLoudnessTap() {
        let loudnessMeasurement = playbackLoudnessMeasurement
        playbackPlayerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channelData = buffer.floatChannelData else { return }

            // The node's output is one lane per channel, but the stride is asked for rather than
            // assumed: reading an interleaved buffer as if it were not would measure one channel
            // in `channelCount` and hear a different signal.
            let samplesBetweenFrames = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            var sumOfSquares: Float = 0
            for frameIndex in 0..<frameCount {
                let sample = channelData[0][frameIndex * samplesBetweenFrames]
                sumOfSquares += sample * sample
            }

            loudnessMeasurement.record(rootMeanSquare: (sumOfSquares / Float(frameCount)).squareRoot())
        }
    }

    private func stopPlaybackEngine() {
        guard isPlaybackEngineRunning else { return }
        playbackPlayerNode.stop()
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        // Nothing is being rendered any more, and no tick is left to say so.
        onVoiceLoudness?(0)
    }

    // MARK: - Reporting the playback position

    private func startPlaybackHeadPollingTimer() {
        stopPlaybackHeadPollingTimer()
        let pollingTimer = Timer(timeInterval: Self.playbackPositionPollingIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackHeadTick()
            }
        }
        // Common modes, so a word is still reported while a panel or menu is being interacted with —
        // the pointing tour waits on those reports.
        RunLoop.main.add(pollingTimer, forMode: .common)
        playbackHeadPollingTimer = pollingTimer
    }

    private func stopPlaybackHeadPollingTimer() {
        playbackHeadPollingTimer?.invalidate()
        playbackHeadPollingTimer = nil
    }

    /// Reports every word the playback position has reached, and ends the segment once its audio
    /// has been played through.
    private func handlePlaybackHeadTick() {
        guard currentlyPlayingSegment != nil else {
            stopPlaybackHeadPollingTimer()
            return
        }

        guard let lastRenderTime = playbackPlayerNode.lastRenderTime,
              let playbackTime = playbackPlayerNode.playerTime(forNodeTime: lastRenderTime) else {
            consecutiveMissingPlaybackReadings += 1
            if consecutiveMissingPlaybackReadings >= Self.consecutiveMissingPlaybackReadingsBeforeGivingUp {
                print("🔇 TTS: the playback position went missing — segment \(currentlyPlayingSegment?.segmentIndex ?? -1) is written off as played, so the rest of this reply is silent")
                finishCurrentSegmentPlayback()
            }
            return
        }

        consecutiveMissingPlaybackReadings = 0

        // Negative for the moment before the node has rendered its first cycle.
        let playedFrameCount = playbackTime.sampleTime
        guard playedFrameCount >= 0 else { return }

        // The tap's latest reading, which is this tick's answer to how loud the voice is right now.
        // Read here rather than off the playback position because the position says where the voice
        // is, not how it sounds — and at one tick per 20 ms the reading is never stale by more than
        // the buffer it came out of.
        onVoiceLoudness?(
            VoiceLoudness.loudness(fromRootMeanSquare: playbackLoudnessMeasurement.rootMeanSquare)
        )

        // The first frame the node has rendered is the first sound the user could have heard — asked
        // of the playback position, because asking for playback says only that it was scheduled.
        if playedFrameCount > 0 {
            // Once per reply rather than once per segment: both teardown calls clear the flag,
            // and this report is what ends the spinner.
            if !hasHeardTheFirstSoundOfTheCurrentReply {
                hasHeardTheFirstSoundOfTheCurrentReply = true
                onFirstSoundHeard?()
            }
        }

        // The word marks carry the frame their word starts at, in the same timeline the playback
        // position is counted in — the node was stopped before this segment's buffers were
        // scheduled, which is what puts both at zero.
        while nextWordMarkIndexToReport < wordMarksBeingPlayed.count,
              wordMarksBeingPlayed[nextWordMarkIndexToReport].startFrame <= playedFrameCount {
            onSpokenCharacterRange?(wordMarksBeingPlayed[nextWordMarkIndexToReport].characterRange)
            nextWordMarkIndexToReport += 1
        }

        guard playedFrameCount >= totalFramesBeingPlayed else { return }
        finishCurrentSegmentPlayback()
    }

    private func finishCurrentSegmentPlayback() {
        stopPlaybackHeadPollingTimer()
        currentlyPlayingSegment = nil
        wordMarksBeingPlayed = []
        totalFramesBeingPlayed = 0
        nextWordMarkIndexToReport = 0
        consecutiveMissingPlaybackReadings = 0
        // The gap before the next segment is silent, and the timer that would have reported the
        // silence is stopped here — so the last sound of the segment is reported over by this.
        onVoiceLoudness?(0)
        // TEMPORARY, with the 🔇/🔊 lines above: what this voice measures, to check the glow's
        // scale against it. Comes out with them.
        print("🔊 TTS: segment peak \(String(format: "%.3f", playbackLoudnessMeasurement.peakRootMeanSquare)) rms")
        onPlaybackFinished?()
    }

    // MARK: - The voice

    /// Picks the voice to speak with: an explicit Info.plist identifier if it resolves, otherwise the
    /// highest-quality voice installed for the user's language.
    ///
    /// macOS ships only "compact" voices by default, so ranking by quality is what picks up the better
    /// "enhanced" and "premium" ones where the user has downloaded them.
    private static func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let preferredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: preferredVoiceIdentifierInfoPlistKey),
           let preferredVoice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return preferredVoice
        }

        let installedVoices = AVSpeechSynthesisVoice.speechVoices()

        // Locale.preferredLanguages, never Locale.current: Locale.current is resolved against the
        // app bundle's own localizations, and this bundle ships no .lproj at all, so it always
        // resolves to English — which would pick an English voice on a Chinese Mac.
        // Locale.preferredLanguages reads the system's AppleLanguages list directly.
        let currentLanguageCode = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let voicesForCurrentLanguage = installedVoices.filter { installedVoice in
            guard let currentLanguageCode else { return true }
            return installedVoice.language.hasPrefix(currentLanguageCode)
        }

        let candidateVoices = voicesForCurrentLanguage.isEmpty ? installedVoices : voicesForCurrentLanguage

        return candidateVoices.max { firstVoice, secondVoice in
            firstVoice.quality.rawValue < secondVoice.quality.rawValue
        }
    }

}

// MARK: - How loud the audio being played is

/// The level of the audio passing through the player node, written from the render thread and read
/// from the main actor.
///
/// The tap that fills it runs on the render thread, where a lock held for the length of a poll is
/// not an option, so the two directions are kept to the width of one `Float` under a lock that is
/// held for two instructions at a time. `nonisolated` puts the whole class outside the target's
/// default main-actor isolation, which is what lets the render thread touch it at all.
private nonisolated final class PlaybackLoudnessMeasurement {

    private let lock = NSLock()
    private var mostRecentRootMeanSquare: Float = 0
    private var highestRootMeanSquareSinceReset: Float = 0

    /// The most recent buffer's level, which is what a tick reports.
    var rootMeanSquare: Float {
        lock.lock()
        defer { lock.unlock() }
        return mostRecentRootMeanSquare
    }

    /// The loudest level since the last reset, which nothing but the diagnostic read uses.
    var peakRootMeanSquare: Float {
        lock.lock()
        defer { lock.unlock() }
        return highestRootMeanSquareSinceReset
    }

    func record(rootMeanSquare: Float) {
        lock.lock()
        mostRecentRootMeanSquare = rootMeanSquare
        highestRootMeanSquareSinceReset = max(highestRootMeanSquareSinceReset, rootMeanSquare)
        lock.unlock()
    }

    /// Called before a segment is played, so what the last one measured cannot be read as this
    /// one's opening.
    func reset() {
        lock.lock()
        mostRecentRootMeanSquare = 0
        highestRootMeanSquareSinceReset = 0
        lock.unlock()
    }
}

// MARK: - One segment, from its text to its audio

/// A single speech segment: its audio as it is produced, and the word positions inside it once it
/// is finished.
///
/// `nonisolated` on purpose. `write(_:toBufferCallback:)` answers with one buffer per few tens of
/// milliseconds of speech, so a hop to the main actor per buffer would put hundreds of hops on the
/// thread drawing the overlay's waveform.
///
/// A word mark records the frames already produced when the word was reported, which is that word's
/// position in the finished audio.
private nonisolated final class PreparedSpeechSegment {

    struct SynthesizedAudio {
        let audioBuffers: [AVAudioPCMBuffer]
        let audioFormat: AVAudioFormat
        let wordMarks: [(characterRange: NSRange, startFrame: Int)]
        let totalFrames: Int
    }

    let segmentIndex: Int
    let spokenText: String

    /// Called once, the first time a buffer arrives, with that buffer's format — how the playback
    /// engine learns what to connect with, since the voice's output format exists nowhere else.
    var onFirstAudioBufferProduced: ((AVAudioFormat) -> Void)?

    private let lock = NSLock()
    private var accumulatedAudioBuffers: [AVAudioPCMBuffer] = []
    private var accumulatedWordMarks: [(characterRange: NSRange, startFrame: Int)] = []
    private var accumulatedFrameCount = 0
    private var didProduceFirstAudioBuffer = false
    private var didFinishSynthesis = false

    init(segmentIndex: Int, spokenText: String) {
        self.segmentIndex = segmentIndex
        self.spokenText = spokenText
    }

    var isSynthesisComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinishSynthesis
    }

    /// Everything playback needs, or nil while the synthesis is still running.
    var synthesizedAudio: SynthesizedAudio? {
        lock.lock()
        defer { lock.unlock() }
        guard didFinishSynthesis, let audioFormat = accumulatedAudioBuffers.first?.format else { return nil }
        return SynthesizedAudio(
            audioBuffers: accumulatedAudioBuffers,
            audioFormat: audioFormat,
            wordMarks: accumulatedWordMarks,
            totalFrames: accumulatedFrameCount
        )
    }

    /// Records a produced buffer, and reports the first one's format out loud.
    ///
    /// The frame count is advanced here rather than at the word mark, so a word reported after
    /// this buffer carries the position the buffer ended at — which is where that word begins.
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock()
        accumulatedAudioBuffers.append(audioBuffer)
        accumulatedFrameCount += Int(audioBuffer.frameLength)
        let isFirstAudioBuffer = !didProduceFirstAudioBuffer
        didProduceFirstAudioBuffer = true
        lock.unlock()

        guard isFirstAudioBuffer else { return }
        onFirstAudioBufferProduced?(audioBuffer.format)
    }

    func appendWordMark(characterRange: NSRange) {
        lock.lock()
        defer { lock.unlock() }
        accumulatedWordMarks.append((characterRange: characterRange, startFrame: accumulatedFrameCount))
    }

    /// Synthesis ends by the synthesizer handing over a buffer of length zero.
    func markSynthesisComplete() {
        lock.lock()
        defer { lock.unlock() }
        didFinishSynthesis = true
    }
}

// MARK: - Driving the synthesizer

/// Owns the `AVSpeechSynthesizer` and runs it, one segment at a time.
///
/// A type of its own because of where the work lands: the synthesizer's callbacks arrive on a queue
/// of its own, off the main actor, and the state they touch has to be off it with them.
/// `nonisolated` puts the whole class outside the default main-actor isolation.
///
/// The queue below enforces serialisation rather than the caller, because a second segment arriving
/// while the first is still synthesising is the ordinary case for a reply of more than one segment.
private nonisolated final class SpeechSegmentSynthesizer: NSObject, AVSpeechSynthesizerDelegate {

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()

    /// The voice every segment is spoken with. Set once, before the first segment.
    var voice: AVSpeechSynthesisVoice?

    /// Reports the format of the first buffer of the first segment — the playback engine has
    /// nothing to connect with until the voice's own audio exists.
    var onFirstAudioBufferProduced: ((AVAudioFormat) -> Void)?

    private var currentGeneration = 0
    private var activeSynthesis: (utterance: AVSpeechUtterance, segment: PreparedSpeechSegment)?

    /// Segments whose text is final and which are waiting for the synthesizer to be free.
    /// Drained in the order they were handed over, which is the order they are spoken in.
    private var queuedSegmentsWaitingForSynthesis: [PreparedSpeechSegment] = []

    /// True between a `write()` being started and its zero-length closing buffer arriving. That
    /// buffer is the only signal there is that the synthesizer has finished with the previous
    /// segment, and it is what starts the next queued one.
    private var isSynthesisInFlight = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Queues one segment for synthesis and returns immediately. The returned segment is filled in as
    /// the audio is produced; the caller polls `isSynthesisComplete` rather than being called back.
    ///
    /// A segment handed over while another is still being synthesised waits in the queue rather than
    /// starting a second `write()`, and that is the whole reason the queue exists. A second `write()`
    /// disowns every callback the first one was still owed, the zero-length closing buffer included —
    /// and a segment that never reports itself complete is one `speakPreparedSegment` waits on with no
    /// deadline at all.
    func beginSynthesizing(spokenText: String, segmentIndex: Int) -> PreparedSpeechSegment {
        let segment = PreparedSpeechSegment(
            segmentIndex: segmentIndex,
            spokenText: spokenText
        )
        segment.onFirstAudioBufferProduced = { [weak self] audioFormat in
            self?.onFirstAudioBufferProduced?(audioFormat)
        }

        lock.lock()
        queuedSegmentsWaitingForSynthesis.append(segment)
        lock.unlock()

        startNextQueuedSynthesisIfSynthesizerIsFree()

        return segment
    }

    /// Starts the oldest queued segment's `write()`, unless one is already running.
    ///
    /// The generation is bumped when a `write()` begins rather than when a segment is handed over,
    /// so it counts `write()` calls: a segment that is only queued has no callbacks to disown yet,
    /// and bumping for it would orphan the segment already being synthesised.
    private func startNextQueuedSynthesisIfSynthesizerIsFree() {
        lock.lock()
        guard !isSynthesisInFlight, !queuedSegmentsWaitingForSynthesis.isEmpty else {
            lock.unlock()
            return
        }
        let segment = queuedSegmentsWaitingForSynthesis.removeFirst()
        isSynthesisInFlight = true
        currentGeneration += 1
        let generation = currentGeneration
        lock.unlock()

        let utterance = AVSpeechUtterance(string: segment.spokenText)
        utterance.voice = voice

        lock.lock()
        activeSynthesis = (utterance: utterance, segment: segment)
        lock.unlock()

        speechSynthesizer.write(utterance) { [weak self] audioBuffer in
            guard let self, let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else { return }

            self.lock.lock()
            let isStillTheCurrentGeneration = (generation == self.currentGeneration)
            self.lock.unlock()
            guard isStillTheCurrentGeneration else { return }

            // Synthesis is finished by a buffer of length zero rather than by a callback of its
            // own, and that same buffer is what frees the synthesizer for the next segment.
            guard pcmBuffer.frameLength > 0 else {
                segment.markSynthesisComplete()
                self.finishSynthesisInFlight()
                return
            }
            segment.appendAudioBuffer(pcmBuffer)
        }
    }

    /// Marks the synthesizer free and hands it whatever has been queued since.
    private func finishSynthesisInFlight() {
        lock.lock()
        isSynthesisInFlight = false
        lock.unlock()

        startNextQueuedSynthesisIfSynthesizerIsFree()
    }

    /// Abandons the synthesis in flight and makes its late callbacks land nowhere.
    ///
    /// Stopping the synthesizer does not promise that it will stop delivering, so the generation bump
    /// is what disowns the callbacks already on their way.
    func cancelSynthesisInFlight() {
        lock.lock()
        currentGeneration += 1
        activeSynthesis = nil
        // A stopped `write()` never delivers the closing buffer that would otherwise have cleared
        // this, so leaving it set would make every later segment queue behind a synthesis that no
        // longer exists.
        queuedSegmentsWaitingForSynthesis = []
        isSynthesisInFlight = false
        lock.unlock()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: The synthesizer's word ranges

    func speechSynthesizer(
        _ speechSynthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        lock.lock()
        let active = activeSynthesis
        lock.unlock()

        // The utterance is the identity that matters here, not the generation: the synthesizer hands
        // the utterance back with every callback, so a late word from a replaced segment cannot be
        // mistaken for this one's.
        guard let active, active.utterance === utterance else { return }
        active.segment.appendWordMark(characterRange: characterRange)
    }
}
