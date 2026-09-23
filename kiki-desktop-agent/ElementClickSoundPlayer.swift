//
//  ElementClickSoundPlayer.swift
//  kiki-desktop-agent
//
//  The short sound that goes out with a click Kiki posts on the user's behalf.

import AVFoundation

/// Plays the sound that accompanies a click Kiki posts on the user's behalf.
///
/// The sound belongs to the *gesture*, not the mouse event: a `[DOUBLECLICK:…]` is two
/// down/up pairs 50 ms apart, so a sound per event would be a stutter. It is never played for
/// a refused click — see `refusalOfClick`, which the caller asks first — and the audio is
/// decoded and readied in `init` because a click lands inside the stop's one-second dwell.
@MainActor
final class ElementClickSoundPlayer {

    private static let clickSoundFileName = "click"
    private static let clickSoundFileExtension = "mp3"

    /// How loud the click is. Deliberately low: it lands while a reply is being spoken, so it
    /// is the quietest thing the app plays and can never be heard over the voice.
    private static let clickVolume: Float = 0.25

    /// Nil when the asset is missing from the bundle or could not be decoded, in which case
    /// clicks are silent — a sound is feedback, and its absence must not take the click down.
    private let clickPlayer: AVAudioPlayer?

    init() {
        guard let clickSoundURL = Bundle.main.url(
            forResource: Self.clickSoundFileName,
            withExtension: Self.clickSoundFileExtension
        ) else {
            print("⚠️ Kiki: \(Self.clickSoundFileName).\(Self.clickSoundFileExtension) not found in bundle — clicks will be silent")
            clickPlayer = nil
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: clickSoundURL)
            player.volume = Self.clickVolume
            // Neither the decode nor the output readiness is paid for on the first click.
            player.prepareToPlay()
            clickPlayer = player
        } catch {
            print("⚠️ Kiki: Failed to load the click sound: \(error)")
            clickPlayer = nil
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
}
