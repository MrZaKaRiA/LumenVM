import Foundation
import Darwin

public struct DiskUsage: Equatable {
    public let capacityBytes: Int64
    public let allocatedBytes: Int64
}

public enum SparseDisk {
    /// ftruncate extends the logical address space without reserving physical SSD blocks.
    public static func create(at url: URL, capacityBytes: Int64) throws {
        guard capacityBytes > 0 else { throw LibraryError.diskCreation("Disk capacity must be positive.") }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryError.diskCreation(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(capacityBytes)) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(url.path)
            throw LibraryError.diskCreation(message)
        }
    }

    public static func usage(at url: URL) throws -> DiskUsage {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LibraryError.diskCreation(String(cString: strerror(errno))) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw LibraryError.diskCreation("The virtual disk must be a regular file.") }
        return DiskUsage(capacityBytes: Int64(info.st_size), allocatedBytes: Int64(info.st_blocks) * 512)
    }
}

public final class MachineLibrary {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func location(for id: UUID) -> VMLocation {
        VMLocation(directory: root.appendingPathComponent(id.uuidString + ".lumen", isDirectory: true))
    }
    public func load() throws -> [VirtualMachineRecord] {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        return try directories.filter { $0.pathExtension == "lumen" }.map { url in
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw LibraryError.invalidConfiguration("A linked machine folder cannot be opened: \(url.lastPathComponent)")
            }
            let record = try JSONDecoder().decode(VirtualMachineRecord.self, from: Data(contentsOf: VMLocation(directory: url).configuration))
            guard url.lastPathComponent == location(for: record.id).directory.lastPathComponent else {
                throw LibraryError.invalidConfiguration("The machine identifier does not match its folder: \(url.lastPathComponent)")
            }
            try record.validate()
            return record
        }.sorted { $0.createdAt < $1.createdAt }
    }
    public func create(_ record: VirtualMachineRecord) throws {
        try record.validate()
        let destination = location(for: record.id)
        guard !FileManager.default.fileExists(atPath: destination.directory.path) else {
            throw LibraryError.invalidConfiguration("A machine with this identifier already exists.")
        }
        let staging = root.appendingPathComponent(".creating-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedLocation = VMLocation(directory: staging)
        try SparseDisk.create(at: stagedLocation.disk, capacityBytes: Int64(record.diskGiB) * 1_073_741_824)
        try encode(record).write(to: stagedLocation.configuration, options: .atomic)
        try FileManager.default.moveItem(at: staging, to: destination.directory)
    }
    public func save(_ record: VirtualMachineRecord) throws {
        try record.validate()
        let url = location(for: record.id).configuration
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.missingMachine }
        try encode(record).write(to: url, options: .atomic)
    }
    /// Grows the sparse disk's logical size. Shrinking is refused because it would destroy guest data.
    /// The guest must extend its own partition afterwards.
    public func growDisk(for id: UUID, toGiB capacity: Int) throws {
        let disk = location(for: id).disk
        let current = try SparseDisk.usage(at: disk).capacityBytes
        let requested = Int64(capacity) * 1_073_741_824
        guard requested >= current else { throw LibraryError.invalidConfiguration("Disks can grow but never shrink; shrinking would destroy guest data.") }
        guard requested > current else { return }
        let descriptor = open(disk.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LibraryError.diskCreation(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(requested)) == 0 else { throw LibraryError.diskCreation(String(cString: strerror(errno))) }
    }
    private func encode(_ record: VirtualMachineRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}
