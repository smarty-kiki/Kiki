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

    /// The directory every screenshot is written to, when `KIKI_SAVE_CAPTURES` names one.
    ///
    /// A diagnostic switch, unset in normal use. The picture a reply was written against is gone
    /// the moment the next step captures over it, so a click that landed on the wrong occurrence —
    /// or on nothing at all — cannot be explained after the fact without it.
    private static let directoryToSaveCapturesIn = ProcessInfo.processInfo.environment["KIKI_SAVE_CAPTURES"]

    /// Writes the saved screenshots, in the order they were taken.
    ///
    /// Serial and off the main actor for the reasons the encode is: the write is tens of
    /// milliseconds and the overlay animates while it happens, and a run of captures read back as
    /// a timeline is worth more than the writes overlapped are.
    private static let captureSavingQueue = DispatchQueue(
        label: "com.smarty.kiki.screenshot-saving",
        qos: .utility
    )

    /// Numbers the saved screenshots so a log line and a file can be matched up.
    private static var captureSequenceNumber = 0

    /// Writes one screenshot out, and prints where it went so a log line can be matched to a file.
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
        print("🖼️ Screenshot \(sequenceNumberText) screen \(screenNumber) "
            + "(\(widthInPixels)x\(heightInPixels)) → \(filePath)")
    }

    /// How long the app keeps looking for a screen that has stopped changing before it looks anyway.
    ///
    /// Bounded rather than open-ended because a screen does not always settle: a video, a spinner and a
    /// progress bar are all still moving at the moment the model needs to see them.
    private static let millisecondsToWaitForTheScreenToSettle = 2500

    /// The gap between the two captures compared to decide whether the screen has stopped changing.
    private static let millisecondsBetweenSettleChecks = 250

    /// Captures every connected display once the screen has stopped changing.
    ///
    /// A step's screenshot is taken the moment the step before it has finished acting, and a posted
    /// event returns long before the app receiving it has redrawn. Captured straight away, the picture
    /// is the screen as it was *before* kiki's own last click — the page may already have navigated
    /// away — and the model then answers from elements that are no longer there and points at where
    /// they used to be. Two captures matching byte for byte are this app's own answer to "has the
    /// screen finished reacting", and the later of the pair is the one worth sending.
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
            // Worth a line: it is the difference between a screenshot that shows what the last
            // action did and one that shows the screen as it was before it, and from outside the
            // app that difference is an unexplained few hundred milliseconds.
            print("⏳ Screen still changing \(millisecondsWaited)ms in — waiting for it to settle")
        }

        // Saved on its way out rather than inside the loop: the rounds above are checks, and only the
        // picture the model is actually sent belongs in the diagnostic record.
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
    /// `savingCaptures` is off for the repeat captures `captureAllScreensAsJPEGOnceTheScreenHasSettled`
    /// makes to watch the screen settle, which are throwaways and would otherwise double every entry in
    /// the diagnostic record and renumber the ones that matter.
    static func captureAllScreensAsJPEG(savingCaptures: Bool = true) async throws -> [CompanionScreenCapture] {
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
            // The pointer is deliberately left out of the picture. By the time a step's screenshot is
            // taken it is kiki's own puppet — every flight that acts carries it onto the element it is
            // about to press — so it comes to rest on the very label the app has to read back off the
            // screen, and it is drawn *over* that label. A two-character chinese caption with an arrow
            // across half of it disappears from the recognized lines altogether: the label stops
            // matching, the click falls back to the model's own estimate, and the one mechanism that
            // exists to aim a click at an element stops applying to the element just used.
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
