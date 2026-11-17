import Testing
import Foundation
@testable import LumenCore

@Suite struct GuestProcessTests {
    @Test func testControlFramesSurviveFragmentedReadsAndSkipUnrecognizedInput() throws {
        var frames = GuestProcessFrames()
        let command = try GuestProcessFrames.encode(GuestProcessMessage(command: .pause))
        #expect(try frames.append(command.prefix(3)).isEmpty)
        let status = GuestProcessStatus(state: .paused, progress: 0.5, error: nil)
        let events = try frames.append(command.dropFirst(3) + Data("diagnostic line\n{\"command\":\"execute-shell\"}\n".utf8)
            + GuestProcessFrames.encode(GuestProcessMessage(status: status)))
        #expect(events.count == 2)
        #expect(events[0].command == .pause)
        #expect(events[1].status?.state == .paused)
        #expect(events[1].status?.progress == 0.5)
        #expect(try frames.append(Data()).isEmpty)
    }

    @Test func testControlFramesRejectOversizedMessages() throws {
        var frames = GuestProcessFrames()
        #expect(throws: (any Error).self) { try frames.append(Data(repeating: 65, count: 16_385)) }
        var terminatedFrames = GuestProcessFrames()
        #expect(throws: (any Error).self) { try terminatedFrames.append(Data(repeating: 65, count: 16_385) + Data([10])) }
        #expect(throws: (any Error).self) { try GuestProcessFrames.encode(GuestProcessMessage(
            status: GuestProcessStatus(state: .failed, progress: 0, error: String(repeating: "x", count: 17_000)))) }
    }

    @Test func testRuntimeLeaseProtectsDiskAndConfigurationUntilGuestExits() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("GuestLeaseTests-" + UUID().uuidString)
        let library = try MachineLibrary(root: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var record = VirtualMachineRecord(name: "Lease test", guest: .ubuntu)
        try library.create(record)
        let location = library.location(for: record.id)
        var lease: GuestRuntimeLease? = try GuestRuntimeLease(directory: location.directory)
        #expect(lease != nil)
        #expect(throws: (any Error).self) { try GuestRuntimeLease(directory: location.directory) }
        record.name = "Changed"
        #expect(throws: (any Error).self) { try library.save(record) }
        #expect(throws: (any Error).self) { try library.growDisk(for: record.id, toGiB: record.diskGiB + 8) }
        #expect(throws: (any Error).self) { try library.deletePermanently(record.id) }
        #expect(try library.load().first?.name == "Lease test")
        #expect(try SparseDisk.usage(at: location.disk).capacityBytes == Int64(record.diskGiB) * 1_073_741_824)
        lease = nil
        try library.save(record)
        try library.growDisk(for: record.id, toGiB: record.diskGiB + 8)
        #expect(try library.load().first?.name == "Changed")
        try library.deletePermanently(record.id)
        #expect(!FileManager.default.fileExists(atPath: location.directory.path))
    }

    @Test func testRuntimeLeaseRejectsSymbolicLinks() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("GuestLockLinkTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("UnrelatedFile")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("NativeRuntime.lock"), withDestinationURL: target)
        #expect(throws: (any Error).self) { try GuestRuntimeLease(directory: directory) }
        #expect(try String(contentsOf: target) == "untouched")
    }
}
