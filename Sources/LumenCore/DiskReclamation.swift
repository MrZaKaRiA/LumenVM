import Foundation
import Darwin

public struct DiskReclamation: Sendable {
    public let before: DiskUsage
    public let after: DiskUsage
    /// Measured disk-image blocks, not a promise about APFS snapshots or volume free space.
    public var reclaimedBytes: Int64 { max(0, before.allocatedBytes - after.allocatedBytes) }
}

extension SparseDisk {
    /// Release only blocks read back as entirely zero. Does not interpret guest
    /// filesystems, shrink capacity, write zeroes or copy/preallocate the disk.
    /// The caller must hold the VM runtime lease and keep the guest shut down.
    public static func reclaimZeroBlocks(at url: URL, progress: @Sendable (Double) -> Void = { _ in },
                                         isCancelled: @Sendable () -> Bool = { false }) throws -> DiskReclamation {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0 else { throw failure() }
        guard (original.st_mode & S_IFMT) == S_IFREG, original.st_nlink == 1, original.st_uid == geteuid() else {
            throw LibraryError.invalidConfiguration("Reclamation requires a regular disk image owned by your account, without hard links.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw LibraryError.invalidConfiguration("This disk image is in use. Shut down its VM before reclaiming space.")
        }
        let before = DiskUsage(capacityBytes: Int64(original.st_size), allocatedBytes: Int64(original.st_blocks) * 512)
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw failure() }
        let unit = max(4096, Int(filesystem.f_bsize))
        guard unit <= 1_048_576, unit.nonzeroBitCount == 1 else {
            throw LibraryError.invalidConfiguration("This filesystem's allocation size is not supported for reclamation.")
        }
        let limit = original.st_size - original.st_size % off_t(unit)
        let bufferSize = 4 * 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: unit)
        let zero = UnsafeMutableRawPointer.allocate(byteCount: unit, alignment: unit)
        zero.initializeMemory(as: UInt8.self, repeating: 0, count: unit)
        defer { buffer.deallocate(); zero.deallocate() }
        // Persist any completed hole punches even if the scan is cancelled.
        defer { _ = fsync(fd) }
        var cursor: off_t = 0
        var useExtents = true
        var lastProgress = -1.0
        func report(_ offset: off_t) {
            let value = original.st_size == 0 ? 1 : min(1, Double(offset) / Double(original.st_size))
            if value - lastProgress >= 0.01 || value == 1 { lastProgress = value; progress(value) }
        }
        func punch(_ offset: off_t, _ length: off_t) throws {
            guard length > 0 else { return }
            if isCancelled() { throw CancellationError() }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: offset, fp_length: length)
            guard fcntl(fd, F_PUNCHHOLE, &hole) == 0 else {
                if errno == ENOTSUP || errno == EOPNOTSUPP || errno == ENOSYS {
                    throw LibraryError.invalidConfiguration("This host filesystem cannot release disk-image blocks in place. The disk's capacity and contents are preserved.")
                }
                throw failure()
            }
        }
        while cursor < limit {
            if isCancelled() { throw CancellationError() }
            var end = limit
            if useExtents {
                let data = lseek(fd, cursor, SEEK_DATA)
                if data < 0 {
                    if errno == ENXIO { break }
                    if errno == EINVAL || errno == ENOTSUP { useExtents = false }
                    else { throw failure() }
                } else {
                    cursor = max(cursor, data - data % off_t(unit))
                    if cursor >= limit { break }
                    let hole = lseek(fd, data, SEEK_HOLE)
                    if hole < 0 {
                        if errno == EINVAL || errno == ENOTSUP { useExtents = false }
                        else if errno != ENXIO { throw failure() }
                    } else {
                        guard hole > data else { throw LibraryError.diskCreation("Invalid disk extent returned by the host filesystem.") }
                        end = min(limit, hole + (off_t(unit) - hole % off_t(unit)) % off_t(unit))
                    }
                }
            }
            while cursor < end {
                if isCancelled() { throw CancellationError() }
                let count = Int(min(off_t(bufferSize), end - cursor))
                var readCount = 0
                while readCount < count {
                    let amount = pread(fd, buffer.advanced(by: readCount), count - readCount, cursor + off_t(readCount))
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw LibraryError.diskCreation("The disk changed or could not be read during reclamation.") }
                    readCount += amount
                }
                var zeroStart: Int?
                for offset in stride(from: 0, to: count, by: unit) {
                    if memcmp(buffer.advanced(by: offset), zero, unit) == 0 {
                        if zeroStart == nil { zeroStart = offset }
                    } else if let start = zeroStart {
                        try punch(cursor + off_t(start), off_t(offset - start))
                        zeroStart = nil
                    }
                }
                if let start = zeroStart { try punch(cursor + off_t(start), off_t(count - start)) }
                cursor += off_t(count)
                report(cursor)
            }
        }
        guard fsync(fd) == 0 else { throw failure() }
        var final = stat()
        guard fstat(fd, &final) == 0, final.st_size == original.st_size else {
            throw LibraryError.diskCreation("The disk's capacity changed during reclamation.")
        }
        report(original.st_size)
        return DiskReclamation(before: before, after: DiskUsage(capacityBytes: Int64(final.st_size), allocatedBytes: Int64(final.st_blocks) * 512))
    }

    private static func failure() -> LibraryError { .diskCreation(String(cString: strerror(errno))) }
}
