import XCTest
@testable import LumenCore

final class DetectionAndPolicyTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        temporary = root.appendingPathComponent("LumenDetect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    func testLegacyMachineJSONStillLoadsWithDefaults() throws {
        let json = """
        {"cpuCount":4,"createdAt":813392216.8,"diskGiB":64,"guest":"ubuntu","id":"282C21D8-C21B-41CE-943D-E2748A37A18B",
         "installerPath":"/Users/x/ubuntu-26.04.1-desktop-arm64.iso","macAddress":"02:28:2c:21:d8:c2","memoryGiB":4,"name":"Ubuntu"}
        """
        let record = try JSONDecoder().decode(VirtualMachineRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.macAddress, "02:28:2c:21:d8:c2")
        XCTAssertEqual(record.diskSyncMode, .balanced)
        XCTAssertEqual(record.displayWidth, 1920)
        XCTAssertFalse(record.autoResizeDisplay)
        XCTAssertTrue(record.clipboardSharing)
        XCTAssertNoThrow(try record.validate())
        let roundTrip = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundTrip, record)
    }

    func testFilenameRecognition() {
        let cases: [(String, String?, CPUArchitecture)] = [
            ("ubuntu-26.04.1-desktop-arm64.iso", "ubuntu", .arm64),
            ("ubuntu-24.04.2-live-server-arm64.iso", "ubuntu-server", .arm64),
            ("kubuntu-25.04-desktop-arm64.iso", "kubuntu", .arm64),
            ("debian-13.1.0-arm64-netinst.iso", "debian", .arm64),
            ("Fedora-Workstation-Live-42-1.1.aarch64.iso", "fedora", .arm64),
            ("openSUSE-Leap-15.6-DVD-aarch64-Media.iso", "opensuse-leap", .arm64),
            ("openSUSE-Tumbleweed-DVD-aarch64-Current.iso", "opensuse-tumbleweed", .arm64),
            ("kali-linux-2025.3-installer-arm64.iso", "kali", .arm64),
            ("Rocky-10.0-aarch64-minimal.iso", "rocky", .arm64),
            ("archboot-2025.10.01-aarch64-ARCH-local.iso", "arch", .arm64),
            ("alpine-standard-3.22.1-aarch64.iso", "alpine", .arm64),
            ("linuxmint-22.2-cinnamon-64bit.iso", "linux-mint", .x86_64),
            ("ubuntu-24.04-desktop-amd64.iso", "ubuntu", .x86_64)
        ]
        for (name, distro, arch) in cases {
            let detected = InstallerDetector.detect(url: temporary.appendingPathComponent(name))
            XCTAssertEqual(detected.distribution?.id, distro, name)
            XCTAssertEqual(detected.architecture, arch, name)
        }
        let windows = InstallerDetector.detect(url: temporary.appendingPathComponent("Windows11_Client_arm64_en-us_26300_9457.iso"))
        XCTAssertEqual(windows.guest, .windows)
        XCTAssertEqual(windows.architecture, .arm64)
        XCTAssertEqual(InstallerDetector.detect(url: temporary.appendingPathComponent("UniversalMac_26.0_Restore.ipsw")).guest, .macOS)
        XCTAssertNil(LinuxDistribution.match("aarch64-random.iso"))
    }

    func testReadsISOLabelAndEFIBootLoader() throws {
        // Build a tiny ISO 9660 image: EFI/BOOT/BOOTAA64.EFI with a recognizable volume label.
        let source = temporary.appendingPathComponent("src")
        let boot = source.appendingPathComponent("EFI/BOOT")
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        try Data("efi".utf8).write(to: boot.appendingPathComponent("BOOTAA64.EFI"))
        let iso = temporary.appendingPathComponent("media.iso")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-iso", "-default-volume-name", "Fedora-WS-Live-42", "-o", iso.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipIf(process.terminationStatus != 0, "hdiutil is unavailable")
        let detected = InstallerDetector.detect(url: iso)
        XCTAssertEqual(detected.volumeLabel, "FEDORA_WS_LIVE_42")
        XCTAssertTrue(detected.hasARM64BootLoader)
        XCTAssertEqual(detected.architecture, .arm64)
        XCTAssertEqual(detected.distribution?.id, "fedora")
    }

    func testResourcePolicyKeepsRoomForMacOS() {
        let host = HostResources(memoryGiB: 48, cpuCount: 12, performanceCores: 8)
        let policy = ResourcePolicy(defaultsFor: host)
        XCTAssertEqual(policy.memoryReserveGiB, 12)
        XCTAssertEqual(policy.guestMemoryBudgetGiB(on: host), 36)
        XCTAssertEqual(policy.maxCPUsPerMachine(on: host), 10)
        XCTAssertTrue(policy.canStart(memoryGiB: 8, alreadyRunningGiB: 28, on: host))
        XCTAssertFalse(policy.canStart(memoryGiB: 8, alreadyRunningGiB: 30, on: host))
        let small = HostResources(memoryGiB: 8, cpuCount: 8)
        XCTAssertEqual(ResourcePolicy(defaultsFor: small).guestMemoryBudgetGiB(on: small), 4)
        let recommended = ResourcePolicy(defaultsFor: small).recommended(for: .ubuntu, distribution: LinuxDistribution.entry(id: "ubuntu"), on: small)
        XCTAssertEqual(recommended.memoryGiB, 4)
    }

    func testWindowsHelperDiscIsInteractiveAndWellFormed() throws {
        let files = WindowsSetupMedia.files(bypassChecks: true, sharedFolderName: "Lumen Shared")
        let xml = try XCTUnwrap(files.first { $0.relativePath == "autounattend.xml" }).contents
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
        XCTAssertTrue(xml.contains("BypassTPMCheck"))
        XCTAssertTrue(xml.contains("BypassSecureBootCheck"))
        XCTAssertTrue(xml.contains("processorArchitecture=\"arm64\""))
        XCTAssertFalse(xml.contains("<ProductKey>"))
        XCTAssertFalse(xml.contains("<DiskConfiguration>"))
        XCTAssertTrue(files.contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") && $0.contents.contains(#"\\10.0.2.2\Lumen Shared"#) })
        let plain = WindowsSetupMedia.autounattend(bypassChecks: false)
        XCTAssertFalse(plain.contains("LabConfig"))
        XCTAssertNoThrow(try XMLDocument(xmlString: plain))
    }

    func testDiskGrowsButNeverShrinks() throws {
        let library = try MachineLibrary(root: temporary)
        let record = VirtualMachineRecord(name: "Grow", guest: .debian, diskGiB: 16)
        try library.create(record)
        try library.growDisk(for: record.id, toGiB: 32)
        let usage = try SparseDisk.usage(at: library.location(for: record.id).disk)
        XCTAssertEqual(usage.capacityBytes, 32 * 1_073_741_824)
        XCTAssertLessThan(usage.allocatedBytes, 1_048_576)
        XCTAssertThrowsError(try library.growDisk(for: record.id, toGiB: 16))
    }
}
