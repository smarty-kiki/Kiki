import Foundation

/// Which terminal a message came from and which one an answer belongs to; never a bare `UUID`.
typealias CommandTerminalIdentifier = UUID

/// The command line tool's way in: a Unix domain socket the app listens on.
///
/// `nonisolated`, because an `accept` or write landing on the main actor while the overlay animates
/// would be a stutter. One serial queue carries all of it, because the `text` snapshots are read as a
/// timeline and reordering them would show a reply that never was. A connection's role is decided by
/// what it *asks for* — a command takes the reply-watching role, a click takes none — and
/// `@unchecked Sendable` holds because the queue owns the connections, a lock owns the one flag the
/// main actor reads, and nothing else is shared.
nonisolated final class CompanionCommandSocketServer: @unchecked Sendable {

    /// What the app does with each thing a terminal can send — arguments, so a half-wired server does
    /// not compile: one listening without a handler accepts a connection it can never answer. The `Bool`
    /// is whether the reply was asked for aloud; the second argument of the rest is the terminal to answer.
    init(
        commandHandler: @escaping @MainActor (String, Bool) -> Void,
        cancelHandler: @escaping @MainActor () -> Void,
        clickHandler: @escaping @MainActor (KikiClickRequest, CommandTerminalIdentifier) -> Void,
        screenshotHandler: @escaping @MainActor (KikiScreenshotRequest, CommandTerminalIdentifier) -> Void,
        locateHandler: @escaping @MainActor (KikiLocateRequest, CommandTerminalIdentifier) -> Void,
        readinessProvider: @escaping @MainActor () -> KikiCommandReadiness
    ) {
        self.commandHandler = commandHandler
        self.cancelHandler = cancelHandler
        self.clickHandler = clickHandler
        self.screenshotHandler = screenshotHandler
        self.locateHandler = locateHandler
        self.readinessProvider = readinessProvider
    }

    private let commandHandler: @MainActor (String, Bool) -> Void
    private let cancelHandler: @MainActor () -> Void

    /// A terminal asking for a click; the identifier travels with the request because the click
    /// outlives it, and the reply-watching role may change hands in the meantime.
    private let clickHandler: @MainActor (KikiClickRequest, CommandTerminalIdentifier) -> Void

    private let screenshotHandler: @MainActor (KikiScreenshotRequest, CommandTerminalIdentifier) -> Void
    private let locateHandler: @MainActor (KikiLocateRequest, CommandTerminalIdentifier) -> Void

    /// Asked once per connection on the main actor, never per chunk — which would hop the streaming
    /// path for nothing.
    private let readinessProvider: @MainActor () -> KikiCommandReadiness

    private let queue = DispatchQueue(label: "com.smarty.kiki.command-socket")

    private var listeningFileDescriptor: Int32 = -1
    private var listeningSource: DispatchSourceRead?

    /// Every connection the app is holding open — read and written on `queue` alone, so no lock.
    private var attachedTerminals: [CommandTerminalIdentifier: AttachedTerminal] = [:]

    private var replyWatchingTerminalIdentifier: CommandTerminalIdentifier?

    /// Far out of reach — the tool never has more than two open — but a client that says nothing
    /// cannot accumulate connections without limit.
    private static let maximumSimultaneousTerminals = 16

    /// One connection from the tool, from `accept` until it is released. A class so the read source
    /// and its descriptor stay together, and the handler reaches it through the table by identifier,
    /// so no source outlives the connection keeping it alive.
    private final class AttachedTerminal {
        let identifier: CommandTerminalIdentifier
        let fileDescriptor: Int32
        var readSource: DispatchSourceRead?
        var receiveBuffer = Data()

        init(identifier: CommandTerminalIdentifier, fileDescriptor: Int32) {
            self.identifier = identifier
            self.fileDescriptor = fileDescriptor
        }
    }

    /// A terminal is watching the reply, and ready to be written to — a lock rather than `queue.sync`,
    /// because the queue can be inside a blocking `write` and the reader here is the main actor.
    private let attachmentLock = NSLock()
    private var aTerminalIsWatchingTheReply = false

    /// Long enough that only a terminal which has genuinely stopped reading trips it, short enough
    /// that one cannot hold the serial queue — and so every later snapshot — indefinitely.
    private static let sendTimeoutSeconds: Int = 2

    /// Whether anybody is watching the reply being streamed — the gate on the streaming snapshot,
    /// because the whole parse per chunk is worth re-running for a reader and nobody else. Named for
    /// the role rather than the connection, which watches nothing.
    var hasATerminalWatchingTheReply: Bool {
        attachmentLock.lock()
        defer { attachmentLock.unlock() }
        return aTerminalIsWatchingTheReply
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.startListening() }
    }

    private func startListening() {
        guard listeningFileDescriptor < 0 else { return }

        let pathByteCount = KikiCommandProtocol.socketPath.utf8.count
        guard pathByteCount <= KikiCommandProtocol.maximumSocketPathByteCount else {
            print("Command socket path is \(pathByteCount) bytes, past the \(KikiCommandProtocol.maximumSocketPathByteCount)-byte limit a `sockaddr_un` can hold — the kiki command line tool cannot connect.")
            return
        }

        do {
            try FileManager.default.createDirectory(
                atPath: KikiCommandProtocol.socketDirectoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            print("Could not create \(KikiCommandProtocol.socketDirectoryPath): \(error)")
            return
        }

        // A socket file outlives the process that bound it, so a crash would otherwise leave the next
        // launch unable to bind. Removing it never races a live listener: `open` activates the running
        // app rather than starting a second one.
        unlink(KikiCommandProtocol.socketPath)

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            print("Could not open a command socket: errno \(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(KikiCommandProtocol.socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            // The path was measured above, so it and its NUL terminator fit; `sockaddr_un()`
            // zero-initialises, which is what puts the terminator there.
            destination.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddressPointer in
                bind(fileDescriptor, socketAddressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("Could not bind \(KikiCommandProtocol.socketPath): errno \(errno)")
            close(fileDescriptor)
            return
        }

        // Only this user may talk to it — it can ask Kiki to move the mouse and click, so the socket's
        // permissions are the boundary around who may give that order.
        chmod(KikiCommandProtocol.socketPath, S_IRUSR | S_IWUSR)

        guard listen(fileDescriptor, 8) == 0 else {
            print("Could not listen on \(KikiCommandProtocol.socketPath): errno \(errno)")
            close(fileDescriptor)
            return
        }

        // Non-blocking, so the accept loop drains the backlog and stops on `EAGAIN` with the queue free.
        setNonBlocking(fileDescriptor)

        listeningFileDescriptor = fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { close(fileDescriptor) }
        source.resume()
        listeningSource = source

        print("Command socket listening at \(KikiCommandProtocol.socketPath)")
    }

    // MARK: - Connections

    private func acceptPendingConnections() {
        while true {
            let acceptedFileDescriptor = accept(listeningFileDescriptor, nil, nil)
            guard acceptedFileDescriptor >= 0 else { return }
            adopt(acceptedFileDescriptor)
        }
    }

    /// Registers a connection and announces readiness to it, and nothing else: what it is for, and what
    /// it displaces, is decided by the request it sends. Decided here, anything able to open the socket
    /// would hold that power before saying a word — a `kiki click` on its way in would cut off the
    /// terminal watching the reply and then be refused itself.
    private func adopt(_ acceptedFileDescriptor: Int32) {
        guard attachedTerminals.count < Self.maximumSimultaneousTerminals else {
            close(acceptedFileDescriptor)
            return
        }

        // Without this a write to a terminal that has gone away raises SIGPIPE, whose default action
        // is to kill the process — the whole app, for a hung-up reader.
        var noSigPipe: Int32 = 1
        setsockopt(
            acceptedFileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var sendTimeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
        setsockopt(
            acceptedFileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let terminal = AttachedTerminal(identifier: UUID(), fileDescriptor: acceptedFileDescriptor)
        attachedTerminals[terminal.identifier] = terminal

        let source = DispatchSource.makeReadSource(fileDescriptor: acceptedFileDescriptor, queue: queue)
        let identifier = terminal.identifier
        source.setEventHandler { [weak self] in self?.drainBytesFromTheTerminal(with: identifier) }
        source.setCancelHandler { close(acceptedFileDescriptor) }
        source.resume()
        terminal.readSource = source

        announceReadiness(toTheTerminalWith: identifier)
    }

    private func release(_ identifier: CommandTerminalIdentifier) {
        guard let terminal = attachedTerminals.removeValue(forKey: identifier) else { return }
        terminal.readSource?.cancel()
        terminal.readSource = nil

        if replyWatchingTerminalIdentifier == identifier {
            replyWatchingTerminalIdentifier = nil
            setATerminalIsWatchingTheReply(false)
        }
    }

    private func drainBytesFromTheTerminal(with identifier: CommandTerminalIdentifier) {
        guard let terminal = attachedTerminals[identifier] else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(terminal.fileDescriptor, &buffer, buffer.count)
        let readErrno = errno

        guard bytesRead > 0 else {
            // Zero is the terminal closing; a negative result is `EAGAIN` with no data, not a drop.
            if bytesRead == 0 || readErrno != EAGAIN {
                release(identifier)
            }
            return
        }

        absorbReceivedBytes(Data(buffer[0..<bytesRead]), from: identifier)
    }

    private func setATerminalIsWatchingTheReply(_ isWatching: Bool) {
        attachmentLock.lock()
        aTerminalIsWatchingTheReply = isWatching
        attachmentLock.unlock()
    }

    // MARK: - Reading

    private func absorbReceivedBytes(_ receivedBytes: Data, from identifier: CommandTerminalIdentifier) {
        guard let terminal = attachedTerminals[identifier] else { return }
        terminal.receiveBuffer.append(receivedBytes)

        // JSON Lines: one message per `\n`-terminated line.
        while let lineEndIndex = terminal.receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = Data(terminal.receiveBuffer[terminal.receiveBuffer.startIndex..<lineEndIndex])
            terminal.receiveBuffer.removeSubrange(terminal.receiveBuffer.startIndex...lineEndIndex)

            guard !lineBytes.isEmpty else { continue }
            guard let request = try? KikiCommandProtocol.makeDecoder().decode(KikiCommandRequest.self, from: lineBytes) else {
                print("Ignoring an unreadable line from the command line tool")
                continue
            }
            handOff(request, from: identifier)
        }
    }

    private func handOff(_ request: KikiCommandRequest, from identifier: CommandTerminalIdentifier) {
        switch request.type {
        case KikiCommandProtocol.MessageType.command:
            guard let commandText = request.text, !commandText.isEmpty else { return }
            let speakReply = request.speakReply ?? true
            // Claimed before the handler runs, so this turn's refusal, `accepted` and reply all
            // address this terminal.
            claimTheReplyWatchingRole(for: identifier)
            Task { @MainActor in commandHandler(commandText, speakReply) }

        case KikiCommandProtocol.MessageType.cancel:
            Task { @MainActor in cancelHandler() }

        case KikiCommandProtocol.MessageType.click:
            guard let clickRequest = request.click else { return }
            // The connection goes along with the request because this answer belongs to it: by the time
            // the click is made the role may belong to somebody else, or to nobody.
            Task { @MainActor in clickHandler(clickRequest, identifier) }

        case KikiCommandProtocol.MessageType.screenshot:
            guard let screenshotRequest = request.screenshot else { return }
            Task { @MainActor in screenshotHandler(screenshotRequest, identifier) }

        case KikiCommandProtocol.MessageType.locate:
            guard let locateRequest = request.locate else { return }
            Task { @MainActor in locateHandler(locateRequest, identifier) }

        default:
            // Ignored rather than an error, so a newer CLI can add a type this app does not know.
            break
        }
    }

    /// Gives one connection the reply-watching role, taking it from whoever holds it. Reachable only
    /// from a command: the two ways a person talks to Kiki — a typed command and Control+Option — are
    /// the ones that interrupt what is running, and a click takes nobody's place. The displaced terminal
    /// is told before its connection goes, because a hang-up on its own cannot be read — it looks
    /// exactly like Kiki having died.
    private func claimTheReplyWatchingRole(for identifier: CommandTerminalIdentifier) {
        guard attachedTerminals[identifier] != nil else { return }
        guard replyWatchingTerminalIdentifier != identifier else { return }

        if let previousIdentifier = replyWatchingTerminalIdentifier {
            if let supersededLine = Self.encodedLine(for: .superseded) {
                writeLineToClient(supersededLine, toTheTerminalWith: previousIdentifier)
            }
            release(previousIdentifier)
        }

        replyWatchingTerminalIdentifier = identifier
        setATerminalIsWatchingTheReply(true)
    }

    // MARK: - Writing

    /// Sends an event to the terminal watching the reply. Every message is an absolute snapshot, never
    /// a delta, so one dropped for want of a watcher costs the reader nothing and none can leave it out
    /// of step.
    func send(_ event: KikiCommandEvent) {
        guard let line = Self.encodedLine(for: event) else { return }
        queue.async { [weak self] in
            // Resolved at write time rather than queue time: the command that moved the role may have
            // arrived since.
            guard let self, let identifier = self.replyWatchingTerminalIdentifier else { return }
            self.writeLineToClient(line, toTheTerminalWith: identifier)
        }
    }

    /// Sends an event to one particular terminal, which is how a click is answered — addressed, not
    /// broadcast, because a watcher has no use for a `clicked` line it never asked for.
    func send(_ event: KikiCommandEvent, toTheTerminalWith identifier: CommandTerminalIdentifier) {
        guard let line = Self.encodedLine(for: event) else { return }
        queue.async { [weak self] in self?.writeLineToClient(line, toTheTerminalWith: identifier) }
    }

    private static func encodedLine(for event: KikiCommandEvent) -> Data? {
        guard let payload = try? KikiCommandProtocol.makeEncoder().encode(event) else { return nil }
        var line = payload
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Writes one whole line, waiting for a reader that is behind rather than hanging up on it.
    /// `SO_SNDTIMEO` alone does not do this: an accepted socket inherits the listening socket's
    /// `O_NONBLOCK`, so a write gives up the instant the send buffer is full — and a terminal merely
    /// between reads answers `EAGAIN` exactly as one that is gone does. Half a snapshot is not a
    /// snapshot, so a truncated line never reaches the wire.
    private func writeLineToClient(_ line: Data, toTheTerminalWith identifier: CommandTerminalIdentifier) {
        guard let terminal = attachedTerminals[identifier] else { return }

        let deadline = Date().addingTimeInterval(TimeInterval(Self.sendTimeoutSeconds))
        var bytesWrittenSoFar = 0
        while bytesWrittenSoFar < line.count {
            let bytesWritten = line.withUnsafeBytes { lineBuffer in
                write(
                    terminal.fileDescriptor,
                    lineBuffer.baseAddress?.advanced(by: bytesWrittenSoFar),
                    lineBuffer.count - bytesWrittenSoFar
                )
            }
            if bytesWritten > 0 {
                bytesWrittenSoFar += bytesWritten
                continue
            }
            guard bytesWritten < 0, errno == EAGAIN, Date() < deadline else {
                release(identifier)
                return
            }
            guard waitForRoomToWriteToTheTerminal(terminal.fileDescriptor, until: deadline) else {
                release(identifier)
                return
            }
        }
    }

    /// Waits for the send buffer to have room, or for the deadline — recomputing the time left each
    /// round, so the deadline is the whole line's and not each wait's.
    private func waitForRoomToWriteToTheTerminal(_ fileDescriptor: Int32, until deadline: Date) -> Bool {
        var descriptorSet = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let millisecondsLeft = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard millisecondsLeft > 0 else { return false }

            let pollResult = poll(&descriptorSet, 1, millisecondsLeft)
            if pollResult > 0 { return true }
            if pollResult == 0 { return false }
            // A signal interrupted the wait; retrying is right, because the deadline above still ends
            // it — a timeout here would drop a terminal nothing is wrong with.
            if errno != EINTR { return false }
        }
    }

    /// Says how a request can be served to the terminal that just connected, and to it alone — not
    /// through `send`, which answers whoever watches the reply, so with a turn streaming the new
    /// terminal would sit out its startup timeout waiting for a `ready` that went elsewhere.
    private func announceReadiness(toTheTerminalWith identifier: CommandTerminalIdentifier) {
        Task { @MainActor in
            send(.ready(readinessProvider()), toTheTerminalWith: identifier)
        }
    }

    private func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }
}
