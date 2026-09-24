//
//  CompanionPanelView.swift
//  kiki-desktop-agent
//
//  The SwiftUI content hosted inside the menu bar panel: voice status,
//  push-to-talk shortcut, and quick settings.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var deepSeekAPIKeyInput: String = ""
    @State private var isReplacingDeepSeekAPIKey: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            if isSetUp {
                taskProgressSection
                    .padding(.top, 14)

                Spacer()
                    .frame(height: 6)

                howToUseKikiSection
                    .padding(.top, 16)

                Spacer()
                    .frame(height: 14)

                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                automaticClickingToggleRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 14)

                savedDeepSeekAPIKeySection
                    .padding(.horizontal, 16)
            } else {
                settingsCopySection
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                // A row goes away as its own step is finished, so the setup half shows exactly what
                // is still missing and nothing that is already done.
                if !companionManager.allPermissionsGranted {
                    Spacer()
                        .frame(height: 16)

                    settingsSection
                        .padding(.horizontal, 16)
                }

                Spacer()
                    .frame(height: 14)

                deepSeekAPIKeySection
                    .padding(.horizontal, 16)
            }

            // Show Kiki toggle — hidden for now
            // if isSetUp {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showKikiCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    /// Whether Kiki has been set up at all: a key saved and every permission in place.
    ///
    /// The panel is split on this one question rather than on each half's own state, so the setup
    /// half and the everyday half can never both claim a row — which is what the key field did when
    /// it was shown unconditionally beside the shortcut copy. It reads `hasCompletedOnboarding`
    /// rather than the Keychain so that a key deleted outside the app does not put a fresh install's
    /// panel back.
    private var isSetUp: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Kiki")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .kikiDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Task Progress

    /// What the task in progress has taken, where it stands, and how close its context is to being
    /// compressed into a summary.
    ///
    /// Read off `taskProgress` rather than worked out here: the estimate walks every character of
    /// the conversation, and this body re-evaluates on every chunk of the reply.
    ///
    /// Absent until there is a task: a panel that says "no task yet" every time it is opened is
    /// describing nothing, and the row would be there for the whole life of the app without ever
    /// having anything to say.
    @ViewBuilder
    private var taskProgressSection: some View {
        if companionManager.taskProgress.hasATask {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("任务")

                taskStatusCard
            }
            .padding(.horizontal, 16)
        }
    }

    /// The card itself: where the task stands on one line, and how full Kiki's head is on the next.
    ///
    /// Tinted and outlined in the accent rather than filled with `surface1` like the cards below it,
    /// because those three describe ways of talking to Kiki that are always available while this one
    /// is the task happening now — and it is the blue thing on a panel of grey ones.
    private var taskStatusCard: some View {
        let progress = companionManager.taskProgress

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(progress.isRunning ? DS.Colors.blue400 : DS.Colors.textTertiary)
                    .frame(width: 6, height: 6)

                Text(taskStateDescription(of: progress))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text("第 \(progress.roundCount) 件事 · 走了 \(progress.stepCount) 步")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize()
            }

            HStack(spacing: 8) {
                contextUseBar(fractionUsed: progress.fractionOfTheRoomBeforeCompressionUsed)

                Text(memoryUseDescription(of: progress))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.accentSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.blue500.opacity(0.35), lineWidth: 0.5)
        )
    }

    /// Whether Kiki is still working on the task, and which step of it it is on.
    private func taskStateDescription(of progress: TaskProgress) -> String {
        guard progress.isRunning else {
            // Deliberately 忙完了 rather than a countdown to the idle reset: the task is over as far
            // as the user is concerned, and the history being kept is what the next question will
            // continue from rather than something still in progress.
            return "忙完了"
        }
        return "正在忙 · 第 \(progress.stepInTheRoundInProgress) 步"
    }

    /// How full Kiki's head is, said the way a person would say it rather than the way the
    /// compression is implemented.
    ///
    /// The threshold that makes it "getting full" is the same one the bar changes colour at, so the
    /// sentence and the bar agree about when that is instead of being two opinions of it.
    private func memoryUseDescription(of progress: TaskProgress) -> String {
        let percentUsed = Int(progress.fractionOfTheRoomBeforeCompressionUsed * 100)

        if progress.fractionOfTheRoomBeforeCompressionUsed >= 0.8 {
            return "脑子快满了 · 只剩 \(100 - percentUsed)%"
        }
        return "脑子用了 \(percentUsed)% · 还有 \(100 - percentUsed)% 才满"
    }

    /// How much of the room there is before the compression, drawn as a bar.
    ///
    /// Measured against the trigger rather than against the model's whole window, so a full bar and
    /// the compression starting are the same moment.
    private func contextUseBar(fractionUsed: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.surface3)

                Capsule()
                    .fill(fractionUsed >= 0.8 ? DS.Colors.warning : DS.Colors.accentText)
                    .frame(width: geometry.size.width * fractionUsed)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Setup Copy

    /// What the panel says while Kiki cannot be used yet. The three ways to use it are not described
    /// here — those are `howToUseKikiSection`, which waits until there is something to use.
    @ViewBuilder
    private var settingsCopySection: some View {
        if companionManager.allPermissionsGranted {
            // All permissions granted but setup unfinished leaves one cause: no key saved.
            Text("粘贴下面的 DeepSeek API Key 就可以开始了")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("需要授权")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("部分权限已被撤销，请在下方重新授予全部四项以继续使用 Kiki。")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("嗨，我是 Kiki。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("一个我做着玩的小项目，帮我在用电脑的时候顺便学点东西。")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Kiki 不会在后台常驻，只在你按下快捷键的那一刻截一次屏，所以这个权限可以放心给。要是你还是不放心……那我也没办法了。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - How To Use Kiki

    /// The three ways into Kiki, one card each.
    ///
    /// They are cards rather than three lines because they do not read alike: two are keyboard
    /// shortcuts that differ only in which modifiers and whether the key is held, and the third is
    /// not a key at all. Written as a paragraph — which is what this was — the one shortcut that
    /// needs a key held and the one that needs it tapped blur together, and the terminal is not
    /// mentioned anywhere.
    private var howToUseKikiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("怎么用 Kiki")

            askingKikiCard
            followingTheUserCard
            commandLineCard
        }
        .padding(.horizontal, 16)
    }

    /// The everyday way in: hold both keys, speak, let go.
    private var askingKikiCard: some View {
        usageModeCard(
            iconName: "mic",
            title: "给 Kiki 提要求",
            description: "松开就发出去，Kiki 看着屏幕回答，并指给你看"
        ) {
            HStack(spacing: 4) {
                shortcutKeyCap(symbol: "⌃", keyName: "control")
                shortcutKeySeparator
                shortcutKeyCap(symbol: "⌥", keyName: "option")

                Text("按住说话")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 2)
            }
        }
    }

    /// The other way in: Kiki watches the user do something once, then does it again on a loop.
    private var followingTheUserCard: some View {
        usageModeCard(
            iconName: "record.circle",
            title: "Kiki 跟着做",
            description: "按一下开始记录你的操作，再按一下循环重放，再按一下停下来"
        ) {
            HStack(spacing: 4) {
                shortcutKeyCap(symbol: "⇧", keyName: "shift")
                shortcutKeySeparator
                shortcutKeyCap(symbol: "⌥", keyName: "option")

                Text("按一下")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 2)
            }
        }
    }

    /// The way in that is not a key: a typed request that runs the same pipeline.
    private var commandLineCard: some View {
        usageModeCard(
            iconName: "terminal",
            title: "命令行",
            description: "打字提要求，回复流回终端；默认不出声，加了 --speak 才念出来"
        ) {
            Text("kiki command '…'")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.codeText)
        }
    }

    /// One card. The shortcut row is a closure because the third card has a command line where the
    /// other two have keycaps — the shape is shared, what names the trigger is not.
    private func usageModeCard(
        iconName: String,
        title: String,
        description: String,
        @ViewBuilder trigger: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            // Aligned under the title rather than under the icon, so the shortcut and the sentence
            // describing it read as one block.
            trigger()
                .padding(.leading, 24)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// A key drawn the way a keyboard draws it: the modifier's own glyph, then its name.
    private func shortcutKeyCap(symbol: String, keyName: String) -> some View {
        HStack(spacing: 3) {
            Text(symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text(keyName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var shortcutKeySeparator: some View {
        Text("+")
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            sectionHeader("权限")
                .padding(.bottom, 4)

            microphonePermissionRow

            // Only for the on-device transcription backend: the network providers never
            // touch the Speech Recognition TCC service, so this row would be un-grantable.
            if companionManager.buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission {
                speechRecognitionPermissionRow
            }

            accessibilityPermissionRow

            screenRecordingPermissionRow

            screenContentPermissionRow

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("辅助功能")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // System prompt on the first attempt, System Settings after that.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("授权")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Revealed in Finder so the user can drag the app into the
                        // Accessibility list when it does not appear there on its own.
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("在访达中显示")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("屏幕录制")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "只在你按快捷键时截屏"
                         : "授权后请退出并重新打开")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Native prompt on the first attempt, which also adds the app to the
                    // list; System Settings after that.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("授权")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    /// The second stage of the screen permission chain, shown before the first stage is
    /// granted. 「屏幕内容」 is a separate TCC grant that macOS only offers once
    /// ScreenCaptureKit has taken a real screenshot, so it cannot be requested until
    /// Screen Recording is in place. Greyed out rather than hidden, so the panel doesn't
    /// grow a row out of nowhere after the first grant.
    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        let canRequestPermission = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted || !canRequestPermission ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("屏幕内容")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(canRequestPermission ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("授权")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(canRequestPermission ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: canRequestPermission)
                .disabled(!canRequestPermission)
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("麦克风")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Native dialog on the first attempt; System Settings once denied.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("授权")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var speechRecognitionPermissionRow: some View {
        let isGranted = companionManager.hasSpeechRecognitionPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("语音识别")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestSpeechRecognitionPermission()
                }) {
                    Text("授权")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("授权")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Kiki Cursor Toggle

    private var showKikiCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("显示 Kiki")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isKikiCursorEnabled },
                set: { companionManager.setKikiCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Automatic Clicking Toggle

    /// The switch for the one thing Kiki does to the machine rather than on it.
    ///
    /// It covers both halves — pressing and scrolling — because in the user's mind it answers one
    /// question, "may Kiki move things on my screen with the mouse", and a switch that stopped at
    /// pressing would let the screen keep moving after it was turned off.
    ///
    /// Off, a `[CLICK:…]` means what it meant before pressing existed: the cursor still
    /// flies to the element and the bubble still says 「点这里」. A refused press
    /// degrades to the same thing.
    private var automaticClickingToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("允许 Kiki 用鼠标操作")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isAutomaticClickingEnabled },
                set: { companionManager.setAutomaticClickingEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("语音转文字")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - DeepSeek API Key

    /// The key while it is still missing: the field, and nothing to collapse.
    private var deepSeekAPIKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            deepSeekAPIKeyTitleRow

            deepSeekAPIKeyField
        }
    }

    /// The key once it is saved: a line saying so, and a way back to the field.
    ///
    /// The field is put away because a saved key never needs re-typing, but it has to stay
    /// reachable — this row is the only place in the app that can put a different key in the
    /// Keychain, so collapsing it without the 更换 button would make a key unchangeable.
    private var savedDeepSeekAPIKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("DeepSeek API 密钥")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text("已保存")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)

                Button(action: {
                    isReplacingDeepSeekAPIKey.toggle()
                }) {
                    Text(isReplacingDeepSeekAPIKey ? "取消" : "更换")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if isReplacingDeepSeekAPIKey {
                deepSeekAPIKeyField
            }
        }
    }

    private var deepSeekAPIKeyTitleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)

            Text("DeepSeek API 密钥")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Text(companionManager.hasDeepSeekAPIKey ? "已保存" : "未设置")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(companionManager.hasDeepSeekAPIKey ? DS.Colors.success : DS.Colors.warning)
        }
    }

    private var deepSeekAPIKeyField: some View {
        HStack(spacing: 6) {
                // A SecureField so a key pasted with someone looking over your shoulder
                // isn't readable off the screen. The field stays empty even when a key is
                // saved — the 「已保存」 label above is the confirmation, and an empty
                // field can't silently re-write what was stored before. The placeholder
                // differs for the same reason.
                SecureField(
                    companionManager.hasDeepSeekAPIKey ? "*******************" : "sk-...",
                    text: $deepSeekAPIKeyInput
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .onSubmit(saveDeepSeekAPIKeyFromInput)

                Button(action: saveDeepSeekAPIKeyFromInput) {
                    Text("保存")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(canSaveDeepSeekAPIKey ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: canSaveDeepSeekAPIKey)
                .disabled(!canSaveDeepSeekAPIKey)
        }
    }

    /// Whether the key field holds anything worth saving. Whitespace-only input counts
    /// as empty, so a stray space can't overwrite a working key.
    private var canSaveDeepSeekAPIKey: Bool {
        !deepSeekAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stores the pasted key in the Keychain and empties the field, so the secret
    /// doesn't sit in a text field for the rest of the session.
    private func saveDeepSeekAPIKeyFromInput() {
        guard canSaveDeepSeekAPIKey else { return }
        companionManager.saveDeepSeekAPIKey(deepSeekAPIKeyInput)
        deepSeekAPIKeyInput = ""
        // Saving a replacement puts the field back away, so the panel returns to the line that
        // says the key is saved rather than keeping the empty field on screen.
        isReplacingDeepSeekAPIKey = false
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("模型")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                // Both accept image input, which every request carries: DeepSeek's
                // text-only models reject the screenshots outright.
                modelOptionButton(label: "Flash", modelID: DeepSeekAPI.defaultModel)
                modelOptionButton(label: "V4 Pro", modelID: "deepseek-v4-pro")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("退出 Kiki")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("重新观看引导")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if companionManager.isRestingInTheStatusItemIcon {
            return DS.Colors.textTertiary
        }
        // Blue like the other working states: waking is something Kiki is doing, where resting is
        // something it is not.
        if companionManager.isWakingFromTheStatusItemIcon {
            return DS.Colors.blue400
        }
        // The red of the record dot itself while the user is working, so the panel and the cursor
        // are recognizably the same state; blue while Kiki is the one doing the work.
        if companionManager.recordedActionsPhase == .recordingWhatTheUserIsDoing {
            return DS.Colors.overlayCursorClickRed
        }
        if companionManager.recordedActionsPhase == .replayingWhatTheUserDid {
            return DS.Colors.blue400
        }
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "设置中"
        }
        // Ahead of the overlay check, which would otherwise call a resting Kiki "就绪" — the cursor
        // is hidden because it is in the icon, not because Kiki is not running.
        if companionManager.isRestingInTheStatusItemIcon {
            return "休息中"
        }
        if companionManager.isWakingFromTheStatusItemIcon {
            return "苏醒中"
        }
        // Ahead of the overlay check for the same reason resting is: a recording runs whether or not
        // the cursor has been turned off, and 就绪 over a recording would be the one wrong answer.
        switch companionManager.recordedActionsPhase {
        case .recordingWhatTheUserIsDoing:
            return "记录中"
        case .replayingWhatTheUserDid:
            return "重放中"
        case .neitherRecordingNorReplaying:
            break
        }
        if !companionManager.isOverlayVisible {
            return "就绪"
        }
        switch companionManager.voiceState {
        case .idle:
            return "等待中"
        case .listening:
            return "聆听中"
        case .processing:
            return "处理中"
        case .responding:
            return "回复中"
        }
    }

}
