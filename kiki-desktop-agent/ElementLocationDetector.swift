//
//  ElementLocationDetector.swift
//  kiki-desktop-agent
//
//  Uses Claude's Computer Use API to identify the screen location of UI elements in
//  screenshots, so the buddy can animate to the element a user asks about and point at it.
//

import AppKit
import Foundation

/// Detects the screen location of UI elements in screenshots using Claude's Computer Use API,
/// whose tool definition activates Claude's specialized pixel-counting training.
class ElementLocationDetector {
    private let apiKey: String
    private let apiURL: URL
    private let model: String
    private let session: URLSession

    /// Anthropic-recommended resolutions for Computer Use, paired with their aspect ratios. Higher
    /// resolutions get downsampled by the API and degrade precision, so these are intentionally small.
    private static let supportedComputerUseResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768,  1024.0 / 768.0),  // 4:3   = 1.333 (legacy displays)
        (1280, 800,  1280.0 / 800.0),  // 16:10  = 1.600 (MacBook Air, MacBook Pro, most Macs)
        (1366, 768,  1366.0 / 768.0)   // ~16:9  = 1.779 (external monitors, ultrawide fallback)
    ]

    init(apiKey: String, model: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Detects the screen location of a UI element the user is asking about.
    ///
    /// - Parameters:
    ///   - screenshotData: JPEG or PNG screenshot data from ScreenCaptureKit
    ///   - userQuestion: The user's voice transcript (e.g., "How do I add a project?")
    ///   - displayWidthInPoints: The captured display's width in screen points
    ///   - displayHeightInPoints: The captured display's height in screen points
    ///
    /// - Returns: A `CGPoint` in display-local macOS coordinates (bottom-left origin) if an
    ///   element was identified, or `nil` if no element was found or detection failed.
    func detectElementLocation(
        screenshotData: Data,
        userQuestion: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        // The resolution closest to this display's aspect ratio, so the image Claude sees is not
        // stretched — distortion degrades X-axis accuracy most.
        let computerUseResolution = bestComputerUseResolution(
            forDisplayWidth: displayWidthInPoints,
            displayHeight: displayHeightInPoints
        )

        print("🎯 ElementLocationDetector: display is \(displayWidthInPoints)x\(displayHeightInPoints) " +
              "(ratio \(String(format: "%.3f", Double(displayWidthInPoints) / Double(displayHeightInPoints)))), " +
              "using Computer Use resolution \(computerUseResolution.width)x\(computerUseResolution.height)")

        guard let resizedScreenshotData = resizeScreenshotForComputerUse(
            originalImageData: screenshotData,
            targetWidth: computerUseResolution.width,
            targetHeight: computerUseResolution.height
        ) else {
            print("⚠️ ElementLocationDetector: failed to resize screenshot")
            return nil
        }

        guard let computerUseCoordinate = await callComputerUseAPI(
            resizedScreenshotData: resizedScreenshotData,
            userQuestion: userQuestion,
            declaredDisplayWidth: computerUseResolution.width,
            declaredDisplayHeight: computerUseResolution.height
        ) else {
            return nil
        }

        // Claude occasionally returns values slightly outside the declared display dimensions.
        let clampedX = max(0, min(computerUseCoordinate.x, CGFloat(computerUseResolution.width)))
        let clampedY = max(0, min(computerUseCoordinate.y, CGFloat(computerUseResolution.height)))

        let scaledX = (clampedX / CGFloat(computerUseResolution.width)) * CGFloat(displayWidthInPoints)
        let scaledYTopLeftOrigin = (clampedY / CGFloat(computerUseResolution.height)) * CGFloat(displayHeightInPoints)

        // Computer Use reports a top-left origin, AppKit and the cursor overlay use bottom-left.
        let scaledYBottomLeftOrigin = CGFloat(displayHeightInPoints) - scaledYTopLeftOrigin

        print("🎯 ElementLocationDetector: mapped (\(Int(clampedX)), \(Int(clampedY))) in " +
              "\(computerUseResolution.width)x\(computerUseResolution.height) → " +
              "(\(Int(scaledX)), \(Int(scaledYBottomLeftOrigin))) in " +
              "\(displayWidthInPoints)x\(displayHeightInPoints) display-local AppKit coords")

        return CGPoint(x: scaledX, y: scaledYBottomLeftOrigin)
    }

    // MARK: - Private Helpers

    /// Picks the recommended Computer Use resolution whose aspect ratio is closest to the display's.
    private func bestComputerUseResolution(
        forDisplayWidth displayWidth: Int,
        displayHeight: Int
    ) -> (width: Int, height: Int) {
        let displayAspectRatio = Double(displayWidth) / Double(max(1, displayHeight))

        var bestWidth = 1280
        var bestHeight = 800
        var smallestAspectRatioDifference = Double.greatestFiniteMagnitude

        for resolution in Self.supportedComputerUseResolutions {
            let difference = abs(displayAspectRatio - resolution.aspectRatio)
            if difference < smallestAspectRatioDifference {
                smallestAspectRatioDifference = difference
                bestWidth = resolution.width
                bestHeight = resolution.height
            }
        }

        return (width: bestWidth, height: bestHeight)
    }

    /// Calls the Claude Computer Use API with a resized screenshot and user question.
    /// Returns the raw coordinate from Claude's response in the declared resolution space, or nil.
    private func callComputerUseAPI(
        resizedScreenshotData: Data,
        userQuestion: String,
        declaredDisplayWidth: Int,
        declaredDisplayHeight: Int
    ) async -> CGPoint? {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The beta header is what activates Computer Use and its pixel-counting training.
        request.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")

        let mediaType = detectImageMediaType(for: resizedScreenshotData)
        let base64Screenshot = resizedScreenshotData.base64EncodedString()

        let userPrompt = """
        The user asked this question while looking at their screen: "\(userQuestion)"

        Look at the screenshot. If there is a specific UI element (button, link, menu item, text field, icon, etc.) that the user should interact with or is asking about, click on that element.

        If the question is purely conceptual (e.g., "what does HTML mean?") and there's no specific element to point to, just respond with text saying "no specific element".
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "tools": [
                [
                    "type": "computer_20251124",
                    "name": "computer",
                    "display_width_px": declaredDisplayWidth,
                    "display_height_px": declaredDisplayHeight
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Screenshot
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userPrompt
                        ]
                    ]
                ]
            ]
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData

            let payloadMB = Double(bodyData.count) / 1_048_576.0
            print("🎯 ElementLocationDetector: sending \(String(format: "%.1f", payloadMB))MB request " +
                  "(declared \(declaredDisplayWidth)x\(declaredDisplayHeight))")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                print("⚠️ ElementLocationDetector: API error \(statusCode): \(errorBody.prefix(200))")
                return nil
            }

            return parseCoordinateFromResponse(data: data)

        } catch {
            print("⚠️ ElementLocationDetector: request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses the Computer Use API response to extract click coordinates: Claude returns a `tool_use`
    /// content block with `{"action": "left_click", "coordinate": [x, y]}`, or text when it found no
    /// element, which returns nil.
    private func parseCoordinateFromResponse(data: Data) -> CGPoint? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
            print("⚠️ ElementLocationDetector: could not parse response JSON")
            return nil
        }

        for block in contentBlocks {
            guard let blockType = block["type"] as? String,
                  blockType == "tool_use",
                  let input = block["input"] as? [String: Any],
                  let coordinate = input["coordinate"] as? [NSNumber],
                  coordinate.count == 2 else {
                continue
            }

            let x = CGFloat(coordinate[0].doubleValue)
            let y = CGFloat(coordinate[1].doubleValue)
            print("🎯 ElementLocationDetector: raw coordinate (\(Int(x)), \(Int(y)))")
            return CGPoint(x: x, y: y)
        }

        print("🎯 ElementLocationDetector: no specific element detected (conceptual question)")
        return nil
    }

    /// Resizes screenshot data to the specified Computer Use resolution.
    ///
    /// Uses `NSBitmapImageRep` rather than `NSImage.lockFocus()`, which on a Retina display creates a
    /// bitmap at 2× the declared size — a JPEG twice as large as the resolution declared to the
    /// Computer Use tool, and coordinates reported in the wrong scale.
    private func resizeScreenshotForComputerUse(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        // Point size matching the pixel dimensions, so nothing is scaled on the way in.
        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }

        return jpegData
    }

    /// Detects MIME type by inspecting the first bytes of image data.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }
}
