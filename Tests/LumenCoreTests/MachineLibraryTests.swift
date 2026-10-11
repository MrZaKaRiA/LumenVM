import XCTest
@testable import LumenCore

final class MachineLibraryTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        temporary = root.appendingPathComponent("LumenTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let temporary, FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
    }

    func testSparseDiskUsesOnlyWrittenBlocksAndNeverOverwrites() throws {
        let disk = temporary.appendingPathComponent("Disk.img")
        let capacity: Int64 = 64 * 1_073_741_824
        try SparseDisk.create(at: disk, capacityBytes: capacity)
        let empty = try SparseDisk.usage(at: disk)
        XCTAssertEqual(empty.capacityBytes, capacity)
        XCTAssertLessThan(empty.allocatedBytes, 1_048_576)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: 32 * 1_073_741_824)
        try handle.write(contentsOf: Data(repeating: 0xAF, count: 1_048_576))
        try handle.synchronize()
        try handle.close()
        let written = try SparseDisk.usage(at: disk)
        XCTAssertEqual(written.capacityBytes, capacity)
        XCTAssertGreaterThan(written.allocatedBytes, empty.allocatedBytes)
        XCTAssertLessThan(written.allocatedBytes, 8 * 1_048_576)
        XCTAssertThrowsError(try SparseDisk.create(at: disk, capacityBytes: 10))
        XCTAssertEqual(try SparseDisk.usage(at: disk), written)
    }

    func testLibraryPersistsResourcesIdentityAndInstallerEject() throws {
        let library = try MachineLibrary(root: temporary)
        var record = VirtualMachineRecord(name: "Debian / work", guest: .debian, installerPath: "/install/debian-arm64.iso")
        try library.create(record)
        XCTAssertEqual(try library.load(), [record])
        XCTAssertEqual(library.location(for: record.id).directory.deletingLastPathComponent().path, temporary.path)
        let originalMAC = record.macAddress
        record.installerPath = nil
        try library.save(record)
        let restored = try XCTUnwrap(library.load().first)
        XCTAssertNil(restored.installerPath)
        XCTAssertEqual(restored.macAddress, originalMAC)
        XCTAssertThrowsError(try library.create(record))
    }

    func testUnsupportedAndWrongArchitectureDoNotCreateDisks() throws {
        let library = try MachineLibrary(root: temporary)
        for record in [
            VirtualMachineRecord(name: "Wrong architecture", guest: .ubuntu, installerPath: "/ubuntu-amd64.iso"),
            VirtualMachineRecord(name: "Unsupported", guest: .android),
            VirtualMachineRecord(name: "Invalid capacity", guest: .linux, diskGiB: -1),
            VirtualMachineRecord(name: "Bad Mac image", guest: .macOS, installerPath: "/mac.iso")
        ] {
            XCTAssertThrowsError(try library.create(record))
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.location(for: record.id).directory.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [])
    }

    func testMachineIdentityCannotRedirectLibraryToAnotherFolder() throws {
        let library = try MachineLibrary(root: temporary)
        let record = VirtualMachineRecord(name: "Original", guest: .ubuntu)
        try library.create(record)
        var forged = record
        forged.id = UUID()
        try JSONEncoder().encode(forged).write(to: library.location(for: record.id).configuration)
        XCTAssertThrowsError(try library.load())
    }

    func testDiskUsageRejectsSymlink() throws {
        let disk = temporary.appendingPathComponent("original")
        let link = temporary.appendingPathComponent("link")
        try SparseDisk.create(at: disk, capacityBytes: 4096)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: disk)
        XCTAssertThrowsError(try SparseDisk.usage(at: link))
    }
}
