//
//  DesignSystem.swift
//  kiki-desktop-agent
//
//  Design system: a purple accent palette on light surfaces, plus the shared button styles.

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Hover and pressed step darker, never lighter — the direction that reads as "under the
        // finger" on a light surface.

        /// The panel's plate — everything else sits on it.
        static let background = Color(hex: "#F1F1F5")

        /// Cards and raised rows.
        static let surface1 = Color(hex: "#FFFFFF")

        /// Recessed fills, such as input fields.
        static let surface2 = Color(hex: "#F7F7FA")

        /// Hover backgrounds on interactive elements.
        static let surface3 = Color(hex: "#E9E9EF")

        /// Active/pressed states on interactive elements.
        static let surface4 = Color(hex: "#DFDFE7")

        // ── Borders ──────────────────────────────────────────────────

        /// Card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#D9D9E1")

        /// Focused inputs, hovered card outlines.
        static let borderStrong = Color(hex: "#B9B9C5")

        // ── Text ─────────────────────────────────────────────────────

        /// Body text, titles, headings.
        static let textPrimary = Color(hex: "#1B1B1F")

        /// Descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#55555E")

        /// Section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#7E7E88")

        /// On top of the accent fill, like the primary button's label.
        static let textOnAccent: Color = .white

        // ── Purple Scale ────────────────────────────────────────────
        // Built around the purple the cursor already wears (#bd79ff). 50–200 tinted backgrounds,
        // 300–400 cursor and lighter accents, 500–700 fills and accent text, 800–950 deep surfaces.

        static let purple50  = Color(hex: "#f8f4ff")
        static let purple100 = Color(hex: "#f1e7ff")
        static let purple200 = Color(hex: "#e3ceff")
        static let purple300 = Color(hex: "#d2acff")
        static let purple400 = Color(hex: "#bd79ff")
        static let purple500 = Color(hex: "#a855f7")
        static let purple600 = Color(hex: "#9333ea")
        static let purple700 = Color(hex: "#8f46eb")
        static let purple800 = Color(hex: "#7b34d9")
        static let purple900 = Color(hex: "#6326b0")
        static let purple950 = Color(hex: "#3c1870")

        // ── Accent (derived from the purple scale) ──────────────────

        /// Accent fill — solid button backgrounds. #8f46eb on white text is ~5.0:1 (WCAG AA).
        static let accent = purple700

        /// Accent hover — #7b34d9 on white text is ~6.3:1 (WCAG AA+).
        static let accentHover = purple800

        /// Accent-colored text, icons and status dots on light backgrounds.
        static let accentText = purple600

        /// Selected backgrounds, such as the card holding the task in progress.
        static let accentSubtle = purple500.opacity(0.10)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages.
        static let destructive = Color(hex: "#D93A3F")

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#C02F34")

        /// Destructive for text — darker than the fill, for contrast on light backgrounds.
        static let destructiveText = Color(hex: "#C2262B")

        /// Success — checkmarks, granted status, completion indicators; a green of its own, never the
        /// accent.
        static let success = Color(hex: "#0A7452")

        /// Warning — caution messages, failed-verification explanations.
        static let warning = Color(hex: "#9C5D00")

        /// Warning for text — darker, for light backgrounds.
        static let warningText = Color(hex: "#8A5200")

        /// Info/feature highlight — prompt card headers, code highlights; a blue rather than the
        /// purple, so informational elements stay distinct from accent-colored ones.
        static let info = Color(hex: "#1D6FD0")

        /// Monospace code snippets.
        static let codeText = Color(hex: "#7C3AED")

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The cursor/bubble color used in OverlayWindow — the triangle, the waveform bars, the
        /// spinner's arc and the bubble fills. A token of its own: it is the screen overlay's colour,
        /// and what the app icon draws.
        static let overlayCursorPurple = Color(hex: "#BD79FF")

        /// The color the cursor turns while it is carrying the user's mouse to a click.
        ///
        /// Not decoration and not an error colour: it is the whole of how the user is told the
        /// pointer in their hand is Kiki's. One colour, one meaning, which is why the bubble fills
        /// below avoid it.
        static let overlayCursorClickRed = Color(hex: "#FF878D")

        // ── Overlay Response Bubble ──────────────────────────────────
        // The bubble stays dark while the panel goes light: it is read over whatever is on screen,
        // not on the panel's plate, and dark holds up over both a white window and a black terminal.

        /// The bubble's fill.
        static let responseBubbleBackground = Color(hex: "#171918")

        /// The reply's own text.
        static let responseBubbleText = Color(hex: "#ECEEED")

        /// The bubble's hairline outline.
        static let responseBubbleBorder = Color(hex: "#373B39")

        // ── Floating Button Gradient ─────────────────────────────────

        /// Outside the palette, so the floating button reads as a jewel on the desktop.
        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────

        /// User bubble in the help chat. Purple 900 — deep enough for white text.
        static let helpChatUserBubble = purple900

        /// Hover/pressed variant of the user bubble.
        static let helpChatUserBubbleHover = purple800

        /// Footer behind the floating help chat — a step greyer than the panel's plate, so the chat
        /// zone reads as a docked surface.
        static let helpChatBackdrop = Color(hex: "#E9E9EF")

        // ── Disabled State ───────────────────────────────────────────
        // Material Design 3's disabled pattern: container at 12% onSurface, content at 38%.

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Content reveal, button state changes.
        static let normal: Double = 0.25
        /// Fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Material Design 3's state-layer system: the button's content color, overlaid at these opacities.

    enum StateLayer {
        /// Hover — indicates interactivity.
        static let hover: Double = 0.08
        /// Focus — keyboard navigation; slightly stronger than hover.
        static let focus: Double = 0.12
        /// Pressed — same strength as focus.
        static let pressed: Double = 0.12
        /// Dragged — strongest.
        static let dragged: Double = 0.16
    }
}

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen: accent fill, white text, one per view.
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    // Kept separate so the scale animates on a slower timeline (0.6s) than the background snap.
    @State private var isHoverScaleExpanded = false

    // Builds up gradually (0.6s) on hover entry, fades out faster (0.3s) on exit.
    @State private var isHoverGlowActive = false

    // Toggles while hovered to drive a breathing pulse in the glow shadow.
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            // The breathing oscillates opacity and radius on a slow 2.5s loop.
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHoverScaleExpanded ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                // Fast snap, so the colour change feels responsive.
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverScaleExpanded = hovering
                }

                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    // A finite animation overrides the repeating one, so it stops cleanly.
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions: surface fill, primary text.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — transparent at rest, surface fill on hover.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — no background in any state, not even hover; only the text colour changes.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, where a border helps define the button's bounds.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — dangerous/irreversible actions: red-tinted, intensifying on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circle for utility actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Where the tooltip sits horizontally: `.leading` near a window's left edge, `.trailing` near
    /// its right, else `.center`.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor rects, not NSCursor.push/pop: window-managed, so no conflict with SwiftUI's
            // own cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show after a delay, like a native tooltip; hide immediately.
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Above the button so it does not overlap, aligned by tooltipAlignment so it cannot clip
            // at a window edge, hit testing off so it never disturbs hover.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// The shared pointing-hand cursor; disabled controls keep the arrow.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Buddy Composer Visual Style

enum BuddyComposerVisualStyle {
    static let waveformLeadingColor = Color(hex: "#F3FBFF")
    static let waveformTrailingColor = Color(hex: "#8FD2FF")
    static let waveformGlowColor = Color(hex: "#AEE3FF")
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// AppKit's cursor rect system for a pointing hand. More reliable than NSCursor.push()/pop() in
/// .onHover: cursor rects are managed at the window level and never conflict with SwiftUI.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects so AppKit recalculates them after a resize.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// The same cursor-rect approach as PointerCursorView, for an I-beam. Unlike NSCursor.push()/pop()
/// in .onHover, it cannot leave the cursor stack unbalanced when the mouse moves quickly between
/// views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Passes mouse events through so the TextField underneath still receives focus, clicks and
    /// selection; the cursor rects are registered with the window and work independently of hit
    /// testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects so AppKit recalculates them after a resize.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Bridges to AppKit's `NSView.toolTip`, because SwiftUI's `.help()` conflicts with `.onHover`
/// tracking areas.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// From a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// This color blended toward white; `fraction` runs 0.0 (unchanged) to 1.0 (white).
    func blendedWithWhite(fraction: Double) -> Color {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
