import XCTest
@testable import LumenCore

final class DetectionAndPolicyTests: XCTestCase {
    func testDisplayReceiptRejectsStalePartialAndAppendedMessages() throws {
        let setup = WindowsDisplaySetup(password: "test", share: "LumenSetup_test$", ticket: UUID().uuidString)
        XCTAssertTrue(setup.acceptsReceipt(Data(setup.ticket.utf8)))
        XCTAssertFalse(setup.acceptsReceipt(Data(UUID().uuidString.utf8)))
        XCTAssertFalse(setup.acceptsReceipt(Data(setup.ticket.dropLast().utf8)))
        XCTAssertFalse(setup.acceptsReceipt(Data((setup.ticket + "extra").utf8)))
        XCTAssertFalse(setup.acceptsReceipt(Data()))
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, displaySetup: setup)
        XCTAssertEqual(files.first { $0.relativePath == "lumen/display-ready.ps1" }?.contents, setup.script)
        let configuration = try XCTUnwrap(files.first { $0.relativePath == "lumen/display-setup.json" }).contents
        let restored = try JSONDecoder().decode(WindowsDisplaySetup.self, from: Data(configuration.utf8))
        XCTAssertEqual(restored.ticket, setup.ticket)
        XCTAssertEqual(restored.password, setup.password)
        // A new host launch updates only data on the disc; the protected task
        // keeps the same code and cannot execute a replacement CD script.
        let relaunched = WindowsDisplaySetup(password: "different", share: "different", ticket: UUID().uuidString)
        XCTAssertEqual(setup.script, relaunched.script)
        XCTAssertTrue(setup.script.contains("display-setup.json"))
        XCTAssertFalse(setup.script.contains("FromBase64String"))
        XCTAssertTrue(setup.script.contains("OOBEInProgress"))
        let finish = try XCTUnwrap(files.first { $0.relativePath == "lumen/finish-setup.cmd" }).contents
        XCTAssertTrue(finish.contains("Start-ScheduledTask"))
        // FirstLogonCommands must return so Windows can finish OOBE; readiness
        // executes asynchronously from the protected graphics task.
        XCTAssertFalse(finish.contains("-File"))
        let graphics = try XCTUnwrap(files.first { $0.relativePath == "lumen/install-graphics-service.cmd" }).contents
        XCTAssertTrue(graphics.contains("New-ScheduledTaskTrigger -AtLogOn"))
        XCTAssertTrue(graphics.contains(#"$env:TARGET+'\display-ready.ps1'"#))
    }

    func testMultipleFoldersMigrateAndPersistWithPermissions() throws {
        var record = VirtualMachineRecord(name: "Folders", guest: .windows, sharedDirectoryPath: "/tmp/first", sharedFolderReadOnly: true)
        XCTAssertEqual(record.sharedFolders, [SharedFolder(path: "/tmp/first", readOnly: true)])
        record.sharedFolders.append(SharedFolder(path: "/tmp/second"))
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(VirtualMachineRecord.self, from: data)
        XCTAssertEqual(restored.sharedFolders, record.sharedFolders)
        XCTAssertEqual(restored.sharedDirectoryPath, "/tmp/first")
        record.sharedFolders = []
        XCTAssertNil(record.sharedDirectoryPath)
        XCTAssertTrue(record.additionalSharedFolders.isEmpty)
    }

    func testSharedFolderNamesAreDistinctAndPortable() {
        let names = SharedFolder.named([
            SharedFolder(path: "/tmp/a/Desktop"), SharedFolder(path: "/tmp/b/desktop"),
            SharedFolder(path: "/tmp/a/IPC$"), SharedFolder(path: "/tmp/a/what?*folder")
        ]).map(\.name)
        XCTAssertEqual(names, ["Desktop", "desktop (2)", "Shared_IPC$", "what__folder"])
    }

    func testManagedSharingUsesPrivateGuestEndpointAndUserStartup() throws {
        let password = String(repeating: "a", count: 64)
        let connection = WindowsFolderConnection(password: password, shares: ["Desktop", "Files (2)"])
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, managedSharing: connection)
        let script = try XCTUnwrap(files.first { $0.relativePath == "lumen/connect-folders.ps1" }?.contents)
        XCTAssertTrue(script.contains("10.0.2.4"))
        XCTAssertTrue(script.contains("/user:Lumen"))
        XCTAssertFalse(script.contains("10.0.2.2"))
        XCTAssertFalse(script.contains("Z:"))
        XCTAssertTrue(files.contains { $0.relativePath == "lumen/install-sharing.cmd" })
        let driver = try XCTUnwrap(files.first { $0.relativePath == "lumen/install-drivers.cmd" }?.contents)
        XCTAssertTrue(driver.contains("install-sharing.cmd"))
    }

    func testFolderCredentialIsDiscDataNeverCodeCopiedToTools() throws {
        let password = String(repeating: "b", count: 64)
        let connection = WindowsFolderConnection(password: password, shares: ["Desktop"])
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, managedSharing: connection)
        let script = try XCTUnwrap(files.first { $0.relativePath == "lumen/connect-folders.ps1" }?.contents)
        // The script (copied to world-readable Tools) is fixed and holds no secret.
        XCTAssertEqual(script, WindowsFolderConnection.script)
        XCTAssertFalse(script.contains(password))
        XCTAssertFalse(script.contains("FromBase64String"))
        XCTAssertTrue(script.contains("connect-folders.json"))
        XCTAssertTrue(script.contains("cmdkey.exe"))
        XCTAssertTrue(script.contains("^[0-9a-f]{64}$"))
        let data = try XCTUnwrap(files.first { $0.relativePath == "lumen/connect-folders.json" }?.contents)
        XCTAssertEqual(try JSONDecoder().decode(WindowsFolderConnection.self, from: Data(data.utf8)), connection)
        // Data documents with credentials are removed after copying the tools.
        let driver = try XCTUnwrap(files.first { $0.relativePath == "lumen/install-drivers.cmd" }?.contents)
        XCTAssertTrue(driver.contains(#"del /q "%ProgramData%\Lumen\Tools\*.json""#))
        let xml = try XCTUnwrap(files.first { $0.relativePath == "autounattend.xml" }?.contents)
        XCTAssertTrue(xml.contains(#"del /q &quot;%ProgramData%\Lumen\Tools\*.json&quot;"#))
        // Startup runs only the protected copy, never a script from any CD volume.
        let install = WindowsFolderConnection.installScript
        let encoded = try XCTUnwrap(install.components(separatedBy: "-EncodedCommand ").last?.components(separatedBy: "\r\n").first)
        let installer = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf16LittleEndian))
        let launchEncoded = try XCTUnwrap(installer.components(separatedBy: "-EncodedCommand ").last?.components(separatedBy: "'").first)
        let launch = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: launchEncoded)), encoding: .utf16LittleEndian))
        XCTAssertTrue(launch.contains(#"Lumen\Tools\connect-folders.ps1"#))
        XCTAssertFalse(launch.contains("LUMENSETUP"))
        XCTAssertFalse(launch.contains("DriveType"))
    }

    func testGuestToolsFolderIsWritableOnlyByAdministratorsAndSystem() throws {
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil)
        let driver = try XCTUnwrap(files.first { $0.relativePath == "lumen/install-drivers.cmd" }?.contents)
        XCTAssertTrue(driver.contains("/inheritance:r"))
        XCTAssertTrue(driver.contains("*S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX"))
        XCTAssertTrue(driver.contains("/setowner *S-1-5-32-544"))
        XCTAssertTrue(driver.contains("/reset /T"))
        // The folder is protected before the tools are copied in.
        let protect = try XCTUnwrap(driver.range(of: "call :ProtectTools"))
        let copy = try XCTUnwrap(driver.range(of: #"xcopy "%~dp0*""#))
        XCTAssertLessThan(protect.lowerBound, copy.lowerBound)
        XCTAssertFalse(driver.contains("S-1-1-0"), "Everyone must not be granted access")
    }

    func testWindowsMenuCommandsUseFixedGuestPathsAndSupportedKeys() {
        let marker = WindowsGuestCommands.makeDiscMarker()
        XCTAssertTrue(WindowsGuestCommands.isDiscMarker(marker))
        XCTAssertNotEqual(marker, WindowsGuestCommands.makeDiscMarker())
        let install = WindowsGuestCommands.installDrivers(marker: marker)
        let connect = WindowsGuestCommands.connectFolders(marker: marker)
        for command in [install, WindowsGuestCommands.displaySettings,
                        WindowsGuestCommands.networkSettings, WindowsGuestCommands.deviceManager, connect] {
            XCTAssertTrue(GuestKeyboard.supports(command))
            XCTAssertLessThan(command.count, 260, "Windows Run has a limited command length")
            XCTAssertFalse(command.contains("/Users/"))
        }
        XCTAssertTrue(install.contains("-Verb RunAs"))
        XCTAssertTrue(install.contains("-FileSystemLabel LUMENSETUP"))
        XCTAssertFalse(install.contains("ExecutionPolicy"))
        // A spoofed LUMENSETUP ISO cannot know the marker of the disc Lumen just built.
        for command in [install, connect] {
            XCTAssertTrue(command.contains(#"\lumen\id-"# + marker))
            XCTAssertTrue(command.contains("if($v){"))
        }
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, discMarker: marker)
        XCTAssertEqual(files.first { $0.relativePath == "lumen/id-" + marker }?.contents, marker)
        XCTAssertFalse(WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, discMarker: "../x")
            .contains { $0.relativePath.hasPrefix("lumen/id-") })
        for invalid in ["", "ABCDEF0123456789", "0123456789abcde", "0123456789abcdef0", "';calc;'00000000"] {
            XCTAssertFalse(WindowsGuestCommands.isDiscMarker(invalid))
        }
    }

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

    func testRecognizesAbyssLinuxBeforeVoid() throws {
        for name in ["abyss-linux-20261019-aarch64.iso", "void-suckless-dev-aarch64.iso", "media ABYSS_LIVE"] {
            let entry = LinuxDistribution.match(name)
            XCTAssertEqual(entry?.id, "abyss", name)
            XCTAssertEqual(entry?.family, .abyssLinux, name)
        }
        XCTAssertEqual(LinuxDistribution.match("void-live-aarch64-20250202-base.iso")?.id, "void")
        XCTAssertEqual(LinuxDistribution.match("VOID_LIVE")?.id, "void")
        XCTAssertTrue(GuestOS.abyssLinux.isLinux)
        XCTAssertTrue(GuestOS.abyssLinux.usesAppleVirtualization)
        XCTAssertNil(LinuxDistribution.entry(id: "abyss")?.downloadURL)
    }

    func testExistingVoidMachineStillDecodesAndAbyssRoundTrips() throws {
        let legacy = Data(#"{"id":"0B232D1B-0000-4000-8000-000000000000","name":"Void Linux","guest":"voidLinux","distribution":"void","cpuCount":4,"memoryGiB":8,"diskGiB":32}"#.utf8)
        var record = try JSONDecoder().decode(VirtualMachineRecord.self, from: legacy)
        XCTAssertEqual(record.guest, .voidLinux)
        XCTAssertEqual(record.operatingSystemName, "Void Linux")
        record.guest = .abyssLinux
        record.distribution = "abyss"
        let decoded = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.guest, .abyssLinux)
        XCTAssertEqual(decoded.operatingSystemName, "Abyss Linux")
        XCTAssertNoThrow(try decoded.validate())
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
        XCTAssertEqual(policy.recommended(for: .windows, on: host).cpus, 8)
        XCTAssertLessThan(policy.recommended(for: .windows, on: host).cpus, host.cpuCount)
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
        XCTAssertTrue(files.contains { $0.relativePath == "startup.nsh" && $0.contents.contains("bootaa64.efi") })
        XCTAssertTrue(files.contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") && $0.contents.contains("-EncodedCommand") })
        let plain = WindowsSetupMedia.autounattend(bypassChecks: false)
        XCTAssertFalse(plain.contains("LabConfig"))
        XCTAssertNoThrow(try XMLDocument(xmlString: plain))
        XCTAssertTrue(plain.contains("<DynamicUpdate><Enable>false</Enable>"))
    }

    func testLocalAccountSetupIsOptionalAndPreservesLegacyRecords() throws {
        var record = VirtualMachineRecord(name: "Windows", guest: .windows)
        XCTAssertTrue(record.windowsLocalAccount)
        XCTAssertFalse(record.windowsCompatibilityDisplay)
        XCTAssertTrue(record.windowsAutomaticDisplaySetup)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "windowsLocalAccount")
        let legacy = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.windowsLocalAccount)
        record.windowsLocalAccount = false
        XCTAssertEqual(try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record)), record)
        for local in [true, false] {
            let xml = WindowsSetupMedia.autounattend(bypassChecks: false, preferLocalAccount: local)
            let doc = try XMLDocument(xmlString: xml)
            let nodes = try doc.nodes(forXPath: "//*[local-name()='settings'][@pass='oobeSystem']//*[local-name()='HideOnlineAccountScreens']")
            XCTAssertEqual(nodes.first?.stringValue, local ? "true" : nil)
            XCTAssertFalse(xml.contains("<UserAccounts>"))
            XCTAssertFalse(xml.contains("<AutoLogon>"))
            XCTAssertFalse(xml.contains("SkipMachineOOBE"))
            let commands = try doc.nodes(forXPath: "//*[local-name()='FirstLogonCommands']//*[local-name()='CommandLine']")
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?.stringValue, #"cmd /d /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\lumen\finish-setup.cmd call %i:\lumen\finish-setup.cmd /setup"#)
        }
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
        XCTAssertThrowsError(try library.growDisk(for: record.id, toGiB: Int.max))
    }

    func testWindowsDriverMediaPersistsWithoutChangingLegacyIdentity() throws {
        let original = VirtualMachineRecord(name: "Windows", guest: .windows,
            windowsDriversPath: "/shared/virtio-win.iso", portForwards: [PortForward(hostPort: 2222, guestPort: 22)])
        let restored = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.macAddress, original.macAddress)
        XCTAssertEqual(restored.displayWidth, 2560)
        var invalid = original
        invalid.windowsDriversPath = "/shared/driver.exe"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testDriverSetupUsesARM64AndNeverPausesUnattendedInstallation() throws {
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil)
        let xml = try XCTUnwrap(files.first { $0.relativePath == "autounattend.xml" }).contents
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
        XCTAssertFalse(xml.contains("BypassSecureBootCheck"))
        XCTAssertTrue(xml.contains("drvload"))
        XCTAssertTrue(xml.contains(#"viogpudo\w11\ARM64\viogpudo.inf"#))
        XCTAssertTrue(xml.contains("install-drivers.cmd /setup"))
        let script = try XCTUnwrap(files.first { $0.relativePath == "lumen/install-drivers.cmd" }).contents
        XCTAssertTrue(script.contains("NetKVM viogpudo Balloon"))
        XCTAssertTrue(script.contains("if /i \"%~1\"==\"/quiet\" exit /b %FAILED%"))
        XCTAssertFalse(script.lowercased().contains("testsigning"))
        XCTAssertFalse(script.lowercased().contains("amd64"))
        let graphics = try XCTUnwrap(files.first { $0.relativePath == "lumen/install-graphics-service.cmd" }).contents
        XCTAssertTrue(script.contains("call \"%~dp0install-graphics-service.cmd\""))
        XCTAssertTrue(graphics.contains("Get-AuthenticodeSignature"))
        XCTAssertTrue(graphics.contains("viogpuap.exe"))
        XCTAssertTrue(graphics.contains("sc config vgpusrv"))
        XCTAssertTrue(graphics.contains("WaitForStatus('Running'"))
        let display = try XCTUnwrap(files.first { $0.relativePath == "lumen/configure-display.cmd" }).contents
        XCTAssertTrue(graphics.contains("New-ScheduledTaskTrigger -AtStartup"))
        XCTAssertTrue(graphics.contains("-User SYSTEM -RunLevel Highest"))
        XCTAssertTrue(display.contains("Get-PnpDevice -PresentOnly"))
        XCTAssertTrue(display.contains("$env:LUMEN_DISPLAY_BOOT -ne '1'"))
        XCTAssertTrue(display.contains("PCI\\VEN_1AF4&DEV_1050*"))
        XCTAssertTrue(display.contains("Remove-ItemProperty"))
        XCTAssertTrue(display.contains("shutdown.exe /r /t 0"))
        XCTAssertFalse(display.contains("shutdown.exe /r /f"))
        XCTAssertFalse(graphics.contains("Services\\BasicDisplay"))
        // The desktop entry must retain the adjacent resize-service helper and ask for UAC.
        XCTAssertTrue(xml.contains("xcopy"))
        XCTAssertTrue(xml.contains(#"%ProgramData%\Lumen\Tools\"#))
        let desktop = try XCTUnwrap(files.first { $0.relativePath == "lumen/Install Lumen Drivers.cmd" }).contents
        XCTAssertTrue(desktop.contains("-Verb RunAs"))
        XCTAssertTrue(desktop.contains(#"Lumen\Tools\finish-setup.cmd"#))
    }

    func testOlderWindowsMachinesKeepAVisibleRecoveryFramebuffer() throws {
        var record = VirtualMachineRecord(name: "Windows", guest: .windows)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "windowsCompatibilityDisplay")
        object.removeValue(forKey: "windowsAutomaticDisplaySetup")
        let legacy = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.windowsCompatibilityDisplay)
        XCTAssertFalse(legacy.windowsAutomaticDisplaySetup)
        record.windowsCompatibilityDisplay = false
        let modern = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(modern.windowsCompatibilityDisplay)
    }

    func testUnsafeShareNamesAreNeverInsertedIntoBatchCommands() throws {
        for name in ["name\r\ncalc", "quote\"", "path\\child", "path/child", "a|b"] {
            XCTAssertFalse(WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: name)
                .contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") })
        }
        XCTAssertTrue(WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: "My Shared Folder")
            .contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") })
        let name = "O'Brien & %PATH% !shared! é"
        let script = try XCTUnwrap(WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: name)
            .first { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") }).contents
        XCTAssertFalse(script.contains(name))
        XCTAssertFalse(script.contains("net use Z:"))
        let payload = try XCTUnwrap(script.components(separatedBy: "-EncodedCommand ").last?.components(separatedBy: "\r\n").first)
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        let command = try XCTUnwrap(String(data: data, encoding: .utf16LittleEndian))
        XCTAssertTrue(command.contains("$p='\\\\10.0.2.2\\O''Brien & %PATH% !shared! é'"))
        XCTAssertTrue(command.contains("-FilePath explorer.exe"))
    }

    func testLocalFileSelectionRejectsDirectoriesAndNonlocalInstallers() throws {
        let image = temporary.appendingPathComponent("My Windows ARM64.ISO")
        try Data([0]).write(to: image)
        XCTAssertNoThrow(try LocalFileSelection.validateInstaller(image))
        XCTAssertThrowsError(try LocalFileSelection.validateFolder(image))
        let folder = temporary.appendingPathComponent("folder.iso", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try LocalFileSelection.validateInstaller(folder))
        XCTAssertNoThrow(try LocalFileSelection.validateFolder(folder))
        XCTAssertThrowsError(try LocalFileSelection.validateInstaller(URL(string: "https://example.com/windows-arm64.iso")!))
        XCTAssertThrowsError(try LocalFileSelection.validateInstaller(temporary.appendingPathComponent("missing.iso")))
        XCTAssertThrowsError(try LocalFileSelection.validateInstaller(temporary.appendingPathComponent("setup.exe")))
    }

    func testMacSharingUsesPublishedNameAndExactEnabledFolder() throws {
        let data = Data(#"{"First":{"path":"/tmp/LumenFolder","smb_name":"Published Name","smb_shared":1,"smb_read_only":1},"Disabled":{"path":"/tmp/Disabled","smb_name":"Disabled","smb_shared":0}}"#.utf8)
        let share = try XCTUnwrap(MacSMBShare.configuredShare(for: URL(fileURLWithPath: "/tmp/LumenFolder"), in: data))
        XCTAssertEqual(share.name, "Published Name")
        XCTAssertTrue(share.readOnly)
        XCTAssertNil(try MacSMBShare.configuredShare(for: URL(fileURLWithPath: "/tmp/Disabled"), in: data))
        XCTAssertNil(try MacSMBShare.configuredShare(for: URL(fileURLWithPath: "/tmp/LumenFolder/child"), in: data))
        XCTAssertThrowsError(try MacSMBShare.configuredShare(for: temporary, in: Data("not json".utf8)))
    }

    func testPortForwardingValidatesBoundsAndDuplicateEndpoints() throws {
        let rule = PortForward(hostPort: 2222, guestPort: 22)
        XCTAssertEqual(rule.qemuOption, "hostfwd=tcp:127.0.0.1:2222-:22")
        var record = VirtualMachineRecord(name: "Windows", guest: .windows, portForwards: [rule])
        XCTAssertNoThrow(try record.validate())
        record.portForwards.append(PortForward(hostPort: 2222, guestPort: 80))
        XCTAssertThrowsError(try record.validate())
        record.portForwards = [rule, PortForward(transport: .udp, hostPort: 2222, guestPort: 53)]
        XCTAssertNoThrow(try record.validate())
        record.portForwards = [PortForward(hostPort: 65536, guestPort: 80)]
        XCTAssertThrowsError(try record.validate())
        record.portForwards = [rule]
        record.guest = .ubuntu
        XCTAssertThrowsError(try record.validate())
    }

    func testPasswordInjectionRejectsUnmappableCharactersBeforeTyping() {
        XCTAssertTrue(GuestKeyboard.supports("Test 123!@#$%^&*()_+-=[]{};:'\",.<>/?`~\\|"))
        for password in ["", "pässword", "🔐", "hello\nworld", "tabs\t"] {
            XCTAssertFalse(GuestKeyboard.supports(password))
        }
    }

    func testISODetectionFindsPrimaryDescriptorAfterBootRecord() throws {
        var bytes = Data(repeating: 0, count: 20 * 2048)
        let signature = Data("CD001".utf8)
        bytes.replaceSubrange(16 * 2048 + 1..<16 * 2048 + 6, with: signature)
        bytes[16 * 2048] = 0 // El Torito boot descriptor first.
        let base = 17 * 2048
        bytes[base] = 1
        bytes.replaceSubrange(base + 1..<base + 6, with: signature)
        bytes[base + 128] = 0
        bytes[base + 129] = 8
        let label = Data("CCCOMA_X64FRE_EN-US_DV9".utf8)
        bytes.replaceSubrange(base + 40..<base + 40 + label.count, with: label)
        let url = temporary.appendingPathComponent("renamed.iso")
        try bytes.write(to: url)
        let detected = InstallerDetector.detect(url: url)
        XCTAssertEqual(detected.guest, .windows)
        XCTAssertEqual(detected.architecture, .x86_64)
    }
}
