import Foundation
import Darwin

/// Only fixed native-VM actions cross the inherited parent/child pipes.
public enum GuestProcessCommand: String, Codable {
    case show, pause, resume, shutdown, forceStop, installTools, unlock, refresh
}

public struct GuestProcessStatus: Codable {
    public let state: VMRuntimeState
    public let progress: Double
    public let error: String?
    public init(state: VMRuntimeState, progress: Double, error: String?) {
        self.state = state; self.progress = progress; self.error = error
    }
}

public struct GuestProcessMessage: Codable {
    public var command: GuestProcessCommand?
    public var status: GuestProcessStatus?
    public var libraryAction: String?
    public init(command: GuestProcessCommand? = nil, status: GuestProcessStatus? = nil, libraryAction: String? = nil) {
        self.command = command; self.status = status; self.libraryAction = libraryAction
    }
}

/// Bounded JSON lines accept partial pipe reads, never shell commands or archives.
public struct GuestProcessFrames {
    private var pending = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [GuestProcessMessage] {
        pending.append(data)
        var messages: [GuestProcessMessage] = []
        while let end = pending.firstIndex(of: 10) {
            guard end <= 16_384 else { throw LibraryError.invalidConfiguration("The guest control message is too large.") }
            let line = pending.prefix(upTo: end)
            pending.removeSubrange(...end)
            if let message = try? JSONDecoder().decode(GuestProcessMessage.self, from: line) { messages.append(message) }
        }
        guard pending.count <= 16_384 else { throw LibraryError.invalidConfiguration("The guest control message is too large.") }
        return messages
    }
    public static func encode(_ message: GuestProcessMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard data.count <= 16_384 else { throw LibraryError.invalidConfiguration("The guest control message is too large.") }
        return data + Data([10])
    }
}

/// The kernel releases this lease after a crash. Never unlink a live lock file.
public final class GuestRuntimeLease {
    private let descriptor: Int32
    public init(directory: URL) throws {
        let path = directory.appendingPathComponent("NativeRuntime.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LibraryError.invalidConfiguration("Could not open this VM's runtime lock.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            close(fd)
            throw LibraryError.invalidConfiguration("The VM runtime lock must be a regular file owned by your account.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LibraryError.invalidConfiguration("This VM is already open in its own app. Shut it down there before starting it again, changing its settings or deleting it.")
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
