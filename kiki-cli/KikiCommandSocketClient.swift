import Foundation

/// The command line tool's end of the socket the app listens on.
final class KikiCommandSocketClient {

    let fileDescriptor: Int32

    private var receiveBuffer = Data()

    /// Writes are serialised because the Ctrl-C handler comes in on its own queue and can land in
    /// the middle of a command being sent.
    private let writeLock = NSLock()

    /// Fails when nothing is listening.
    ///
    /// A socket file left behind by a process that is gone answers `ECONNREFUSED` here, which is
    /// the same answer as "not running" — so a stale file needs no case of its own.
    init?(socketPath: String) {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= KikiCommandProtocol.maximumSocketPathByteCount else { return nil }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            // The path was measured against the limit above, and `sockaddr_un()` zero-initialises,
            // so it and its NUL terminator fit.
            destination.copyBytes(from: pathBytes)
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddressPointer in
                connect(descriptor, socketAddressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(descriptor)
            return nil
        }

        // The app dying mid-write would otherwise raise SIGPIPE, whose default action is to kill
        // this process — turning a lost connection into a crash with no message.
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        fileDescriptor = descriptor
    }

    deinit {
        close(fileDescriptor)
    }

    // MARK: - Sending

    func send(_ request: KikiCommandRequest) {
        guard let payload = try? KikiCommandProtocol.makeEncoder().encode(request) else { return }

        var line = payload
        line.append(UInt8(ascii: "\n"))

        writeLock.lock()
        defer { writeLock.unlock() }
        _ = line.withUnsafeBytes { lineBuffer in
            write(fileDescriptor, lineBuffer.baseAddress, lineBuffer.count)
        }
    }

    // MARK: - Receiving

    /// How a read ended.
    ///
    /// A wait that ran out and a connection the app closed are different things to the person
    /// watching — the second means Kiki went away mid-reply — so they are not collapsed into one
    /// answer. Being displaced by another terminal is not a third case here: the app says so with
    /// a `superseded` message before it closes, so that arrives as an ordinary event.
    enum ReadOutcome {
        case event(KikiCommandEvent)
        case timedOut
        case disconnected
    }

    /// The next message, waiting up to `timeoutSeconds` for it.
    func readNextEvent(timeoutSeconds: Double) -> ReadOutcome {
        while true {
            if let lineBytes = takeNextLineBytes() {
                guard let event = try? KikiCommandProtocol.makeDecoder().decode(KikiCommandEvent.self, from: lineBytes) else {
                    // A line this build cannot read is skipped rather than fatal: a newer app may
                    // have added a type, and the ones this build does know still arrive on their own.
                    continue
                }
                return .event(event)
            }
            guard waitForBytesToArrive(timeoutSeconds: timeoutSeconds) else { return .timedOut }
            guard readWhateverIsAvailable() else { return .disconnected }
        }
    }

    private func takeNextLineBytes() -> Data? {
        guard let lineEndIndex = receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let lineBytes = Data(receiveBuffer[receiveBuffer.startIndex..<lineEndIndex])
        receiveBuffer.removeSubrange(receiveBuffer.startIndex...lineEndIndex)
        return lineBytes
    }

    private func waitForBytesToArrive(timeoutSeconds: Double) -> Bool {
        var descriptorSet = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(timeoutSeconds * 1000)

        while true {
            let pollResult = poll(&descriptorSet, 1, timeoutMilliseconds)
            if pollResult > 0 { return true }
            if pollResult == 0 { return false }
            // A signal interrupted the wait. Retrying is right because the Ctrl-C handler ends the
            // process on its own; treating `EINTR` as a timeout would cut a reply short.
            if errno != EINTR { return false }
        }
    }

    private func readWhateverIsAvailable() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fileDescriptor, &buffer, buffer.count)
        guard bytesRead > 0 else { return false }
        receiveBuffer.append(contentsOf: buffer[0..<bytesRead])
        return true
    }
}
