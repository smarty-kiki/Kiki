import Foundation

/// The command line tool's end of the socket the app listens on.
final class KikiCommandSocketClient {

    let fileDescriptor: Int32

    private var receiveBuffer = Data()

    /// Serialised: the Ctrl-C handler writes from its own queue.
    private let writeLock = NSLock()

    /// A stale socket file answers `ECONNREFUSED`, the same as "not running", so it needs no case.
    init?(socketPath: String) {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= KikiCommandProtocol.maximumSocketPathByteCount else { return nil }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            // Measured above; `sockaddr_un()` zero-initialises, so it fits with its NUL.
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

        // The app dying mid-write would otherwise raise SIGPIPE, which by default kills this process.
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

    /// A wait that ran out and a connection the app closed are not collapsed: the second means Kiki
    /// went away mid-reply. Displacement arrives as an ordinary `superseded` event.
    enum ReadOutcome {
        case event(KikiCommandEvent)
        case timedOut
        case disconnected
    }

    func readNextEvent(timeoutSeconds: Double) -> ReadOutcome {
        while true {
            if let lineBytes = takeNextLineBytes() {
                guard let event = try? KikiCommandProtocol.makeDecoder().decode(KikiCommandEvent.self, from: lineBytes) else {
                    // Unreadable line: skipped, not fatal — a newer app may have added a type.
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
            // EINTR: the Ctrl-C handler ends the process itself, so retry — a timeout would cut it short.
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
