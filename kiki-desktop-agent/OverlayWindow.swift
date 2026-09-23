//
//  OverlayWindow.swift
//  kiki-desktop-agent
//
//  System-wide transparent overlay for the blue cursor: one window per display.
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
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Appears even when the app is not active.
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

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
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

/// The buddy's behavioral mode: following the cursor, flying to an element, or arrived and
/// pointing at one.
enum BuddyNavigationMode {
    /// Following the mouse cursor with a spring.
    case followingCursor
    /// Flying toward a detected element.
    case navigatingToTarget
    /// Arrived, pointing at it with a speech bubble.
    case pointingAtTarget
    /// Flying toward the menu bar icon the pointer was left resting on.
    case navigatingToStatusItemIcon
    /// Arrived at the icon and disappeared into it. No amount of moving the pointer reaches this
    /// one; only the waking flight undoes it.
    case mergedIntoStatusItemIcon
    /// Flying back out of the icon, to the position beside the pointer where following resumes.
    case wakingFromStatusItemIcon

    /// Whether a timer is driving the buddy frame by frame, which is what rules out the implicit
    /// position and rotation animations everywhere else: they would fight it for the same frame.
    var isFlightInProgress: Bool {
        self == .navigatingToTarget
            || self == .navigatingToStatusItemIcon
            || self == .wakingFromStatusItemIcon
    }
}

// SwiftUI view for the blue glowing cursor pointer, one per screen. The view checks whether the
// cursor is on THIS screen and only shows the buddy triangle when it is; during a voice
// interaction the triangle is replaced by a waveform, spinner or streaming text bubble.
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seeded from the current mouse location so the buddy does not flash
        // at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(
            x: localX + BlueCursorView.followingOffsetFromPointer.x,
            y: localY + BlueCursorView.followingOffsetFromPointer.y
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

    /// Whether the buddy is following the cursor, flying to a target, or arrived and pointing.
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The cursor-like up-left tilt the triangle holds whenever it is not flying, which is also the
    /// orientation it lands on a target in.
    private static let restingTriangleRotationDegrees = -35.0

    /// Rest at `restingTriangleRotationDegrees`; faces the direction of travel while flying.
    @State private var triangleRotationDegrees: Double = BlueCursorView.restingTriangleRotationDegrees

    /// Where the triangle's tip sits relative to the point `.position(cursorPosition)` places the
    /// view at, with the resting rotation applied. The tip, not the frame centre, has to land on an
    /// element: `Triangle` draws it `height / 1.5` above the centroid, and the resting tilt swings
    /// it up and to the left.
    private static let triangleTipOffsetFromFrameCenter: CGPoint = {
        let triangleFrameEdgeLength: CGFloat = 16
        let triangleHeight = triangleFrameEdgeLength * sqrt(3.0) / 2.0
        let tipOffsetBeforeRotation = CGPoint(x: 0, y: -(triangleHeight / 1.5))
        let restingRotationRadians = BlueCursorView.restingTriangleRotationDegrees * .pi / 180
        // Positive angles rotate clockwise in SwiftUI's y-down space, so the standard
        // rotation matrix applies unchanged.
        return CGPoint(
            x: tipOffsetBeforeRotation.x * cos(restingRotationRadians) - tipOffsetBeforeRotation.y * sin(restingRotationRadians),
            y: tipOffsetBeforeRotation.x * sin(restingRotationRadians) + tipOffsetBeforeRotation.y * cos(restingRotationRadians)
        )
    }()

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position when navigation started, for detecting a move large enough to cancel the
    /// return flight.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Drives the frame-by-frame bezier flight. Invalidated when the flight ends or the view goes away.
    @State private var navigationAnimationTimer: Timer?

    /// Grows to ~1.3x at the midpoint of the arc and shrinks back to 1.0x on landing.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// The bubble's pop-in entrance: springs from 0.5 to 1.0 as the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True while flying back to the cursor after pointing — the only flight a mouse movement cancels.
    @State private var isReturningToCursor: Bool = false

    /// True while the user's pointer is actually in Kiki's hand.
    ///
    /// Narrower than the red, and deliberately separate from it: a press needs the pointer standing
    /// on the element, because the press is something the user watches happen to *their* mouse, while
    /// a scroll does not — a scroll carries its point on the event exactly as a press does, and lands
    /// on whatever sits under that point regardless of where the pointer is. It stays true across the
    /// dwell between two stops of one run, so it is not simply "the pointer is locked" — that lock
    /// ends the moment a carry lands.
    @State private var isHoldingTheUsersPointerForTheAction: Bool = false

    /// Whether Kiki is about to do something where the cursor is standing, which is what the red
    /// means: red is a drawing of "Kiki will act here", and it is read from the manager's own answer
    /// rather than kept here, because a second copy of that answer is a second answer — and the one
    /// drawn is the one the user plans around.
    ///
    /// Nil is a stop Kiki will only point at, and nil is also what the manager writes when the tour
    /// ends under the cursor, so the red leaves with the intention rather than with the flight.
    private var isAboutToPerformAnAction: Bool {
        companionManager.pointingTarget?.actionToPerformOnArrival != nil
    }

    /// How the user is told Kiki is about to act where the cursor is standing.
    private var cursorColor: Color {
        isAboutToPerformAnAction ? DS.Colors.overlayCursorClickRed : DS.Colors.overlayCursorBlue
    }

    /// Whether the user's own hands are being watched, which is what the record dot replaces the
    /// triangle for. Read from the manager, because the recorder lives there and the panel says the
    /// same thing.
    private var isRecordingWhatTheUserIsDoing: Bool {
        companionManager.recordedActionsPhase == .recordingWhatTheUserIsDoing
    }

    /// How far below and to the right of the pointer the buddy sits while following it, applied to
    /// the two positions it takes up *around* a pointer: following it, and flying home to it. The
    /// first leg of a pointer-carrying flight is the exception: aiming it here would draw as a pause
    /// rather than a reach for the mouse, since the buddy already stands here.
    static let followingOffsetFromPointer = CGPoint(x: 35, y: 25)

    /// How long the triangle takes to fade between blue and red. Only the colour is on this clock —
    /// the mouse changes hands at the two moments the flight does, not a quarter of a second later.
    static let cursorClickColourFadeDuration: Double = 0.28

    /// How long each leg of a pointer-carrying flight takes. Shorter than an ordinary flight's
    /// `0.6...1.4`, because getting to a click is two legs — out to the user's pointer, then on to
    /// the element — and both must fit inside `CompanionManager.pointingTourArrivalTimeoutSeconds`
    /// (3.0s), which ends an overrun silently without posting the click and also sizes the tour's
    /// stall watchdog.
    private static let pointerCarryingFlightDuration: ClosedRange<Double> = 0.45...1.0

    /// The height of the display whose top-left corner is the origin of the Accessibility API's screen
    /// space — the primary display. Read fresh rather than cached, since the arrangement can change.
    private var primaryScreenHeightInPoints: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    // MARK: - Onboarding Video Layout

    // The frame is the clip's own shape — `kiki-intro.mp4` is 1280x720 and this is 320x180, both
    // 16:9 — so `.resizeAspectFill` scales it to fit and crops nothing. Any other shape crops the
    // edges away, and the burned-in subtitles sit low enough to be the first thing cut.
    private let onboardingVideoPlayerWidth: CGFloat = 320
    private let onboardingVideoPlayerHeight: CGFloat = 180

    private let fullWelcomeMessage = "嗨！我是 Kiki"

    /// Bubble phrases for an arrival the user was only meant to look at, which is most pointing:
    /// the cursor is answering "where is it?". Inviting someone to look is never wrong, not even
    /// when they are about to click the thing anyway.
    private let navigationLookPhrases = [
        "看这里！",
        "在这儿！",
        "找到了！",
        "就是这个！"
    ]

    /// For an arrival the model described as something to operate with one press, tagged
    /// [CLICK:...]. See `CompanionManager.PointingBubbleInvitation`.
    private let navigationClickPhrases = [
        "点这里！",
        "点这个！",
        "就点它！"
    ]

    /// For an arrival that takes two presses — a file to open, a word to select — tagged
    /// [DOUBLECLICK:...]. The wording says which gesture this is because the two look identical on
    /// screen, and 「点这里！」 over a file about to open describes the wrong one.
    private let navigationDoubleClickPhrases = [
        "双击这里！",
        "双击它！",
        "在这里双击！"
    ]

    /// For an arrival that takes three presses — a whole paragraph to select — tagged
    /// [TRIPLECLICK:...]. Same reason again: 「双击这里！」 over a paragraph about to be selected three
    /// times over would be naming a gesture that is not the one coming.
    private let navigationTripleClickPhrases = [
        "三击这里！",
        "三击它！",
        "在这里三击！"
    ]

    /// For an arrival where the answer is in the element's context menu, tagged [RIGHTCLICK:...].
    /// The wording is here for the same reason as the double-click pool: the gestures look identical
    /// until they happen, so the bubble is the only thing saying which button is about to go down.
    private let navigationRightClickPhrases = [
        "右键这里！",
        "右键点它！",
        "在这里点右键！"
    ]

    /// For an arrival where the answer is past the edge of what is on screen, tagged [SCROLLUP:...]
    /// and its three siblings. One pool per direction for the same reason the two press pools are
    /// separate: the four look identical on screen until the content moves, so the bubble is the only
    /// thing saying which way it is about to go. 「帮你往下滚！」 states the direction too, since a
    /// pool picked by the wrong branch would read as a scroll the user did not ask for.
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

    /// For an arrival that is the beginning of a movement rather than the whole gesture — a drag,
    /// tagged [DRAG:...]. The bubble says what is happening rather than where the pointer is, because
    /// a drag is not over when the cursor lands: the phrase stays up for the length of the carry.
    private let navigationDragPhrases = [
        "帮你拖过去！",
        "这就拖过去！",
        "拖着它走！"
    ]

    /// The phrase pool an arrival draws from, chosen by what the model's tag asked for.
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

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
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

            // Always in the view tree so the opacity animation works reliably; nothing is
            // visible without a player. allowsHitTesting(false) prevents it from taking clicks.
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
                // Drives the fade in both directions — the video fades out by this same
                // modifier — so this one duration is what both ends of the clip take, and
                // anything waiting on the fade-out has to wait this long.
                .animation(.easeInOut(duration: 1.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // The "按住 control + option 然后介绍你自己" prompt, streamed after the video ends.
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
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

            // Shown once the buddy arrives at a detected element: a scale-bounce from 0.5x
            // with a bright initial glow that settles.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
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

            // Blue triangle cursor — idle or responding. Following uses a spring; navigation must
            // carry no implicit animation, since the bezier timer drives the position at 60fps.
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
                // Taken and given back as a fade rather than a cut, so the pointer changing hands
                // reads as the buddy taking hold of it. Both moments happen while it is moving.
                .animation(
                    .easeInOut(duration: BlueCursorView.cursorClickColourFadeDuration),
                    value: isAboutToPerformAnAction
                )

            // Red record dot — replaces the triangle while the user's own actions are being recorded,
            // in the triangle's own place beside the pointer.
            Circle()
                .fill(DS.Colors.overlayCursorClickRed)
                .frame(width: 12, height: 12)
                .shadow(color: DS.Colors.overlayCursorClickRed, radius: 8, x: 0, y: 0)
                .opacity(buddyIsVisibleOnThisScreen && isRecordingWhatTheUserIsDoing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                isOnScreen: buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing.
            BlueCursorSpinnerView(
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
                x: swiftUIPosition.x + BlueCursorView.followingOffsetFromPointer.x,
                y: swiftUIPosition.y + BlueCursorView.followingOffsetFromPointer.y
            )

            startTrackingCursor()

            // Welcome only on first appearance, and only if the cursor starts on this screen.
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
            // Whether the overlay thinks it is holding the pointer and whether `PointerCarrier`
            // actually is are different questions, and the second is the one that matters: a view
            // that goes away while the pointer is detached leaves a mouse that nothing hands back.
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
                // Landing is this view's own doing and it has already finished. A view built after
                // the fact — a display change rebuilds them all — never gets here, since the
                // manager ends the visit before it rebuilds.
                break
            case .cursorWakingFromIcon:
                startWakingFromStatusItemIcon()
            }
        }
        // Keyed on the location alone, not on the target: the manager withdraws the press of a stop
        // the cursor is standing on without moving it, and a flight to the spot it never left would
        // be the result of watching the whole value.
        .onChange(of: companionManager.pointingTarget?.screenLocation) { _ in
            // Fly the buddy to the detected element so it points at it. Read as the target whole
            // rather than as the two fields the flight needs: a newer flight that landed between the
            // change and this callback is the one to fly, and the fields of one target are the only
            // answer that is internally consistent.
            guard let pointingTarget = companionManager.pointingTarget else { return }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: pointingTarget.displayFrame.midX, y: pointingTarget.displayFrame.midY))
                  || pointingTarget.displayFrame == screenFrame else {
                // The target is on another screen: a pointing tour moving between displays takes it
                // out from under this screen's buddy, which would otherwise stay parked in
                // `.pointingAtTarget` on an element no longer pointed at — and that mode is always
                // visible, so both screens would show a buddy.
                standDownNavigationForOtherScreen()
                return
            }

            startNavigatingToElement(screenLocation: pointingTarget.screenLocation)
        }
        // A drag is drawn rather than flown: the manager posts the movement step by step, and the view
        // that owns the display the drag is on follows it. Nothing else moves the triangle while that
        // runs — the flight that brought the cursor here is over, and its own arrival deliberately stays
        // open until the drag is done — so this is the only writer of `cursorPosition` during one.
        //
        // Only the view whose screen the drag is on: both ends of a drag are resolved against one
        // screenshot, so it never leaves that display, and a view on another display is hidden anyway.
        .onChange(of: companionManager.screenLocationOfTheDragInFlight) { dragScreenLocation in
            guard let dragScreenLocation, screenFrame.contains(dragScreenLocation) else { return }
            cursorPosition = convertScreenPointToSwiftUICoordinates(dragScreenLocation)
        }
        .onChange(of: companionManager.buddyReturnHomeRequestCount) { _ in
            // A count rather than the `shouldReturnBuddyToCursorAfterPointing` flag beside it: a tour
            // the user cut off writes `false` into a flag it never set to `true`, so an `.onChange` on
            // the flag saw no change and the buddy stayed frozen in `.pointingAtTarget` — a mode that
            // skips cursor tracking — for the rest of the session. A count cannot fail to change.
            guard buddyNavigationMode != .followingCursor else { return }
            startFlyingBackToCursor()
        }
    }

    /// Whether the buddy triangle should be visible on this screen: the cursor is here during
    /// following, or this is the screen navigating or pointing. While another screen is
    /// navigating the buddy is hidden here, so only one is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // Another screen's view is the one navigating — hide this one's to avoid a
            // duplicate buddy.
            if companionManager.pointingTarget != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget, .navigatingToStatusItemIcon,
             .wakingFromStatusItemIcon:
            return true
        case .mergedIntoStatusItemIcon:
            // It is not on the screen any more. It is the icon.
            return false
        }
    }

    // MARK: - Cursor Tracking

    /// Tracks the mouse for as long as the overlay is up, one timer per display. Both writes below
    /// are guarded on the value having changed: a `@State` write marks the view dirty whether or not
    /// the value differs, so an unguarded tick re-evaluates this whole body sixty times a second on
    /// every display with the mouse still.
    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            let isCursorNowOnThisScreen = self.screenFrame.contains(mouseLocation)
            if isCursorNowOnThisScreen != self.isCursorOnThisScreen {
                self.isCursorOnThisScreen = isCursorNowOnThisScreen
            }

            // Forward flight and pointing are not interrupted by mouse movement — they complete.
            // Only the return flight is cancelled by it, so the buddy snaps to following.
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
                x: swiftUIPosition.x + BlueCursorView.followingOffsetFromPointer.x,
                y: swiftUIPosition.y + BlueCursorView.followingOffsetFromPointer.y
            )
            if followedPosition != self.cursorPosition {
                self.cursorPosition = followedPosition
            }
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI coordinates (top-left
    /// origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    /// The other direction: a SwiftUI point in this overlay back to a macOS screen point. Needed
    /// because the buddy's position is only known in SwiftUI coordinates while the pointer and the
    /// click live in AppKit's, so carrying the mouse along an arc means converting every frame. The
    /// two are exact inverses: an error here offsets where the mouse and the click end up.
    private func convertSwiftUICoordinatesToScreenPoint(_ swiftUIPoint: CGPoint) -> CGPoint {
        let x = swiftUIPoint.x + screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - swiftUIPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // For as long as the cursor is in the icon's hands nothing may be flown anywhere — and this
        // is where every such request arrives: a tour stop, the onboarding demo's own triggers, a
        // fresh tag on a reply. While it is in the icon there is no cursor to send; while it is on
        // its way back out there is one, but it is already flying somewhere.
        guard !companionManager.isNotTakingInputBecauseOfTheStatusItemIcon else { return }

        // Don't interrupt welcome animation. Nothing is going to fly, so anything the
        // pointer is being held for is not going to happen either.
        guard !showWelcome || welcomeText.isEmpty else {
            releaseTheUsersPointerIfHoldingIt()
            return
        }

        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Place the triangle so its tip — not the center of its 16×16 frame — lands on the element,
        // by offsetting the frame by the negative of the tip's own offset.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x - BlueCursorView.triangleTipOffsetFromFrameCenter.x,
            y: targetInSwiftUI.y - BlueCursorView.triangleTipOffsetFromFrameCenter.y
        )

        // Clamp to the screen bounds, so the arc's endpoint stays on this display.
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Recorded so a mouse move large enough to cancel the return flight can be detected.
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        // What this flight does was decided by the manager before it published the location, and it
        // is two questions rather than one. A stop Kiki is only going to point at is a plain arc and
        // stays blue; a stop it is going to act on turns red on the way, and then the action's own
        // answer decides whether the user's pointer comes along.
        guard companionManager.pointingTarget?.actionToPerformOnArrival != nil else {
            // The run, if there was one, ends here: this stop will not be acted on, so the pointer
            // goes back to the user before the flight rather than after it.
            releaseTheUsersPointerIfHoldingIt()
            animateBezierFlightArc(to: clampedTarget) {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.startPointingAtElement()
            }
            return
        }

        // Asked rather than assumed, so that an action which genuinely needs nothing carried has
        // one place to say so. Both kinds say yes today, a scroll for a reason of its own —
        // `carriesTheUsersPointer` has it.
        guard companionManager.pointingTarget?.actionToPerformOnArrival?.carriesTheUsersPointer ?? false
        else {
            // Red, but the pointer stays where it is: nothing about this action is waiting on the
            // pointer, and the user is free to keep using it while Kiki works.
            animateBezierFlightArc(to: clampedTarget) {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.startPointingAtElement()
            }
            return
        }

        if isHoldingTheUsersPointerForTheAction {
            // Already holding it from the stop before: no flight out to the pointer and nothing to
            // fade in, just on to the next element with the mouse still in hand. This is what makes
            // a run of presses read as one gesture.
            carryTheMouseAlongAnArc(to: clampedTarget, endingOn: screenLocation)
        } else {
            // The colour starts turning as the flight leaves rather than when it lands, so the grab
            // lands on a triangle already plainly red. Nothing is held yet: for the whole of this
            // leg the mouse is still the user's, and the red means "about to", not "already".
            isHoldingTheUsersPointerForTheAction = true
            flyToWhereTheUsersPointerIsStanding {
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.carryTheMouseAlongAnArc(to: clampedTarget, endingOn: screenLocation)
            }
        }
    }

    /// Flies the buddy to wherever the user's pointer happens to be, the first leg of a
    /// pointer-carrying run: the buddy goes to the mouse, and only then does the mouse move with it.
    /// A pointer on another display is the one case with nothing to fly to — the arc cannot leave
    /// this window — so the grab that follows warps it here instead.
    private func flyToWhereTheUsersPointerIsStanding(then onArrival: @escaping () -> Void) {
        let mouseLocation = NSEvent.mouseLocation
        guard screenFrame.contains(mouseLocation) else {
            onArrival()
            return
        }

        // The pointer itself, not the spot the buddy parks in while following it: aiming this leg at
        // the offset position would aim it where the buddy already stands and draw as a pause.
        // Landing on the pointer is what this leg is for.
        let pointerInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)

        animateBezierFlightArc(
            to: pointerInSwiftUI,
            durationRange: BlueCursorView.pointerCarryingFlightDuration
        ) {
            onArrival()
        }
    }

    /// Carries the user's pointer along the arc the buddy is about to fly: the pointer is taken and
    /// the arc begins in the same breath, so the fade to red, the grab and the start of the movement
    /// are one moment. Taking hold always warps the pointer under the cursor rather than flying to it,
    /// which recovers a pointer pushed aside during a dwell and one on another display alike.
    ///
    /// `endingOn` is where the pointer is left, deliberately not the arc's own destination: the arc
    /// lands the *frame centre* on a target clamped inside the screen's edges, while the click is
    /// posted on the element itself, and an app that hit-tests against the pointer would act on a
    /// neighbour.
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
            durationRange: BlueCursorView.pointerCarryingFlightDuration,
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

    /// Puts the pointer where the buddy currently is — the per-frame half of a carry.
    private func moveThePointerUnder(swiftUIPosition: CGPoint) {
        PointerCarrier.carryThePointer(
            toAppKitScreenLocation: convertSwiftUICoordinatesToScreenPoint(swiftUIPosition),
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Gives the pointer back to the user, fading the colour back as it goes.
    ///
    /// Idempotent, because every teardown path calls it and they overlap. It must never leave the
    /// pointer detached — nothing in the system hands it back on its own.
    private func releaseTheUsersPointerIfHoldingIt() {
        guard isHoldingTheUsersPointerForTheAction else { return }
        isHoldingTheUsersPointerForTheAction = false

        // Handed back now, while the colour takes its own quarter of a second to leave: the red is
        // the cursor's own state and fades out over the journey home, but the pointer is the user's
        // again the moment the run is over — and that journey is a leg they may be moving the mouse
        // through, which a delayed hand-back would be dragging around behind them.
        PointerCarrier.releaseThePointer(
            atAppKitScreenLocation: NSEvent.mouseLocation,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
    }

    /// Animates the buddy along a quadratic bezier arc to the destination. The triangle rotates to
    /// face its direction of travel each frame, scales up at the midpoint, and the glow intensifies.
    ///
    /// The two optional parameters are for the pointer-carrying flights: `durationRange` lets a
    /// carrying leg be quicker so two still fit inside the arrival timeout, and `onEachFrame` keeps
    /// the pointer under the cursor. The last frame deliberately does not call it — that branch snaps
    /// the buddy onto its destination, where a carrying caller places the pointer instead.
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

        // Flight duration scales with distance, clamped to the caller's range.
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

            // Quadratic bezier.
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

            // Scale pulse, peaking at the midpoint of the flight.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy scale-in entrance and
    /// variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Back to the resting angle now that we have arrived, which is the orientation
        // `triangleTipOffsetFromFrameCenter` describes.
        triangleRotationDegrees = BlueCursorView.restingTriangleRotationDegrees

        // Starts small for the scale-bounce entrance.
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // A pointing tour keeps the buddy on the element until the narration has finished with it,
        // so the hold-and-return below is skipped: this arrival releases the narration, and the next
        // stop's flight replaces this bubble when it lands.
        let isPointingTourStop = companionManager.isPointingTourActive
        if isPointingTourStop {
            // The narration may have run out while this flight was in the air, in which case there
            // is nothing left to point at and the buddy goes home.
            if companionManager.shouldReturnBuddyToCursorAfterPointing {
                startFlyingBackToCursor()
                return
            }
            // This is where the press is posted and where the manager works out whether another
            // one follows it — asked of the manager rather than tracked here, because only it
            // knows what the tour has left.
            companionManager.buddyDidArriveAtPointingTarget()
        }

        // The pointer is deliberately *not* handed back on arrival: the cursor stays red while it
        // dwells on the element it has just pressed, and the red is the whole of what says the mouse
        // is not the user's yet. The hand-back belongs to the two moments a run really ends — the
        // flight home, and the next flight that is not going to press anything.

        // Custom bubble text from the manager (the onboarding demo) if there is one, otherwise a
        // random phrase from the pool for the invitation the model's tag carried. The default is
        // the pool for a plain look, which is what an arrival with nothing behind it is.
        let pointerPhrase = companionManager.pointingTarget?.bubbleText
            ?? phrases(for: companionManager.pointingTarget?.bubbleInvitation ?? .lookAtElement)
                .randomElement()
            ?? "就在这儿！"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            guard !isPointingTourStop else { return }
            // All characters streamed — hold, then fly back.
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

    /// Streams the navigation bubble text one character at a time with variable delays
    /// (30–60ms) for a natural "speaking" rhythm.
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

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        // The pointer is given back before the flight rather than after it, so the colour fades
        // back over the journey home — and because the flight ends with the buddy following the
        // pointer again, which it cannot do while holding it.
        releaseTheUsersPointerIfHoldingIt()

        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(
            x: cursorInSwiftUI.x + BlueCursorView.followingOffsetFromPointer.x,
            y: cursorInSwiftUI.y + BlueCursorView.followingOffsetFromPointer.y
        )

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        resetBuddyToFollowingMode()
        companionManager.clearDetectedElementLocation()
    }

    /// Parks this screen's buddy back into cursor-following because the target it was flying to or
    /// pointing at belongs to another screen — what a pointing tour does when it moves between
    /// displays. The manager's target is deliberately left alone: the other screen's buddy is using
    /// it, and clearing it here would strand that flight.
    private func standDownNavigationForOtherScreen() {
        guard buddyNavigationMode != .followingCursor else { return }
        resetBuddyToFollowingMode()
    }

    /// Drops the navigation animation state without touching the manager's target. All three ways a
    /// navigation can end arrive here — completing, being cancelled by the user moving the pointer,
    /// and standing down for another display — so this is where the pointer is handed back: a run cut
    /// off partway has no arrival of its own to release it.
    private func resetBuddyToFollowingMode() {
        releaseTheUsersPointerIfHoldingIt()
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = BlueCursorView.restingTriangleRotationDegrees
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
    }

    // MARK: - Visiting The Status Item Icon

    /// Flies the buddy to the menu bar icon the pointer was left resting on.
    ///
    /// Only the view whose screen holds the icon flies, the same match on screen frame the pointing
    /// tour uses: the icon sits in one display's menu bar, and every other screen's view is happily
    /// following the pointer and has nothing to merge into.
    private func startMergingIntoStatusItemIcon(iconScreenFrame: CGRect) {
        let iconCentreOnScreen = CGPoint(x: iconScreenFrame.midX, y: iconScreenFrame.midY)
        guard screenFrame.contains(iconCentreOnScreen) else { return }

        // The icon's centre, with neither the triangle-tip offset nor the screen-edge clamp that
        // `startNavigatingToElement` applies: this is a landing on the icon itself rather than a tip
        // resting on an element, and the clamp's 20pt margin would hold the buddy a whole margin
        // below the menu bar, short of the icon it is meant to disappear into.
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(iconCentreOnScreen)

        buddyNavigationMode = .navigatingToStatusItemIcon
        isReturningToCursor = false

        animateBezierFlightArc(to: targetInSwiftUI) {
            guard self.buddyNavigationMode == .navigatingToStatusItemIcon else { return }
            self.settleIntoStatusItemIcon()
        }
    }

    /// Landed: the manager is told, so the icon can take on the cursor's colour, and the cursor
    /// itself fades out where it stands.
    private func settleIntoStatusItemIcon() {
        buddyNavigationMode = .mergedIntoStatusItemIcon
        triangleRotationDegrees = BlueCursorView.restingTriangleRotationDegrees
        companionManager.cursorDidLandOnStatusItemIcon()

        withAnimation(.easeOut(duration: 0.3)) {
            self.cursorOpacity = 0.0
        }
    }

    /// Comes back out where it stands, for the two cases the manager ends a visit by itself — the
    /// overlay going away, and a display change rebuilding this view. It is a recovery rather than
    /// the waking gesture: no flight, just the cursor back beside the pointer and following it.
    private func resumeFollowingFromStatusItemIcon() {
        guard buddyNavigationMode == .mergedIntoStatusItemIcon
                || buddyNavigationMode == .navigatingToStatusItemIcon
                || buddyNavigationMode == .wakingFromStatusItemIcon else { return }

        resetBuddyToFollowingMode()

        withAnimation(.easeOut(duration: 0.3)) {
            self.cursorOpacity = 1.0
        }
    }

    /// The waking flight: fade in where the cursor disappeared, fly to the position beside the
    /// pointer it would have been following from, and hand it back to following on landing.
    ///
    /// Only the view that flew into the icon has anything to bring out — every other screen's view
    /// has been following the pointer throughout.
    private func startWakingFromStatusItemIcon() {
        guard buddyNavigationMode == .mergedIntoStatusItemIcon else { return }

        // Where the pointer is now, not where it was when the waking wait began: the flight was
        // committed a moment ago and the standing position is defined relative to the pointer, so
        // the cursor lands beside wherever the user has got to.
        let pointerInSwiftUI = convertScreenPointToSwiftUICoordinates(NSEvent.mouseLocation)
        let standingPosition = CGPoint(
            x: pointerInSwiftUI.x + BlueCursorView.followingOffsetFromPointer.x,
            y: pointerInSwiftUI.y + BlueCursorView.followingOffsetFromPointer.y
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
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
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

// MARK: - Blue Cursor Waveform

/// The blue waveform that replaces the triangle cursor while the user holds push-to-talk and speaks.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    /// Whether the waveform is the shape actually being drawn on this screen.
    ///
    /// The timeline is paused when it is not: a `TimelineView` keeps to its schedule whatever its
    /// `opacity` is, so this view — which cross-fades with the triangle rather than being inserted and
    /// removed — re-evaluated its body and committed a full-screen transparent window to the render
    /// server 36 times a second per display for as long as the app ran. Bar heights come from the
    /// timeline's date, so unpausing resumes mid-phase.
    let isOnScreen: Bool

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0, paused: !isOnScreen)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
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

// MARK: - Blue Cursor Spinner

/// The blue spinner that replaces the triangle cursor while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    /// Whether the spinner is the shape actually being drawn on this screen.
    ///
    /// The timeline is paused when it is not. The rotation cannot be a `repeatForever` animation:
    /// `rotationEffect` is *animatable*, so the interpolation is SwiftUI's own rather than
    /// CoreAnimation's — every frame the attribute graph recomputed the animator and committed a
    /// transaction, on a view permanently in the tree that had no idea whether it could be seen.
    /// There is one per display. The angle comes from the timeline's date, so unpausing resumes
    /// mid-turn.
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
                            DS.Colors.overlayCursorBlue.opacity(0.0),
                            DS.Colors.overlayCursorBlue
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotationDegrees(at: timelineContext.date)))
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
        }
    }

    /// Where the turn has got to at a given moment, in degrees. Taken from the absolute time rather
    /// than a frame count, so pausing is a break in the drawing rather than a jump.
    private func rotationDegrees(at timelineDate: Date) -> Double {
        let secondsIntoTheTurn = timelineDate.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: rotationPeriodSeconds)
        return secondsIntoTheTurn / rotationPeriodSeconds * 360.0
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    /// The overlay window covering each display, keyed by display ID. Keyed on the ID rather than
    /// kept in a flat array because a display change has to tell "already covered" apart from "new",
    /// and the display ID is the only thing about a screen that survives a re-plug — the `NSScreen`
    /// instance does not.
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

    /// Rebuilds the overlay to match the current display configuration — a monitor plugged in,
    /// unplugged, resized, or moved.
    ///
    /// Overlay windows are otherwise built only when the overlay is shown, so a display connected
    /// while the app is running would never get one: no cursor, no waveform or bubble, and no view to
    /// receive a pointing animation aimed at that screen.
    ///
    /// A screen still connected with an unchanged frame keeps its window, so a change does not restart
    /// the other screens' flights or the onboarding video, and a repeated call is harmless.
    func refreshOverlaysForDisplayConfigurationChange(
        onScreens screens: [NSScreen],
        companionManager: CompanionManager
    ) {
        let connectedDisplayIDs = Set(screens.map { $0.displayID })

        // Displays that are gone lose their window. Clearing the content view is what runs the
        // hosted view's `onDisappear`, which is where the pointer is released.
        let disconnectedDisplayIDs = overlayWindowsByDisplayID.keys.filter { !connectedDisplayIDs.contains($0) }
        for displayID in disconnectedDisplayIDs {
            guard let window = overlayWindowsByDisplayID.removeValue(forKey: displayID) else { continue }
            window.orderOut(nil)
            window.contentView = nil
        }

        for screen in screens {
            // Already covered by a window of the right size — leave it alone.
            if let existingWindow = overlayWindowsByDisplayID[screen.displayID],
               existingWindow.frame == screen.frame {
                continue
            }

            // Either a display never covered, or one resized or moved. The hosted view bakes in
            // this screen's frame when it is built, so both cases need a fresh window.
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

    /// Builds the overlay window covering one screen. Shared by the initial show and the rebuild
    /// after a display change so the two can't drift apart.
    private func makeOverlayWindow(
        for screen: NSScreen,
        isFirstAppearance: Bool,
        companionManager: CompanionManager
    ) -> OverlayWindow {
        let window = OverlayWindow(screen: screen)

        let contentView = BlueCursorView(
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

    /// Fades out overlay windows over `duration` seconds, then removes them.
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

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays inside SwiftUI. The custom
/// NSView subclass keeps the player layer sized to the view's bounds.
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
