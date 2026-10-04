//  VoiceLoudness.swift
//  kiki-desktop-agent
//
//  How loud Kiki's voice is at this instant: measured off the audio, never guessed at from the words.

import AVFoundation
import Combine
import Foundation

enum VoiceLoudness {

    /// The root mean square that counts as full loudness: `AVSpeechSynthesizer` speech measures around
    /// 0.07 ordinarily and peaks near 0.28, so 0.25 sits mid-range and leaves a sentence's peaks room.
    static let rootMeanSquareOfOrdinarySpeech: Float = 0.25

    /// A level meter's scale, cheaply: loudness is heard on the square root of the amplitude —
    /// without it a sentence's quiet half would sit pinned at zero.
    static func loudness(fromRootMeanSquare rootMeanSquare: Float) -> CGFloat {
        guard rootMeanSquare > 0 else { return 0 }
        let fractionOfOrdinarySpeech = rootMeanSquare / rootMeanSquareOfOrdinarySpeech
        return CGFloat(min(fractionOfOrdinarySpeech.squareRoot(), 1))
    }
}

/// What the cursor's glow widens and narrows by — a type of its own rather than a `@Published` on
/// `CompanionManager`, which every observer would re-evaluate tens of times a second for one cursor.
@MainActor
final class VoiceLoudnessMeter: ObservableObject {

    /// How loud the voice being heard is, from 0 to 1. Silence is zero and there is no third state —
    /// the rise and the fall between two of these are the drawing's own animation.
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
/// `AVPlayer` publishes no level of its own, and `MTAudioProcessingTap` would put a C callback on the
/// render thread for a number that only has to be roughly right. The clip is local and lasts under
/// half a minute, so decoding it once costs less than either — and the music under the intro is
/// deliberately not measured, because the glow follows a voice and music is not one.
struct OnboardingNarrationLoudnessEnvelope {

    /// The resolution the track is measured at, which is also how often the player is asked where it
    /// is: fine enough that a syllable moves the glow, coarse enough to stay a table of numbers.
    static let secondsPerStep = 1.0 / 30.0

    private let loudnessPerStep: [CGFloat]

    /// A step past the end reads as silence rather than as a failure: the clip's length and its step
    /// count disagree by a fraction of one, and the glow must not freeze on the final step's value.
    func loudness(atSeconds seconds: Double) -> CGFloat {
        guard !loudnessPerStep.isEmpty else { return 0 }
        let stepIndex = Int(seconds / Self.secondsPerStep)
        guard loudnessPerStep.indices.contains(stepIndex) else { return 0 }
        return loudnessPerStep[stepIndex]
    }

    /// Decodes the audio track and measures it, or nil if the file has no audio at all. `AVAudioFile`
    /// reads straight out of the mp4, and `nonisolated` keeps the fraction of a second this takes off
    /// the actor drawing the video's fade-in.
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

        // The tail is shorter than a whole step; measuring it over its own length rather than over the
        // step it did not fill keeps the last word off a silence-dragged value.
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
