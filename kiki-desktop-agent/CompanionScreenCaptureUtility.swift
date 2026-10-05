//
//  CompanionScreenCaptureUtility.swift
//  kiki-desktop-agent
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

    /// The screenshot's size in pixels — the denominator of the whole coordinate conversion, from
    /// what the model reads off the image to the display's points.
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// The queue the JPEG encode runs on: pure data work, but the type is `@MainActor`, so it would
    /// otherwise run on the main thread — tens of milliseconds per display, while the overlay
    /// animates.
    private static let jpegEncodingQueue = DispatchQueue(
        label: "com.smarty.kiki.screenshot-jpeg-encoding",
        qos: .userInitiated,
        attributes: .concurrent
    )

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

    /// The directory every screenshot is written to, when `KIKI_SAVE_CAPTURES` names one — a
    /// diagnostic switch: the picture a reply was written against is gone by the next capture, so a
    /// click that landed wrong cannot be explained without it.
    private static let directoryToSaveCapturesIn = ProcessInfo.processInfo.environment["KIKI_SAVE_CAPTURES"]

    /// Writes the saved screenshots in the order they were taken; serial and off the main actor
    /// for the reasons the encode is.
    private static let captureSavingQueue = DispatchQueue(
        label: "com.smarty.kiki.screenshot-saving",
        qos: .utility
    )

    private static var captureSequenceNumber = 0

    private static func saveCaptureIfAsked(
        _ jpegData: Data,
        screenNumber: Int,
        widthInPixels: Int,
        heightInPixels: Int
    ) {
        guard let directoryToSaveCapturesIn else { return }

        captureSequenceNumber += 1
        let sequenceNumberText = String(format: "%02d", captureSequenceNumber)
        let filePath = "\(directoryToSaveCapturesIn)/capture-\(sequenceNumberText)-screen\(screenNumber).jpg"

        captureSavingQueue.async {
            try? FileManager.default.createDirectory(
                atPath: directoryToSaveCapturesIn,
                withIntermediateDirectories: true
            )
            try? jpegData.write(to: URL(fileURLWithPath: filePath))
        }
        print("Screenshot \(sequenceNumberText) screen \(screenNumber) "
            + "(\(widthInPixels)x\(heightInPixels)) → \(filePath)")
    }

    /// How long the app keeps looking for the screen to stop changing before it looks anyway; bounded
    /// because a video, a spinner or a progress bar is still moving when the model needs to see it.
    private static let millisecondsToWaitForTheScreenToSettle = 2500

    private static let millisecondsBetweenSettleChecks = 250

    /// Captures every connected display once the screen has stopped changing.
    ///
    /// A posted event returns long before the app receiving it has redrawn, so a capture taken
    /// straight away shows the screen *before* kiki's own last click and the model answers from
    /// elements that are gone. Two captures matching byte for byte answer "has the screen finished
    /// reacting"; the later of the pair is the one sent.
    static func captureAllScreensAsJPEGOnceTheScreenHasSettled() async throws -> [CompanionScreenCapture] {
        var capturedScreens = try await captureAllScreensAsJPEG(savingCaptures: false)
        var millisecondsWaited = 0

        while millisecondsWaited < millisecondsToWaitForTheScreenToSettle {
            try await Task.sleep(for: .milliseconds(millisecondsBetweenSettleChecks))
            millisecondsWaited += millisecondsBetweenSettleChecks

            let recapturedScreens = try await captureAllScreensAsJPEG(savingCaptures: false)
            let hasTheScreenStoppedChanging = recapturedScreens.map(\.imageData)
                == capturedScreens.map(\.imageData)
            capturedScreens = recapturedScreens

            if hasTheScreenStoppedChanging { break }
            // Otherwise the delay is unexplained from outside the app.
            print("Screen still changing \(millisecondsWaited)ms in — waiting for it to settle")
        }

        // Saved on its way out: only the picture the model is sent belongs in the diagnostic record.
        for (displayIndex, screenCapture) in capturedScreens.enumerated() {
            saveCaptureIfAsked(
                screenCapture.imageData,
                screenNumber: displayIndex + 1,
                widthInPixels: screenCapture.screenshotWidthInPixels,
                heightInPixels: screenCapture.screenshotHeightInPixels
            )
        }

        return capturedScreens
    }

    /// Captures every connected display as JPEG data, labeled with whether the cursor is on it.
    ///
    /// `savingCaptures` is off for the settle checks, throwaways that would otherwise double the
    /// diagnostic record and renumber the entries that matter.
    static func captureAllScreensAsJPEG(savingCaptures: Bool = true) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude this app's own windows so the model sees the user's content.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // AppKit frames rather than SCDisplay.frame: NSEvent.mouseLocation is AppKit (bottom-left
        // origin) while SCDisplay.frame is Core Graphics (top-left).
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is first
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
            // NSScreen.frame, so displayFrame shares the mouse's coordinate system.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            // The pointer is deliberately left out: a screenshot is taken when the pointer is kiki's
            // own puppet, resting on the very label the app must read back and drawn *over* it — a
            // label an arrow crosses can vanish, and the click falls back to the model's estimate.
            configuration.showsCursor = false
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

            // Read off the image, not from `configuration.width`/`height`, which state what was
            // *requested*: every coordinate the model reports is scaled by these, so a disagreement
            // would describe a coordinate space its image does not have.
            let capturedWidthInPixels = cgImage.width
            let capturedHeightInPixels = cgImage.height
            if capturedWidthInPixels != configuration.width
                || capturedHeightInPixels != configuration.height {
                // Worth a line: an ignored request is invisible otherwise.
                print("Screenshot is \(capturedWidthInPixels)x\(capturedHeightInPixels) "
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

            if savingCaptures {
                saveCaptureIfAsked(
                    jpegData,
                    screenNumber: displayIndex + 1,
                    widthInPixels: capturedWidthInPixels,
                    heightInPixels: capturedHeightInPixels
                )
            }
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
