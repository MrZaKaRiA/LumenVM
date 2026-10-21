import XCTest
@testable import LumenCore

final class GuestProcessTests: XCTestCase {
    func testControlFramesSurviveFragmentedReadsAndSkipUnrecognizedInput() throws {
        var frames = GuestProcessFrames()
        let command = try GuestProcessFrames.encode(GuestProcessMessage(command: .pause))
        XCTAssertTrue(try frames.append(command.prefix(3)).isEmpty)
        let status = GuestProcessStatus(state: .paused, progress: 0.5, error: nil)
        let events = try frames.append(command.dropFirst(3) + Data("diagnostic line\n{\"command\":\"execute-shell\"}\n".utf8)
            + GuestProcessFrames.encode(GuestProcessMessage(status: status)))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].command, .pause)
        XCTAssertEqual(events[1].status?.state, .paused)
        XCTAssertEqual(events[1].status?.progress, 0.5)
        XCTAssertTrue(try frames.append(Data()).isEmpty)
    }

    func testControlFramesRejectOversizedMessages() throws {
        var frames = GuestProcessFrames()
        XCTAssertThrowsError(try frames.append(Data(repeating: 65, count: 16_385)))
        var terminatedFrames = GuestProcessFrames()
        XCTAssertThrowsError(try terminatedFrames.append(Data(repeating: 65, count: 16_385) + Data([10])))
        XCTAssertThrowsError(try GuestProcessFrames.encode(GuestProcessMessage(
            status: GuestProcessStatus(state: .failed, progress: 0, error: String(repeating: "x", count: 17_000)))))
    }

    func testRuntimeLeaseProtectsDiskAndConfigurationUntilGuestExits() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("GuestLeaseTests-" + UUID().uuidString)
        let library = try MachineLibrary(root: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var record = VirtualMachineRecord(name: "Lease test", guest: .ubuntu)
        try library.create(record)
        let location = library.location(for: record.id)
        var lease: GuestRuntimeLease? = try GuestRuntimeLease(directory: location.directory)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try GuestRuntimeLease(directory: location.directory))
        record.name = "Changed"
        XCTAssertThrowsError(try library.save(record))
        XCTAssertThrowsError(try library.growDisk(for: record.id, toGiB: record.diskGiB + 8))
        XCTAssertThrowsError(try library.deletePermanently(record.id))
        XCTAssertEqual(try library.load().first?.name, "Lease test")
        XCTAssertEqual(try SparseDisk.usage(at: location.disk).capacityBytes, Int64(record.diskGiB) * 1_073_741_824)
        lease = nil
        try library.save(record)
        try library.growDisk(for: record.id, toGiB: record.diskGiB + 8)
        XCTAssertEqual(try library.load().first?.name, "Changed")
        try library.deletePermanently(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path))
    }

    func testRuntimeLeaseRejectsSymbolicLinks() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("GuestLockLinkTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("UnrelatedFile")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("NativeRuntime.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try GuestRuntimeLease(directory: directory))
        XCTAssertEqual(try String(contentsOf: target), "untouched")
    }
}
