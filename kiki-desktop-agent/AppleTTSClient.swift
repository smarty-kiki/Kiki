//  AppleTTSClient.swift
//  kiki-desktop-agent
//
//  Text-to-speech backed by Apple's on-device AVSpeechSynthesizer: no API key, no network, no cost.

import AVFoundation
import Foundation

/// Speaks the reply one speech segment at a time, synthesising each while the model is still writing
/// the rest: synthesis and playback are separate calls, so only playback sits in front of the voice.
///
/// `write(_:toBufferCallback:)` is driven strictly serially — a second `write()` disowns the first's
/// callbacks, including the zero-length closing buffer that alone marks a segment complete.
///
/// There is deliberately no pause API: `pauseSpeaking`/`continueSpeaking` leave the synthesizer silent
/// for the rest of the utterance while reporting `isPaused == false`. `CompanionManager` withholds the
/// next segment instead.
@MainActor
final class AppleTTSClient {

    // MARK: - What the caller hears about

    /// Reports a word as it is reached, in UTF-16 offsets within the segment's own text, taken from the
    /// playback position rather than the synthesizer. `CompanionManager` adds its start offset.
    var onSpokenCharacterRange: (@MainActor (NSRange) -> Void)?

    /// Reports that the segment handed to `speakPreparedSegment` has been heard in full. The next
    /// segment is withheld until it arrives, so audio that never ends strands the rest of the reply.
    var onPlaybackFinished: (@MainActor () -> Void)?

    /// Reports that audio of the current reply has actually reached the output, once per reply: only
    /// the playback position knows the node has rendered, not the scheduling of it.
    var onFirstSoundHeard: (@MainActor () -> Void)?

    /// Reports how loud the audio being rendered is, from 0 to 1, once per tick and zero once the
    /// segment is over — the raw measurement, since the glow's rise and fall is the drawing's own.
    var onVoiceLoudness: (@MainActor (CGFloat) -> Void)?

    /// False between segments, which is why `CompanionManager` schedules the transient cursor hide off
    /// its own `isSpeakingReply`.
    var isPlaying: Bool { currentlyPlayingSegment != nil }

    // MARK: - Configuration

    /// Optional Info.plist key naming an exact voice to speak with. Absent, or naming a voice this
    /// machine does not have, the best voice for the user's own language is used.
    private static let preferredVoiceIdentifierInfoPlistKey = "AppleTTSVoiceIdentifier"

    /// How often the playback position is read while a segment plays: the words it reports drive the
    /// pointing tour, so this is the resolution a tour trigger fires at.
    private static let playbackPositionPollingIntervalSeconds: TimeInterval = 0.02

    /// How many consecutive nil readings of the playback position write a playback off.
    ///
    /// `playerTime(forNodeTime:)` returns nil only while the node is not playing, so after `play()` it
    /// means the audio fell over — and a segment that never reports finished is a reply that never
    /// continues, so this turns it into a late end.
    private static let consecutiveMissingPlaybackReadingsBeforeGivingUp = 25

    // MARK: - Synthesis

    private let speechSegmentSynthesizer = SpeechSegmentSynthesizer()

    /// Every segment handed over for synthesis, in order — kept after playback because
    /// `speakPreparedSegment(segmentIndex:)` finds one by its index.
    private var preparedSpeechSegments: [PreparedSpeechSegment] = []

    // MARK: - Playback

    private let playbackEngine = AVAudioEngine()
    private let playbackPlayerNode = AVAudioPlayerNode()
    private var isPlaybackEngineRunning = false

    /// Whether any audio of the current reply has reached the output, which is what makes
    /// `onFirstSoundHeard` once per reply. Clearing it early costs nothing — the next tick that sees
    /// the node render reports again — while clearing it too late costs the caller the report.
    private var hasHeardTheFirstSoundOfTheCurrentReply = false

    /// The format the player node is connected to the mixer with: the voice's own output format,
    /// which is not knowable until the first buffer of audio exists.
    private var connectedPlaybackAudioFormat: AVAudioFormat?

    /// What the tap below most recently measured, read by the polling timer — written on the render
    /// thread and carried by that poll to the main actor.
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

    /// Hands one speech segment over to be synthesised and returns immediately; its text is final by
    /// the time it arrives here.
    func prepareSpeechSegment(spokenText: String, segmentIndex: Int) {
        let preparedSegment = speechSegmentSynthesizer.beginSynthesizing(
            spokenText: spokenText,
            segmentIndex: segmentIndex
        )
        preparedSpeechSegments.append(preparedSegment)
    }

    /// Plays a segment that was handed over earlier, waiting for its synthesis if it has not finished.
    /// Synthesis runs at roughly six times real time, so every segment but the first is usually ready.
    func speakPreparedSegment(segmentIndex: Int) async {
        guard let speechSegment = preparedSpeechSegments.first(where: { $0.segmentIndex == segmentIndex }) else {
            return
        }

        while !speechSegment.isSynthesisComplete {
            // The reply may have been replaced while this was waiting: the segment is then gone from
            // the list and there is nothing left to play.
            guard preparedSpeechSegments.contains(where: { $0 === speechSegment }) else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard preparedSpeechSegments.contains(where: { $0 === speechSegment }) else { return }

        guard let synthesizedAudio = speechSegment.synthesizedAudio else {
            // Synthesis completed without producing audio. Reporting the segment finished is the only
            // safe direction — waiting for audio that will never exist would strand the rest.
            onPlaybackFinished?()
            return
        }

        startPlaybackEngineIfNeeded(withAudioFormat: synthesizedAudio.audioFormat)

        // Stopping the node drops anything scheduled and resets its timeline, so this segment's
        // word-mark frames are counted from zero rather than keeping the last segment's.
        playbackPlayerNode.stop()
        // The previous segment's last reading outlives its audio, and would be reported as this
        // segment's opening syllable.
        playbackLoudnessMeasurement.reset()
        for audioBuffer in synthesizedAudio.audioBuffers {
            // Written out in full rather than as `scheduleBuffer(_:)`, which inside an `async` function
            // is ambiguous: AVFoundation also publishes a one-argument `async` overload that suspends
            // until the buffer has played, and the compiler picks it — one buffer at a time, waited out.
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

    /// Stops the audio immediately, without touching what has been prepared; both callers follow it
    /// with `discardPreparedSegments()`.
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

    /// Drops every segment that has not been played, and abandons the one being synthesised. A stopped
    /// `write()` can still deliver buffers, so callbacks check their generation before touching one.
    func discardPreparedSegments() {
        preparedSpeechSegments = []
        hasHeardTheFirstSoundOfTheCurrentReply = false
        speechSegmentSynthesizer.cancelSynthesisInFlight()
        stopPlaybackEngine()
    }

    // MARK: - The playback engine

    /// Connects the player node and starts the engine, once per reply — as soon as the first buffer
    /// exists, during the model's own generation window: starting takes about 10 ms and also opens the
    /// output device, so neither cost lands when the first word is due.
    private func startPlaybackEngineIfNeeded(withAudioFormat audioFormat: AVAudioFormat) {
        if let connectedPlaybackAudioFormat, connectedPlaybackAudioFormat != audioFormat {
            // The voice is pinned, so this should not arise; reconnecting is the cheap answer, and it
            // beats scheduling buffers into a mismatched connection, which fails silently.
            disconnectThePlaybackGraph()
        }

        // Checked against the engine itself, where the next thing to happen is a buffer going into it:
        // a hardware change stops the engine, the notification that means it arrives after the fact if
        // at all, and scheduling into a stopped engine fails silently — the reply just goes quiet.
        if isPlaybackEngineRunning, !playbackEngine.isRunning {
            print("TTS: the playback engine had stopped, rebuilding it before this segment")
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
        // graph attached — so a remembered format says nothing about whether the engine is running.
        guard !isPlaybackEngineRunning else { return }

        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
        } catch {
            // Reported rather than swallowed, but not fatal: `handlePlaybackHeadTick` finds no position,
            // runs out its missing readings and ends the segment, which releases the rest of the reply.
            print("TTS playback engine failed to start: \(error)")
        }
    }

    /// Takes the player node and the engine down to where they stand before a reply's first segment,
    /// so what happens next is the connect and the start rather than a schedule into a graph that has
    /// gone. A tap goes with its connection, so removing it is safe exactly while a format is remembered.
    private func disconnectThePlaybackGraph() {
        playbackPlayerNode.stop()
        playbackPlayerNode.removeTap(onBus: 0)
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        connectedPlaybackAudioFormat = nil
    }

    /// Puts a tap on the player node that measures the audio as it is rendered — installed and removed
    /// with its connection, so there is never more than one. The block runs on the render thread and
    /// touches only the lock-protected measurement it was handed.
    private func installPlaybackLoudnessTap() {
        let loudnessMeasurement = playbackLoudnessMeasurement
        playbackPlayerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channelData = buffer.floatChannelData else { return }

            // The stride is asked for rather than assumed: reading an interleaved buffer as if it
            // were not would measure one channel in `channelCount`.
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

    private func handlePlaybackHeadTick() {
        guard currentlyPlayingSegment != nil else {
            stopPlaybackHeadPollingTimer()
            return
        }

        guard let lastRenderTime = playbackPlayerNode.lastRenderTime,
              let playbackTime = playbackPlayerNode.playerTime(forNodeTime: lastRenderTime) else {
            consecutiveMissingPlaybackReadings += 1
            if consecutiveMissingPlaybackReadings >= Self.consecutiveMissingPlaybackReadingsBeforeGivingUp {
                print("TTS: the playback position went missing — segment \(currentlyPlayingSegment?.segmentIndex ?? -1) is written off as played, so the rest of this reply is silent")
                finishCurrentSegmentPlayback()
            }
            return
        }

        consecutiveMissingPlaybackReadings = 0

        // Negative for the moment before the node has rendered its first cycle.
        let playedFrameCount = playbackTime.sampleTime
        guard playedFrameCount >= 0 else { return }

        // The tap's latest reading, not a value derived from the position: the position says where the
        // voice is, not how it sounds.
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

        // The word marks and the playback position share one timeline, both starting at zero because
        // the node was stopped before this segment's buffers were scheduled.
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
        onPlaybackFinished?()
    }

    // MARK: - The voice

    /// Picks the voice to speak with: an explicit Info.plist identifier if it resolves, otherwise the
    /// highest-quality voice installed for the user's language — macOS ships only "compact" voices by
    /// default, so ranking by quality is what picks up the "enhanced" and "premium" ones.
    private static func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let preferredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: preferredVoiceIdentifierInfoPlistKey),
           let preferredVoice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return preferredVoice
        }

        let installedVoices = AVSpeechSynthesisVoice.speechVoices()

        // Locale.preferredLanguages, never Locale.current: Locale.current resolves against the app
        // bundle's own localizations, and this bundle ships no .lproj at all, so it always resolves to
        // English — which would pick an English voice on a Chinese Mac.
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

/// The level of the audio passing through the player node, written from the render thread and read from
/// the main actor under a lock held for two instructions — the render thread cannot hold one for the
/// length of a poll. `nonisolated` is what lets that thread touch it at all.
private nonisolated final class PlaybackLoudnessMeasurement {

    private let lock = NSLock()
    private var mostRecentRootMeanSquare: Float = 0

    /// The most recent buffer's level, which is what a tick reports.
    var rootMeanSquare: Float {
        lock.lock()
        defer { lock.unlock() }
        return mostRecentRootMeanSquare
    }

    func record(rootMeanSquare: Float) {
        lock.lock()
        mostRecentRootMeanSquare = rootMeanSquare
        lock.unlock()
    }

    /// Called before a segment is played, so the last one's reading cannot be read as this one's.
    func reset() {
        lock.lock()
        mostRecentRootMeanSquare = 0
        lock.unlock()
    }
}

// MARK: - One segment, from its text to its audio

/// A single speech segment: its audio as it is produced, and the word positions inside it once it is
/// finished — a mark records the frames already produced when the word was reported, which is where
/// that word starts in the finished audio.
///
/// `nonisolated` on purpose: `write(_:toBufferCallback:)` answers one buffer per few tens of
/// milliseconds, and a main-actor hop per buffer would land on the thread drawing the overlay.
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

    /// The frame count is advanced here, so a word mark arrives carrying the position this buffer
    /// ended at — which is where that word begins.
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
/// A type of its own because its callbacks arrive on a queue of its own, off the main actor, and the
/// state they touch has to go with them — `nonisolated` puts the class outside the default isolation.
/// The queue below serialises rather than the caller, since a second segment mid-synthesis is ordinary.
private nonisolated final class SpeechSegmentSynthesizer: NSObject, AVSpeechSynthesizerDelegate {

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()

    /// The voice every segment is spoken with. Set once, before the first segment.
    var voice: AVSpeechSynthesisVoice?

    /// Reports the first buffer's format — the playback engine has nothing to connect with until the
    /// voice's own audio exists.
    var onFirstAudioBufferProduced: ((AVAudioFormat) -> Void)?

    private var currentGeneration = 0
    private var activeSynthesis: (utterance: AVSpeechUtterance, segment: PreparedSpeechSegment)?

    /// Segments whose text is final and which are waiting for the synthesizer to be free.
    /// Drained in the order they were handed over, which is the order they are spoken in.
    private var queuedSegmentsWaitingForSynthesis: [PreparedSpeechSegment] = []

    /// True between a `write()` being started and its zero-length closing buffer arriving — the only
    /// signal that the synthesizer has finished, and what starts the next queued segment.
    private var isSynthesisInFlight = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Queues one segment for synthesis and returns immediately. The returned segment is filled in as
    /// the audio is produced; the caller polls `isSynthesisComplete` rather than being called back.
    ///
    /// A segment handed over mid-synthesis waits in the queue, and that is the whole reason the queue
    /// exists: a second `write()` disowns the first one's callbacks, the zero-length closing buffer
    /// included, and a segment that never reports complete is one `speakPreparedSegment` waits on forever.
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
    /// The generation is bumped when a `write()` begins, not when a segment is queued, so it counts
    /// `write()` calls: bumping for a merely queued segment would orphan the one being synthesised.
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

            // Synthesis is finished by a buffer of length zero, not a callback of its own — and that
            // same buffer frees the synthesizer for the next segment.
            guard pcmBuffer.frameLength > 0 else {
                segment.markSynthesisComplete()
                self.finishSynthesisInFlight()
                return
            }
            segment.appendAudioBuffer(pcmBuffer)
        }
    }

    private func finishSynthesisInFlight() {
        lock.lock()
        isSynthesisInFlight = false
        lock.unlock()

        startNextQueuedSynthesisIfSynthesizerIsFree()
    }

    /// Abandons the synthesis in flight and makes its late callbacks land nowhere: stopping the
    /// synthesizer does not promise it will stop delivering, so the generation bump disowns the
    /// callbacks already on their way.
    func cancelSynthesisInFlight() {
        lock.lock()
        currentGeneration += 1
        activeSynthesis = nil
        // A stopped `write()` never delivers the closing buffer that would have cleared this, so
        // leaving it set would make every later segment queue behind a synthesis that is gone.
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

        // The utterance is the identity here, not the generation: a late word from a replaced segment
        // cannot be mistaken for this one's.
        guard let active, active.utterance === utterance else { return }
        active.segment.appendWordMark(characterRange: characterRange)
    }
}
