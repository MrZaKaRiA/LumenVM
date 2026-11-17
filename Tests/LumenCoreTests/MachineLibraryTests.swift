import Testing
import Foundation
@testable import LumenCore

@Suite final class MachineLibraryTests {
    private let temporary: URL
    init() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        temporary = root.appendingPathComponent("LumenTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    deinit {
        if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) }
    }

    @Test func testSparseDiskUsesOnlyWrittenBlocksAndNeverOverwrites() throws {
        let disk = temporary.appendingPathComponent("Disk.img")
        let capacity: Int64 = 64 * 1_073_741_824
        try SparseDisk.create(at: disk, capacityBytes: capacity)
        let empty = try SparseDisk.usage(at: disk)
        #expect(empty.capacityBytes == capacity)
        #expect(empty.allocatedBytes < 1_048_576)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: 32 * 1_073_741_824)
        try handle.write(contentsOf: Data(repeating: 0xAF, count: 1_048_576))
        try handle.synchronize()
        try handle.close()
        let written = try SparseDisk.usage(at: disk)
        #expect(written.capacityBytes == capacity)
        #expect(written.allocatedBytes > empty.allocatedBytes)
        #expect(written.allocatedBytes < 8 * 1_048_576)
        #expect(throws: (any Error).self) { try SparseDisk.create(at: disk, capacityBytes: 10) }
        #expect(try SparseDisk.usage(at: disk) == written)
    }

    @Test func testPermanentDeletionRemovesSparseDiskAndKeepsExternalInstaller() throws {
        let library = try MachineLibrary(root: temporary.appendingPathComponent("Machines"))
        let installer = temporary.appendingPathComponent("installer.iso")
        try Data("original installer".utf8).write(to: installer)
        let record = VirtualMachineRecord(name: "Disposable", guest: .ubuntu, installerPath: installer.path)
        try library.create(record)
        let location = library.location(for: record.id)
        let handle = try FileHandle(forWritingTo: location.disk)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 1_048_576))
        try handle.close()
        #expect(try SparseDisk.usage(at: location.disk).allocatedBytes > 0)
        try library.deletePermanently(record.id)
        #expect(!FileManager.default.fileExists(atPath: location.directory.path))
        #expect(try Data(contentsOf: installer) == Data("original installer".utf8))
        #expect(throws: (any Error).self) { try library.deletePermanently(record.id) }
    }

    @Test func testLibraryPersistsResourcesIdentityAndInstallerEject() throws {
        let library = try MachineLibrary(root: temporary)
        var record = VirtualMachineRecord(name: "Debian / work", guest: .debian, installerPath: "/install/debian-arm64.iso")
        try library.create(record)
        #expect(try library.load() == [record])
        #expect(library.location(for: record.id).directory.deletingLastPathComponent().path == temporary.path)
        let originalMAC = record.macAddress
        record.installerPath = nil
        try library.save(record)
        let restored = try #require(try library.load().first)
        #expect(restored.installerPath == nil)
        #expect(restored.macAddress == originalMAC)
        #expect(throws: (any Error).self) { try library.create(record) }
    }

    @Test func testUnsupportedAndWrongArchitectureDoNotCreateDisks() throws {
        let library = try MachineLibrary(root: temporary)
        for record in [
            VirtualMachineRecord(name: "Wrong architecture", guest: .ubuntu, installerPath: "/ubuntu-amd64.iso"),
            VirtualMachineRecord(name: "Unsupported", guest: .android),
            VirtualMachineRecord(name: "Invalid capacity", guest: .linux, diskGiB: -1),
            VirtualMachineRecord(name: "Bad Mac image", guest: .macOS, installerPath: "/mac.iso")
        ] {
            #expect(throws: (any Error).self) { try library.create(record) }
            #expect(!FileManager.default.fileExists(atPath: library.location(for: record.id).directory.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == [])
    }

    @Test func testMachineIdentityCannotRedirectLibraryToAnotherFolder() throws {
        let library = try MachineLibrary(root: temporary)
        let record = VirtualMachineRecord(name: "Original", guest: .ubuntu)
        try library.create(record)
        var forged = record
        forged.id = UUID()
        try JSONEncoder().encode(forged).write(to: library.location(for: record.id).configuration)
        #expect(throws: (any Error).self) { try library.load() }
    }

    @Test func testDiskUsageRejectsSymlink() throws {
        let disk = temporary.appendingPathComponent("original")
        let link = temporary.appendingPathComponent("link")
        try SparseDisk.create(at: disk, capacityBytes: 4096)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: disk)
        #expect(throws: (any Error).self) { try SparseDisk.usage(at: link) }
    }
}
