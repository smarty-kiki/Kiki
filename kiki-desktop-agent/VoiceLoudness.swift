//  VoiceLoudness.swift
//  kiki-desktop-agent
//
//  How loud the voice Kiki is speaking with is at this instant, in the one shape the cursor's glow
//  can be drawn from.
//
//  Two things ever speak for Kiki — the reply being read aloud, and the onboarding video's own
//  narration — and neither is guessed at from the words: each is measured off the audio that is
//  actually coming out.

import AVFoundation
import Combine
import Foundation

/// Turns a measured root mean square into the 0-to-1 loudness the glow widens by.
enum VoiceLoudness {

    /// The root mean square that counts as full loudness.
    ///
    /// Speech synthesized by `AVSpeechSynthesizer` measures around 0.07 at an ordinary moment and
    /// peaks near 0.28, so this puts the ordinary case in the middle of the range and leaves the
    /// peaks of a sentence somewhere to go.
    static let rootMeanSquareOfOrdinarySpeech: Float = 0.25

    /// A level meter's scale, cheaply. Loudness is heard on something much closer to the square
    /// root of the amplitude than to the amplitude itself, and without this a sentence's quiet half
    /// would sit pinned at zero.
    static func loudness(fromRootMeanSquare rootMeanSquare: Float) -> CGFloat {
        guard rootMeanSquare > 0 else { return 0 }
        let fractionOfOrdinarySpeech = rootMeanSquare / rootMeanSquareOfOrdinarySpeech
        return CGFloat(min(fractionOfOrdinarySpeech.squareRoot(), 1))
    }
}

/// What the cursor's glow widens and narrows by.
///
/// A type of its own rather than a `@Published` on `CompanionManager`: this changes with the audio,
/// tens of times a second, and everything observing the manager — the panel included — would
/// re-evaluate that often for a number that only the cursor draws.
@MainActor
final class VoiceLoudnessMeter: ObservableObject {

    /// How loud the voice being heard is, from 0 to 1. Silence is zero and there is no third state:
    /// a glow driven by a silence and a glow nothing is driving are the same picture.
    ///
    /// The rise and the fall between two of these are the drawing's own animation, which is why the
    /// values can arrive at whatever rate their source happens to produce them.
    @Published private(set) var loudness: CGFloat = 0

    func report(_ measuredLoudness: CGFloat) {
        // The guard `settleVoiceState` keeps, for the same reason: a write that changes nothing
        // still invalidates every view reading it, and silence arrives as a report every 20 ms.
        guard measuredLoudness != loudness else { return }
        loudness = measuredLoudness
    }
}

/// How loud a video's own audio track is over time, measured once and then read off by position.
///
/// `AVPlayer` publishes no level of its own, and the alternative — `MTAudioProcessingTap` — puts a
/// C callback on the render thread to answer a question that only has to be roughly right. The clip
/// is local and lasts under half a minute, so decoding it once costs less than either, and it is
/// the video's own track that is decoded: the music playing underneath the intro is deliberately
/// not measured, because the glow follows a voice and music is not one.
struct OnboardingNarrationLoudnessEnvelope {

    /// The resolution the track is measured at, which is also how often the player is asked where
    /// it is. Fine enough that a syllable moves the glow, coarse enough to be a table of numbers.
    static let secondsPerStep = 1.0 / 30.0

    private let loudnessPerStep: [CGFloat]

    /// A step past the end reads as silence rather than as a failure: the clip's own length and the
    /// number of steps it produced disagree by a fraction of one, and the last thing that should
    /// happen is the glow freezing at whatever the final step happened to measure.
    func loudness(atSeconds seconds: Double) -> CGFloat {
        guard !loudnessPerStep.isEmpty else { return 0 }
        let stepIndex = Int(seconds / Self.secondsPerStep)
        guard loudnessPerStep.indices.contains(stepIndex) else { return 0 }
        return loudnessPerStep[stepIndex]
    }

    /// Decodes the audio track and measures it, or nil if the file has no audio at all.
    ///
    /// `AVAudioFile` reads the track straight out of the mp4, which is what keeps this a page of
    /// code rather than a pipeline of sample buffers. `nonisolated` because it belongs off the main
    /// actor: it takes a fraction of a second, and the thing it would otherwise be holding up is
    /// the fade-in of the video it is measuring.
    nonisolated static func measuring(videoAt videoURL: URL) -> OnboardingNarrationLoudnessEnvelope? {
        guard let audioFile = try? AVAudioFile(forReading: videoURL) else { return nil }

        let audioFormat = audioFile.processingFormat
        let channelCount = Int(audioFormat.channelCount)
        guard channelCount > 0 else { return nil }

        // Counted in samples rather than in frames, because every channel of a frame is summed.
        let samplesPerStep = max(Int(audioFormat.sampleRate * secondsPerStep) * channelCount, 1)
        let bufferFrameCapacity: AVAudioFrameCount = 4096
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: bufferFrameCapacity) else {
            return nil
        }

        var loudnessPerStep: [CGFloat] = []
        var sumOfSquares = 0.0
        var samplesInStep = 0

        while audioFile.framePosition < audioFile.length {
            guard (try? audioFile.read(into: readBuffer, frameCount: bufferFrameCapacity)) != nil else { break }
            guard readBuffer.frameLength > 0, let channelData = readBuffer.floatChannelData else { break }

            for frameIndex in 0..<Int(readBuffer.frameLength) {
                for channelIndex in 0..<channelCount {
                    let sample = Double(channelData[channelIndex][frameIndex])
                    sumOfSquares += sample * sample
                }
                samplesInStep += channelCount

                if samplesInStep >= samplesPerStep {
                    loudnessPerStep.append(
                        VoiceLoudness.loudness(
                            fromRootMeanSquare: Float((sumOfSquares / Double(samplesInStep)).squareRoot())
                        )
                    )
                    sumOfSquares = 0
                    samplesInStep = 0
                }
            }
        }

        // The tail of the clip is shorter than a whole step; measuring it over its own length
        // rather than over the step it did not fill is the difference between the last word and a
        // value dragged towards silence by the silence around it.
        if samplesInStep > 0 {
            loudnessPerStep.append(
                VoiceLoudness.loudness(
                    fromRootMeanSquare: Float((sumOfSquares / Double(samplesInStep)).squareRoot())
                )
            )
        }

        guard !loudnessPerStep.isEmpty else { return nil }
        return OnboardingNarrationLoudnessEnvelope(loudnessPerStep: loudnessPerStep)
    }
}
