import Darwin
import Foundation
import Security

public enum LocalIPCError: LocalizedError {
    case invalidSocketPath
    case socketAlreadyInUse
    case systemCall(String, Int32)
    case connectionClosed
    case invalidResponse
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            return "The local socket path is too long."
        case .socketAlreadyInUse:
            return "Another Anton process already owns the local bridge."
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        case .connectionClosed:
            return "The local bridge closed the connection."
        case .invalidResponse:
            return "The local bridge returned an invalid response."
        case .authenticationFailed:
            return "The local bridge rejected the request."
        }
    }
}

public enum IPCTokenStore {
    public static func load(from url: URL = AntonPaths.tokenURL()) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    @discardableResult
    public static func ensure(at url: URL = AntonPaths.tokenURL()) throws -> String {
        if let existing = load(from: url) {
            return existing
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not create an IPC token."]
            )
        }

        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return token
    }
}

public final class UnixSocketClient {
    private let socketURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(socketURL: URL = AntonPaths.socketURL()) {
        self.socketURL = socketURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func send(
        _ request: BridgeRequest,
        timeout: TimeInterval = 2
    ) throws -> BridgeResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalIPCError.systemCall("socket", errno)
        }
        defer { Darwin.close(fd) }

        configureNoSIGPIPE(fd)
        try configureTimeout(fd, seconds: timeout)

        var address = try unixAddress(for: socketURL.path)
        let addressLength = unixAddressLength(for: socketURL.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard result == 0 else {
            throw LocalIPCError.systemCall("connect", errno)
        }

        var data = try encoder.encode(request)
        data.append(0x0A)
        try writeAll(data, to: fd)
        let responseData = try readLine(from: fd)
        guard let response = try? decoder.decode(BridgeResponse.self, from: responseData) else {
            throw LocalIPCError.invalidResponse
        }
        return response
    }
}

public final class UnixSocketServer {
    public typealias ResponseHandler = (BridgeResponse) -> Void
    public typealias RequestHandler = (BridgeRequest, @escaping ResponseHandler) -> Void

    private let socketURL: URL
    private let queue: DispatchQueue
    private let clientQueue: DispatchQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var socketIdentity: SocketFileIdentity?
    private var running = false
    private var token = ""
    private var requestHandler: RequestHandler?

    public init(socketURL: URL = AntonPaths.socketURL()) {
        self.socketURL = socketURL
        self.queue = DispatchQueue(label: "com.augustalabs.anton.ipc.accept")
        self.clientQueue = DispatchQueue(
            label: "com.augustalabs.anton.ipc.clients",
            attributes: .concurrent
        )
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        stop()
    }

    public func start(token: String, handler: @escaping RequestHandler) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try prepareSocketPath()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalIPCError.systemCall("socket", errno)
        }

        var boundIdentity: SocketFileIdentity?
        do {
            configureNoSIGPIPE(fd)
            var address = try unixAddress(for: socketURL.path)
            let addressLength = unixAddressLength(for: socketURL.path)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, addressLength)
                }
            }
            guard bindResult == 0 else {
                throw LocalIPCError.systemCall("bind", errno)
            }
            boundIdentity = try identityOfSocket(at: socketURL.path)
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                throw LocalIPCError.systemCall("chmod", errno)
            }
            guard Darwin.listen(fd, 32) == 0 else {
                throw LocalIPCError.systemCall("listen", errno)
            }
        } catch {
            Darwin.close(fd)
            unlinkSocketIfOwned(boundIdentity, at: socketURL.path)
            throw error
        }

        self.token = token
        self.requestHandler = handler
        self.listenerFD = fd
        self.socketIdentity = boundIdentity
        self.running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        lock.lock()
        let fd = listenerFD
        let ownedSocketIdentity = socketIdentity
        let wasRunning = running
        listenerFD = -1
        socketIdentity = nil
        running = false
        requestHandler = nil
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if wasRunning {
            unlinkSocketIfOwned(ownedSocketIdentity, at: socketURL.path)
        }
    }

    /// A crashed process can leave a stale filesystem entry behind. Probe it
    /// before removal so a second Anton instance can never unlink the socket
    /// belonging to the healthy supervised process.
    private func prepareSocketPath() throws {
        guard let existing = socketFileIdentity(at: socketURL.path) else { return }
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            throw LocalIPCError.systemCall("socket", errno)
        }
        defer { Darwin.close(probe) }
        var address = try unixAddress(for: socketURL.path)
        let addressLength = unixAddressLength(for: socketURL.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, addressLength)
            }
        }
        if result == 0 {
            throw LocalIPCError.socketAlreadyInUse
        }
        unlinkSocketIfOwned(existing, at: socketURL.path)
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = Darwin.accept(currentListenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            configureNoSIGPIPE(clientFD)
            clientQueue.async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        do {
            try configureTimeout(clientFD, seconds: 660)
            let requestData = try readLine(from: clientFD)
            let request = try decoder.decode(BridgeRequest.self, from: requestData)
            guard
                request.protocolVersion == antonProtocolVersion,
                constantTimeEqual(request.token, token)
            else {
                let response = BridgeResponse(
                    requestID: request.requestID,
                    decision: .deny,
                    message: "Authentication failed"
                )
                try send(response, to: clientFD)
                Darwin.close(clientFD)
                return
            }

            guard let requestHandler else {
                Darwin.close(clientFD)
                return
            }

            let responseLock = NSLock()
            var didRespond = false
            requestHandler(request) { [weak self] response in
                responseLock.lock()
                guard !didRespond else {
                    responseLock.unlock()
                    return
                }
                didRespond = true
                responseLock.unlock()
                defer { Darwin.close(clientFD) }
                try? self?.send(response, to: clientFD)
            }
        } catch {
            Darwin.close(clientFD)
        }
    }

    private func send(_ response: BridgeResponse, to fd: Int32) throws {
        var data = try encoder.encode(response)
        data.append(0x0A)
        try writeAll(data, to: fd)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private var currentListenerFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listenerFD
    }
}

private func unixAddress(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let maximum = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= maximum else {
        throw LocalIPCError.invalidSocketPath
    }

    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        _ = bytes.withUnsafeBytes { source in
            memcpy(destination.baseAddress, source.baseAddress, bytes.count)
        }
    }
    address.sun_len = UInt8(unixAddressLength(for: path))
    return address
}

private func unixAddressLength(for path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
}

private func configureNoSIGPIPE(_ fd: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    )
}

private func configureTimeout(_ fd: Int32, seconds: TimeInterval) throws {
    let wholeSeconds = Int(seconds)
    let microseconds = Int((seconds - Double(wholeSeconds)) * 1_000_000)
    var timeout = timeval(tv_sec: wholeSeconds, tv_usec: Int32(microseconds))
    guard setsockopt(
        fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw LocalIPCError.systemCall("setsockopt", errno)
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard var pointer = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        while remaining > 0 {
            let written = Darwin.write(fd, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                throw LocalIPCError.systemCall("write", errno)
            }
            if written == 0 {
                throw LocalIPCError.connectionClosed
            }
            remaining -= written
            pointer = pointer.advanced(by: written)
        }
    }
}

private func readLine(from fd: Int32, maximumBytes: Int = 262_144) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while result.count < maximumBytes {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw LocalIPCError.systemCall("read", errno)
        }
        if count == 0 {
            if result.isEmpty {
                throw LocalIPCError.connectionClosed
            }
            break
        }

        if let newlineIndex = buffer.prefix(count).firstIndex(of: 0x0A) {
            result.append(contentsOf: buffer[..<newlineIndex])
            return result
        }
        result.append(contentsOf: buffer[..<count])
    }

    guard !result.isEmpty else {
        throw LocalIPCError.connectionClosed
    }
    return result
}

private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
        difference |= left[index] ^ right[index]
    }
    return difference == 0
}

private struct SocketFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private func socketFileIdentity(at path: String) -> SocketFileIdentity? {
    var information = stat()
    let result = path.withCString { pointer in
        Darwin.lstat(pointer, &information)
    }
    guard result == 0 else { return nil }
    return SocketFileIdentity(
        device: information.st_dev,
        inode: information.st_ino
    )
}

private func identityOfSocket(at path: String) throws -> SocketFileIdentity {
    if let identity = socketFileIdentity(at: path) {
        return identity
    }
    throw LocalIPCError.systemCall("lstat", errno)
}

private func unlinkSocketIfOwned(
    _ identity: SocketFileIdentity?,
    at path: String
) {
    guard let identity, socketFileIdentity(at: path) == identity else { return }
    path.withCString { pointer in
        _ = Darwin.unlink(pointer)
    }
}
