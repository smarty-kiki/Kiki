//
//  ScreenshotTextRecognizer.swift
//  kiki-desktop-agent
//
//  Reads the text on a screenshot on-device, and finds the piece of text the model was
//  pointing at within it: the model names the element, this app says where it is.
//
//  The model reads a *recognizable* shape essentially exactly and a *measurable* position
//  only roughly, so the coordinate it writes is a hint about which instance it meant rather
//  than the answer, and the position comes from Vision's reading of the text instead.
//

import AppKit
import Vision

/// One line of text read out of a screenshot, with the rectangle it occupies in that screenshot's own
/// pixel space — the same top-left origin the model's `[POINT:x,y:label]` tags are written in, so the
/// two can be compared without conversion.
struct RecognizedTextLine {
    let text: String
    let boundingBoxInScreenshotPixels: CGRect

    /// The rectangle a run of characters inside this line occupies.
    ///
    /// Vision gives one rectangle per line and no per-word boxes — `boundingBox(for:)` returns the
    /// whole line for every range it is handed — so a word's horizontal extent is derived from its
    /// character offset, dividing the line's box evenly among its characters. That is exact for a
    /// monospaced line and an approximation elsewhere, which costs accuracy rather than correctness.
    func boundingBoxInScreenshotPixels(forCharacterRange characterRange: Range<Int>) -> CGRect {
        // A line Vision read but measured as empty cannot be divided by its own length.
        let characterCount = max(text.count, 1)
        let characterAdvanceInPixels = boundingBoxInScreenshotPixels.width / CGFloat(characterCount)
        let firstCharacterIndex = min(max(characterRange.lowerBound, 0), characterCount)
        let lastCharacterIndex = min(max(characterRange.upperBound, 0), characterCount)

        return CGRect(
            x: boundingBoxInScreenshotPixels.minX + CGFloat(firstCharacterIndex) * characterAdvanceInPixels,
            y: boundingBoxInScreenshotPixels.minY,
            width: CGFloat(lastCharacterIndex - firstCharacterIndex) * characterAdvanceInPixels,
            height: boundingBoxInScreenshotPixels.height
        )
    }
}

/// On-device text recognition over a screenshot. `VNRecognizeTextRequest` runs locally, needs no
/// permission the app does not already hold, and costs nothing per call, which is what makes it
/// usable on every turn rather than only when something has gone visibly wrong.
enum ScreenshotTextRecognizer {

    /// Reads every line of text on a screenshot.
    ///
    /// Returns an empty array rather than throwing when the image cannot be decoded or Vision finds
    /// nothing: a screenshot with no readable text is an ordinary screen, not a failure.
    ///
    /// `VNImageRequestHandler.perform` is synchronous and blocks for the better part of a second, and
    /// calling it directly inside an `async` function occupies one of Swift's cooperative-pool threads
    /// for that whole time — the same pool that delivers the model's streaming response. A queue of its
    /// own keeps the two independent, and concurrent rather than serial so that recognizing several
    /// displays still overlaps.
    private static let textRecognitionQueue = DispatchQueue(
        label: "com.smarty.kiki.screenshot-text-recognition",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func recognizedLines(in imageData: Data) async -> [RecognizedTextLine] {
        await withCheckedContinuation { continuation in
            textRecognitionQueue.async {
                continuation.resume(returning: recognizedLinesSynchronously(in: imageData))
            }
        }
    }

    private static func recognizedLinesSynchronously(in imageData: Data) -> [RecognizedTextLine] {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return []
        }

        let textRecognitionRequest = configuredTextRecognitionRequest()
        do {
            try VNImageRequestHandler(cgImage: screenshotImage, options: [:])
                .perform([textRecognitionRequest])
        } catch {
            print("🔍 Text recognition failed: \(error)")
            return []
        }

        let screenshotWidthInPixels = CGFloat(screenshotImage.width)
        let screenshotHeightInPixels = CGFloat(screenshotImage.height)

        let recognizedLines: [RecognizedTextLine] = (textRecognitionRequest.results ?? []).compactMap { textObservation in
            guard let recognizedText = textObservation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(
                text: recognizedText.string,
                boundingBoxInScreenshotPixels: Self.screenshotPixelRect(
                    fromVisionNormalizedRect: textObservation.boundingBox,
                    screenshotWidthInPixels: screenshotWidthInPixels,
                    screenshotHeightInPixels: screenshotHeightInPixels
                )
            )
        }

        return recognizedLines
    }

    /// A text recognition request set up for the languages the user actually reads, taken from
    /// `Locale.preferredLanguages` and never `Locale.current` — this bundle ships no `.lproj`, so
    /// `Locale.current` resolves against the app's own absent localizations and reports English on a
    /// Chinese Mac. A screen is not one language anyway: a Chinese interface is full of English paths
    /// and identifiers, so the preferred languages are a starting order rather than a restriction.
    private static func configuredTextRecognitionRequest() -> VNRecognizeTextRequest {
        let textRecognitionRequest = VNRecognizeTextRequest()
        textRecognitionRequest.recognitionLevel = .accurate
        // Language correction rewrites what it reads towards real words, which is helpful for prose
        // and harmful here: the point is to read a directory name or identifier exactly as spelled.
        textRecognitionRequest.usesLanguageCorrection = false
        textRecognitionRequest.recognitionLanguages = preferredRecognitionLanguages(
            supportedLanguageIdentifiers: (try? textRecognitionRequest.supportedRecognitionLanguages()) ?? []
        )
        textRecognitionRequest.automaticallyDetectsLanguage = true
        return textRecognitionRequest
    }

    /// Vision's supported languages, reordered so the ones the user reads come first. Vision names a
    /// language at the granularity it models ("zh-Hans") while `Locale.preferredLanguages` adds a
    /// region ("zh-Hans-CN"), so the two are compared at a hyphen boundary rather than for equality.
    private static func preferredRecognitionLanguages(
        supportedLanguageIdentifiers: [String]
    ) -> [String] {
        guard !supportedLanguageIdentifiers.isEmpty else { return [] }

        let preferredLanguages = Locale.preferredLanguages
        let matchingPreferredLanguages = supportedLanguageIdentifiers.filter { supportedLanguageIdentifier in
            preferredLanguages.contains { preferredLanguage in
                supportedLanguageIdentifier == preferredLanguage
                    || preferredLanguage.hasPrefix(supportedLanguageIdentifier + "-")
                    || supportedLanguageIdentifier.hasPrefix(preferredLanguage + "-")
            }
        }

        // Anything unmatched is kept behind the preferred ones rather than dropped: the request has
        // language detection enabled, and a hint list that omits a language is a hint it cannot use.
        let remainingLanguages = supportedLanguageIdentifiers.filter { supportedLanguageIdentifier in
            !matchingPreferredLanguages.contains(supportedLanguageIdentifier)
        }
        return matchingPreferredLanguages + remainingLanguages
    }

    /// Converts a Vision rectangle into the screenshot's own pixel space. Vision reports rectangles
    /// normalized to 0…1 with the origin at the *bottom* left, while every coordinate on the pointing
    /// path — the model's tags included — is in pixels from the top left. Getting this backwards puts
    /// the cursor the same distance below the target that the target is above the middle of the screen.
    private static func screenshotPixelRect(
        fromVisionNormalizedRect normalizedRect: CGRect,
        screenshotWidthInPixels: CGFloat,
        screenshotHeightInPixels: CGFloat
    ) -> CGRect {
        CGRect(
            x: normalizedRect.minX * screenshotWidthInPixels,
            y: (1 - normalizedRect.maxY) * screenshotHeightInPixels,
            width: normalizedRect.width * screenshotWidthInPixels,
            height: normalizedRect.height * screenshotHeightInPixels
        )
    }
}

/// Finds which piece of on-screen text the model was pointing at, matching on the label inside a
/// `[POINT:x,y:label]` tag and treating the coordinate it wrote as a hint about *which* occurrence
/// was meant. Quality of match is compared before distance from that hint: the label says what the
/// thing is, the coordinate only narrows down which one of several it was.
enum ScreenshotTextElementMatcher {

    /// How far a match may sit from the coordinate the model wrote, in screenshot pixels, and still
    /// be believed.
    ///
    /// Without a limit, a label that happens to appear somewhere on a busy screen matches even when
    /// the model was pointing at something with no text at all; with too tight a limit the fix does
    /// not apply to the errors it exists for, which are large — the model's own vertical error on a
    /// screen of five identical lines measured 120 pixels. 400 is a quarter of a 1280-wide capture.
    private static let maximumSnapDistanceInScreenshotPixels: CGFloat = 400

    /// Tokens shorter than this are not searched for on their own. A label of "search bar" should
    /// still match a screen that only says "Search", but a stray "bar" or "of" matches half the text
    /// on a screen and drags the cursor there.
    private static let minimumTokenLengthForPartialMatch = 3

    /// The rectangle of the text element the model was pointing at, or nil when nothing on the screen
    /// matches what it named. Nil is the ordinary case rather than a failure — most of what a cursor
    /// points at is an icon, a pane or a window with no text of its own — and leaves the model's own
    /// coordinate in place.
    ///
    /// `claimedBoxes` are the rectangles earlier stops of the same tour have already resolved to, and
    /// a candidate landing on one is passed over as though it had not matched — this scores each stop
    /// on its own, so nothing else stops two stops from parking on the same piece of text twice.
    static func elementBox(
        matchingElementLabel elementLabel: String?,
        nearScreenshotCoordinate screenshotCoordinate: CGPoint,
        amongRecognizedLines recognizedLines: [RecognizedTextLine],
        avoidingBoxesClaimedByEarlierStopsOnTheSameScreen claimedBoxes: [CGRect]
    ) -> CGRect? {
        guard let elementLabel else { return nil }
        let trimmedElementLabel = elementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedElementLabel.isEmpty else { return nil }

        var bestMatch: (quality: TextMatchQuality, distanceInPixels: CGFloat, box: CGRect)?

        for recognizedLine in recognizedLines {
            let lineCharacters = Array(recognizedLine.text)
            let lowercasedLineCharacters = Array(recognizedLine.text.lowercased())
            // Lowercasing can change a string's length in a handful of scripts, and a character
            // offset means nothing once the two disagree.
            guard lowercasedLineCharacters.count == lineCharacters.count else { continue }

            for needle in searchNeedles(forElementLabel: trimmedElementLabel) {
                let needleCharacters = Array(needle.text.lowercased())
                guard !needleCharacters.isEmpty, needleCharacters.count <= lineCharacters.count else { continue }

                for characterRange in Self.ranges(
                    of: needleCharacters,
                    in: lowercasedLineCharacters
                ) {
                    let isWholeWord = Self.isWholeWord(
                        characterRange,
                        among: lineCharacters
                    )
                    let quality = needle.quality(isWholeWord)
                    let box = recognizedLine.boundingBoxInScreenshotPixels(forCharacterRange: characterRange)
                    // Spent on an earlier stop of this tour. Two sub-ranges of one line tile rather
                    // than overlap, so this only ever turns away a candidate that really is the same
                    // piece of text.
                    guard !claimedBoxes.contains(where: { $0.intersects(box) }) else { continue }
                    let distanceInPixels = Self.distanceInPixels(
                        from: screenshotCoordinate,
                        to: CGPoint(x: box.midX, y: box.midY)
                    )

                    if let currentBestMatch = bestMatch {
                        let isBetterMatch = quality > currentBestMatch.quality
                            || (quality == currentBestMatch.quality
                                && distanceInPixels < currentBestMatch.distanceInPixels)
                        guard isBetterMatch else { continue }
                    }
                    bestMatch = (quality: quality, distanceInPixels: distanceInPixels, box: box)
                }
            }
        }

        guard let bestMatch, bestMatch.distanceInPixels <= maximumSnapDistanceInScreenshotPixels else {
            return nil
        }
        return bestMatch.box
    }

    /// Every place this text appears on the screenshot, in reading order: top to bottom, and left to
    /// right within a line.
    ///
    /// For a caller that has a piece of text and no coordinate to go with it — `elementBox` needs one
    /// as its hint and turns away anything far from it, which is the opposite of what a search is for.
    static func elementBoxesInReadingOrder(
        matchingElementLabel elementLabel: String,
        amongRecognizedLines recognizedLines: [RecognizedTextLine]
    ) -> [CGRect] {
        let trimmedElementLabel = elementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedElementLabel.isEmpty else { return [] }

        var matchingBoxes: [CGRect] = []

        for recognizedLine in recognizedLines {
            let lineCharacters = Array(recognizedLine.text)
            let lowercasedLineCharacters = Array(recognizedLine.text.lowercased())
            guard lowercasedLineCharacters.count == lineCharacters.count else { continue }

            var matchesOnThisLine: [(quality: TextMatchQuality, box: CGRect)] = []

            for needle in searchNeedles(forElementLabel: trimmedElementLabel) {
                let needleCharacters = Array(needle.text.lowercased())
                guard !needleCharacters.isEmpty, needleCharacters.count <= lineCharacters.count else { continue }

                for characterRange in Self.ranges(of: needleCharacters, in: lowercasedLineCharacters) {
                    let quality = needle.quality(Self.isWholeWord(characterRange, among: lineCharacters))
                    // A token found inside a longer word is not an appearance of anything: "bar" in
                    // "barrier" is the same letters and plainly not the thing being looked for. A whole
                    // label inside a longer run of Chinese is kept — Chinese writes no spaces, so OCR
                    // runs neighbouring characters together and 确定取消 does contain a 确定.
                    guard quality >= .labelTokenAsWholeWord else { continue }
                    matchesOnThisLine.append((
                        quality: quality,
                        box: recognizedLine.boundingBoxInScreenshotPixels(forCharacterRange: characterRange)
                    ))
                }
            }

            // One appearance, found twice over: a line reading "Search bar" matches the whole label and
            // the token "search", and their boxes overlap. The stronger match wins, so what is counted
            // is the places the text appears rather than the ways each was found.
            var boxesKeptOnThisLine: [CGRect] = []
            for match in matchesOnThisLine.sorted(by: { $0.quality > $1.quality }) {
                guard !boxesKeptOnThisLine.contains(where: { $0.intersects(match.box) }) else { continue }
                boxesKeptOnThisLine.append(match.box)
            }
            matchingBoxes.append(contentsOf: boxesKeptOnThisLine)
        }

        return matchingBoxes.sorted { firstBox, secondBox in
            firstBox.minY == secondBox.minY ? firstBox.minX < secondBox.minX : firstBox.minY < secondBox.minY
        }
    }

    /// Everything worth looking for, in the order the caller will prefer it: the whole label always,
    /// then its individual tokens. The whole label is the stronger signal because it is what the
    /// model actually wrote, while a model that names "search bar" is often looking at a control
    /// whose only text is "Search".
    private static func searchNeedles(
        forElementLabel elementLabel: String
    ) -> [(text: String, quality: (Bool) -> TextMatchQuality)] {
        var needles: [(text: String, quality: (Bool) -> TextMatchQuality)] = [
            (text: elementLabel, quality: { isWholeWord in
                isWholeWord ? .wholeLabelAsWholeWord : .wholeLabelWithinWord
            })
        ]

        let labelTokens = elementLabel
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= minimumTokenLengthForPartialMatch }
        for labelToken in labelTokens where labelToken != elementLabel {
            needles.append((text: labelToken, quality: { isWholeWord in
                isWholeWord ? .labelTokenAsWholeWord : .labelTokenWithinWord
            }))
        }
        return needles
    }

    /// Every place `needleCharacters` appears in `haystackCharacters`, as character offsets. A plain
    /// scan: labels and lines are both short, and an obvious loop is worth more than an efficient one.
    private static func ranges(
        of needleCharacters: [Character],
        in haystackCharacters: [Character]
    ) -> [Range<Int>] {
        guard needleCharacters.count <= haystackCharacters.count else { return [] }

        var matchingRanges: [Range<Int>] = []
        for startIndex in 0...(haystackCharacters.count - needleCharacters.count) {
            let endIndex = startIndex + needleCharacters.count
            if Array(haystackCharacters[startIndex..<endIndex]) == needleCharacters {
                matchingRanges.append(startIndex..<endIndex)
            }
        }
        return matchingRanges
    }

    /// Whether a run of characters stands alone rather than sitting inside a longer word: "Build" in
    /// a path is a whole word, the "build" inside "builds" is not.
    private static func isWholeWord(_ characterRange: Range<Int>, among lineCharacters: [Character]) -> Bool {
        let indexOfCharacterBefore = characterRange.lowerBound - 1
        if indexOfCharacterBefore >= 0,
           couldContinueTheSameWord(
               lineCharacters[characterRange.lowerBound],
               lineCharacters[indexOfCharacterBefore]
           ) {
            return false
        }

        let indexOfCharacterAfter = characterRange.upperBound
        if indexOfCharacterAfter < lineCharacters.count,
           couldContinueTheSameWord(
               lineCharacters[characterRange.upperBound - 1],
               lineCharacters[indexOfCharacterAfter]
           ) {
            return false
        }

        return true
    }

    /// Whether a neighbouring character could be another character of the *same word* as the character
    /// it sits against at the edge of a match.
    ///
    /// Two conditions. It has to be a letter or a digit at all, which is what makes the "build" inside
    /// "builds" not a whole word. And it has to be written in the same writing system as the character
    /// it touches — asked as "both ASCII or both not" — because two characters from different systems
    /// are not one word however tightly a line of OCR runs them together. Without that second
    /// condition, a glyph OCR invented and glued onto a label demotes the label from "stands alone" to
    /// "part of a longer word", which outranks a hundred pixels of distance when the two are compared.
    /// A Chinese character glued to a Chinese label still counts as continuing it, so a label inside a
    /// longer run of Chinese still ranks below the same label standing on its own.
    private static func couldContinueTheSameWord(
        _ edgeCharacter: Character,
        _ neighbouringCharacter: Character
    ) -> Bool {
        guard isWordCharacter(neighbouringCharacter) else { return false }
        return edgeCharacter.isASCII == neighbouringCharacter.isASCII
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func distanceInPixels(from firstPoint: CGPoint, to secondPoint: CGPoint) -> CGFloat {
        let deltaX = firstPoint.x - secondPoint.x
        let deltaY = firstPoint.y - secondPoint.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}

/// How strong a statement a match makes that this is the text the model meant. Ordered so the whole
/// label always beats any part of it, and standing alone as a word always beats being embedded in one
/// — without the second distinction, a model pointing at a `Build` directory would just as happily be
/// snapped onto `builder`.
private enum TextMatchQuality: Int, Comparable {
    case labelTokenWithinWord = 1
    case labelTokenAsWholeWord = 2
    case wholeLabelWithinWord = 3
    case wholeLabelAsWholeWord = 4

    static func < (firstQuality: TextMatchQuality, secondQuality: TextMatchQuality) -> Bool {
        firstQuality.rawValue < secondQuality.rawValue
    }
}
