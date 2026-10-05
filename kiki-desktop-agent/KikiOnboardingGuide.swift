//
//  KikiOnboardingGuide.swift
//  kiki-desktop-agent
//
//  The first-run guide: Kiki walks a fresh install through its setup, one permission at a time.
//

import AppKit
import AVFoundation
import Combine
import Speech

/// The segmented first-run guide: one segment per fact that can be missing, in the order the facts
/// must be granted — a script in Kiki's own voice each, saying why the grant is needed, automating
/// whatever can be (prompts, panes, the alerts' 「允许」, the relaunch) and pointing the cursor at the
/// rest: 能自动的就自动，不能自动的就引导的非常清晰.
///
/// The facts are the manager's `@Published` flags and the guide keeps no other state; the intro video
/// is the ending rather than a segment.
@MainActor
final class KikiOnboardingGuide {
    private weak var companionManager: CompanionManager?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Which segments there are, and which one is due

    private enum OnboardingGuideSegment: Hashable {
        case brain
        case seeing
        case seeingConfirmed
        case operating
        case hearing
    }

    /// Guided — and checked — in this order, so an install missing two grants gets the earlier one first.
    private static let segmentsInTheOrderTheyAreGuided: [OnboardingGuideSegment] = [
        .brain, .seeing, .seeingConfirmed, .operating, .hearing
    ]

    /// What keeps the guide from looping: a fact still missing when its script ends is left to the
    /// next launch, never nagged about.
    private var segmentsAttemptedThisLaunch: Set<OnboardingGuideSegment> = []

    /// One at a time; the next starts when this one's script ends.
    private var segmentBeingPlayed: OnboardingGuideSegment?
    private var segmentScriptTask: Task<Void, Never>?

    /// Read by the manager to hold the intro back until the guide stops speaking.
    var isPlayingASegmentScript: Bool { segmentBeingPlayed != nil }

    private var onboardingFactObservation: AnyCancellable?

    /// Called once by the manager, at the end of `start()`. Every publisher replays its current value
    /// on subscription, so the merge's first emission decides: segment 1 on a fresh install, silence
    /// on a complete one.
    func beginFollowingTheOnboardingFacts() {
        guard let companionManager, onboardingFactObservation == nil else { return }

        onboardingFactObservation = Publishers.MergeMany(
            companionManager.$hasDeepSeekAPIKey.map { _ in () },
            companionManager.$hasScreenRecordingPermission.map { _ in () },
            companionManager.$hasScreenContentPermission.map { _ in () },
            companionManager.$hasAccessibilityPermission.map { _ in () },
            companionManager.$hasMicrophonePermission.map { _ in () },
            // `hasRequiredSpeechRecognitionPermission` is computed; only the flag under it can move
            // at run time, so that is the one observed.
            companionManager.$hasSpeechRecognitionPermission.map { _ in () },
            // Not a permission fact, but segment 1's cursor needs a panel to point at: without it the
            // loop re-points at a hidden panel, and no flight is made when the panel comes back.
            companionManager.$isTheSettingsPanelVisible.map { _ in () }
        )
        // Hopped: `@Published` announces in `willSet`, so a synchronous sink reads the values from
        // before the change that woke it.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.theOnboardingFactsMoved()
        }
    }

    private func theOnboardingFactsMoved() {
        // First, so a script waiting on this very fact is woken before anything else is decided.
        releaseTheWaitForTheOnboardingFactsToMove()

        guard let companionManager, segmentBeingPlayed == nil else { return }
        guard let firstMissingSegment = Self.segmentsInTheOrderTheyAreGuided.first(where: { segment in
            isTheFactOf(segment, stillMissingIn: companionManager)
        }) else {
            // Nothing left to play, so this is where the intro goes out — from the script's own end
            // rather than the permission poll, so it lands after the last closing line. The manager
            // latches it, so asking again costs nothing.
            companionManager.playIntroDemoIfNeeded()
            return
        }
        guard !segmentsAttemptedThisLaunch.contains(firstMissingSegment) else { return }

        startPlayingTheScriptOf(firstMissingSegment)
    }

    /// The one copy of each fact test.
    private func isTheFactOf(
        _ segment: OnboardingGuideSegment,
        stillMissingIn companionManager: CompanionManager
    ) -> Bool {
        switch segment {
        case .brain:
            !companionManager.hasDeepSeekAPIKey
        case .seeing:
            !companionManager.hasScreenRecordingPermission
        case .seeingConfirmed:
            !companionManager.hasScreenContentPermission
        case .operating:
            !companionManager.hasAccessibilityPermission
        case .hearing:
            !companionManager.hasMicrophonePermission
                || !companionManager.hasRequiredSpeechRecognitionPermission
        }
    }

    private func startPlayingTheScriptOf(_ segment: OnboardingGuideSegment) {
        guard companionManager != nil else { return }
        segmentsAttemptedThisLaunch.insert(segment)
        segmentBeingPlayed = segment
        print("Onboarding guide: segment \(segment)")

        segmentScriptTask = Task { [weak self] in
            guard let self, let companionManager = self.companionManager else { return }
            await self.playTheScriptOf(segment, in: companionManager)
            self.segmentBeingPlayed = nil
            self.segmentScriptTask = nil
            print("Onboarding guide: segment \(segment) finished")
            // Re-evaluated at a script's end too: a script woken by its own fact has already consumed
            // that emission, and the segment after it would otherwise wait for a fact that is not the
            // one it asks about.
            self.theOnboardingFactsMoved()
        }
    }

    // MARK: - Waiting for the facts to move

    /// The wait a script sits on while nothing has changed, and the watchdog racing it.
    private var factMovementContinuation: CheckedContinuation<Void, Never>?
    private var factMovementWatchdogTask: Task<Void, Never>?

    /// The timeout is what lets a script re-point at its target while no fact has moved.
    private func waitForTheOnboardingFactsToMove(forAtMostSeconds seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            factMovementContinuation = continuation

            factMovementWatchdogTask?.cancel()
            factMovementWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.releaseTheWaitForTheOnboardingFactsToMove()
            }
        }
    }

    /// Taken and cleared, so it resumes exactly once — the watchdog and an arriving fact race here.
    private func releaseTheWaitForTheOnboardingFactsToMove() {
        factMovementWatchdogTask?.cancel()
        factMovementWatchdogTask = nil

        guard let continuation = factMovementContinuation else { return }
        factMovementContinuation = nil
        continuation.resume()
    }

    // MARK: - Speaking, past a turn

    /// A turn owns the voice, the cursor and the keyboard while it runs, so a guide line waits.
    /// - Returns: false at the deadline while a turn is still running; the script gives up rather than
    ///   talking over it.
    private func waitUntilNoTurnIsUnderway(forAtMostSeconds seconds: TimeInterval) async -> Bool {
        guard let companionManager else { return false }

        let momentToGiveUpWaiting = Date().addingTimeInterval(seconds)
        while companionManager.isATurnUnderwayRightNow {
            guard Date() < momentToGiveUpWaiting else { return false }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return true
    }

    private func say(_ lineToSpeak: String) async {
        guard let companionManager else { return }
        guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }
        await companionManager.speakAnOnboardingGuideLine(lineToSpeak)
    }

    private func pause(forSeconds seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - The stage

    /// What a segment points with and points into. On a fresh install it raises the overlay, which
    /// `start()` deliberately leaves down until setup is complete, and posts for the panel rather than
    /// placing it, which is the menu bar manager's job.
    private func bringUpTheCursorAndTheSettingsPanel(in companionManager: CompanionManager) {
        companionManager.showTheOverlayForTheFirstRunOnboardingGuide()
        NotificationCenter.default.post(name: .kikiShowPanel, object: nil)
    }

    // MARK: - Pointing

    private func pointAtTheSystemSettingsWindow(saying bubbleText: String, in companionManager: CompanionManager) {
        guard let settingsWindowFrame = companionManager.frameOfTheSystemSettingsWindow() else { return }
        companionManager.pointTheCursorAtAppKitScreenLocation(
            CGPoint(x: settingsWindowFrame.midX, y: settingsWindowFrame.midY),
            saying: bubbleText
        )
    }

    /// Points at the row carrying this label inside System Settings, or the middle of the window when
    /// the row cannot be found. The label is found on the picture, not estimated: only the user's hand
    /// can flip this switch, so being unmistakable about which switch is the point.
    private func pointAtTheSettingsRowLabelled(
        _ rowLabel: String,
        saying bubbleText: String,
        in companionManager: CompanionManager
    ) async {
        guard let settingsWindowFrame = companionManager.frameOfTheSystemSettingsWindow() else { return }

        if let rowLocation = await companionManager.locationStandingAloneAsLabel(
            rowLabel,
            insideOneOf: [settingsWindowFrame]
        ) {
            companionManager.pointTheCursorAtAppKitScreenLocation(rowLocation.screenLocation, saying: bubbleText)
            return
        }

        companionManager.pointTheCursorAtAppKitScreenLocation(
            CGPoint(x: settingsWindowFrame.midX, y: settingsWindowFrame.midY),
            saying: bubbleText
        )
    }

    /// Where each alert's own button stands, as a nudge in points from the low-in-the-alert anchor:
    /// the consent alert keeps its two buttons side by side, so 「打开系统设置」 stands right of
    /// center, and the quit prompt's single button stands higher than the anchor. Measured on screen;
    /// a name not listed here keeps the anchor itself.
    private static let pointingOffsetsFromTheAlertAnchorByButtonName: [String: CGSize] = [
        CompanionManager.SystemAlertHost.universalAccessAuthWarn.buttonNameItAsksFor: CGSize(width: 70, height: 0),
        CompanionManager.SystemAlertHost.systemSettings.buttonNameItAsksFor: CGSize(width: 0, height: 20)
    ]

    /// Low in the alert, where its buttons stand — on the button itself where its name is one the
    /// offsets above were measured for.
    private func pointAtTheSystemAlertWindow(
        _ systemAlertWindow: CompanionManager.SystemAlertWindow,
        naming buttonName: String,
        saying bubbleText: String,
        in companionManager: CompanionManager
    ) {
        let pointingOffset = Self.pointingOffsetsFromTheAlertAnchorByButtonName[buttonName] ?? .zero
        companionManager.pointTheCursorAtAppKitScreenLocation(
            CGPoint(
                x: systemAlertWindow.frame.midX + pointingOffset.width,
                y: systemAlertWindow.frame.minY + systemAlertWindow.frame.height * 0.18 + pointingOffset.height
            ),
            saying: bubbleText
        )
    }

    /// The frontmost system alert that appeared since a snapshot — the system's own reply to whatever
    /// was asked in between, since one already standing at the snapshot belongs to something asked
    /// earlier. A third-party panel that merely looks like a dialog matches no host and is never named.
    private func systemAlertWindowThatAppearedSince(
        _ systemAlertWindowsBefore: [CompanionManager.SystemAlertWindow],
        in companionManager: CompanionManager
    ) -> CompanionManager.SystemAlertWindow? {
        companionManager.systemAlertWindowsInFrontToBackOrder().first { systemAlertWindow in
            !systemAlertWindowsBefore.contains { systemAlertWindowBefore in
                systemAlertWindowBefore.frame == systemAlertWindow.frame
            }
        }
    }

    // MARK: - The five scripts

    private func playTheScriptOf(_ segment: OnboardingGuideSegment, in companionManager: CompanionManager) async {
        switch segment {
        case .brain:
            await playTheBrainSegment(in: companionManager)
        case .seeing:
            await playTheSeeingSegment(in: companionManager)
        case .seeingConfirmed:
            await playTheSeeingConfirmedSegment(in: companionManager)
        case .operating:
            await playTheOperatingSegment(in: companionManager)
        case .hearing:
            await playTheHearingSegment(in: companionManager)
        }
    }

    /// Segment 1 — the DeepSeek key, the one grant only a paste can give: a line, the cursor on the
    /// key field, and a wait; nothing to open and nothing to press.
    private func playTheBrainSegment(in companionManager: CompanionManager) async {
        bringUpTheCursorAndTheSettingsPanel(in: companionManager)

        await say("hi 我是 Kiki，很高兴见到你，在我工作前，我得先长个脑子——把 DeepSeek 的 Key 贴在这儿就行。")

        // Re-pointed every beat: the panel is still laying out at the first flight, and a faded bubble
        // should come back rather than leave the user hunting.
        while !companionManager.hasDeepSeekAPIKey {
            guard !Task.isCancelled else { return }
            guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }

            await companionManager.pointTheCursorAtSettingsPanelAnchor(
                .deepSeekAPIKeyField,
                saying: "把 Key 贴在这里",
                waitingUpToSeconds: 5
            )
            await waitForTheOnboardingFactsToMove(forAtMostSeconds: 30)
        }

        await say("有脑子了。")
    }

    /// Segment 2 — Screen Recording. The alert and the pane open themselves; the switch inside System
    /// Settings is the user's hand. No capture is possible yet, so everything is pointed at by frame,
    /// never by text read off the screen. Every alert is named by its host, except the two System
    /// Settings owns — the fingerprint check and the quit-and-reopen prompt — told apart by size below.
    private func playTheSeeingSegment(in companionManager: CompanionManager) async {
        bringUpTheCursorAndTheSettingsPanel(in: companionManager)
        await say("我还什么都看不见呢——我来把「屏幕录制」找出来。")

        let systemAlertWindowsBeforeAsking = companionManager.systemAlertWindowsInFrontToBackOrder()
        WindowPositionManager.requestScreenRecordingPermission()
        // The alert animates in behind the request; without this the first beat can look before it stands.
        await pause(forSeconds: 1.5)

        var numberOfTimesThePaneWasReopened = 0

        // The fingerprint check stands at one size every time, and the first Settings-owned sheet's
        // size is remembered to tell it from the quit-and-reopen prompt. A sheet of that size is the
        // check again — which is what a retry after a cancelled attempt arrives as.
        var fingerprintCheckSheetSize: CGSize?

        while !companionManager.hasScreenRecordingPermission {
            guard !Task.isCancelled else { return }
            guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }

            let isTheSettingsWindowUp = companionManager.frameOfTheSystemSettingsWindow() != nil

            if let alertWindow = systemAlertWindowThatAppearedSince(systemAlertWindowsBeforeAsking, in: companionManager) {
                let isTheFingerprintChecksSheet = alertWindow.host == .systemSettings
                    && (fingerprintCheckSheetSize == nil || fingerprintCheckSheetSize == alertWindow.frame.size)
                if isTheFingerprintChecksSheet {
                    fingerprintCheckSheetSize = alertWindow.frame.size
                }
                let buttonToName = isTheFingerprintChecksSheet
                    ? CompanionManager.SystemAlertHost.fingerprintCheckButtonName
                    : alertWindow.host.buttonNameItAsksFor
                print("Onboarding guide: alert standing from \(alertWindow.host), naming 「\(buttonToName)」")
                pointAtTheSystemAlertWindow(
                    alertWindow,
                    naming: buttonToName,
                    saying: "点「\(buttonToName)」",
                    in: companionManager
                )
            } else if isTheSettingsWindowUp {
                pointAtTheSystemSettingsWindow(saying: "在「屏幕录制」里把 Kiki 打开", in: companionManager)
            } else if numberOfTimesThePaneWasReopened < 2 {
                numberOfTimesThePaneWasReopened += 1
                WindowPositionManager.requestScreenRecordingPermission()
            } else {
                // Neither the alert nor the pane came up: point at the panel's own row, which
                // carries the button that opens the pane.
                await companionManager.pointTheCursorAtSettingsPanelAnchor(
                    .screenRecordingPermissionRow,
                    saying: "点「授权」打开系统设置",
                    waitingUpToSeconds: 5
                )
            }

            await waitForTheOnboardingFactsToMove(forAtMostSeconds: 18)
        }

        await say("看得见了。我重启一下自己，马上回来。")
        restartKikiItself()
    }

    /// Segment 3 — 屏幕内容, the grant ScreenCaptureKit asks for itself: macOS offers it only once a
    /// real capture has been attempted, so the 试拍 is the ask.
    private func playTheSeeingConfirmedSegment(in companionManager: CompanionManager) async {
        bringUpTheCursorAndTheSettingsPanel(in: companionManager)
        await say("我回来了。再让我确认一下「屏幕内容」，然后就能看见你的屏幕了。")

        var systemAlertWindowsBeforeTheRequest = companionManager.systemAlertWindowsInFrontToBackOrder()
        var numberOfTestCapturesLeft = 3

        while !companionManager.hasScreenContentPermission {
            guard !Task.isCancelled else { return }
            guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }

            if let alertWindow = systemAlertWindowThatAppearedSince(systemAlertWindowsBeforeTheRequest, in: companionManager) {
                // Still standing: keep the cursor on it rather than asking again over it.
                let buttonToName = alertWindow.host.buttonNameItAsksFor
                pointAtTheSystemAlertWindow(
                    alertWindow,
                    naming: buttonToName,
                    saying: "点一下「\(buttonToName)」就行",
                    in: companionManager
                )
            } else if numberOfTestCapturesLeft > 0 {
                numberOfTestCapturesLeft -= 1
                systemAlertWindowsBeforeTheRequest = companionManager.systemAlertWindowsInFrontToBackOrder()
                companionManager.requestScreenContentPermission()
                // The alert takes a moment to stand up; the next beat is what looks for it.
                await pause(forSeconds: 1.5)
            } else {
                // The system has stopped offering its alert — the way back is the panel's own row.
                await companionManager.pointTheCursorAtSettingsPanelAnchor(
                    .screenContentPermissionRow,
                    saying: "点「授权」再试一次",
                    waitingUpToSeconds: 5
                )
            }

            await waitForTheOnboardingFactsToMove(forAtMostSeconds: 20)
        }

        await say("这下真能看见了！不过我现在还没法帮你操作。")
    }

    /// Segment 4 — Accessibility. The prompt and the pane open themselves; the row inside System
    /// Settings is the user's hand. The grant is live, so nothing restarts.
    private func playTheOperatingSegment(in companionManager: CompanionManager) async {
        bringUpTheCursorAndTheSettingsPanel(in: companionManager)
        await say("我来把「辅助功能」打开——开了它，我才能替你动手。")

        let systemAlertWindowsBeforeAsking = companionManager.systemAlertWindowsInFrontToBackOrder()
        WindowPositionManager.requestAccessibilityPermission()
        // The alert animates in behind the request; without this the first beat can name the wrong row.
        await pause(forSeconds: 1.5)

        var numberOfTimesThePaneWasReopened = 0

        while !companionManager.hasAccessibilityPermission {
            guard !Task.isCancelled else { return }
            guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }

            let isTheSettingsWindowUp = companionManager.frameOfTheSystemSettingsWindow() != nil

            // Anything that appeared is one of the system's own alerts — the walk keeps nothing
            // else — and is named first whatever else is standing: the leftover settings pane is
            // not in that list.
            if let alertWindow = systemAlertWindowThatAppearedSince(systemAlertWindowsBeforeAsking, in: companionManager) {
                // A Settings-owned sheet on this road is the fingerprint check: 辅助功能 takes
                // effect the moment it is granted, so no quit-and-reopen prompt follows it.
                let buttonToName = alertWindow.host == .systemSettings
                    ? CompanionManager.SystemAlertHost.fingerprintCheckButtonName
                    : alertWindow.host.buttonNameItAsksFor
                print("Onboarding guide: alert standing from \(alertWindow.host), naming 「\(buttonToName)」")
                pointAtTheSystemAlertWindow(
                    alertWindow,
                    naming: buttonToName,
                    saying: "点「\(buttonToName)」",
                    in: companionManager
                )
            } else if isTheSettingsWindowUp {
                await pointAtTheSettingsRowLabelled("Kiki", saying: "把 Kiki 打开", in: companionManager)
            } else if numberOfTimesThePaneWasReopened < 2 {
                numberOfTimesThePaneWasReopened += 1
                WindowPositionManager.requestAccessibilityPermission()
            }

            await waitForTheOnboardingFactsToMove(forAtMostSeconds: 18)
        }

        closeTheSystemSettingsWindowIfItIsStillUp()

        await say("现在我可以帮你操作电脑了。")
    }

    /// Segment 5 — the microphone and speech recognition, the two grants Kiki can press the alerts for
    /// itself: Accessibility is in place by now, so the user does nothing. A grant already refused has
    /// no alert left to press — macOS asks once — so that falls back to the pane and the row.
    private func playTheHearingSegment(in companionManager: CompanionManager) async {
        bringUpTheCursorAndTheSettingsPanel(in: companionManager)
        await say("还差最后一步——我还听不见你说话呢。弹出来的框我来点，你看着就行。")

        await getTheMicrophoneGrant(in: companionManager)
        await getTheSpeechRecognitionGrant(in: companionManager)

        if companionManager.hasMicrophonePermission && companionManager.hasRequiredSpeechRecognitionPermission {
            closeTheSystemSettingsWindowIfItIsStillUp()
            await say("好了，我能听见你了。")
        }
    }

    /// Presses 「允许」 on the alert Kiki can press itself, or points at the pane's row when there is
    /// no alert left to press.
    private func getTheMicrophoneGrant(in companionManager: CompanionManager) async {
        guard !companionManager.hasMicrophonePermission else { return }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await takeTheGrantBehindASystemAlert(
                showingThePromptWith: { companionManager.promptForMicrophoneIfNotDetermined() },
                until: { companionManager.hasMicrophonePermission },
                in: companionManager
            )
            return
        }

        WindowPositionManager.openMicrophoneSettings()
        await guideTheUserToTheSettingsRow(
            labelled: "Kiki",
            saying: "把 Kiki 打开",
            reopeningTheSettingsWith: { WindowPositionManager.openMicrophoneSettings() },
            until: { companionManager.hasMicrophonePermission },
            in: companionManager
        )
    }

    /// The same two ways the microphone is asked for.
    private func getTheSpeechRecognitionGrant(in companionManager: CompanionManager) async {
        guard !companionManager.hasRequiredSpeechRecognitionPermission else { return }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await takeTheGrantBehindASystemAlert(
                showingThePromptWith: { companionManager.requestSpeechRecognitionPermission() },
                until: { companionManager.hasRequiredSpeechRecognitionPermission },
                in: companionManager
            )
            return
        }

        // Not determined no longer: the request opens the pane itself.
        companionManager.requestSpeechRecognitionPermission()
        await guideTheUserToTheSettingsRow(
            labelled: "Kiki",
            saying: "把 Kiki 打开",
            reopeningTheSettingsWith: { companionManager.requestSpeechRecognitionPermission() },
            until: { companionManager.hasRequiredSpeechRecognitionPermission },
            in: companionManager
        )
    }

    /// Shows a system permission alert, presses its 「允许」 for the user, and keeps at it until the fact
    /// lands — the shape both of segment 5's grants are taken with. Each beat presses when it can and
    /// points when it cannot: Automatic Clicking off, no Accessibility, nothing standing alone as 「允许」.
    private func takeTheGrantBehindASystemAlert(
        showingThePromptWith showThePrompt: () -> Void,
        until factIsGranted: () -> Bool,
        in companionManager: CompanionManager
    ) async {
        let systemAlertWindowsBeforeAsking = companionManager.systemAlertWindowsInFrontToBackOrder()
        showThePrompt()
        // The alert animates in over the better part of a second; the beat waits so the press can aim.
        await pause(forSeconds: 1.5)

        while !factIsGranted() {
            guard !Task.isCancelled else { return }
            guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }

            if let alertWindow = systemAlertWindowThatAppearedSince(systemAlertWindowsBeforeAsking, in: companionManager) {
                // The matcher behind the press cannot find 「允许」 inside 「不允许」, so a press
                // either lands on the right button or does not happen.
                let wasThePressSentOnItsWay = await companionManager.pressTheSystemAlertButtonLabelled("允许")
                // A refusal while an action is still in the air is not a reason to point: that action
                // is the press this beat sent a moment ago, still flying, and a bubble saying
                // 「点一下「允许」就行」 over a button Kiki is already pressing says the opposite of what is
                // happening. The next beat re-asks, by which time it has landed or failed.
                if !wasThePressSentOnItsWay, !companionManager.isAnActionBeingWaitedOn {
                    print("Onboarding guide: pointing at the alert instead of pressing 「允许」")
                    let buttonToName = alertWindow.host.buttonNameItAsksFor
                    pointAtTheSystemAlertWindow(
                        alertWindow,
                        naming: buttonToName,
                        saying: "点一下「\(buttonToName)」就行",
                        in: companionManager
                    )
                }
            }

            await waitForTheOnboardingFactsToMove(forAtMostSeconds: 15)
        }
    }

    /// The road for a grant macOS will not ask about again: point at the row until the fact lands.
    private func guideTheUserToTheSettingsRow(
        labelled rowLabel: String,
        saying bubbleText: String,
        reopeningTheSettingsWith reopenTheSettings: () -> Void,
        until factIsGranted: () -> Bool,
        in companionManager: CompanionManager
    ) async {
        var numberOfTimesThePaneWasReopened = 0

        while !factIsGranted() {
            guard !Task.isCancelled else { return }
            guard await waitUntilNoTurnIsUnderway(forAtMostSeconds: 90) else { return }

            if companionManager.frameOfTheSystemSettingsWindow() != nil {
                await pointAtTheSettingsRowLabelled(rowLabel, saying: bubbleText, in: companionManager)
            } else if numberOfTimesThePaneWasReopened < 3 {
                numberOfTimesThePaneWasReopened += 1
                reopenTheSettings()
            }

            await waitForTheOnboardingFactsToMove(forAtMostSeconds: 18)
        }
    }

    // MARK: - Closing System Settings

    /// Quits System Settings once the grant it was opened for has landed, so the pane does not stand
    /// over the segments that follow, the intro at the end of the guide included.
    /// `terminate()`, never Apple Events: an Apple Event would take an Automation grant, and its
    /// prompt would appear in the middle of the guide, to close a window.
    private func closeTheSystemSettingsWindowIfItIsStillUp() {
        for systemSettingsApplication in NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ) {
            systemSettingsApplication.terminate()
        }
    }

    // MARK: - Restarting Kiki itself

    /// Quits Kiki and opens it again, for the one grant that only takes effect in a new process. The
    /// detached shell waits for this process to be gone before running `/usr/bin/open` — `open` on a
    /// still-running app only brings it forward. Never the binary itself, which would hand TCC's
    /// attribution to whatever started it, and never `-n`, which would raise a second Kiki.
    private func restartKikiItself() {
        print("Onboarding guide: restarting Kiki for the Screen Recording grant")
        let bundlePath = Bundle.main.bundlePath
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let relaunchingShellCommand = "while kill -0 \(processIdentifier) 2>/dev/null; do sleep 0.2; done; "
            + "/usr/bin/open \(Self.shellSingleQuoted(bundlePath))"

        let relaunchingProcess = Process()
        relaunchingProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunchingProcess.arguments = ["-c", relaunchingShellCommand]
        try? relaunchingProcess.run()

        NSApp.terminate(nil)
    }

    /// The text as one `/bin/sh` word, single-quoted — a single quote inside it closed, escaped and
    /// reopened, the one thing a single-quoted run cannot hold.
    private static func shellSingleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
