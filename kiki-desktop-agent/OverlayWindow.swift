//
//  OverlayWindow.swift — the transparent overlay for the purple cursor, one window per display.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Above submenus and popups
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        self.hidesOnDeactivate = false

        self.setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Never key or main: the overlay must not steal focus.
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

enum BuddyNavigationMode {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
    case navigatingToStatusItemIcon
    /// Moving the pointer does not reach it; only the waking flight undoes it.
    case mergedIntoStatusItemIcon
    case wakingFromStatusItemIcon

    /// Whether a timer is driving the buddy frame by frame, so the implicit position and rotation animations are off.
    var isFlightInProgress: Bool {
        self == .navigatingToTarget
            || self == .navigatingToStatusItemIcon
            || self == .wakingFromStatusItemIcon
    }
}

struct CursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seeded from the mouse location so the buddy does not flash at (0,0) before onAppear.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(
            x: localX + CursorView.followingOffsetFromPointer.x,
            y: localY + CursorView.followingOffsetFromPointer.y
        ))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The up-left tilt the triangle holds whenever it is not flying, and lands on a target in.
    private static let restingTriangleRotationDegrees = -35.0

    @State private var triangleRotationDegrees: Double = CursorView.restingTriangleRotationDegrees

    /// Where the tip sits relative to the view's `.position(...)`: the tip, not the frame centre, is what lands on an element.
    private static let triangleTipOffsetFromFrameCenter: CGPoint = {
        let triangleFrameEdgeLength: CGFloat = 16
        let triangleHeight = triangleFrameEdgeLength * sqrt(3.0) / 2.0
        let tipOffsetBeforeRotation = CGPoint(x: 0, y: -(triangleHeight / 1.5))
        let restingRotationRadians = CursorView.restingTriangleRotationDegrees * .pi / 180
        // Positive angles rotate clockwise in SwiftUI's y-down space, so the standard matrix applies.
        return CGPoint(
            x: tipOffsetBeforeRotation.x * cos(restingRotationRadians) - tipOffsetBeforeRotation.y * sin(restingRotationRadians),
            y: tipOffsetBeforeRotation.x * sin(restingRotationRadians) + tipOffsetBeforeRotation.y * cos(restingRotationRadians)
        )
    }()

    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// Where the cursor was when navigation started, for the move that cancels the return flight.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    @State private var navigationAnimationTimer: Timer?

    @State private var buddyFlightScale: CGFloat = 1.0
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True while flying back to the cursor after pointing.
    @State private var isReturningToCursor: Bool = false

    /// True while the user's pointer is actually in Kiki's hand, across the dwell between two stops of a run.
    /// Narrower than the red: a press needs it on the element (the user watches their mouse), a scroll not.
    @State private var isHoldingTheUsersPointerForTheAction: Bool = false

    /// Whether Kiki is about to do something where the cursor is standing — what the red means. Read
    /// from the manager rather than kept here: a second copy would be a second answer.
    ///
    /// Nil is a stop Kiki will only point at, and what the manager writes when a tour ends.
    private var isAboutToPerformAnAction: Bool {
        companionManager.pointingTarget?.actionToPerformOnArrival != nil
    }

    private var cursorColor: Color {
        isAboutToPerformAnAction ? DS.Colors.overlayCursorClickRed : DS.Colors.overlayCursorPurple
    }

    private var isRecordingWhatTheUserIsDoing: Bool {
        companionManager.recordedActionsPhase == .recordingWhatTheUserIsDoing
    }

    /// How far below-right of the pointer the buddy sits when *around* it — following or flying home; a carrying flight's first leg aims at the pointer itself.
    static let followingOffsetFromPointer = CGPoint(x: 35, y: 25)

    /// How long the triangle takes to fade purple↔red. Only the colour is on this clock; the mouse changes hands with the flight itself.
    static let cursorClickColourFadeDuration: Double = 0.28

    /// Shorter than an ordinary flight's `0.6...1.4`: reaching a click is two legs and both must fit
    /// inside `CompanionManager.pointingTourArrivalTimeoutSeconds` (3.0s), which drops an overrun silently.
    private static let pointerCarryingFlightDuration: ClosedRange<Double> = 0.45...1.0

    /// The height of the display whose top-left corner is the Accessibility origin. Read fresh, not cached: the arrangement can change.
    private var primaryScreenHeightInPoints: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    // MARK: - Onboarding Video Layout

    // The frame is the clip's own shape so `.resizeAspectFill` fits without cropping; any other shape cuts the burned-in subtitles.
    private let onboardingVideoPlayerWidth: CGFloat = 320
    private let onboardingVideoPlayerHeight: CGFloat = 180

    private let fullWelcomeMessage = "嗨！我是 Kiki"

    /// The default pool, for an arrival the user was only meant to look at.
    private let navigationLookPhrases = [
        "看这里！",
        "在这儿！",
        "找到了！",
        "就是这个！"
    ]

    /// For [CLICK:...].
    private let navigationClickPhrases = [
        "点这里！",
        "点这个！",
        "就点它！"
    ]

    /// For [DOUBLECLICK:...]. One pool per gesture: they look identical until they happen, so only the wording says which is coming.
    private let navigationDoubleClickPhrases = [
        "双击这里！",
        "双击它！",
        "在这里双击！"
    ]

    /// For [TRIPLECLICK:...], for the double-click pool's reason.
    private let navigationTripleClickPhrases = [
        "三击这里！",
        "三击它！",
        "在这里三击！"
    ]

    /// For [RIGHTCLICK:...]: the bubble is the only thing saying which button goes down.
    private let navigationRightClickPhrases = [
        "右键这里！",
        "右键点它！",
        "在这里点右键！"
    ]

    /// For [SCROLLUP:...] and its three siblings, for the press pools' reason: only the bubble says which way it goes.
    private let navigationScrollUpPhrases = [
        "往上滚！",
        "这就往上翻！",
        "帮你往上滚！"
    ]

    private let navigationScrollDownPhrases = [
        "往下滚！",
        "这就往下翻！",
        "帮你往下滚！"
    ]

    private let navigationScrollLeftPhrases = [
        "往左滚！",
        "这就往左翻！",
        "帮你往左滚！"
    ]

    private let navigationScrollRightPhrases = [
        "往右滚！",
        "这就往右翻！",
        "帮你往右滚！"
    ]

    /// For [DRAG:...]. A drag is not over when the cursor lands, so the phrase stays up for the carry.
    private let navigationDragPhrases = [
        "帮你拖过去！",
        "这就拖过去！",
        "拖着它走！"
    ]

    /// For [TYPE:...]. Deliberately not naming the words — what matters at a glance is that the keyboard is being used at all.
    private let navigationTypingPhrases = [
        "帮你打字！",
        "这就打上去！",
        "我来输入！"
    ]

    /// The pool an arrival draws from, chosen by the tag.
    ///
    /// A combination's is built rather than stored: it must say which combination, written the one way
    /// `ElementKeyboard.phraseForPressingKey` writes it, so bubble, report and terminal all say ⌘S alike.
    private func phrases(
        for pointingBubbleInvitation: CompanionManager.PointingBubbleInvitation
    ) -> [String] {
        switch pointingBubbleInvitation {
        case .lookAtElement: return navigationLookPhrases
        case .clickElement: return navigationClickPhrases
        case .doubleClickElement: return navigationDoubleClickPhrases
        case .tripleClickElement: return navigationTripleClickPhrases
        case .rightClickElement: return navigationRightClickPhrases
        case .dragElement: return navigationDragPhrases
        case .keyboardElement(.text): return navigationTypingPhrases
        case .keyboardElement(.combination(let name)):
            let writtenCombination = ElementKeyboard.phraseForPressingKey(name)
            return [
                "帮你按 \(writtenCombination)！",
                "这就按 \(writtenCombination)！",
                "按一下 \(writtenCombination)！"
            ]
        case .scrollElement(let direction, _):
            switch direction {
            case .up: return navigationScrollUpPhrases
            case .down: return navigationScrollDownPhrases
            case .left: return navigationScrollLeftPhrases
            case .right: return navigationScrollRightPhrases
            }
        }
    }

    var body: some View {
        ZStack {
            // Nearly transparent, which helps compositing.
            Color.black.opacity(0.001)

            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorPurple)
                            .shadow(color: DS.Colors.overlayCursorPurple.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Always in the view tree so the opacity animation works reliably; nothing shows without a player.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                // One duration drives the fade both ways (the video fades out through this same modifier), so a fade-out wait is this long.
                .animation(.easeInOut(duration: 1.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorPurple)
                            .shadow(color: DS.Colors.overlayCursorPurple.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorPurple)
                            .shadow(
                                color: DS.Colors.overlayCursorPurple.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // The voice, drawn as light around the cursor.
            CursorVoiceGlowView(
                voiceLoudnessMeter: companionManager.voiceLoudnessMeter,
                cursorColor: cursorColor,
                cursorPosition: cursorPosition,
                flightScale: buddyFlightScale,
                buddyNavigationMode: buddyNavigationMode,
                opacity: buddyIsVisibleOnThisScreen && !isRecordingWhatTheUserIsDoing
                    && (companionManager.voiceState == .idle || companionManager.voiceState == .responding)
                    ? cursorOpacity : 0
            )

            // Following uses a spring; navigation takes no implicit animation, since the bezier timer drives the position at 60fps.
            Triangle()
                .fill(cursorColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: cursorColor, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && !isRecordingWhatTheUserIsDoing && (companionManager.voiceState == .idle || companionManager.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode.isFlightInProgress ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )
                // A fade, so the hand-over reads as the buddy taking hold of it.
                .animation(
                    .easeInOut(duration: CursorView.cursorClickColourFadeDuration),
                    value: isAboutToPerformAnAction
                )

            // Red record dot, in the triangle's own place beside the pointer.
            Circle()
                .fill(DS.Colors.overlayCursorClickRed)
                .frame(width: 12, height: 12)
                .shadow(color: DS.Colors.overlayCursorClickRed, radius: 8, x: 0, y: 0)
                .opacity(buddyIsVisibleOnThisScreen && isRecordingWhatTheUserIsDoing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)

            CursorWaveformView(
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                isOnScreen: buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            CursorSpinnerView(
                isOnScreen: buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(
                x: swiftUIPosition.x + CursorView.followingOffsetFromPointer.x,
                y: swiftUIPosition.y + CursorView.followingOffsetFromPointer.y
            )

            startTrackingCursor()

            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            // The second matters: a view going away while the pointer is detached leaves a mouse nothing hands back.
            releaseTheUsersPointerIfHoldingIt()
            PointerCarrier.releaseThePointerIfCarrying()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.statusItemIconPhase) { newPhase in
            switch newPhase {
            case .notInTheIcon:
                resumeFollowingFromStatusItemIcon()
            case .cursorFlyingToIcon(let iconScreenFrame):
                startMergingIntoStatusItemIcon(iconScreenFrame: iconScreenFrame)
            case .cursorRestingInIcon:
                // Landing is this view's own doing and finished; a rebuilt view (a display change) never lands here.
                break
            case .cursorWakingFromIcon:
                startWakingFromStatusItemIcon()
            }
        }
        // Bumped only for a flight, not a location: two stops can name one point, and keyed on the location the second is never flown to — no bubble, no arrival.
        .onChange(of: companionManager.pointingFlightRequestCount) { _ in
            // Read as the target whole: a newer flight that landed before this callback is the one to fly.
            guard let pointingTarget = companionManager.pointingTarget else { return }

            guard screenFrame.contains(CGPoint(x: pointingTarget.displayFrame.midX, y: pointingTarget.displayFrame.midY))
                  || pointingTarget.displayFrame == screenFrame else {
                // On another screen: this one's buddy would otherwise stay parked in `.pointingAtTarget` — two buddies shown.
                standDownNavigationForOtherScreen()
                return
            }

            startNavigatingToElement(screenLocation: pointingTarget.screenLocation)
        }
        // A drag is drawn rather than flown — the manager posts the movement step by step — and this is the only writer of `cursorPosition` while one runs, the flight's arrival left open.
        .onChange(of: companionManager.screenLocationOfTheDragInFlight) { dragScreenLocation in
            guard let dragScreenLocation, screenFrame.contains(dragScreenLocation) else { return }
            cursorPosition = convertScreenPointToSwiftUICoordinates(dragScreenLocation)
        }
        .onChange(of: companionManager.buddyReturnHomeRequestCount) { _ in
            // A count, not the flag: a cut-off tour writes `false` into a flag it never set, so `.onChange` sees nothing and the buddy stays frozen in `.pointingAtTarget` — skipping cursor tracking.
            guard buddyNavigationMode != .followingCursor else { return }
            startFlyingBackToCursor()
        }
    }

    /// Only one buddy is ever visible at a time, so a screen another view is navigating to hides this one's.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if companionManager.pointingTarget != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget, .navigatingToStatusItemIcon,
             .wakingFromStatusItemIcon:
            return true
        case .mergedIntoStatusItemIcon:
            // Off the screen entirely — it is the icon.
            return false
        }
    }

    // MARK: - Cursor Tracking

    /// One timer per display. Both writes are guarded on a change: a `@State` write marks the view dirty whether or not the value differs, so an unguarded tick re-evaluates the body 60 times a second.
    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            let isCursorNowOnThisScreen = self.screenFrame.contains(mouseLocation)
            if isCursorNowOnThisScreen != self.isCursorOnThisScreen {
                self.isCursorOnThisScreen = isCursorNowOnThisScreen
            }

            // Mouse movement interrupts only the return flight; forward flight and pointing complete.
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            if self.buddyNavigationMode != .followingCursor {
                return
            }

            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let followedPosition = CGPoint(
                x: swiftUIPosition.x + CursorView.followingOffsetFromPointer.x,
                y: swiftUIPosition.y + CursorView.followingOffsetFromPointer.y
            )
            if followedPosition != self.cursorPosition {
                self.cursorPosition = followedPosition
            }
        }
    }

    /// AppKit screen point (bottom-left origin) to SwiftUI coordinates (top-left origin) local to this window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    /// The other direction — a carry converts every frame; the buddy is in SwiftUI coordinates, the pointer in AppKit's.
    private func convertSwiftUICoordinatesToScreenPoint(_ swiftUIPoint: CGPoint) -> CGPoint {
        let x = swiftUIPoint.x + screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - swiftUIPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    private func startNavigatingToElement(screenLocation: CGPoint) {
        // While the cursor is in the icon's hands none may fly: there is no cursor to send in, and one already flying out.
        guard !companionManager.isNotTakingInputBecauseOfTheStatusItemIcon else { return }

        // Don't interrupt the welcome animation: nothing is going to fly, so nothing the pointer is held for will happen either.
        guard !showWelcome || welcomeText.isEmpty else {
            releaseTheUsersPointerIfHoldingIt()
            return
        }

        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset by the negative of the tip's own offset, so the tip — not the frame's centre — lands on the element.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x - CursorView.triangleTipOffsetFromFrameCenter.x,
            y: targetInSwiftUI.y - CursorView.triangleTipOffsetFromFrameCenter.y
        )

        // Clamp to the screen bounds, so the arc's endpoint stays on this display.
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Recorded so a big enough mouse move can cancel the return flight.
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        // Red-and-carrying is the manager's decision, made before it published: a point-only stop stays a plain purple arc.
        guard companionManager.pointingTarget?.actionToPerformOnArrival != nil else {
            // This stop is not acted on, so any run ends here: the pointer goes back before the flight, not after.
            releaseTheUsersPointerIfHoldingIt()
            animateBezierFlightArc(to: clampedTarget) {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.startPointingAtElement()
            }
            return
        }

        // Asked rather than assumed — `carriesTheUsersPointer` is where an action says what it needs.
        guard companionManager.pointingTarget?.actionToPerformOnArrival?.carriesTheUsersPointer ?? false
        else {
            // Red, but the pointer stays: nothing about this action waits on it, and the user keeps it.
            animateBezierFlightArc(to: clampedTarget) {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.startPointingAtElement()
            }
            return
        }

        if isHoldingTheUsersPointerForTheAction {
            // Already holding it: no flight out to the pointer, just on to the next element — a run of presses reads as one gesture.
            carryTheMouseAlongAnArc(to: clampedTarget, endingOn: screenLocation)
        } else {
            // The colour turns as the flight leaves, so the grab lands on a plainly red triangle; nothing is held yet — red means "about to".
            isHoldingTheUsersPointerForTheAction = true
            flyToWhereTheUsersPointerIsStanding {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.carryTheMouseAlongAnArc(to: clampedTarget, endingOn: screenLocation)
            }
        }
    }

    /// The first leg of a pointer-carrying run: a pointer on another display has nothing to fly to — the arc cannot leave this window — so the grab warps it here.
    private func flyToWhereTheUsersPointerIsStanding(then onArrival: @escaping () -> Void) {
        let mouseLocation = NSEvent.mouseLocation
        guard screenFrame.contains(mouseLocation) else {
            onArrival()
            return
        }

        // The pointer itself, not the spot the buddy parks in — the offset position would draw as a pause.
        let pointerInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)

        animateBezierFlightArc(
            to: pointerInSwiftUI,
            durationRange: CursorView.pointerCarryingFlightDuration
        ) {
            onArrival()
        }
    }

    /// Carries the user's pointer along the arc the buddy is about to fly. Taking hold always warps,
    /// never flies — recovering a pointer pushed aside during a dwell and one on another display.
    ///
    /// `endingOn` is where the pointer is left, not the arc's destination: the arc lands the frame
    /// centre on a clamped target, the click on the element itself.
    private func carryTheMouseAlongAnArc(
        to swiftUIPosition: CGPoint,
        endingOn screenLocation: CGPoint
    ) {
        PointerCarrier.startCarryingThePointer(
            toAppKitScreenLocation: convertSwiftUICoordinatesToScreenPoint(cursorPosition),
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )

        animateBezierFlightArc(
            to: swiftUIPosition,
            durationRange: CursorView.pointerCarryingFlightDuration,
            onEachFrame: { positionInSwiftUI in
                self.moveThePointerUnder(swiftUIPosition: positionInSwiftUI)
            }
        ) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            PointerCarrier.carryThePointer(
                toAppKitScreenLocation: screenLocation,
                primaryScreenHeightInPoints: self.primaryScreenHeightInPoints
            )
            self.startPointingAtElement()
        }
    }

    /// The per-frame half of a carry.
    private func moveThePointerUnder(swiftUIPosition: CGPoint) {
        PointerCarrier.carryThePointer(
            toAppKitScreenLocation: convertSwiftUICoordinatesToScreenPoint(swiftUIPosition),
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Gives the pointer back to the user, fading the colour as it goes. Idempotent: every teardown path calls it, and it must never leave the pointer detached.
    private func releaseTheUsersPointerIfHoldingIt() {
        guard isHoldingTheUsersPointerForTheAction else { return }
        isHoldingTheUsersPointerForTheAction = false

        // Handed back now, though the colour takes a quarter of a second to leave: the run is over, and the way home is the user's leg.
        PointerCarrier.releaseThePointer(
            atAppKitScreenLocation: NSEvent.mouseLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Animates the buddy along a quadratic bezier arc, rotating it to face its direction of travel.
    ///
    /// `durationRange` and `onEachFrame` serve the pointer-carrying flights: quicker legs so two fit the
    /// arrival timeout, and a frame hook keeping the pointer under the cursor — except on the last frame,
    /// where the buddy snaps onto its destination and the caller places the pointer.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        durationRange: ClosedRange<Double> = 0.6...1.4,
        onEachFrame: ((CGPoint) -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        let flightDurationSeconds = min(
            max(distance / 800.0, durationRange.lowerBound),
            durationRange.upperBound
        )
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point: the midpoint raised, so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut.
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)
            onEachFrame?(self.cursorPosition)

            // Face the direction of travel, from the tangent to the bezier curve.
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° because the tip points up at 0° rotation while atan2 returns 0° for rightward.
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse, peaking mid-flight.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Back to the resting angle, the orientation `triangleTipOffsetFromFrameCenter` assumes.
        triangleRotationDegrees = CursorView.restingTriangleRotationDegrees

        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // A pointing tour keeps the buddy on the element until the narration is done with it: the hold-and-return below is skipped; this arrival releases the narration instead.
        let isPointingTourStop = companionManager.isPointingTourActive
        if isPointingTourStop {
            // The narration may have run out while this flight was in the air: nothing left to point at.
            if companionManager.shouldReturnBuddyToCursorAfterPointing {
                startFlyingBackToCursor()
                return
            }
            // Where the press is posted — asked of the manager, not tracked here: only it knows what the tour has left.
            companionManager.buddyDidArriveAtPointingTarget()
        }

        // The pointer is deliberately *not* handed back on arrival: the cursor stays red while it dwells on the element it just pressed; only the two moments a run really ends hand it back.

        // The manager's own text (the onboarding demo), otherwise a random phrase from the tag's invitation pool; a plain look's by default.
        let pointerPhrase = companionManager.pointingTarget?.bubbleText
            ?? phrases(for: companionManager.pointingTarget?.bubbleInvitation ?? .lookAtElement)
                .randomElement()
            ?? "就在这儿！"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            guard !isPointingTourStop else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the bubble text a character at a time, for a natural speaking rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // The first character is what triggers the scale-bounce entrance.
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    private func startFlyingBackToCursor() {
        // Given back before the flight, not after: the colour fades over the way home, and a buddy still holding the pointer cannot follow it.
        releaseTheUsersPointerIfHoldingIt()

        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(
            x: cursorInSwiftUI.x + CursorView.followingOffsetFromPointer.x,
            y: cursorInSwiftUI.y + CursorView.followingOffsetFromPointer.y
        )

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    private func finishNavigationAndResumeFollowing() {
        resetBuddyToFollowingMode()
        companionManager.clearDetectedElementLocation()
    }

    /// Parks this screen's buddy back into cursor-following because the target is another screen's; the manager's target is left alone — clearing it would strand that flight.
    private func standDownNavigationForOtherScreen() {
        guard buddyNavigationMode != .followingCursor else { return }
        resetBuddyToFollowingMode()
    }

    /// Drops the navigation state without touching the manager's target. Every way a navigation can end arrives here, so this is where the pointer is handed back — a cut-off run has no arrival.
    private func resetBuddyToFollowingMode() {
        releaseTheUsersPointerIfHoldingIt()
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = CursorView.restingTriangleRotationDegrees
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
    }

    // MARK: - Visiting The Status Item Icon

    /// Flies the buddy to the icon. Only the screen holding it flies; the others are following the pointer, with nothing to merge into.
    private func startMergingIntoStatusItemIcon(iconScreenFrame: CGRect) {
        let iconCentreOnScreen = CGPoint(x: iconScreenFrame.midX, y: iconScreenFrame.midY)
        guard screenFrame.contains(iconCentreOnScreen) else { return }

        // The icon's centre, with neither the tip offset nor the screen-edge clamp: its 20pt margin would hold the buddy short of the icon.
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(iconCentreOnScreen)

        buddyNavigationMode = .navigatingToStatusItemIcon
        isReturningToCursor = false

        animateBezierFlightArc(to: targetInSwiftUI) {
            guard self.buddyNavigationMode == .navigatingToStatusItemIcon else { return }
            self.settleIntoStatusItemIcon()
        }
    }

    /// The manager is told on landing, so the icon can take on the cursor's colour.
    private func settleIntoStatusItemIcon() {
        buddyNavigationMode = .mergedIntoStatusItemIcon
        triangleRotationDegrees = CursorView.restingTriangleRotationDegrees
        companionManager.cursorDidLandOnStatusItemIcon()

        withAnimation(.easeOut(duration: 0.3)) {
            self.cursorOpacity = 0.0
        }
    }

    /// Comes back out where it stands, for the two cases the manager ends a visit by itself — the overlay going away, a display change rebuilding this view. A recovery, not a flight.
    private func resumeFollowingFromStatusItemIcon() {
        guard buddyNavigationMode == .mergedIntoStatusItemIcon
                || buddyNavigationMode == .navigatingToStatusItemIcon
                || buddyNavigationMode == .wakingFromStatusItemIcon else { return }

        resetBuddyToFollowingMode()

        withAnimation(.easeOut(duration: 0.3)) {
            self.cursorOpacity = 1.0
        }
    }

    /// The waking flight: fade in where the cursor disappeared, fly beside the pointer, resume following on landing. Only the view that flew in has anything to bring out.
    private func startWakingFromStatusItemIcon() {
        guard buddyNavigationMode == .mergedIntoStatusItemIcon else { return }

        // Now, not when the waking wait began: the standing spot is relative to the pointer, so the cursor lands beside wherever the user got to.
        let pointerInSwiftUI = convertScreenPointToSwiftUICoordinates(NSEvent.mouseLocation)
        let standingPosition = CGPoint(
            x: pointerInSwiftUI.x + CursorView.followingOffsetFromPointer.x,
            y: pointerInSwiftUI.y + CursorView.followingOffsetFromPointer.y
        )

        buddyNavigationMode = .wakingFromStatusItemIcon
        isReturningToCursor = false

        withAnimation(.easeIn(duration: 0.25)) {
            self.cursorOpacity = 1.0
        }

        animateBezierFlightArc(to: standingPosition) {
            guard self.buddyNavigationMode == .wakingFromStatusItemIcon else { return }
            self.resetBuddyToFollowingMode()
            self.companionManager.cursorDidFinishWakingFromTheStatusItemIcon()
        }
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Cursor Voice Glow

/// The light around the cursor while Kiki is speaking, which widens and narrows with the voice.
/// A view of its own because the level arrives tens of times a second: anything else reading it would
/// be re-evaluated that often. The rise and fall are the view's own animation rather than a smoothed
/// value, so two sources may report at two different rates.
private struct CursorVoiceGlowView: View {

    @ObservedObject var voiceLoudnessMeter: VoiceLoudnessMeter
    /// The cursor's colour as it stands, so the glow turns red with the triangle on a flight that is going to press or carry.
    let cursorColor: Color
    let cursorPosition: CGPoint
    let flightScale: CGFloat
    let buddyNavigationMode: BuddyNavigationMode
    let opacity: Double

    /// The whole range the voice moves the glow's diameter through.
    private static let widestGlowDiameter: CGFloat = 52
    private static let narrowestGlowDiameter: CGFloat = 16

    /// Long enough that the glow swells rather than jumps with a syllable, short enough to be still before the next one arrives.
    private static let glowRiseAndFallDuration: Double = 0.12

    private var glowDiameter: CGFloat {
        let voiceLoudness = voiceLoudnessMeter.loudness
        let diameter = Self.narrowestGlowDiameter
            + (Self.widestGlowDiameter - Self.narrowestGlowDiameter) * voiceLoudness
        return diameter * flightScale
    }

    var body: some View {
        Circle()
            .fill(cursorColor)
            .frame(width: glowDiameter, height: glowDiameter)
            .blur(radius: 10)
            // Level and opacity as one number: a silence draws nothing. The peak stays deliberately below the triangle's brightness.
            .opacity(0.55 * voiceLoudnessMeter.loudness * opacity)
            .position(cursorPosition)
            .animation(
                buddyNavigationMode == .followingCursor
                    ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                    : nil,
                value: cursorPosition
            )
            // On the triangle's own clock: two clocks would show two colours for a quarter of a second, at the moment the user is watching to learn what Kiki is about to press.
            .animation(.easeInOut(duration: CursorView.cursorClickColourFadeDuration), value: cursorColor)
            .animation(.easeOut(duration: Self.glowRiseAndFallDuration), value: voiceLoudnessMeter.loudness)
            .allowsHitTesting(false)
    }
}

// MARK: - Cursor Waveform

/// The purple waveform that replaces the cursor while push-to-talk is held.
private struct CursorWaveformView: View {
    let audioPowerLevel: CGFloat
    /// Whether the waveform is the shape actually being drawn on this screen.
    ///
    /// The timeline is paused when it is not: a `TimelineView` keeps to its schedule whatever its
    /// `opacity` is, so an unpaused, cross-faded one commits a full-screen transparent window 36 times a
    /// second per display. Bar heights come from the date, so unpausing resumes mid-phase.
    let isOnScreen: Bool

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0, paused: !isOnScreen)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorPurple)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorPurple.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Cursor Spinner

/// The purple spinner that replaces the cursor while the AI is processing a voice input.
private struct CursorSpinnerView: View {
    /// Whether the spinner is the shape actually being drawn on this screen.
    ///
    /// The timeline is paused when it is not, and the rotation cannot be `repeatForever`: `rotationEffect`
    /// is *animatable*, so every frame the attribute graph recomputes the animator and commits a
    /// transaction — per display, on a view permanently in the tree.
    let isOnScreen: Bool

    /// One full turn.
    private let rotationPeriodSeconds: Double = 0.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isOnScreen)) { timelineContext in
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(
                    AngularGradient(
                        colors: [
                            DS.Colors.overlayCursorPurple.opacity(0.0),
                            DS.Colors.overlayCursorPurple
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotationDegrees(at: timelineContext.date)))
                .shadow(color: DS.Colors.overlayCursorPurple.opacity(0.6), radius: 6, x: 0, y: 0)
        }
    }

    /// Where the turn has got to, in degrees. From the absolute time, not a frame count, so pausing is a break, not a jump.
    private func rotationDegrees(at timelineDate: Date) -> Double {
        let secondsIntoTheTurn = timelineDate.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: rotationPeriodSeconds)
        return secondsIntoTheTurn / rotationPeriodSeconds * 360.0
    }
}

// One overlay window per screen, so the buddy follows the cursor across monitors.
@MainActor
class OverlayWindowManager {
    /// Keyed by display ID, the only thing about a screen that survives a re-plug; a display change must tell "already covered" from "new".
    private var overlayWindowsByDisplayID: [CGDirectDisplayID: OverlayWindow] = [:]
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        hideOverlay()

        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        for screen in screens {
            let window = makeOverlayWindow(
                for: screen,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            overlayWindowsByDisplayID[screen.displayID] = window
            window.orderFrontRegardless()
        }
    }

    /// Rebuilds the overlay when the display configuration changes — else windows exist only while the
    /// overlay is shown, so a display plugged in at runtime would never get one. Unchanged screens keep
    /// their windows, flights and video.
    func refreshOverlaysForDisplayConfigurationChange(
        onScreens screens: [NSScreen],
        companionManager: CompanionManager
    ) {
        let connectedDisplayIDs = Set(screens.map { $0.displayID })

        // Gone displays lose their window; clearing the content view runs `onDisappear`, where the pointer is released.
        let disconnectedDisplayIDs = overlayWindowsByDisplayID.keys.filter { !connectedDisplayIDs.contains($0) }
        for displayID in disconnectedDisplayIDs {
            guard let window = overlayWindowsByDisplayID.removeValue(forKey: displayID) else { continue }
            window.orderOut(nil)
            window.contentView = nil
        }

        for screen in screens {
            if let existingWindow = overlayWindowsByDisplayID[screen.displayID],
               existingWindow.frame == screen.frame {
                continue
            }

            // Never covered, or resized or moved: the hosted view bakes in this screen's frame when built, so both need a fresh window.
            if let staleWindow = overlayWindowsByDisplayID.removeValue(forKey: screen.displayID) {
                staleWindow.orderOut(nil)
                staleWindow.contentView = nil
            }

            let window = makeOverlayWindow(
                for: screen,
                isFirstAppearance: false,
                companionManager: companionManager
            )

            overlayWindowsByDisplayID[screen.displayID] = window
            window.orderFrontRegardless()
        }
    }

    /// Builds the overlay window covering one screen — shared by the initial show and the display-change rebuild.
    private func makeOverlayWindow(
        for screen: NSScreen,
        isFirstAppearance: Bool,
        companionManager: CompanionManager
    ) -> OverlayWindow {
        let window = OverlayWindow(screen: screen)

        let contentView = CursorView(
            screenFrame: screen.frame,
            isFirstAppearance: isFirstAppearance,
            companionManager: companionManager
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = screen.frame
        window.contentView = hostingView

        return window
    }

    func hideOverlay() {
        for window in overlayWindowsByDisplayID.values {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindowsByDisplayID.removeAll()
    }

    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = Array(overlayWindowsByDisplayID.values)
        overlayWindowsByDisplayID.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindowsByDisplayID.isEmpty
    }
}

// MARK: - Onboarding Video Player

private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
