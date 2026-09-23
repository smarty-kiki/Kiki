//
//  CompanionScreenCaptureUtility.swift
//  kiki-desktop-agent
//
//  Standalone screenshot capture for the companion voice flow.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect

    /// The size of the screenshot in `imageData`, in pixels.
    ///
    /// These are the denominator of the whole conversion: the model reads a coordinate off
    /// the image, and it is scaled from these down to the display's size in points.
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// The queue the JPEG encode runs on.
    ///
    /// Pure data work, but the type is `@MainActor`, so it was on the main thread by
    /// association — tens of milliseconds per display, landing in the window where the overlay
    /// animates the waveform away and the spinner in. Concurrent, one encode per display.
    private static let jpegEncodingQueue = DispatchQueue(
        label: "com.smarty.kiki.screenshot-jpeg-encoding",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// JPEG data for a captured image, encoded off the main actor.
    private static func encodedJPEGData(
        from capturedImage: CGImage,
        compressionQuality: CGFloat
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            jpegEncodingQueue.async {
                continuation.resume(returning: NSBitmapImageRep(cgImage: capturedImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]))
            }
        }
    }

    /// Captures every connected display as JPEG data, labeled with whether the cursor is on it.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude this app's own windows so the model sees the user's content, not our overlays.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // NSEvent.mouseLocation and NSScreen.frame are AppKit coordinates (bottom-left origin)
        // while SCDisplay.frame is Core Graphics (top-left). On multi-display setups the Y
        // origins differ for secondary displays, which breaks cursor-contains checks.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // NSScreen.frame, so displayFrame shares a coordinate system with
            // NSEvent.mouseLocation and the overlay's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            // Read off the image, not from `configuration.width`/`height`, which state what
            // was *requested* and are the same only if ScreenCaptureKit honours the request.
            // Every coordinate the model reports is scaled by these two numbers, so a
            // disagreement tells the model a coordinate space its image does not have.
            let capturedWidthInPixels = cgImage.width
            let capturedHeightInPixels = cgImage.height
            if capturedWidthInPixels != configuration.width
                || capturedHeightInPixels != configuration.height {
                // Worth a line rather than silence: an ignored request is invisible otherwise.
                print("⚠️ Screenshot is \(capturedWidthInPixels)x\(capturedHeightInPixels) "
                    + "but \(configuration.width)x\(configuration.height) was requested")
            }

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: capturedWidthInPixels,
                screenshotHeightInPixels: capturedHeightInPixels
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
