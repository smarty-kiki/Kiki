//
//  ElementActionSoundPlayer.swift
//  kiki-desktop-agent
//
//  The short sounds that go out with the gestures Kiki performs on the user's behalf.

import AVFoundation

/// Plays the sounds that accompany the gestures Kiki performs on the user's behalf.
///
/// The sound belongs to the *gesture*, not the raw event: a `[DOUBLECLICK:…]` is two down/up pairs
/// 50 ms apart, so a sound per event would be a stutter. It is never played for a gesture that was
/// refused — see `refusalOfClick` and `refusalOfCombination`, which the caller asks first — and the
/// audio is decoded and readied in `init` because a gesture lands inside the stop's one-second dwell.
///
/// A press and a key combination each have one; a scroll and a drag have none, because what moves is
/// its own feedback and neither of them presses a key.
@MainActor
final class ElementActionSoundPlayer {

    private static let clickSoundFileName = "click"
    private static let keyPressSoundFileName = "type"
    private static let soundFileExtension = "mp3"

    /// How loud the click is. Deliberately low: it lands while a reply is being spoken, so it
    /// is the quietest thing the app plays and can never be heard over the voice.
    private static let clickVolume: Float = 0.25

    /// Its own number rather than the click's, because the two recordings are not equally loud: the
    /// key press is a longer, softer sound whose loudest stretch sits about 10 dB below the click's,
    /// and 0.75 is what brings it up to the same loudness. Played at the click's 0.25 it would be
    /// inaudible beside the very sound it is meant to sit alongside.
    private static let keyPressVolume: Float = 0.75

    /// Nil when the asset is missing from the bundle or could not be decoded, in which case that
    /// gesture is silent — a sound is feedback, and its absence must not take the gesture down.
    private let clickPlayer: AVAudioPlayer?
    private let keyPressPlayer: AVAudioPlayer?

    init() {
        clickPlayer = Self.makePlayer(
            fileName: Self.clickSoundFileName,
            volume: Self.clickVolume
        )
        keyPressPlayer = Self.makePlayer(
            fileName: Self.keyPressSoundFileName,
            volume: Self.keyPressVolume
        )
    }

    private static func makePlayer(fileName: String, volume: Float) -> AVAudioPlayer? {
        guard let soundURL = Bundle.main.url(
            forResource: fileName,
            withExtension: soundFileExtension
        ) else {
            print("Kiki: \(fileName).\(soundFileExtension) not found in bundle — that sound will be silent")
            return nil
        }

        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.volume = volume
            // Neither the decode nor the output readiness is paid for on the first gesture.
            player.prepareToPlay()
            return player
        } catch {
            print("Kiki: Failed to load \(fileName).\(soundFileExtension): \(error)")
            return nil
        }
    }

    /// Plays the click sound once, from its beginning. Rewinding matters because two clicks
    /// can fall inside the same second — a reply with two `[CLICK:…]` stops — and a player
    /// still sounding ignores the second `play()`.
    func playClickSound() {
        guard let clickPlayer else { return }
        clickPlayer.currentTime = 0
        clickPlayer.play()
    }

    /// Plays the key-press sound once, from its beginning, for the click's own rewind reason: the
    /// two halves of a multi-step turn can ask for one combination shortly after another.
    func playKeyPressSound() {
        guard let keyPressPlayer else { return }
        keyPressPlayer.currentTime = 0
        keyPressPlayer.play()
    }
}
