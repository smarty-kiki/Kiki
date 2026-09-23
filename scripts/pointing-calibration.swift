//
//  pointing-calibration.swift
//  Kiki
//
//  Measures how accurately DeepSeek reads pixel coordinates off a Kiki
//  screenshot, and says what kind of error the pointing pipeline is actually
//  suffering from.
//
//  Why this exists: the cursor's flight ends wherever the model said the element
//  was, so any error in the model's reading is what the user feels as "the cursor
//  lands off to one side". Everything the app does with those numbers is exact —
//  scale from image pixels to display points, flip from top-left to AppKit's
//  bottom-left origin, add the display's origin — which leaves two candidates:
//  the model's own estimation noise, or a scale error introduced if DeepSeek
//  downscales the image internally before the model ever sees it. Those two need
//  opposite fixes (snapping to the real element vs. multiplying the coordinate),
//  and the fit printed at the end is what tells them apart.
//
//  How it measures: it renders a 1280x800 image — the exact size
//  `CompanionScreenCaptureUtility` produces for a 1440x900-point display — with
//  nine lettered tiles at known pixel coordinates, encodes it as JPEG at the same
//  0.8 quality the app uses, and sends it to DeepSeek with the same image label,
//  the same coordinate-space convention and the same pointing instructions the app
//  uses. Each answer is matched back to its tile by letter, so every row of the
//  table is one true coordinate next to the model's reading of it.
//
//  Usage:
//      swiftc -O scripts/pointing-calibration.swift -o /tmp/pointing-calibration
//      /tmp/pointing-calibration
//
//  Options:
//      --image-size WxH      screenshot size to test (default 1280x800)
//      --display-points WxH  display size it stands for (default 1440x900)
//      --model ID            DeepSeek model (default deepseek-flash)
//      --keep-image PATH     where to write the rendered JPEG (default /tmp/…)
//
//  The API key is read from DEEPSEEK_API_KEY, or from the same Keychain item the
//  app stores it in. Reading it from the Keychain makes macOS ask for permission
//  the first time; "Always Allow" keeps it to a single prompt.
//

import AppKit
import Foundation
import Security

// MARK: - Calibration markers

/// One lettered tile: where it really is, and (once the model has answered)
/// where the model said it was.
struct CalibrationMarker {
    let letter: String
    /// The tile's center in the screenshot's own pixel space — top-left origin,
    /// which is the space the model is asked to report in.
    let truePixelCoordinate: CGPoint
    var reportedPixelCoordinate: CGPoint?
}

/// The lettered tiles to render, spread over the frame so the fit below has
/// something to work with: the outer ring is what makes a scale error visible
/// (it shows up as error that grows with distance from the origin) while the
/// center point separates a scale error from a constant offset.
private let tileLettersByPosition = [
    ["A", "B", "C"],
    ["D", "E", "F"],
    ["G", "H", "I"],
]

private let tileHorizontalFractions: [CGFloat] = [0.03, 0.5, 0.97]
private let tileVerticalFractions: [CGFloat] = [0.05, 0.5, 0.95]

/// Edge length of one tile, in screenshot pixels. Big enough that the model can
/// see it clearly at this resolution, small enough that "the tile's center" is an
/// unambiguous point rather than a region.
private let tileEdgeLengthInPixels: CGFloat = 46

// MARK: - The prompt

/// The element-pointing section of `companionVoiceResponseSystemPrompt`, copied
/// verbatim from `CompanionManager.swift`.
///
/// Copied rather than imported because this script is compiled on its own
/// (`swiftc … scripts/pointing-calibration.swift`) and cannot reach into the app
/// target. That means it can drift: if the pointing instructions in
/// `CompanionManager.swift` change, this block has to be re-copied or the numbers
/// it prints describe a prompt the app no longer sends.
private let pointingInstructionsCopiedFromCompanionManager = """
element pointing:
you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

when you point, write the coordinate tag right after the sentence that mentions the element, so the cursor can land on it exactly while you are talking about it. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). the tag and the label inside it ALWAYS stay in english even though your spoken text is chinese — that part is parsed by code and never read aloud.
"""

/// The question asked of the model: one tag per tile, nothing else, so the reply
/// is nothing but coordinates and the letters that identify them.
private let calibrationUserPrompt = """
这是一张测试图。图中有九个方块，每个里面有一个大写字母，从左上到右下依次是 A 到 I。请为每一个方块写一个 [POINT:x,y:label] 标签，label 就写方块里的那个字母，x,y 是方块中心在这张图里的像素坐标。除了这九个标签，什么都不要写。
"""

// MARK: - Realistic-UI calibration

/// The grid test above measures something narrower than it looks. It tells the
/// model where a tile *is* — "中心在这张图里的像素坐标" — and asks it to read that
/// point back, which it does almost perfectly. Real pointing never works that
/// way: the model has to recognize an element on its own and decide, with no
/// instruction, which point of it to report. On a 240-pixel-wide search field,
/// "the center" and "the left edge where the magnifier sits" are 120 pixels
/// apart, and nothing in the app's prompt says which one it wants.
///
/// That difference is invisible to the grid test by construction, so this mode
/// closes it: a mock macOS screen with four named widgets at known rectangles,
/// asked about one widget at a time in the plain language a user would use. Each
/// answer is then compared against the widget's center, its bounds, and its
/// corners, which is what separates "the model points at elements accurately"
/// from "the model points at a consistent corner of them".
private enum MockUILayout {
    static let menuBarHeight: CGFloat = 24
    static let windowRect = CGRect(x: 160, y: 60, width: 960, height: 680)
    static let sidebarWidth: CGFloat = 180
    static let toolbarHeight: CGFloat = 48

    /// The four widgets the questions below ask about. Wide-and-short rectangles
    /// dominate real interfaces, and they are the shape that turns a corner
    /// convention into a large horizontal miss, so three of the four are that
    /// shape and the sidebar is deliberately tall to give the vertical axis the
    /// same chance to show one.
    static let searchFieldRect = CGRect(x: 470, y: 106, width: 240, height: 28)
    static let shareButtonRect = CGRect(x: 950, y: 680, width: 140, height: 34)
    static let settingsRowRect = CGRect(x: 168, y: 232, width: 164, height: 32)
    static var sidebarRect: CGRect {
        CGRect(x: windowRect.minX, y: windowRect.minY + 32,
               width: sidebarWidth, height: windowRect.height - 32)
    }
}

/// One widget of the mock screen, plus the question that asks for it.
struct RealisticUIElement {
    let name: String
    /// What a user would actually type to be pointed at this thing — no
    /// coordinate hint of any kind, because supplying one would put the test
    /// back where the grid test already is.
    let question: String
    /// The widget's full bounds in the screenshot's pixel space, top-left origin.
    let trueRectInPixels: CGRect
    var reportedPixelCoordinate: CGPoint?

    var centerInPixels: CGPoint {
        CGPoint(x: trueRectInPixels.midX, y: trueRectInPixels.midY)
    }
}

private func makeRealisticUIElements() -> [RealisticUIElement] {
    [
        RealisticUIElement(name: "搜索框", question: "搜索框在哪里？",
                           trueRectInPixels: MockUILayout.searchFieldRect),
        RealisticUIElement(name: "分享按钮", question: "分享按钮在哪里？",
                           trueRectInPixels: MockUILayout.shareButtonRect),
        RealisticUIElement(name: "设置", question: "设置在哪里？",
                           trueRectInPixels: MockUILayout.settingsRowRect),
        RealisticUIElement(name: "侧边栏", question: "侧边栏在哪里？",
                           trueRectInPixels: MockUILayout.sidebarRect),
    ]
}

// MARK: - Rendering

/// Draws the calibration screenshot, in the same pixel format and JPEG quality
/// `CompanionScreenCaptureUtility` produces.
///
/// The pieces are placed in the model's own coordinate space — top-left origin —
/// and converted to the bottom-left origin this context draws in by
/// `bottomLeftY(forTopLeftY:)` at the moment of drawing. That conversion is the
/// harness's one chance to be wrong in a way that would make every number it
/// prints meaningless, so it lives in one place rather than being folded into
/// each `NSRect`.
///
/// The context is deliberately left unflipped. A flipped `NSGraphicsContext`
/// draws AppKit text mirrored — the tiles land in the right places but every
/// letter comes out upside down, which the model would then read as a different
/// letter and the run would silently be garbage.
private func renderCalibrationScreenshot(
    imageWidthInPixels: Int,
    imageHeightInPixels: Int,
    markers: [CalibrationMarker]
) -> CGImage? {
    guard let bitmapContext = CGContext(
        data: nil,
        width: imageWidthInPixels,
        height: imageHeightInPixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        return nil
    }

    func bottomLeftY(forTopLeftY topLeftY: CGFloat) -> CGFloat {
        CGFloat(imageHeightInPixels) - topLeftY
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let imageBounds = NSRect(x: 0, y: 0, width: imageWidthInPixels, height: imageHeightInPixels)

    // A plain desktop with a menu bar strip across the top. The tiles alone would
    // calibrate just as well, but a blank page does not look like a screenshot,
    // and the point is to measure the model's reading of a screen — not of a
    // diagram it might approach differently.
    NSColor(white: 0.93, alpha: 1).setFill()
    imageBounds.fill()
    NSColor(white: 0.85, alpha: 1).setFill()
    NSRect(x: 0, y: bottomLeftY(forTopLeftY: 24), width: imageBounds.width, height: 24).fill()

    for marker in markers {
        let tileCenterY = bottomLeftY(forTopLeftY: marker.truePixelCoordinate.y)
        let tileRect = NSRect(
            x: marker.truePixelCoordinate.x - tileEdgeLengthInPixels / 2,
            y: tileCenterY - tileEdgeLengthInPixels / 2,
            width: tileEdgeLengthInPixels,
            height: tileEdgeLengthInPixels
        )

        NSColor(srgbRed: 0.18, green: 0.44, blue: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: tileRect, xRadius: 6, yRadius: 6).fill()

        let letterText = NSAttributedString(string: marker.letter, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 26),
            .foregroundColor: NSColor.white,
        ])
        let letterSize = letterText.size()
        letterText.draw(at: NSPoint(
            x: tileRect.midX - letterSize.width / 2,
            y: tileCenterY - letterSize.height / 2
        ))
    }

    return bitmapContext.makeImage()
}

private func encodeAsJPEG(_ cgImage: CGImage) -> Data? {
    // Same encoding the app uses for its captures, so the model is looking at an
    // image that has been through the same compression.
    NSBitmapImageRep(cgImage: cgImage)
        .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
}

/// Draws a mock macOS screen: a desktop, a menu bar, and a window with a
/// sidebar, a toolbar holding a search field, a content list and a button.
///
/// Every widget is drawn from `MockUILayout`, which the element list also quotes,
/// so a widget cannot end up somewhere other than where the results table says it
/// is. The layout is in the model's own coordinate space — top-left origin — and
/// converted at the moment of drawing by `convert`, for the same reason the grid
/// renderer keeps one `bottomLeftY(forTopLeftY:)` rather than folding the flip
/// into each rectangle. The context is deliberately unflipped: a flipped one
/// draws AppKit text mirrored, which the model would read as different words.
private func renderRealisticUIScreenshot(
    imageWidthInPixels: Int,
    imageHeightInPixels: Int
) -> CGImage? {
    guard let bitmapContext = CGContext(
        data: nil,
        width: imageWidthInPixels,
        height: imageHeightInPixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        return nil
    }

    func bottomLeftY(forTopLeftY topLeftY: CGFloat) -> CGFloat {
        CGFloat(imageHeightInPixels) - topLeftY
    }

    /// Converts a top-left-origin rectangle into the bottom-left-origin one this
    /// context draws in.
    func convert(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: bottomLeftY(forTopLeftY: rect.maxY),
               width: rect.width, height: rect.height)
    }

    func drawText(_ text: String, atTopLeft point: CGPoint, size: CGFloat, color: NSColor) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]).draw(at: NSPoint(x: point.x, y: bottomLeftY(forTopLeftY: point.y + size * 1.2)))
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let window = MockUILayout.windowRect
    let titleBarHeight: CGFloat = 32
    let contentLeft = window.minX + MockUILayout.sidebarWidth
    let contentTop = window.minY + titleBarHeight
    let toolbarBottom = contentTop + MockUILayout.toolbarHeight

    // Desktop
    NSColor(srgbRed: 0.16, green: 0.19, blue: 0.25, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: imageWidthInPixels, height: imageHeightInPixels).fill()

    // Menu bar
    NSColor(white: 0.94, alpha: 1).setFill()
    NSRect(x: 0, y: bottomLeftY(forTopLeftY: MockUILayout.menuBarHeight),
           width: CGFloat(imageWidthInPixels), height: MockUILayout.menuBarHeight).fill()
    drawText("Finder", atTopLeft: CGPoint(x: 24, y: 4), size: 13, color: .black)
    drawText("File", atTopLeft: CGPoint(x: 100, y: 4), size: 13, color: .black)
    drawText("Edit", atTopLeft: CGPoint(x: 150, y: 4), size: 13, color: .black)
    drawText("View", atTopLeft: CGPoint(x: 200, y: 4), size: 13, color: .black)

    // Window body
    NSColor.white.setFill()
    NSBezierPath(roundedRect: convert(window), xRadius: 10, yRadius: 10).fill()

    // Title bar
    NSColor(white: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: convert(CGRect(x: window.minX, y: window.minY,
                                             width: window.width, height: titleBarHeight)),
                 xRadius: 10, yRadius: 10).fill()
    for (trafficLightIndex, tint) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        tint.setFill()
        NSBezierPath(ovalIn: convert(CGRect(x: window.minX + 16 + CGFloat(trafficLightIndex) * 20,
                                            y: window.minY + 11, width: 11, height: 11))).fill()
    }

    // Sidebar
    NSColor(white: 0.96, alpha: 1).setFill()
    convert(MockUILayout.sidebarRect).fill()
    drawText("设置", atTopLeft: CGPoint(x: MockUILayout.settingsRowRect.minX + 8,
                                        y: MockUILayout.settingsRowRect.minY + 8),
             size: 13, color: .darkGray)
    drawText("账户", atTopLeft: CGPoint(x: MockUILayout.settingsRowRect.minX + 8, y: 180),
             size: 13, color: .darkGray)
    drawText("通知", atTopLeft: CGPoint(x: MockUILayout.settingsRowRect.minX + 8, y: 280),
             size: 13, color: .darkGray)
    drawText("通用", atTopLeft: CGPoint(x: MockUILayout.settingsRowRect.minX + 8, y: 330),
             size: 13, color: .darkGray)

    // Toolbar
    NSColor(white: 0.98, alpha: 1).setFill()
    convert(CGRect(x: contentLeft, y: contentTop,
                   width: window.maxX - contentLeft,
                   height: MockUILayout.toolbarHeight)).fill()

    // Search field: a rounded outline with a magnifier and placeholder text
    NSColor.white.setFill()
    NSBezierPath(roundedRect: convert(MockUILayout.searchFieldRect), xRadius: 6, yRadius: 6).fill()
    NSColor(white: 0.78, alpha: 1).setStroke()
    let searchFieldOutline = NSBezierPath(roundedRect: convert(MockUILayout.searchFieldRect),
                                          xRadius: 6, yRadius: 6)
    searchFieldOutline.lineWidth = 1
    searchFieldOutline.stroke()
    let magnifierRadius: CGFloat = 5
    let magnifierCenter = CGPoint(x: MockUILayout.searchFieldRect.minX + 14,
                                  y: MockUILayout.searchFieldRect.midY)
    NSColor(white: 0.55, alpha: 1).setStroke()
    let magnifier = NSBezierPath(ovalIn: convert(CGRect(
        x: magnifierCenter.x - magnifierRadius, y: magnifierCenter.y - magnifierRadius,
        width: magnifierRadius * 2, height: magnifierRadius * 2)))
    magnifier.lineWidth = 1.5
    magnifier.stroke()
    drawText("搜索", atTopLeft: CGPoint(x: MockUILayout.searchFieldRect.minX + 28,
                                        y: MockUILayout.searchFieldRect.minY + 7),
             size: 12, color: NSColor(white: 0.55, alpha: 1))

    // Content list
    for rowIndex in 0..<7 {
        let rowTop = toolbarBottom + 20 + CGFloat(rowIndex) * 52
        NSColor(white: 0.9, alpha: 1).setFill()
        convert(CGRect(x: contentLeft + 24, y: rowTop, width: 420, height: 10)).fill()
        NSColor(white: 0.95, alpha: 1).setFill()
        convert(CGRect(x: contentLeft + 24, y: rowTop + 20, width: 260, height: 8)).fill()
    }

    // Share button
    NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: convert(MockUILayout.shareButtonRect), xRadius: 7, yRadius: 7).fill()
    drawText("分享", atTopLeft: CGPoint(x: MockUILayout.shareButtonRect.midX - 14,
                                        y: MockUILayout.shareButtonRect.minY + 9),
             size: 13, color: .white)

    return bitmapContext.makeImage()
}

// MARK: - The request

/// Builds the marker list for a screenshot of this size.
private func makeCalibrationMarkers(imageWidthInPixels: Int, imageHeightInPixels: Int) -> [CalibrationMarker] {
    var markers: [CalibrationMarker] = []
    for (rowIndex, letterRow) in tileLettersByPosition.enumerated() {
        for (columnIndex, letter) in letterRow.enumerated() {
            markers.append(CalibrationMarker(
                letter: letter,
                truePixelCoordinate: CGPoint(
                    x: (CGFloat(imageWidthInPixels) * tileHorizontalFractions[columnIndex]).rounded(),
                    y: (CGFloat(imageHeightInPixels) * tileVerticalFractions[rowIndex]).rounded()
                )
            ))
        }
    }
    return markers
}

private func readAPIKey() throws -> String {
    if let environmentAPIKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
       !environmentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return environmentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The same service/account pair `DeepSeekAPIKeyStore` writes.
    let lookupQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.smarty.kiki",
        kSecAttrAccount as String: "deepseek-api-key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var keychainLookupResult: CFTypeRef?
    let lookupStatus = SecItemCopyMatching(lookupQuery as CFDictionary, &keychainLookupResult)
    guard lookupStatus == errSecSuccess,
          let apiKeyData = keychainLookupResult as? Data,
          let storedAPIKey = String(data: apiKeyData, encoding: .utf8),
          !storedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CalibrationError.missingAPIKey(status: lookupStatus)
    }
    return storedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
}

enum CalibrationError: LocalizedError {
    case missingAPIKey(status: OSStatus)
    case renderingFailed
    case encodingFailed
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let status):
            return """
            读不到 DeepSeek API Key（Keychain 状态 \(status)）。
            先在 Kiki 的设置面板里保存一个 key，或者用 DEEPSEEK_API_KEY=… 运行。
            """
        case .renderingFailed:
            return "渲染测试图失败。"
        case .encodingFailed:
            return "把测试图编码成 JPEG 失败。"
        case .badResponse(let detail):
            return "DeepSeek 返回了无法解析的响应：\(detail)"
        }
    }
}

/// Sends the image the way the app does — same endpoint, same `image_url` data
/// URL, same label carrying the image's pixel dimensions.
///
/// The one deliberate difference is `stream: false`: the app streams so it can
/// start speaking before the reply is finished, which a calibration run has no
/// use for, and a single JSON body is less to go wrong here. It does not change
/// what the model answers.
private func requestPointingCoordinates(
    imageData: Data,
    imageLabel: String,
    userPrompt: String,
    apiKey: String,
    model: String
) async throws -> String {
    guard let endpoint = URL(string: "https://api.deepseek.com/chat/completions") else {
        throw CalibrationError.badResponse("bad endpoint")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "model": model,
        // The app sends the model's full output ceiling so a long reply cannot
        // lose its trailing tag. Nine tags fit in a couple hundred tokens, and a
        // calibration reply is never long, so this is a small cap on purpose.
        "max_tokens": 2000,
        "stream": false,
        "messages": [
            ["role": "system", "content": pointingInstructionsCopiedFromCompanionManager],
            [
                "role": "user",
                "content": [
                    [
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"],
                    ],
                    ["type": "text", "text": imageLabel],
                    ["type": "text", "text": userPrompt],
                ],
            ],
        ],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (responseData, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw CalibrationError.badResponse("not an HTTP response")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
        let errorBody = String(data: responseData, encoding: .utf8) ?? ""
        throw CalibrationError.badResponse("HTTP \(httpResponse.statusCode): \(errorBody)")
    }
    guard let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          let choices = payload["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let content = message["content"] as? String else {
        throw CalibrationError.badResponse(String(data: responseData, encoding: .utf8) ?? "")
    }
    return content
}

// MARK: - Parsing

/// Pulls every `[POINT:x,y:label]` / `[CLICK:x,y:label]` tag out of a reply.
///
/// The pattern is the app's own, including the case-insensitive tag name, so a
/// tag this script can read is a tag the app can read. The label is allowed to
/// hold an ASCII colon for the reason the app's copy gives: the model is asked to
/// copy an element's on-screen text verbatim, and a timestamp in it is enough to
/// make the tag unmatchable if the label stops at the colon.
private func parsePointingTags(from responseText: String) -> [(coordinate: CGPoint, label: String?)] {
    let pattern = #"\[(?i:POINT|CLICK):(?:none|(\d+)\s*,\s*(\d+)(?::([^\]\s][^\]]*?))?(?::screen(\d+))?)\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

    let allTagMatches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
    return allTagMatches.compactMap { tagMatch in
        guard let xRange = Range(tagMatch.range(at: 1), in: responseText),
              let yRange = Range(tagMatch.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return nil
        }
        var label: String?
        if let labelRange = Range(tagMatch.range(at: 3), in: responseText) {
            label = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }
        return (coordinate: CGPoint(x: x, y: y), label: label)
    }
}

// MARK: - Statistics

/// Least-squares fit of `reported = scale × true + offset` for one axis.
///
/// This is the part that decides what to do about the error. A scale near 1 with
/// a small offset means the model's readings are unbiased and only noisy — no
/// formula can fix that. A scale that is consistently off (or an offset that is
/// consistently large) is a real, correctable distortion.
private func fitScaleAndOffset(
    samples: [(trueCoordinate: Double, reportedCoordinate: Double)]
) -> (scale: Double, offset: Double)? {
    guard samples.count >= 2 else { return nil }
    let trueMean = samples.reduce(0) { $0 + $1.trueCoordinate } / Double(samples.count)
    let reportedMean = samples.reduce(0) { $0 + $1.reportedCoordinate } / Double(samples.count)

    let covariance = samples.reduce(0) { $0 + ($1.trueCoordinate - trueMean) * ($1.reportedCoordinate - reportedMean) }
    let trueVariance = samples.reduce(0) { $0 + pow($1.trueCoordinate - trueMean, 2) }
    guard trueVariance > 0 else { return nil }

    let scale = covariance / trueVariance
    return (scale: scale, offset: reportedMean - scale * trueMean)
}

private func rootMeanSquareError(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
}

// MARK: - Entry point

private struct CalibrationOptions {
    var imageWidthInPixels = 1280
    var imageHeightInPixels = 800
    var displayWidthInPoints = 1440
    var displayHeightInPoints = 900
    var model = "deepseek-flash"
    var renderedImagePath = "/tmp/pointing-calibration-image.jpg"
    /// Stops after writing the image. The table below is only meaningful if the
    /// tiles on it really sit at the coordinates the script believes they do, so
    /// looking at the render first is worth the extra step.
    var renderOnly = false
    /// Measures the thing the grid test cannot: which point of an element the
    /// model picks when nothing told it where the element is.
    var realisticUI = false

    /// Points per screenshot pixel — the factor that turns a miss in the model's
    /// coordinate space into the miss the user sees on screen.
    var pointsPerPixel: Double {
        Double(displayWidthInPoints) / Double(imageWidthInPixels)
    }
}

private func parseSize(_ text: String) -> (Int, Int)? {
    let parts = text.lowercased().split(separator: "x")
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
    return (width, height)
}

private func parseOptions() -> CalibrationOptions {
    var options = CalibrationOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        let value = arguments.first
        switch argument {
        case "--image-size":
            if let value, let (width, height) = parseSize(value) {
                options.imageWidthInPixels = width
                options.imageHeightInPixels = height
                arguments.removeFirst()
            }
        case "--display-points":
            if let value, let (width, height) = parseSize(value) {
                options.displayWidthInPoints = width
                options.displayHeightInPoints = height
                arguments.removeFirst()
            }
        case "--model":
            if let value { options.model = value; arguments.removeFirst() }
        case "--keep-image":
            if let value { options.renderedImagePath = value; arguments.removeFirst() }
        case "--render-only":
            options.renderOnly = true
        case "--realistic":
            options.realisticUI = true
        default:
            break
        }
    }
    return options
}

/// Run from the top-level `await` at the bottom of this file, which is what lets
/// the script be compiled with a plain `swiftc file.swift` — `@main` would need
/// `-parse-as-library` alongside it.
private struct PointingCalibration {
    static func run() async {
        let options = parseOptions()
        print("""
        指向坐标校准
        测试图尺寸: \(options.imageWidthInPixels)x\(options.imageHeightInPixels) 像素（对应 \(options.displayWidthInPoints)x\(options.displayHeightInPoints) 点的屏幕）
        换算比例: 1 像素 = \(String(format: "%.4f", options.pointsPerPixel)) 点
        模型: \(options.model)
        """)

        if options.realisticUI {
            await runRealisticUI(options)
            return
        }

        var markers = makeCalibrationMarkers(
            imageWidthInPixels: options.imageWidthInPixels,
            imageHeightInPixels: options.imageHeightInPixels
        )

        guard let renderedImage = renderCalibrationScreenshot(
            imageWidthInPixels: options.imageWidthInPixels,
            imageHeightInPixels: options.imageHeightInPixels,
            markers: markers
        ) else {
            print("✗ 渲染失败")
            exit(1)
        }
        guard let jpegData = encodeAsJPEG(renderedImage) else {
            print("✗ JPEG 编码失败")
            exit(1)
        }
        try? jpegData.write(to: URL(fileURLWithPath: options.renderedImagePath))
        print("测试图已写入: \(options.renderedImagePath)（可以打开看一眼，方块位置就是下面表里的“真实像素”）\n")

        if options.renderOnly {
            for marker in markers {
                print(String(format: "%-5@  (%4d, %4d)", marker.letter,
                             Int(marker.truePixelCoordinate.x), Int(marker.truePixelCoordinate.y)))
            }
            return
        }

        let apiKey: String
        do {
            apiKey = try readAPIKey()
        } catch {
            print("✗ \(error.localizedDescription)")
            exit(1)
        }

        // The app's own label format, including the pixel dimensions the model is
        // told to use as its coordinate space.
        let imageLabel = "user's screen (cursor is here) (image dimensions: "
            + "\(options.imageWidthInPixels)x\(options.imageHeightInPixels) pixels)"

        let responseText: String
        do {
            responseText = try await requestPointingCoordinates(
                imageData: jpegData,
                imageLabel: imageLabel,
                userPrompt: calibrationUserPrompt,
                apiKey: apiKey,
                model: options.model
            )
        } catch {
            print("✗ 请求失败: \(error.localizedDescription)")
            exit(1)
        }

        print("模型原始回复:")
        print(responseText.trimmingCharacters(in: .whitespacesAndNewlines))
        print("")

        // Match answers to tiles by letter. Matching on the label rather than on
        // reply order means a model that lists the tiles in some other order
        // still gets each reading compared against the right tile.
        for tag in parsePointingTags(from: responseText) {
            guard let label = tag.label?.uppercased(),
                  let markerIndex = markers.firstIndex(where: { $0.letter == label }) else { continue }
            markers[markerIndex].reportedPixelCoordinate = tag.coordinate
        }

        let matchedMarkers = markers.filter { $0.reportedPixelCoordinate != nil }
        guard !matchedMarkers.isEmpty else {
            print("✗ 回复里没有能和方块对应上的 [POINT:…] 标签，无法校准。")
            exit(1)
        }

        let pointsPerPixel = options.pointsPerPixel
        print("字母   真实像素        模型读数        偏差(像素)      偏差(屏幕点)")
        for marker in markers {
            guard let reported = marker.reportedPixelCoordinate else {
                print(String(format: "%-5@  (%4d, %4d)       未匹配", marker.letter,
                             Int(marker.truePixelCoordinate.x), Int(marker.truePixelCoordinate.y)))
                continue
            }
            let deltaX = Double(reported.x - marker.truePixelCoordinate.x)
            let deltaY = Double(reported.y - marker.truePixelCoordinate.y)
            print(String(format: "%-5@  (%4d, %4d)     (%4d, %4d)     (%+6.1f, %+6.1f)   (%+6.1f, %+6.1f)",
                         marker.letter,
                         Int(marker.truePixelCoordinate.x), Int(marker.truePixelCoordinate.y),
                         Int(reported.x), Int(reported.y),
                         deltaX, deltaY,
                         deltaX * pointsPerPixel, deltaY * pointsPerPixel))
        }
        print("")

        let horizontalSamples = matchedMarkers.map {
            (trueCoordinate: Double($0.truePixelCoordinate.x),
             reportedCoordinate: Double($0.reportedPixelCoordinate!.x))
        }
        let verticalSamples = matchedMarkers.map {
            (trueCoordinate: Double($0.truePixelCoordinate.y),
             reportedCoordinate: Double($0.reportedPixelCoordinate!.y))
        }

        let horizontalResiduals = horizontalSamples.map { $0.reportedCoordinate - $0.trueCoordinate }
        let verticalResiduals = verticalSamples.map { $0.reportedCoordinate - $0.trueCoordinate }
        let horizontalErrorInPixels = rootMeanSquareError(horizontalResiduals)
        let verticalErrorInPixels = rootMeanSquareError(verticalResiduals)
        let worstErrorInPixels = matchedMarkers.map { marker -> Double in
            let reported = marker.reportedPixelCoordinate!
            return Double(hypot(reported.x - marker.truePixelCoordinate.x, reported.y - marker.truePixelCoordinate.y))
        }.max() ?? 0

        print("匹配成功: \(matchedMarkers.count)/\(markers.count) 个点位")
        print(String(format: "横向: 读数 = %.4f × 真实 %+.1f   RMS 误差 %.1f 像素 ≈ %.1f 点",
                     fitScaleAndOffset(samples: horizontalSamples)?.scale ?? .nan,
                     fitScaleAndOffset(samples: horizontalSamples)?.offset ?? .nan,
                     horizontalErrorInPixels, horizontalErrorInPixels * pointsPerPixel))
        print(String(format: "纵向: 读数 = %.4f × 真实 %+.1f   RMS 误差 %.1f 像素 ≈ %.1f 点",
                     fitScaleAndOffset(samples: verticalSamples)?.scale ?? .nan,
                     fitScaleAndOffset(samples: verticalSamples)?.offset ?? .nan,
                     verticalErrorInPixels, verticalErrorInPixels * pointsPerPixel))
        print(String(format: "最坏单点偏差: %.1f 像素 ≈ %.1f 点", worstErrorInPixels, worstErrorInPixels * pointsPerPixel))
        print("")

        print(verdict(
            horizontalFit: fitScaleAndOffset(samples: horizontalSamples),
            verticalFit: fitScaleAndOffset(samples: verticalSamples),
            horizontalErrorInPixels: horizontalErrorInPixels,
            verticalErrorInPixels: verticalErrorInPixels,
            worstErrorInPixels: worstErrorInPixels,
            pointsPerPixel: pointsPerPixel
        ))
    }

    /// Asks about one widget at a time, so a reply's single tag belongs to the
    /// question that was asked and never has to be matched by label or by order.
    private static func runRealisticUI(_ options: CalibrationOptions) async {
        var elements = makeRealisticUIElements()

        guard let renderedImage = renderRealisticUIScreenshot(
            imageWidthInPixels: options.imageWidthInPixels,
            imageHeightInPixels: options.imageHeightInPixels
        ) else {
            print("✗ 渲染失败")
            exit(1)
        }
        guard let jpegData = encodeAsJPEG(renderedImage) else {
            print("✗ JPEG 编码失败")
            exit(1)
        }
        try? jpegData.write(to: URL(fileURLWithPath: options.renderedImagePath))
        print("测试图已写入: \(options.renderedImagePath)（打开看一眼，下面每个元素的矩形就是它在该图里的位置）\n")

        if options.renderOnly {
            for element in elements {
                let rect = element.trueRectInPixels
                print(String(format: "%-8@ 矩形 (%4d, %4d, %4d×%4d)",
                             element.name, Int(rect.minX), Int(rect.minY),
                             Int(rect.width), Int(rect.height)))
            }
            return
        }

        let apiKey: String
        do {
            apiKey = try readAPIKey()
        } catch {
            print("✗ \(error.localizedDescription)")
            exit(1)
        }

        let imageLabel = "user's screen (cursor is here) (image dimensions: "
            + "\(options.imageWidthInPixels)x\(options.imageHeightInPixels) pixels)"

        for (elementIndex, element) in elements.enumerated() {
            let responseText: String
            do {
                responseText = try await requestPointingCoordinates(
                    imageData: jpegData,
                    imageLabel: imageLabel,
                    userPrompt: element.question,
                    apiKey: apiKey,
                    model: options.model
                )
            } catch {
                print("✗ 「\(element.question)」请求失败: \(error.localizedDescription)")
                continue
            }
            print("问: \(element.question)")
            print("答: \(responseText.trimmingCharacters(in: .whitespacesAndNewlines))\n")

            if let firstTag = parsePointingTags(from: responseText).first {
                elements[elementIndex].reportedPixelCoordinate = firstTag.coordinate
            }
        }

        reportRealisticUIResults(elements: elements, pointsPerPixel: options.pointsPerPixel)
    }

    private static func reportRealisticUIResults(
        elements: [RealisticUIElement],
        pointsPerPixel: Double
    ) {
        let answered = elements.filter { $0.reportedPixelCoordinate != nil }
        guard !answered.isEmpty else {
            print("✗ 没有一条回复里带可解析的 [POINT:…] 标签，无法判断。")
            exit(1)
        }

        print("元素      真实矩形                     中心           模型读数        距中心(像素)   距中心(点)   落在矩形内")
        var offsetsFromCenter: [(x: Double, y: Double)] = []
        var insideCount = 0
        for element in elements {
            guard let reported = element.reportedPixelCoordinate else {
                print(String(format: "%-8@  未获得坐标", element.name))
                continue
            }
            let center = element.centerInPixels
            let rect = element.trueRectInPixels
            let deltaX = Double(reported.x - center.x)
            let deltaY = Double(reported.y - center.y)
            offsetsFromCenter.append((x: deltaX, y: deltaY))

            let isInside = reported.x >= rect.minX && reported.x <= rect.maxX
                && reported.y >= rect.minY && reported.y <= rect.maxY
            if isInside { insideCount += 1 }

            print(String(format: "%-8@  (%4d, %4d, %4d×%4d)   (%4d, %4d)   (%4d, %4d)   (%+6.1f, %+5.1f)  (%+6.1f, %+5.1f)   %@",
                         element.name,
                         Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height),
                         Int(center.x), Int(center.y),
                         Int(reported.x), Int(reported.y),
                         deltaX, deltaY,
                         deltaX * pointsPerPixel, deltaY * pointsPerPixel,
                         isInside ? "是" : "否"))
        }
        print("")

        let meanOffsetX = offsetsFromCenter.reduce(0) { $0 + $1.x } / Double(offsetsFromCenter.count)
        let meanOffsetY = offsetsFromCenter.reduce(0) { $0 + $1.y } / Double(offsetsFromCenter.count)
        let meanDistanceInPoints = offsetsFromCenter
            .map { hypot($0.x, $0.y) * pointsPerPixel }
            .reduce(0, +) / Double(offsetsFromCenter.count)

        print(String(format: "落点全部落在元素矩形内: %d/%d 个", insideCount, elements.count))
        print(String(format: "相对元素中心的平均偏差: (%+.1f, %+.1f) 像素 = (%+.1f, %+.1f) 点",
                     meanOffsetX, meanOffsetY,
                     meanOffsetX * pointsPerPixel, meanOffsetY * pointsPerPixel))
        print(String(format: "平均偏离元素中心: %.1f 点", meanDistanceInPoints))
        print("")

        var lines = ["结论:"]

        // The grid test's noise floor on this same model is about 2 points, so an
        // offset well past that is not estimation noise — it is a convention the
        // model is applying, and it will reproduce on every element of that shape.
        let meanOffsetInPoints = hypot(meanOffsetX, meanOffsetY) * pointsPerPixel
        if insideCount == elements.count && meanOffsetInPoints < 5 {
            lines.append(String(format: "· 模型认得元素、也落在元素里，平均只偏离中心 %.1f 点。"
                                + "指向本身是准的，用户感觉到的偏移不在这一步。", meanOffsetInPoints))
        } else if insideCount == elements.count {
            lines.append(String(format: "· 每条都落在元素矩形内，但平均偏离中心 %.1f 点，方向一致 —— "
                                + "模型在按自己的习惯取点（例如总取元素左上角、或总取文字起始处），"
                                + "宽而扁的元素上这个偏差主要落在横向。", meanOffsetInPoints))
            lines.append("  这类偏差在提示词里说清「报元素正中心」就能收掉，页面本来就该指向中心。")
        } else {
            lines.append(String(format: "· 有 %d/%d 个落点跑到元素矩形外面了，平均偏离中心 %.1f 点。",
                                elements.count - insideCount, elements.count, meanOffsetInPoints))
            lines.append("  这已经不是「取哪个点」的问题，是模型对元素边界的判断本身有偏差；"
                         + "对照左边的表看是整块偏，还是只有某一类元素偏。")
        }

        lines.append("· 与九宫格模式对照着看：那个模式给的是模型读坐标的噪声下限，")
        lines.append("  这个模式给的是它在真实界面上自己挑点时多偏 —— 两个数不一样，用户感觉到的是后者。")
        print(lines.joined(separator: "\n"))
    }

    /// Turns the numbers into the one thing the table cannot say by itself:
    /// whether the error is correctable by arithmetic or has to be fixed by
    /// snapping to the element.
    private static func verdict(
        horizontalFit: (scale: Double, offset: Double)?,
        verticalFit: (scale: Double, offset: Double)?,
        horizontalErrorInPixels: Double,
        verticalErrorInPixels: Double,
        worstErrorInPixels: Double,
        pointsPerPixel: Double
    ) -> String {
        guard let horizontalFit, let verticalFit else {
            return "样本太少，无法判断。"
        }

        var lines: [String] = ["结论:"]
        let horizontalScaleIsOff = abs(horizontalFit.scale - 1) > 0.02
        let verticalScaleIsOff = abs(verticalFit.scale - 1) > 0.02

        if horizontalScaleIsOff || verticalScaleIsOff {
            lines.append(String(
                format: "· 读数有系统性缩放：横向 %.4f、纵向 %.4f。模型报的坐标整体被压缩（或拉伸）了约 %.1f%%，"
                    + "和“DeepSeek 内部把图片缩小后再让模型按小图坐标回答”的猜测一致。",
                horizontalFit.scale, verticalFit.scale,
                abs(1 - (horizontalFit.scale + verticalFit.scale) / 2) * 100
            ))
            lines.append(String(
                format: "  抵消办法：把上报坐标除以这个系数（横 %.4f、纵 %.4f）即可，一行乘法。",
                horizontalFit.scale, verticalFit.scale
            ))
        } else {
            lines.append(String(
                format: "· 读数没有系统性缩放（横向 %.4f、纵向 %.4f 都接近 1），偏移 %.1f / %.1f 像素。"
                    + "也就是说模型的读数是「无偏但有噪声」，误差不会随距离变大。",
                horizontalFit.scale, verticalFit.scale, horizontalFit.offset, verticalFit.offset))
        }

        if abs(horizontalFit.offset) > 8 || abs(verticalFit.offset) > 8 {
            lines.append(String(
                format: "· 另有固定偏移（横 %+.1f、纵 %+.1f 像素），可以一并减掉，但它的量级通常小于随机误差。",
                horizontalFit.offset, verticalFit.offset
            ))
        }

        let typicalErrorInPoints = (horizontalErrorInPixels + verticalErrorInPixels) / 2 * pointsPerPixel
        let worstErrorInPoints = worstErrorInPixels * pointsPerPixel
        lines.append(String(
            format: "· 随机误差是主要成分：平均约 %.0f 点，最坏 %.0f 点。在 1440×900 的屏幕上，"
                + "这意味着落在小按钮（20–40 点宽）上大概率会偏出去一点，落在大面板上没问题。",
            typicalErrorInPoints, worstErrorInPoints
        ))
        lines.append("· 这类随机误差没法用公式消掉，只能靠落点吸附到真实控件（辅助功能 API 取元素边框）"
            + "或者给截图加刻度让模型有参照物。")
        return lines.joined(separator: "\n")
    }
}

await PointingCalibration.run()
