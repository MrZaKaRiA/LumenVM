import Testing
import Foundation
@testable import LumenCore

@Suite final class DiskReclamationTests {
    private let directory: URL
    init() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/private/tmp")
        directory = root.appendingPathComponent("Reclamation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func testReclamationPreservesEveryByteAndCapacityIncludingUnalignedTail() throws {
        let disk = directory.appendingPathComponent("Disk.img")
        var original = Data(repeating: 0, count: 16 * 1_048_576 + 13)
        for offset in [0, 4097, 4 * 1_048_576 + 4095, 12 * 1_048_576, original.count - 1] { original[offset] = 0xA7 }
        try original.write(to: disk)
        let before = try SparseDisk.usage(at: disk)
        let result = try SparseDisk.reclaimZeroBlocks(at: disk)
        #expect(result.before == before)
        #expect(result.after.capacityBytes == before.capacityBytes)
        #expect(result.reclaimedBytes > 8 * 1_048_576)
        #expect(try Data(contentsOf: disk) == original)
        let again = try SparseDisk.reclaimZeroBlocks(at: disk)
        #expect(again.reclaimedBytes == 0)
        #expect(try Data(contentsOf: disk) == original)
    }

    @Test func testNonzeroDiskIsNotClaimedAsReclaimed() throws {
        let disk = directory.appendingPathComponent("Disk.img")
        let original = Data(repeating: 0xAB, count: 2 * 1_048_576)
        try original.write(to: disk)
        let result = try SparseDisk.reclaimZeroBlocks(at: disk)
        #expect(result.reclaimedBytes == 0)
        #expect(result.before == result.after)
        #expect(try Data(contentsOf: disk) == original)
    }

    @Test func testSparseHolesAreSkippedWithoutGrowingOrChangingData() throws {
        let disk = directory.appendingPathComponent("Disk.img")
        try SparseDisk.create(at: disk, capacityBytes: 256 * 1_048_576)
        let result = try SparseDisk.reclaimZeroBlocks(at: disk)
        #expect(result.before == result.after)
        #expect(result.after.allocatedBytes == 0)
    }

    @Test func testCancellationAndUnsafeLinksPreserveOriginalContents() throws {
        let disk = directory.appendingPathComponent("Disk.img")
        let original = Data(repeating: 0x31, count: 1_048_576)
        try original.write(to: disk)
        #expect(throws: CancellationError.self) { try SparseDisk.reclaimZeroBlocks(at: disk, isCancelled: { true }) }
        #expect(try Data(contentsOf: disk) == original)
        let link = directory.appendingPathComponent("Link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: disk)
        #expect(throws: (any Error).self) { try SparseDisk.reclaimZeroBlocks(at: link) }
        let hardLink = directory.appendingPathComponent("HardLink.img")
        try FileManager.default.linkItem(at: disk, to: hardLink)
        #expect(throws: (any Error).self) { try SparseDisk.reclaimZeroBlocks(at: disk) }
        #expect(try Data(contentsOf: hardLink) == original)
    }

    @Test func testCancellationAfterPartialReclamationPreservesEveryByteAndCanResume() throws {
        let disk = directory.appendingPathComponent("Disk.img")
        var original = Data(repeating: 0, count: 16 * 1_048_576)
        original[0] = 0x51
        original[original.count - 1] = 0xA3
        try original.write(to: disk)
        let before = try SparseDisk.usage(at: disk)
        let cancellation = ReclaimCancellation()
        #expect(throws: CancellationError.self) {
            try SparseDisk.reclaimZeroBlocks(at: disk,
                progress: { _ in cancellation.request() }, isCancelled: { cancellation.requested })
        }
        #expect(try SparseDisk.usage(at: disk).allocatedBytes < before.allocatedBytes)
        #expect(try Data(contentsOf: disk) == original)
        _ = try SparseDisk.reclaimZeroBlocks(at: disk)
        #expect(try Data(contentsOf: disk) == original)
    }

    @Test func testRuntimeLeaseBlocksReclamationThenReleasesWithoutChangingIdentity() throws {
        let library = try MachineLibrary(root: directory)
        let record = VirtualMachineRecord(name: "Reclaim test", guest: .ubuntu)
        try library.create(record)
        let location = library.location(for: record.id)
        let config = try Data(contentsOf: location.configuration)
        var lease: GuestRuntimeLease? = try GuestRuntimeLease(directory: location.directory)
        #expect(lease != nil)
        #expect(throws: (any Error).self) { try library.reclaimDisk(for: record.id) }
        lease = nil
        _ = try library.reclaimDisk(for: record.id)
        #expect(try Data(contentsOf: location.configuration) == config)
        #expect(try library.load() == [record])
    }
}

private final class ReclaimCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func request() { lock.lock(); value = true; lock.unlock() }
}
