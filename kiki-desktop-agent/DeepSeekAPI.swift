//
//  DeepSeekAPI.swift
//  kiki-desktop-agent
//
//  DeepSeek chat client with streaming and image input.
//

import Foundation

/// Errors raised before a DeepSeek request can be sent.
enum DeepSeekAPIError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No DeepSeek API key saved yet. Open the Kiki menu and paste one into the API key field."
        }
    }
}

/// Client for DeepSeek's chat completions API.
///
/// DeepSeek speaks the OpenAI chat-completions dialect rather than Anthropic's, so this is a
/// sibling of `OpenAIAPI`: the system prompt is an ordinary `system` message, images are
/// `image_url` blocks holding a base64 `data:` URL, and streamed text arrives as
/// `choices[].delta.content`. Every request carries a screenshot per display so Kiki can
/// point at things, so the configured model has to accept image input — a text-only model
/// makes every request fail with HTTP 400.
class DeepSeekAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private static let chatCompletionsURL = URL(string: "https://api.deepseek.com/chat/completions")!

    /// The model used unless the user picks another one in the settings panel. Handles text
    /// and image input through the same route, which is what keeps pointing working.
    static let defaultModel = "deepseek-flash"

    /// Sent as `max_tokens`. A ceiling, not a request for a long answer — the model still
    /// stops when its reply is done — set to the models' own output limit rather than a small
    /// number because a reply cut off at the cap loses the `[POINT:...]` tag, which silently
    /// disables pointing for that turn.
    private static let maximumOutputTokens = 393_216

    /// Sent as `max_tokens` for a compression call. A summary is meant to be short, but the four
    /// things it must keep can be a paragraph each, so the ceiling is far above the length the
    /// summary should ever reach.
    private static let maximumCompressionOutputTokens = 8_192

    /// The instructions the compression call runs under.
    ///
    /// The list of what has to survive is the whole point of the call. A summary that drops what
    /// went wrong is worse than no summary at all: it teaches the model to walk into the same
    /// dead end again on the next step, and to keep walking into it, because the record of the
    /// first time is gone.
    private static let conversationCompressionSystemPrompt = """
    You compress a stretch of your own past work into a short summary that you will read back \
    later, in place of the record it replaces.

    These four things must survive however short the summary gets.
    - what the user asked for, in their own terms, including anything they ruled out.
    - what has already been done, what it did, and what that ruled out.
    - every error, refusal and dead end, and why it happened.
    - what is still unfinished, and what the next step was going to be.

    Merge and shorten everything else — pleasantries, repetition, and any step whose outcome a \
    later step already supersedes. Brevity is not the goal: losing one of the four above is a \
    failure, and a summary twice as long that keeps them is the better one.

    Write the summary in the language the conversation is written in, and output it alone — no \
    heading, no preamble, no comment on the record.
    """

    private let apiURL: URL
    private let apiKeyStore: DeepSeekAPIKeyStore
    private let session: URLSession

    /// The DeepSeek model to send requests to. Read when each request is built, so changing
    /// it from the settings panel takes effect on the next turn.
    var model: String

    init(apiKeyStore: DeepSeekAPIKeyStore, model: String = DeepSeekAPI.defaultModel) {
        self.apiURL = Self.chatCompletionsURL
        self.apiKeyStore = apiKeyStore
        self.model = model

        // `.default` rather than `.ephemeral` so TLS session tickets are cached: an ephemeral
        // session does a full handshake per request, which surfaces as transient -1200
        // (errSSLPeerHandshakeFail) errors with large image payloads. Caching is cleared
        // below so no response or credential reaches disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Pre-establishes the TLS connection, so the first real call with its large image
        // payload does not pay for a cold handshake.
        warmUpTLSConnectionIfNeeded()
    }

    /// The MIME type of image data, read off its first bytes. Screen captures are JPEG and
    /// pasted images are PNG; DeepSeek sniffs the real format anyway, but not lying is honest.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG's signature starts 89 50 4E 47.
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// A background HEAD request to establish and cache a TLS session. Failures are ignored.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The session ticket is host-scoped, so the root host is enough.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
        }.resume()
    }

    /// Send a vision request to DeepSeek with streaming.
    ///
    /// `onTextChunk` is awaited on the main actor after each chunk, because the caller cuts
    /// the reply into speech segments as it arrives and cannot do that without awaiting.
    /// Reading the stream therefore pauses for as long as the caller takes, so the caller
    /// must only await work that was already going to be needed. Returns the accumulated
    /// text and the total duration.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) async -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        // Read per request rather than cached: a key pasted into the settings panel while
        // the app is already running has to be picked up on the next turn, with no restart.
        guard let apiKey = apiKeyStore.apiKey else {
            throw DeepSeekAPIError.missingAPIKey
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // DeepSeek shares OpenAI's ordering rules: the system prompt is the first message
        // rather than a separate top-level field.
        var messages: [[String: Any]] = []

        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Each label sits after its image so the model reads the caption as describing the
        // shot above it, which is what makes the pixel dimensions usable for coordinate
        // math. Images are legal only in `user` messages — one in the system prompt or a
        // history turn makes DeepSeek reject the whole request.
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(detectImageMediaType(for: image.data));base64,\(image.data.base64EncodedString())"
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maximumOutputTokens,
            "stream": true,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 DeepSeek streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "DeepSeekAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "DeepSeekAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // SSE, one event per "data: {json}" line.
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // Comment/keep-alive lines start with a colon and are skipped by this same guard.
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            guard jsonString != "[DONE]" else { break }

            // Hybrid models stream their chain of thought separately, under
            // `delta.reasoning_content`. Only `delta.content` is the answer to speak, so
            // the other field is deliberately ignored.
            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String else {
                continue
            }

            accumulatedResponseText += textChunk
            // The whole reply so far, not the delta: the caller's segmenter is written
            // against a growing document, which is what the tag parsing, the tidy passes and
            // the sentence scan all take. It re-does that work per chunk so that there is
            // exactly one implementation of it.
            await onTextChunk(accumulatedResponseText)
        }

        // End of the transport, not of the interaction: a segment finalised chunks ago may still be playing.

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Compresses a stretch of a conversation into a short summary of it.
    ///
    /// Not streamed: nothing is spoken from a summary and nothing is shown arriving, so a stream
    /// would buy progress nobody asked to watch.
    ///
    /// - Parameter existingSummary: What everything compressed before was compressed into, which
    ///   this call folds the new stretch into. Folding rather than summarising the two separately
    ///   is what keeps one summary of the whole past rather than a chain of summaries of its
    ///   parts, each one a summary of a summary.
    func summarizeConversation(
        compressing conversationToCompress: String,
        foldingIn existingSummary: String?
    ) async throws -> String {
        // Read per request for the same reason the streaming call does: a key saved while the app
        // is running has to be picked up without a restart.
        guard let apiKey = apiKeyStore.apiKey else {
            throw DeepSeekAPIError.missingAPIKey
        }

        var conversationText = ""
        if let existingSummary, !existingSummary.isEmpty {
            conversationText += "Already compressed:\n\(existingSummary)\n\n"
        }
        conversationText += "Now to compress:\n\(conversationToCompress)"

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": Self.maximumCompressionOutputTokens,
            "messages": [
                ["role": "system", "content": Self.conversationCompressionSystemPrompt],
                ["role": "user", "content": conversationText]
            ]
        ])

        let (responseBody, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "DeepSeekAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "DeepSeekAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "Compression error (\(httpResponse.statusCode)): "
                    + (String(data: responseBody, encoding: .utf8) ?? "")]
            )
        }

        // The non-streaming shape of the same reply: one assembled message rather than deltas.
        guard let payload = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let summary = message["content"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "DeepSeekAPI",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Compression returned no summary"]
            )
        }

        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
