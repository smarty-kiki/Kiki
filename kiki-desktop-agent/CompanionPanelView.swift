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
                    .frame(height: 4)

                automaticClickingToggleRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 4)

                automaticKeyboardToggleRow
                    .padding(.horizontal, 16)

                // 10 rather than the 4 the rows above use: those carry 4pt of padding of their own and
                // a taller switch.
                Spacer()
                    .frame(height: 10)

                savedDeepSeekAPIKeySection
                    .padding(.horizontal, 16)
            } else if !companionManager.hasCompletedOnboarding {
                // Setup, stage one: the key alone. The permission rows are stage two, and arrive
                // only once this step is done — the same path the guide walks.
                settingsCopySection
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 14)

                deepSeekAPIKeySection
                    .padding(.horizontal, 16)
            } else {
                // Setup, stage two: the grants, all at once — the guide is what takes them one by one.
                settingsCopySection
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 16)

                settingsSection
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

    /// One question for the whole panel, not one per half, so the setup half and the everyday half can
    /// never both claim a row. Read from `hasCompletedOnboarding` rather than the Keychain, so a key
    /// deleted outside the app does not put a fresh install's panel back.
    private var isSetUp: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
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
                            .fill(Color.black.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Task Progress

    /// Read off `taskProgress` rather than worked out here: the estimate walks every character of the
    /// conversation, and this body re-evaluates on every chunk of the reply. Absent until there is a task.
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

    /// Tinted in the accent rather than `surface1` like the cards below, because this one is the task
    /// happening now.
    private var taskStatusCard: some View {
        let progress = companionManager.taskProgress

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(progress.isRunning ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 6, height: 6)

                // The clock is read here, not on the manager: what moves every second is the distance
                // to a moment, not the moment itself, and only this line draws it.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(taskStateDescription(of: progress, at: context.date))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

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
                .stroke(DS.Colors.purple500.opacity(0.35), lineWidth: 0.5)
        )
    }

    /// The countdown shows only while nothing is running: a task in progress is activity, and every step
    /// of it pushes the moment back.
    private func taskStateDescription(of progress: TaskProgress, at now: Date) -> String {
        guard progress.isRunning else {
            return "忙完了" + conversationRemainingDescription(of: progress, at: now)
        }
        return "正在忙 · 第 \(progress.stepInTheRoundInProgress) 步"
    }

    /// Nothing is dropped when the countdown runs out — the history goes when the next question finds
    /// it too old — so this says when the reset comes, not that it has happened.
    private func conversationRemainingDescription(of progress: TaskProgress, at now: Date) -> String {
        guard let secondsLeft = progress.secondsBeforeTheNextQuestionStartsANewConversation(from: now) else {
            return ""
        }
        guard secondsLeft > 0 else {
            return " · 再问就重置"
        }

        if secondsLeft >= 60 {
            // Rounded up: most of a minute reads as that minute, not as the one below it.
            return " · \(Int(ceil(secondsLeft / 60))) 分钟后重置"
        }
        return " · \(Int(secondsLeft)) 秒后重置"
    }

    /// The "getting full" threshold is the one the bar changes colour at, so the sentence and the bar
    /// cannot hold two opinions of when that is.
    private func memoryUseDescription(of progress: TaskProgress) -> String {
        let percentUsed = Int(progress.fractionOfTheRoomBeforeCompressionUsed * 100)

        if progress.fractionOfTheRoomBeforeCompressionUsed >= 0.8 {
            return "脑子快满了 · 只剩 \(100 - percentUsed)%"
        }
        return "脑子用了 \(percentUsed)% · 还有 \(100 - percentUsed)% 才满"
    }

    /// Measured against the trigger, not the model's whole window, so a full bar and the compression
    /// starting are one moment.
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

    /// What the panel says while Kiki cannot be used yet; the three ways to use it are
    /// `howToUseKikiSection`, which waits until there is something to use.
    @ViewBuilder
    private var settingsCopySection: some View {
        if companionManager.allPermissionsGranted {
            // All permissions granted but setup unfinished leaves one cause: no key saved.
            Text("粘贴下面的 DeepSeek API Key 就可以开始了")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // The key is saved and grants are missing — a first run just past the key step, or an
            // install whose grants were revoked — so nothing here may say anything was taken away.
            VStack(alignment: .leading, spacing: 6) {
                Text("还差几项授权")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("在下面逐个把权限打开，Kiki 就能开始了。")
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
                    .foregroundColor(Color(red: 0.72, green: 0.29, blue: 0.29))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - How To Use Kiki

    /// The three ways into Kiki, one card each — cards because they do not read alike: the two
    /// shortcuts differ only in modifiers and whether the key is held, and the third way is not a key.
    private var howToUseKikiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("怎么用 Kiki")

            askingKikiCard
            followingTheUserCard
            commandLineCard
        }
        .padding(.horizontal, 16)
    }

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

    private var commandLineCard: some View {
        usageModeCard(
            iconName: "terminal",
            title: "命令行",
            description: "打字提要求，回复流回终端；默认不出声，加了 --speak 才念出来"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("kiki command '…'")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.codeText)

                commandLineToolInstallRow
            }
        }
    }

    /// Whether the `kiki` command is in PATH, and the way to put it there: the install costs one
    /// system authorisation prompt — `/usr/local/bin` belongs to root — which is why it is a button
    /// the user presses rather than something that happens at launch.
    ///
    /// Absent for a build carrying no tool inside it: there is nothing to install.
    @ViewBuilder
    private var commandLineToolInstallRow: some View {
        if KikiCommandLineInstaller.toolInsideTheRunningApp != nil {
            if companionManager.commandLineToolIsInstalled {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已装好，终端里直接输 kiki")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                }
            } else {
                Button(action: {
                    Task { await companionManager.installTheCommandLineTool() }
                }) {
                    Text(companionManager.isInstallingTheCommandLineTool ? "安装中…" : "安装命令行工具")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(companionManager.isInstallingTheCommandLineTool ? DS.Colors.accent.opacity(0.4) : DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: !companionManager.isInstallingTheCommandLineTool)
                .disabled(companionManager.isInstallingTheCommandLineTool)
            }
        }
    }

    /// The trigger is a closure because the third card has a command line where the other two have
    /// keycaps.
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

            // Aligned under the title, not the icon, so the trigger and its sentence read as one block.
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
                .fill(Color.black.opacity(0.05))
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

    /// 22 is the 授权 button's own height (11 pt text, 4 pt padding, capsule stroke). Rows are pinned to
    /// it, so a grant — which swaps that button for the shorter 已授权 badge — never changes a row's
    /// height, and the panel doesn't shift while the guide walks it.
    private static let permissionRowContentHeight: CGFloat = 22

    /// The permission rows, in the order the first-run guide takes them — the guide's own dependency
    /// order, so the list reads the way the walk goes. A row moves here only when the guide's moves too.
    private var settingsSection: some View {
        VStack(spacing: 2) {
            sectionHeader("权限")
                .padding(.bottom, 4)

            screenRecordingPermissionRow

            screenContentPermissionRow

            accessibilityPermissionRow

            microphonePermissionRow

            // Only for the on-device backend: the network providers never touch the Speech Recognition
            // TCC service, so this row would be un-grantable.
            if companionManager.buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission {
                speechRecognitionPermissionRow
            }
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
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
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
        .frame(height: Self.permissionRowContentHeight)
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

                Text("屏幕录制")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
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
        .frame(height: Self.permissionRowContentHeight)
        .padding(.vertical, 6)
        .background(
            KikiSettingsPanelAnchorReporter(
                companionManager: companionManager,
                anchor: .screenRecordingPermissionRow
            )
        )
    }

    /// The second stage of the screen permission chain: 「屏幕内容」 is a separate TCC grant macOS only
    /// offers once ScreenCaptureKit has taken a real screenshot. Greyed out rather than hidden, so the
    /// panel doesn't grow a row out of nowhere after the first grant.
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
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
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
        .frame(height: Self.permissionRowContentHeight)
        .padding(.vertical, 6)
        .background(
            KikiSettingsPanelAnchorReporter(
                companionManager: companionManager,
                anchor: .screenContentPermissionRow
            )
        )
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
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                }
            } else {
                Button(action: {
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
        .frame(height: Self.permissionRowContentHeight)
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
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
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
        .frame(height: Self.permissionRowContentHeight)
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
                        .fill(DS.Colors.accentText)
                        .frame(width: 6, height: 6)
                    Text("已授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
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
    /// It covers pressing and scrolling together — one question in the user's mind, "may Kiki move
    /// things on my screen with the mouse" — because a switch that stopped at pressing would let the
    /// screen keep moving after it was turned off.
    ///
    /// Off, a `[CLICK:…]` reads as it did before pressing existed: the cursor still flies and the
    /// bubble still says 「点这里」. A refused press degrades to the same thing.
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

    /// The switch for the other way Kiki reaches the machine.
    ///
    /// A row of its own rather than folded into the mouse's: "Kiki has my keyboard" is a different
    /// permission from "Kiki has my mouse", and someone who wants to watch it point and click without
    /// ever handing over the keyboard must be able to say so.
    ///
    /// Off, a `[TYPE:…]` or `[KEY:…]` means what a `[CLICK:…]` means with the mouse switch off: the
    /// cursor still flies and the bubble says 「看这里」.
    private var automaticKeyboardToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("允许 Kiki 用键盘操作")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isAutomaticKeyboardEnabled },
                set: { companionManager.setAutomaticKeyboardEnabled($0) }
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

    private var deepSeekAPIKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            deepSeekAPIKeyTitleRow

            deepSeekAPIKeyField
        }
    }

    /// The key once it is saved: a line saying so, and a way back to the field.
    ///
    /// The field is put away because a saved key never needs re-typing, but it has to stay reachable:
    /// this row is the only place in the app that can put a different key in, so collapsing it without
    /// 更换 would make a key unchangeable.
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
                    .foregroundColor(DS.Colors.accentText)

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
                .foregroundColor(companionManager.hasDeepSeekAPIKey ? DS.Colors.accentText : DS.Colors.warning)
        }
    }

    private var deepSeekAPIKeyField: some View {
        HStack(spacing: 6) {
                // A SecureField so a pasted key isn't readable off the screen. It stays empty even when
                // a key is saved — 「已保存」 above is the confirmation — so it can't silently re-write
                // what was stored, and the placeholder differs for the same reason.
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
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .background(
                        KikiSettingsPanelAnchorReporter(
                            companionManager: companionManager,
                            anchor: .deepSeekAPIKeyField
                        )
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

    /// Stores the pasted key and empties the field, so the secret doesn't sit in a text field for
    /// the rest of the session.
    private func saveDeepSeekAPIKeyFromInput() {
        guard canSaveDeepSeekAPIKey else { return }
        companionManager.saveDeepSeekAPIKey(deepSeekAPIKeyInput)
        deepSeekAPIKeyInput = ""
        // Saving a replacement puts the field back away, rather than leaving the empty field on screen.
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
                    .fill(Color.black.opacity(0.05))
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
                        .fill(isSelected ? Color.white : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    /// Read from the bundle rather than written here, so the number shown is always the one this build
    /// actually is — the same number a release tag and a bug report have to match.
    private var appVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

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

            Spacer()

            if companionManager.hasCompletedOnboarding {
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

            Text("v\(appVersionText)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        // No shadow: the window is cut to this shape's size exactly, so a shadow drawn here is clipped
        // everywhere except the four corner cut-outs, where it reads as a gray smudge.
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
    }

    private var statusDotColor: Color {
        if companionManager.isRestingInTheStatusItemIcon {
            return DS.Colors.textTertiary
        }
        // The accent like the other working states: waking is something Kiki is doing, resting is not.
        if companionManager.isWakingFromTheStatusItemIcon {
            return DS.Colors.accentText
        }
        // The red of the record dot itself while the user is working, so the panel and the cursor
        // are recognizably the same state; the accent while Kiki is the one doing the work.
        if companionManager.recordedActionsPhase == .recordingWhatTheUserIsDoing {
            return DS.Colors.overlayCursorClickRed
        }
        if companionManager.recordedActionsPhase == .replayingWhatTheUserDid {
            return DS.Colors.accentText
        }
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.accentText
        case .processing, .responding:
            return DS.Colors.accentText
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

// MARK: - Settings Panel Anchors

/// Reports where one piece of the panel stands on screen, so the first-run guide can fly the cursor
/// onto it. Each row the guide points at carries one of these behind it, because the panel is the
/// only code that knows where its rows are — they move as the setup section fills in and empties.
private struct KikiSettingsPanelAnchorReporter: NSViewRepresentable {
    let companionManager: CompanionManager
    let anchor: CompanionManager.KikiSettingsPanelAnchor

    func makeNSView(context: Context) -> AnchorReportingView {
        let anchorReportingView = AnchorReportingView(frame: .zero)
        anchorReportingView.onAnchorScreenFrameChanged = { [weak companionManager] anchorScreenFrame in
            companionManager?.setSettingsPanelAnchorScreenFrame(anchorScreenFrame, for: anchor)
        }
        return anchorReportingView
    }

    func updateNSView(_ anchorReportingView: AnchorReportingView, context: Context) {}
}

/// The invisible box a reporter hangs off, laid out by SwiftUI to the same frame as the content it
/// stands behind.
///
/// The screen frame comes from `window.convertToScreen` and nothing else: the panel moves and resizes
/// with its content, so working the position out from the panel's own frame would be a second copy
/// that goes stale the moment either changes.
private final class AnchorReportingView: NSView {
    /// Where this box stands in AppKit global screen coordinates, or nil when it has no place on
    /// screen to report.
    var onAnchorScreenFrameChanged: ((CGRect?) -> Void)?

    private var frameChangedObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The view's own layout changes are only announced with this on, and they are how a row
        // appearing, disappearing or moving gets reported.
        postsFrameChangedNotifications = true
        frameChangedObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.reportTheAnchorScreenFrame()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let frameChangedObserver {
            NotificationCenter.default.removeObserver(frameChangedObserver)
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // The deferred reports below hold this view weakly, so a box torn down before its last report
        // ran would leave a stale frame behind. This is the report that cannot be missed.
        onAnchorScreenFrameChanged?(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeTheWindowTheViewIsIn()
        reportTheAnchorScreenFrame()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reportTheAnchorScreenFrame()
    }

    /// Watches the window this box stands in, so the window moving or resizing under a view whose own
    /// frame has not changed still reports a new screen frame.
    private func observeTheWindowTheViewIsIn() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }

        guard let window else {
            windowObservers = []
            return
        }

        let notificationNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            .kikiPanelDidReposition
        ]
        windowObservers = notificationNames.map { notificationName in
            NotificationCenter.default.addObserver(
                forName: notificationName,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.reportTheAnchorScreenFrame()
            }
        }
    }

    /// Reads the frame one run loop turn from now: these callbacks can arrive inside a SwiftUI update
    /// pass, and reporting through the manager publishes a change of its own.
    private func reportTheAnchorScreenFrame() {
        DispatchQueue.main.async { [weak self] in
            self?.readAndReportTheAnchorScreenFrame()
        }
    }

    private func readAndReportTheAnchorScreenFrame() {
        // A box SwiftUI has not laid out yet is not a place on screen, and reporting one would fly the
        // cursor to the window's corner.
        guard let window, bounds.width > 0, bounds.height > 0 else {
            onAnchorScreenFrameChanged?(nil)
            return
        }
        onAnchorScreenFrameChanged?(window.convertToScreen(convert(bounds, to: nil)))
    }
}
