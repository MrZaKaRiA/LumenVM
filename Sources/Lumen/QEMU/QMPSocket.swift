import Darwin
import Foundation
import LumenCore

struct QMPSocketError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// sendmsg/recvmsg with one SCM_RIGHTS descriptor. Swift cannot use the CMSG_* macros, so the
/// Darwin layout is spelled out: a 12-byte cmsghdr followed by a 4-byte-aligned int.
enum UnixRights {
    private static let headerLength = MemoryLayout<cmsghdr>.size
    private static let controlLength = headerLength + MemoryLayout<Int32>.size

    /// Sends all of `data`; `fd`, if any, rides on the first sendmsg call.
    static func send(_ socket: Int32, data: Data, fd: Int32?) throws {
        var offset = 0
        var pendingFD = fd
        while offset < data.count {
            let sent: Int = data.withUnsafeBytes { bytes -> Int in
                var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress! + offset), iov_len: data.count - offset)
                var message = msghdr()
                return withUnsafeMutablePointer(to: &iov) { iovPointer in
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    guard let descriptor = pendingFD else { return sendmsg(socket, &message, 0) }
                    var control = [UInt8](repeating: 0, count: controlLength)
                    return control.withUnsafeMutableBytes { raw in
                        raw.storeBytes(of: cmsghdr(cmsg_len: socklen_t(controlLength), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
                        raw.storeBytes(of: descriptor, toByteOffset: headerLength, as: Int32.self)
                        message.msg_control = raw.baseAddress
                        message.msg_controllen = socklen_t(controlLength)
                        return sendmsg(socket, &message, 0)
                    }
                }
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw QMPSocketError("Could not write to QEMU’s device monitor: \(String(cString: strerror(errno))).")
            }
            pendingFD = nil
            offset += sent
        }
    }

    /// Receives one message and at most one descriptor (extra descriptors are closed).
    static func receive(_ socket: Int32, maxLength: Int = 256) throws -> (data: Data, fd: Int32?) {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var control = [UInt8](repeating: 0, count: 256)
        while true {
            var received: (Int, [Int32]) = (0, [])
            buffer.withUnsafeMutableBytes { bytes in
                control.withUnsafeMutableBytes { controlBytes in
                    var iov = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                    withUnsafeMutablePointer(to: &iov) { iovPointer in
                        var message = msghdr()
                        message.msg_iov = iovPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlBytes.baseAddress
                        message.msg_controllen = socklen_t(controlBytes.count)
                        let count = recvmsg(socket, &message, 0)
                        guard count >= 0 else { received = (count, []); return }
                        var fds: [Int32] = []
                        var cursor = 0
                        let total = Int(message.msg_controllen)
                        while cursor + headerLength <= total {
                            let header = controlBytes.load(fromByteOffset: cursor, as: cmsghdr.self)
                            let length = Int(header.cmsg_len)
                            guard length >= headerLength, cursor + length <= total else { break }
                            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                                var position = cursor + headerLength
                                while position + 4 <= cursor + length {
                                    fds.append(controlBytes.load(fromByteOffset: position, as: Int32.self))
                                    position += 4
                                }
                            }
                            cursor += (length + 3) & ~3
                        }
                        received = (count, fds)
                    }
                }
            }
            if received.0 < 0 {
                if errno == EINTR { continue }
                throw QMPSocketError("Could not receive a descriptor: \(String(cString: strerror(errno))).")
            }
            for extra in received.1.dropFirst() { close(extra) }
            return (Data(buffer.prefix(received.0)), received.1.first)
        }
    }
}

/// A second QMP monitor on a private unix socket, used only for device hot-plug.
/// The stdio monitor remains the single consumer of VM state events; this connection only
/// tracks replies to its own commands and DEVICE_DELETED events. All socket I/O happens off
/// the main actor: a dedicated reader thread and a serial write queue.
final class QMPSocket: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "Lumen.QMPSocket.write")
    private var socketFD: Int32 = -1
    private var isClosed = false
    private var counter = 0
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var deletedDevices: Set<String> = []
    private var deletionWaiters: [String: CheckedContinuation<Void, Error>] = [:]

    init(path: String) { self.path = path }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return socketFD >= 0 && !isClosed
    }

    /// Connects, reads the greeting and negotiates capabilities.
    func connect(timeout: TimeInterval = 5) async throws {
        let path = self.path
        let (fd, leftover) = try await Self.background {
            try Self.openAndGreet(path: path, deadline: Date().addingTimeInterval(timeout))
        }
        let accepted = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            socketFD = fd
            return true
        }
        guard accepted else { Darwin.close(fd); throw QMPSocketError("QEMU’s device monitor was closed.") }
        // The reader owns the descriptor and runs until close() shuts the socket down.
        let reader = Thread { self.readLoop(fd: fd, initial: leftover) }
        reader.name = "Lumen.QMPSocket.read"
        reader.start()
        _ = try await execute("qmp_capabilities", timeout: timeout)
    }

    /// Sends one command (optionally with a descriptor as SCM_RIGHTS) and awaits its reply.
    @discardableResult
    func execute(_ name: String, arguments: [String: Any]? = nil, fd: Int32? = nil, timeout: TimeInterval = 10) async throws -> Any {
        let (id, socket, closed) = lock.withLock { () -> (String, Int32, Bool) in
            counter += 1
            return ("lumen-dev-\(counter)", socketFD, isClosed)
        }
        guard socket >= 0, !closed else { throw QMPSocketError("QEMU’s device monitor is not connected.") }
        let payload = try QMPMessages.command(name, arguments: arguments, id: id)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: QMPSocketError("QEMU’s device monitor was closed."))
                return
            }
            pending[id] = continuation
            lock.unlock()
            writeQueue.async { [weak self] in
                do { try UnixRights.send(socket, data: payload, fd: fd) }
                catch { self?.finish(id, .failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, .failure(QMPSocketError("QEMU timed out while executing \(name).")))
            }
        }
    }

    /// Discards a stale DEVICE_DELETED record before (re)using a device id.
    func forgetDeletion(of deviceID: String) {
        lock.lock(); deletedDevices.remove(deviceID); lock.unlock()
    }

    /// Waits for DEVICE_DELETED for `deviceID`; returns at once if it already arrived.
    func waitForDeviceDeleted(_ deviceID: String, timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if deletedDevices.remove(deviceID) != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: QMPSocketError("QEMU’s device monitor was closed."))
                return
            }
            deletionWaiters.removeValue(forKey: deviceID)?.resume(throwing: QMPSocketError("Superseded."))
            deletionWaiters[deviceID] = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiter = self.deletionWaiters.removeValue(forKey: deviceID)
                self.lock.unlock()
                waiter?.resume(throwing: QMPSocketError("The guest did not release the USB device within \(Int(timeout)) seconds."))
            }
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let fd = socketFD
        let replies = pending
        let waiters = deletionWaiters
        pending.removeAll()
        deletionWaiters.removeAll()
        lock.unlock()
        // Wakes the reader thread, which owns closing the descriptor.
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        let error = QMPSocketError("QEMU’s device monitor was closed.")
        replies.values.forEach { $0.resume(throwing: error) }
        waiters.values.forEach { $0.resume(throwing: error) }
    }

    private func finish(_ id: String, _ result: Result<Any, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handle(_ line: Data) {
        guard let parsed = QMPLine(line) else { return }
        switch parsed {
        case let .reply(id?, result):
            finish(id, result.mapError { $0 as Error })
        case .event:
            guard let device = parsed.deletedDeviceID else { return }
            lock.lock()
            let waiter = deletionWaiters.removeValue(forKey: device)
            if waiter == nil { deletedDevices.insert(device) }
            lock.unlock()
            waiter?.resume()
        default:
            break
        }
    }

    private func readLoop(fd: Int32, initial: Data) {
        var buffer = initial
        var chunk = [UInt8](repeating: 0, count: 65536)
        outer: while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(Data(line))
            }
            guard buffer.count < 4_194_304 else { break }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { buffer.append(contentsOf: chunk[0..<count]); continue }
            if count < 0, errno == EINTR { continue outer }
            break
        }
        close()
        Darwin.close(fd)
    }

    private static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Blocking connect + greeting read, retried until the deadline while QEMU creates the socket.
    private static func openAndGreet(path: String, deadline: Date) throws -> (Int32, Data) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw QMPSocketError("The device monitor socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw QMPSocketError("Could not create a socket: \(String(cString: strerror(errno))).") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 {
                do { return (fd, try readGreeting(fd: fd, deadline: deadline)) }
                catch { Darwin.close(fd); throw error }
            }
            let failure = errno
            Darwin.close(fd)
            guard (failure == ENOENT || failure == ECONNREFUSED), Date() < deadline else {
                throw QMPSocketError("Could not connect to QEMU’s device monitor: \(String(cString: strerror(failure))).")
            }
            usleep(50_000)
        }
    }

    private static func readGreeting(fd: Int32, deadline: Date) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard case .greeting? = QMPLine(buffer[buffer.startIndex..<newline]) else {
                    throw QMPSocketError("QEMU’s device monitor sent an unexpected greeting.")
                }
                return Data(buffer[buffer.index(after: newline)...])
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw QMPSocketError("QEMU’s device monitor did not greet in time.") }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 5) * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw QMPSocketError("QEMU closed its device monitor during the greeting.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
