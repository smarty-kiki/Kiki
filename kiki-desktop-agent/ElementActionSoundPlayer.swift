//
//  ElementActionSoundPlayer.swift
//  kiki-desktop-agent
//

import AVFoundation

/// Plays the sounds that accompany the gestures Kiki performs on the user's behalf. The sound belongs
/// to the *gesture*, not the raw event: a `[DOUBLECLICK:…]` is two down/up pairs 50 ms apart, so a
/// sound per event would stutter. A refused gesture is never sounded — the caller asks
/// `refusalOfClick` / `refusalOfCombination` first. A scroll and a drag have none: what moves is its
/// own feedback.
@MainActor
final class ElementActionSoundPlayer {

    private static let clickSoundFileName = "click"
    private static let keyPressSoundFileName = "type"
    private static let soundFileExtension = "mp3"

    /// How loud the click is. Deliberately low: it lands while a reply is being spoken.
    private static let clickVolume: Float = 0.25

    /// Its own number rather than the click's: the key-press recording sits about 10 dB below the
    /// click, and 0.75 brings it level.
    private static let keyPressVolume: Float = 0.75

    /// Nil when the asset is missing or could not be decoded — a sound is feedback, and its absence
    /// must not take the gesture down.
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
            // Neither the decode nor the output readiness is paid for on the first gesture, which
            // lands inside a stop's one-second dwell.
            player.prepareToPlay()
            return player
        } catch {
            print("Kiki: Failed to load \(fileName).\(soundFileExtension): \(error)")
            return nil
        }
    }

    /// Always from the beginning: two clicks can fall inside one second, and a player still sounding
    /// ignores the second `play()`.
    func playClickSound() {
        guard let clickPlayer else { return }
        clickPlayer.currentTime = 0
        clickPlayer.play()
    }

    /// The click's own rewind, for the same reason.
    func playKeyPressSound() {
        guard let keyPressPlayer else { return }
        keyPressPlayer.currentTime = 0
        keyPressPlayer.play()
    }
}
