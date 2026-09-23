import Foundation

/// Names which terminal a message came from, and which one an answer belongs to.
///
/// A bare `UUID` in these signatures would read as an anonymous identifier, when the whole point of
/// it is that a click's answer goes back to one particular terminal.
typealias CommandTerminalIdentifier = UUID

/// The command line tool's way in: a Unix domain socket the app listens on.
///
/// `nonisolated` puts the whole class outside the target's default main-actor isolation, which is
/// the point. The overlay animates on the main actor, so an `accept` or a `write` landing there
/// would be felt as a stutter — the same reason the screenshot JPEG encode was moved off it.
///
/// One serial queue carries the accept loop, every read and every write. Serial because the
/// `text` snapshots sent back are read as a timeline and reordering them would leave the terminal
/// showing a reply that never existed.
///
/// Connections are held in a table and given their role by what they *ask for*, rather than by the
/// order they arrived in. A connection sending a command becomes the terminal watching the reply
/// and displaces whoever held that role, because a new question stops the last one. A connection
/// asking for a click takes no role at all: it displaces nothing and is answered on its own
/// descriptor, because a click is not one of the ways a person talks to Kiki and must never take
/// the reply away from a terminal that is watching one.
///
/// `@unchecked Sendable` rather than a conformance the compiler could check, because reachable from
/// any thread is what this class is for: the queue owns the connections and their buffers, a lock
/// owns the one flag the main actor reads, and no other state is shared.
nonisolated final class CompanionCommandSocketServer: @unchecked Sendable {

    /// What the app does with each thing a terminal can send, given once, when the server is built.
    ///
    /// An argument to the initializer rather than four properties assigned afterwards, because a
    /// server that is listening without one of them accepts a connection it can never answer: the
    /// terminal waits on a handler nothing will call, which from out there is indistinguishable
    /// from Kiki being stuck. Required, a half-wired server does not compile, and there is no
    /// second call site for the wiring to be split across.
    ///
    /// The second argument of `commandHandler` is whether that terminal asked for the reply to be
    /// read aloud; the second argument of `clickHandler` is the terminal that asked for the click,
    /// so its answer can be addressed back to it.
    init(
        commandHandler: @escaping @MainActor (String, Bool) -> Void,
        cancelHandler: @escaping @MainActor () -> Void,
        clickHandler: @escaping @MainActor (KikiClickRequest, CommandTerminalIdentifier) -> Void,
        readinessProvider: @escaping @MainActor () -> KikiCommandReadiness
    ) {
        self.commandHandler = commandHandler
        self.cancelHandler = cancelHandler
        self.clickHandler = clickHandler
        self.readinessProvider = readinessProvider
    }

    private let commandHandler: @MainActor (String, Bool) -> Void
    private let cancelHandler: @MainActor () -> Void

    /// A terminal asking for a click. The identifier goes along with the request because the click
    /// outlives the moment it was asked for, while the reply-watching role may change hands in the
    /// meantime: whoever performs the click reports the outcome to that terminal and no other.
    private let clickHandler: @MainActor (KikiClickRequest, CommandTerminalIdentifier) -> Void

    /// Asked on the main actor once per connection — never per chunk. The permission flags and the
    /// Keychain item it reads both belong to the main actor, and a round trip per chunk would put
    /// that hop on the streaming path for nothing.
    private let readinessProvider: @MainActor () -> KikiCommandReadiness

    private let queue = DispatchQueue(label: "com.smarty.kiki.command-socket")

    private var listeningFileDescriptor: Int32 = -1
    private var listeningSource: DispatchSourceRead?

    /// Every connection the app is holding open, by identifier.
    ///
    /// Read and written on `queue` alone, which is what the accept loop, every read and every write
    /// already run on, so the table needs no lock of its own.
    private var attachedTerminals: [CommandTerminalIdentifier: AttachedTerminal] = [:]

    /// The one terminal watching the reply, if any: the one that asked for the command being
    /// answered. A later command takes the role from it; nothing else does.
    private var replyWatchingTerminalIdentifier: CommandTerminalIdentifier?

    /// How many connections may be open at once.
    ///
    /// The old one-terminal-at-a-time rule capped this by construction, and that rule is gone. The
    /// tool never has more than two open — the turn being watched and one click — and it says which
    /// it wants within milliseconds of connecting, so this is far out of reach. It is here so that a
    /// client which connects and then says nothing cannot accumulate connections without limit.
    private static let maximumSimultaneousTerminals = 16

    /// One connection from the tool, from `accept` until it is released.
    ///
    /// A class rather than a struct so the read source and the descriptor it reads stay together.
    /// The table is its only owner, and the source's handler reaches it through the table by
    /// identifier, so no source can keep alive the connection that keeps the source alive.
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

    /// A terminal is watching the reply, and ready to be written to.
    ///
    /// Guarded by a lock rather than read with `queue.sync`, because the queue can be sitting in a
    /// blocking `write` for up to `sendTimeoutSeconds` — and the reader here is the main actor,
    /// which cannot afford to wait that long. Nothing holds the lock across I/O, so the wait is
    /// always a few instructions.
    private let attachmentLock = NSLock()
    private var aTerminalIsWatchingTheReply = false

    /// Long enough that only a terminal which has genuinely stopped reading trips it, short enough
    /// that one cannot hold the serial queue — and therefore every later snapshot — indefinitely.
    private static let sendTimeoutSeconds: Int = 2

    /// Whether anybody is watching the reply being streamed.
    ///
    /// The gate on the streaming snapshot: re-running the whole parse per chunk is worth it for a
    /// reader and for nobody else. Named for the role rather than for the connection, because a
    /// click's connection is a connection too, and nobody is watching anything through it.
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
            print("🔌 Command socket path is \(pathByteCount) bytes, past the \(KikiCommandProtocol.maximumSocketPathByteCount)-byte limit a `sockaddr_un` can hold — the kiki command line tool cannot connect.")
            return
        }

        do {
            try FileManager.default.createDirectory(
                atPath: KikiCommandProtocol.socketDirectoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            print("🔌 Could not create \(KikiCommandProtocol.socketDirectoryPath): \(error)")
            return
        }

        // A socket file outlives the process that bound it, so a crash would otherwise leave the
        // next launch unable to bind. Removing it also never races a live listener: two apps
        // cannot be the same app, and `open` activates the running one rather than starting another.
        unlink(KikiCommandProtocol.socketPath)

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            print("🔌 Could not open a command socket: errno \(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(KikiCommandProtocol.socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            // The path was measured against the limit above, so it and its NUL terminator fit;
            // `sockaddr_un()` zero-initialises, so the terminator is already in place.
            destination.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddressPointer in
                bind(fileDescriptor, socketAddressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("🔌 Could not bind \(KikiCommandProtocol.socketPath): errno \(errno)")
            close(fileDescriptor)
            return
        }

        // Only this user may talk to it. The socket can ask Kiki to move the mouse and click, so
        // its permissions are the boundary around who may give that order.
        chmod(KikiCommandProtocol.socketPath, S_IRUSR | S_IWUSR)

        guard listen(fileDescriptor, 8) == 0 else {
            print("🔌 Could not listen on \(KikiCommandProtocol.socketPath): errno \(errno)")
            close(fileDescriptor)
            return
        }

        // Non-blocking so the accept loop below can drain the backlog and stop on `EAGAIN` rather
        // than sitting in `accept` with the serial queue held.
        setNonBlocking(fileDescriptor)

        listeningFileDescriptor = fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { close(fileDescriptor) }
        source.resume()
        listeningSource = source

        print("🔌 Command socket listening at \(KikiCommandProtocol.socketPath)")
    }

    // MARK: - Connections

    private func acceptPendingConnections() {
        while true {
            let acceptedFileDescriptor = accept(listeningFileDescriptor, nil, nil)
            guard acceptedFileDescriptor >= 0 else { return }
            adopt(acceptedFileDescriptor)
        }
    }

    /// Registers a connection and announces readiness to it, and does nothing else.
    ///
    /// What this connection is for — and therefore what, if anything, it displaces — is decided by
    /// the request it sends, never by the fact that it connected. Displacing here would hand that
    /// power to anything able to open the socket, before it has said a word: a `kiki click` on its
    /// way in would cut off the terminal watching the reply, and then be refused for its own
    /// reasons, leaving the click with nothing and the reply with nobody.
    private func adopt(_ acceptedFileDescriptor: Int32) {
        guard attachedTerminals.count < Self.maximumSimultaneousTerminals else {
            close(acceptedFileDescriptor)
            return
        }

        // Without this a write to a terminal that has gone away raises SIGPIPE, whose default
        // action is to kill the process — the whole app, for a hung-up reader.
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

    /// Lets go of one connection, and of the reply-watching role if this was the one holding it.
    ///
    /// Lowering the flag is what lets a terminal that simply walked away stop paying for snapshots
    /// nobody reads, and what a later command looks at when it claims the role for itself.
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
            // Zero is the terminal closing. A negative result is `EAGAIN` when the source woke for
            // a reason other than data, which is not a reason to drop it.
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
                print("🔌 Ignoring an unreadable line from the command line tool")
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
            // Claimed before the handler runs, so everything this turn sends — a refusal, `accepted`,
            // and the reply itself — is addressed to this terminal.
            claimTheReplyWatchingRole(for: identifier)
            Task { @MainActor in commandHandler(commandText, speakReply) }

        case KikiCommandProtocol.MessageType.cancel:
            Task { @MainActor in cancelHandler() }

        case KikiCommandProtocol.MessageType.click:
            guard let clickRequest = request.click else { return }
            // The connection goes along with the request, because this answer belongs to it: by the
            // time the click has been made the reply-watching role may belong to somebody else, or
            // to nobody, and neither of those is who asked.
            Task { @MainActor in clickHandler(clickRequest, identifier) }

        default:
            // An unknown type is ignored rather than treated as an error, so a newer CLI can add
            // one without this app having to know about it.
            break
        }
    }

    /// Gives one connection the reply-watching role, taking it from whoever holds it.
    ///
    /// This is displacement, and it is deliberately reachable only from a command: the two ways a
    /// person talks to Kiki — a typed command and Control+Option — are the ones that interrupt what
    /// is running, and everything else yields to them. A click in particular takes nobody's place,
    /// including another click's.
    ///
    /// The displaced terminal is told before its connection goes, because a hang-up on its own
    /// cannot be read: a terminal that has just been displaced sees exactly what it would see if
    /// Kiki had died, and those two happen at the same instant, so no later check can separate them.
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

    /// Sends an event to the terminal watching the reply — which is what every reply event is:
    /// `accepted`, each `text` snapshot, `done`, and a turn that failed.
    ///
    /// Every message is an absolute snapshot, never a delta — so a message dropped because no
    /// terminal was watching costs the reader nothing, and a coalesced one cannot leave the
    /// terminal out of step with a reply that has moved on.
    func send(_ event: KikiCommandEvent) {
        guard let line = Self.encodedLine(for: event) else { return }
        queue.async { [weak self] in
            // Resolved when the write happens rather than when it was queued: the role is one
            // answer to "who is watching", and the command that moved it may have arrived since.
            guard let self, let identifier = self.replyWatchingTerminalIdentifier else { return }
            self.writeLineToClient(line, toTheTerminalWith: identifier)
        }
    }

    /// Sends an event to one particular terminal, which is how a click is answered.
    ///
    /// Addressed rather than broadcast: the terminal watching the reply has no use for a `clicked`
    /// line about a request it never made.
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
    ///
    /// `SO_SNDTIMEO` alone does not do this. An accepted socket inherits the listening socket's
    /// `O_NONBLOCK`, so the write gives up the instant the send buffer — a few kilobytes — is full,
    /// and a terminal that is merely between reads cannot be told from one that has gone: both
    /// answer `EAGAIN`, and the second must not be dropped for it. So the wait is written out here.
    /// A truncated line never reaches the wire, because half a snapshot is not a snapshot.
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

    /// Waits for the terminal's send buffer to have room in it, or for the deadline to pass.
    ///
    /// The time left is recomputed each time round rather than passed once, so a line that took a
    /// second to go out still has only the rest of the timeout to finish in — and an interrupted
    /// wait does not restart it.
    private func waitForRoomToWriteToTheTerminal(_ fileDescriptor: Int32, until deadline: Date) -> Bool {
        var descriptorSet = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let millisecondsLeft = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard millisecondsLeft > 0 else { return false }

            let pollResult = poll(&descriptorSet, 1, millisecondsLeft)
            if pollResult > 0 { return true }
            if pollResult == 0 { return false }
            // A signal interrupted the wait. Retrying is right because the deadline above ends it;
            // treating this as a timeout would drop a terminal nothing has gone wrong with.
            if errno != EINTR { return false }
        }
    }

    /// Says how a request can be served to the terminal that just connected, and to it alone.
    ///
    /// It cannot go through `send`: this is an answer to a connection, not to whoever is watching
    /// the reply, and with a turn streaming those are different terminals — the new one would sit
    /// out its whole startup timeout waiting for a `ready` that went to somebody else.
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
