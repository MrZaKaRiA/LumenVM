import Darwin
import Foundation
import LumenCore

struct HostDiskError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Opens, unmounts, mounts and ejects whole host disks. Every entry point validates the BSD name
/// before building a /dev path, and all blocking work runs off the main thread.
enum HostDiskOpener {
    private static let diskutil = "/usr/sbin/diskutil"
    private static let authopen = "/usr/libexec/authopen"

    /// Opens `/dev/rdiskN`. User-owned nodes (for example a disk image attached with
    /// `hdiutil attach -nomount`) open directly; root-owned nodes go through authopen, which shows
    /// the macOS administrator prompt and passes the descriptor back over a socketpair.
    static func open(bsdName: String, readOnly: Bool) async throws -> FileHandle {
        let path = try rawDevicePath(bsdName)
        let flags = readOnly ? O_RDONLY : O_RDWR
        let fd = try await background { () throws -> Int32 in
            let direct = Darwin.open(path, flags | O_CLOEXEC)
            if direct >= 0 { return direct }
            let failure = errno
            guard failure == EACCES || failure == EPERM else {
                throw HostDiskError("Could not open \(path): \(String(cString: strerror(failure))).")
            }
            return try authorizedOpen(path: path, flags: flags)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR else {
            close(fd)
            throw HostDiskError("\(path) is not a disk device.")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Unmounts every volume on the disk (including volumes of an APFS synthesized container).
    static func unmount(bsdName: String) async throws {
        try await run(diskutil, ["unmountDisk", try devicePath(bsdName)], action: "unmount")
    }

    static func mount(bsdName: String) async throws {
        try await run(diskutil, ["mountDisk", try devicePath(bsdName)], action: "mount")
    }

    static func eject(bsdName: String) async throws {
        try await run(diskutil, ["eject", try devicePath(bsdName)], action: "eject")
    }

    /// Current properties of a whole disk, from `diskutil info -plist`.
    static func describe(bsdName: String) async throws -> HostDisk {
        let info = try await diskutilInfo(try devicePath(bsdName))
        guard let disk = HostDisk(diskutilInfo: info), disk.bsdName == bsdName else {
            throw HostDiskError("macOS returned no information for \(bsdName).")
        }
        return disk
    }

    /// Whole disks that back the given paths' volumes (the boot volume, the VM bundle, …).
    /// Throws if any lookup fails, so callers never treat "unknown" as "safe".
    static func protectedWholeDisks(for paths: [String]) async throws -> Set<String> {
        var result = Set<String>()
        for path in paths {
            var info = statfs()
            guard statfs(path, &info) == 0 else {
                throw HostDiskError("Could not determine the volume of \(path): \(String(cString: strerror(errno))).")
            }
            let source = withUnsafeBytes(of: &info.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            // Network and other non-disk volumes have no backing whole disk.
            guard source.hasPrefix("/dev/disk") else { continue }
            result.formUnion(HostDisk.backingWholeDisks(diskutilInfo: try await diskutilInfo(mountPoint)))
        }
        return result
    }

    // MARK: - Internals

    private static func devicePath(_ bsdName: String) throws -> String {
        guard HostDisk.isValidBSDName(bsdName) else { throw HostDiskError("“\(bsdName)” is not a whole-disk name.") }
        return "/dev/\(bsdName)"
    }

    private static func rawDevicePath(_ bsdName: String) throws -> String {
        guard HostDisk.isValidBSDName(bsdName) else { throw HostDiskError("“\(bsdName)” is not a whole-disk name.") }
        return "/dev/r\(bsdName)"
    }

    private static func diskutilInfo(_ target: String) async throws -> [String: Any] {
        let output = try await run(diskutil, ["info", "-plist", target], action: "inspect")
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any] else {
            throw HostDiskError("diskutil returned unreadable information for \(target).")
        }
        return plist
    }

    /// Runs authopen with its stdout bound to one end of a socketpair and receives the descriptor.
    private static func authorizedOpen(path: String, flags: Int32) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw HostDiskError("Could not create a socket pair: \(String(cString: strerror(errno))).")
        }
        defer { close(pair[0]) }
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: authopen)
        process.arguments = ["-stdoutpipe", "-o", String(flags), path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = child
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch {
            try? child.close()
            throw HostDiskError("Could not start authopen: \(error.localizedDescription)")
        }
        // Only authopen may hold the write end, so EOF arrives when it exits.
        try? child.close()
        let received = try? UnixRights.receive(pair[0])
        process.waitUntilExit()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fd = received?.fd else {
            throw HostDiskError("macOS did not grant access to \(path)" + (detail.isEmpty ? " (authorization was cancelled or denied)." : ": \(detail)"))
        }
        guard process.terminationStatus == 0 else {
            close(fd)
            throw HostDiskError("authopen failed for \(path)" + (detail.isEmpty ? "." : ": \(detail)"))
        }
        return fd
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], action: String) async throws -> Data {
        try await background {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            // Drain both pipes concurrently so neither can fill and block the child.
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errorData = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = [errorData, outputData].map {
                    String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }.first { !$0.isEmpty } ?? "exit status \(process.terminationStatus)"
                throw HostDiskError("Could not \(action) \(arguments.last ?? "the disk"): \(detail)")
            }
            return outputData
        }
    }

    private static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
