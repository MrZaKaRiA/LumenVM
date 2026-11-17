import Testing
import Foundation
@testable import LumenCore

@Suite final class DetectionAndPolicyTests {
    @Test func testDisplayReceiptRejectsStalePartialAndAppendedMessages() throws {
        let setup = WindowsDisplaySetup(password: "test", share: "LumenSetup_test$", ticket: UUID().uuidString)
        #expect(setup.acceptsReceipt(Data(setup.ticket.utf8)))
        #expect(!setup.acceptsReceipt(Data(UUID().uuidString.utf8)))
        #expect(!setup.acceptsReceipt(Data(setup.ticket.dropLast().utf8)))
        #expect(!setup.acceptsReceipt(Data((setup.ticket + "extra").utf8)))
        #expect(!setup.acceptsReceipt(Data()))
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, displaySetup: setup)
        #expect(files.first { $0.relativePath == "lumen/display-ready.ps1" }?.contents == setup.script)
        let configuration = try #require(files.first { $0.relativePath == "lumen/display-setup.json" }).contents
        let restored = try JSONDecoder().decode(WindowsDisplaySetup.self, from: Data(configuration.utf8))
        #expect(restored.ticket == setup.ticket)
        #expect(restored.password == setup.password)
        // A new host launch updates only data on the disc; the protected task
        // keeps the same code and cannot execute a replacement CD script.
        let relaunched = WindowsDisplaySetup(password: "different", share: "different", ticket: UUID().uuidString)
        #expect(setup.script == relaunched.script)
        #expect(setup.script.contains("display-setup.json"))
        #expect(!setup.script.contains("FromBase64String"))
        #expect(setup.script.contains("OOBEInProgress"))
        let finish = try #require(files.first { $0.relativePath == "lumen/finish-setup.cmd" }).contents
        #expect(finish.contains("Start-ScheduledTask"))
        // FirstLogonCommands must return so Windows can finish OOBE; readiness
        // executes asynchronously from the protected graphics task.
        #expect(!finish.contains("-File"))
        let graphics = try #require(files.first { $0.relativePath == "lumen/install-graphics-service.cmd" }).contents
        #expect(graphics.contains("New-ScheduledTaskTrigger -AtLogOn"))
        #expect(graphics.contains(#"$env:TARGET+'\display-ready.ps1'"#))
    }

    @Test func testMultipleFoldersMigrateAndPersistWithPermissions() throws {
        var record = VirtualMachineRecord(name: "Folders", guest: .windows, sharedDirectoryPath: "/tmp/first", sharedFolderReadOnly: true)
        #expect(record.sharedFolders == [SharedFolder(path: "/tmp/first", readOnly: true)])
        record.sharedFolders.append(SharedFolder(path: "/tmp/second"))
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(VirtualMachineRecord.self, from: data)
        #expect(restored.sharedFolders == record.sharedFolders)
        #expect(restored.sharedDirectoryPath == "/tmp/first")
        record.sharedFolders = []
        #expect(record.sharedDirectoryPath == nil)
        #expect(record.additionalSharedFolders.isEmpty)
    }

    @Test func testSharedFolderNamesAreDistinctAndPortable() {
        let names = SharedFolder.named([
            SharedFolder(path: "/tmp/a/Desktop"), SharedFolder(path: "/tmp/b/desktop"),
            SharedFolder(path: "/tmp/a/IPC$"), SharedFolder(path: "/tmp/a/what?*folder")
        ]).map(\.name)
        #expect(names == ["Desktop", "desktop (2)", "Shared_IPC$", "what__folder"])
    }

    @Test func testManagedSharingUsesPrivateGuestEndpointAndUserStartup() throws {
        let password = String(repeating: "a", count: 64)
        let connection = WindowsFolderConnection(password: password, shares: ["Desktop", "Files (2)"])
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, managedSharing: connection)
        let script = try #require(files.first { $0.relativePath == "lumen/connect-folders.ps1" }?.contents)
        #expect(script.contains("10.0.2.4"))
        #expect(script.contains("/user:Lumen"))
        #expect(!script.contains("10.0.2.2"))
        #expect(!script.contains("Z:"))
        #expect(files.contains { $0.relativePath == "lumen/install-sharing.cmd" })
        let driver = try #require(files.first { $0.relativePath == "lumen/install-drivers.cmd" }?.contents)
        #expect(driver.contains("install-sharing.cmd"))
    }

    @Test func testFolderCredentialIsDiscDataNeverCodeCopiedToTools() throws {
        let password = String(repeating: "b", count: 64)
        let connection = WindowsFolderConnection(password: password, shares: ["Desktop"])
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, managedSharing: connection)
        let script = try #require(files.first { $0.relativePath == "lumen/connect-folders.ps1" }?.contents)
        // The script (copied to world-readable Tools) is fixed and holds no secret.
        #expect(script == WindowsFolderConnection.script)
        #expect(!script.contains(password))
        #expect(!script.contains("FromBase64String"))
        #expect(script.contains("connect-folders.json"))
        #expect(script.contains("cmdkey.exe"))
        #expect(script.contains("^[0-9a-f]{64}$"))
        let data = try #require(files.first { $0.relativePath == "lumen/connect-folders.json" }?.contents)
        #expect(try JSONDecoder().decode(WindowsFolderConnection.self, from: Data(data.utf8)) == connection)
        // Data documents with credentials are removed after copying the tools.
        let driver = try #require(files.first { $0.relativePath == "lumen/install-drivers.cmd" }?.contents)
        #expect(driver.contains(#"del /q "%ProgramData%\Lumen\Tools\*.json""#))
        let xml = try #require(files.first { $0.relativePath == "autounattend.xml" }?.contents)
        #expect(xml.contains(#"del /q &quot;%ProgramData%\Lumen\Tools\*.json&quot;"#))
        // Startup runs only the protected copy, never a script from any CD volume.
        let install = WindowsFolderConnection.installScript
        let encoded = try #require(install.components(separatedBy: "-EncodedCommand ").last?.components(separatedBy: "\r\n").first)
        let installerData = try #require(Data(base64Encoded: encoded))
        let installer = try #require(String(data: installerData, encoding: .utf16LittleEndian))
        let launchEncoded = try #require(installer.components(separatedBy: "-EncodedCommand ").last?.components(separatedBy: "'").first)
        let launchData = try #require(Data(base64Encoded: launchEncoded))
        let launch = try #require(String(data: launchData, encoding: .utf16LittleEndian))
        #expect(launch.contains(#"Lumen\Tools\connect-folders.ps1"#))
        #expect(!launch.contains("LUMENSETUP"))
        #expect(!launch.contains("DriveType"))
    }

    @Test func testGuestToolsFolderIsWritableOnlyByAdministratorsAndSystem() throws {
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil)
        let driver = try #require(files.first { $0.relativePath == "lumen/install-drivers.cmd" }?.contents)
        #expect(driver.contains("/inheritance:r"))
        #expect(driver.contains("*S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX"))
        #expect(driver.contains("/setowner *S-1-5-32-544"))
        #expect(driver.contains("/reset /T"))
        // The folder is protected before the tools are copied in.
        let protect = try #require(driver.range(of: "call :ProtectTools"))
        let copy = try #require(driver.range(of: #"xcopy "%~dp0*""#))
        #expect(protect.lowerBound < copy.lowerBound)
        #expect(!driver.contains("S-1-1-0"), "Everyone must not be granted access")
    }

    @Test func testWindowsMenuCommandsUseFixedGuestPathsAndSupportedKeys() {
        let marker = WindowsGuestCommands.makeDiscMarker()
        #expect(WindowsGuestCommands.isDiscMarker(marker))
        #expect(marker != WindowsGuestCommands.makeDiscMarker())
        let install = WindowsGuestCommands.installDrivers(marker: marker)
        let connect = WindowsGuestCommands.connectFolders(marker: marker)
        for command in [install, WindowsGuestCommands.displaySettings,
                        WindowsGuestCommands.networkSettings, WindowsGuestCommands.deviceManager, connect] {
            #expect(GuestKeyboard.supports(command))
            #expect(command.count < 260, "Windows Run has a limited command length")
            #expect(!command.contains("/Users/"))
        }
        #expect(install.contains("-Verb RunAs"))
        #expect(install.contains("-FileSystemLabel LUMENSETUP"))
        #expect(!install.contains("ExecutionPolicy"))
        // A spoofed LUMENSETUP ISO cannot know the marker of the disc Lumen just built.
        for command in [install, connect] {
            #expect(command.contains(#"\lumen\id-"# + marker))
            #expect(command.contains("if($v){"))
        }
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, discMarker: marker)
        #expect(files.first { $0.relativePath == "lumen/id-" + marker }?.contents == marker)
        #expect(!WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil, discMarker: "../x")
            .contains { $0.relativePath.hasPrefix("lumen/id-") })
        for invalid in ["", "ABCDEF0123456789", "0123456789abcde", "0123456789abcdef0", "';calc;'00000000"] {
            #expect(!WindowsGuestCommands.isDiscMarker(invalid))
        }
    }

    private let temporary: URL
    init() throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        temporary = root.appendingPathComponent("LumenDetect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    deinit {
        try? FileManager.default.removeItem(at: temporary)
    }

    @Test func testLegacyMachineJSONStillLoadsWithDefaults() throws {
        let json = """
        {"cpuCount":4,"createdAt":813392216.8,"diskGiB":64,"guest":"ubuntu","id":"282C21D8-C21B-41CE-943D-E2748A37A18B",
         "installerPath":"/Users/x/ubuntu-26.04.1-desktop-arm64.iso","macAddress":"02:28:2c:21:d8:c2","memoryGiB":4,"name":"Ubuntu"}
        """
        let record = try JSONDecoder().decode(VirtualMachineRecord.self, from: Data(json.utf8))
        #expect(record.macAddress == "02:28:2c:21:d8:c2")
        #expect(record.diskSyncMode == .balanced)
        #expect(record.displayWidth == 1920)
        #expect(!record.autoResizeDisplay)
        #expect(record.clipboardSharing)
        #expect(throws: Never.self) { try record.validate() }
        let roundTrip = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        #expect(roundTrip == record)
    }

    @Test func testFilenameRecognition() {
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
            #expect(detected.distribution?.id == distro, Comment(rawValue: name))
            #expect(detected.architecture == arch, Comment(rawValue: name))
        }
        let windows = InstallerDetector.detect(url: temporary.appendingPathComponent("Windows11_Client_arm64_en-us_26300_9457.iso"))
        #expect(windows.guest == .windows)
        #expect(windows.architecture == .arm64)
        #expect(InstallerDetector.detect(url: temporary.appendingPathComponent("UniversalMac_26.0_Restore.ipsw")).guest == .macOS)
        #expect(LinuxDistribution.match("aarch64-random.iso") == nil)
    }

    @Test func testRecognizesAbyssLinuxBeforeVoid() throws {
        for name in ["abyss-linux-20261019-aarch64.iso", "void-suckless-dev-aarch64.iso", "media ABYSS_LIVE"] {
            let entry = LinuxDistribution.match(name)
            #expect(entry?.id == "abyss", Comment(rawValue: name))
            #expect(entry?.family == .abyssLinux, Comment(rawValue: name))
        }
        #expect(LinuxDistribution.match("void-live-aarch64-20250202-base.iso")?.id == "void")
        #expect(LinuxDistribution.match("VOID_LIVE")?.id == "void")
        #expect(GuestOS.abyssLinux.isLinux)
        #expect(GuestOS.abyssLinux.usesAppleVirtualization)
        #expect(LinuxDistribution.entry(id: "abyss")?.downloadURL == nil)
    }

    @Test func testExistingVoidMachineStillDecodesAndAbyssRoundTrips() throws {
        let legacy = Data(#"{"id":"0B232D1B-0000-4000-8000-000000000000","name":"Void Linux","guest":"voidLinux","distribution":"void","cpuCount":4,"memoryGiB":8,"diskGiB":32}"#.utf8)
        var record = try JSONDecoder().decode(VirtualMachineRecord.self, from: legacy)
        #expect(record.guest == .voidLinux)
        #expect(record.operatingSystemName == "Void Linux")
        record.guest = .abyssLinux
        record.distribution = "abyss"
        let decoded = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.guest == .abyssLinux)
        #expect(decoded.operatingSystemName == "Abyss Linux")
        #expect(throws: Never.self) { try decoded.validate() }
    }

    @Test func testReadsISOLabelAndEFIBootLoader() throws {
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
        // XCTSkipIf equivalent: cancel the test (reported as skipped) when hdiutil is unavailable.
        if process.terminationStatus != 0 { try Test.cancel("hdiutil is unavailable") }
        let detected = InstallerDetector.detect(url: iso)
        #expect(detected.volumeLabel == "FEDORA_WS_LIVE_42")
        #expect(detected.hasARM64BootLoader)
        #expect(detected.architecture == .arm64)
        #expect(detected.distribution?.id == "fedora")
    }

    @Test func testResourcePolicyKeepsRoomForMacOS() {
        let host = HostResources(memoryGiB: 48, cpuCount: 12, performanceCores: 8)
        let policy = ResourcePolicy(defaultsFor: host)
        #expect(policy.memoryReserveGiB == 12)
        #expect(policy.guestMemoryBudgetGiB(on: host) == 36)
        #expect(policy.maxCPUsPerMachine(on: host) == 10)
        #expect(policy.recommended(for: .windows, on: host).cpus == 8)
        #expect(policy.recommended(for: .windows, on: host).cpus < host.cpuCount)
        #expect(policy.canStart(memoryGiB: 8, alreadyRunningGiB: 28, on: host))
        #expect(!policy.canStart(memoryGiB: 8, alreadyRunningGiB: 30, on: host))
        let small = HostResources(memoryGiB: 8, cpuCount: 8)
        #expect(ResourcePolicy(defaultsFor: small).guestMemoryBudgetGiB(on: small) == 4)
        let recommended = ResourcePolicy(defaultsFor: small).recommended(for: .ubuntu, distribution: LinuxDistribution.entry(id: "ubuntu"), on: small)
        #expect(recommended.memoryGiB == 4)
    }

    @Test func testWindowsHelperDiscIsInteractiveAndWellFormed() throws {
        let files = WindowsSetupMedia.files(bypassChecks: true, sharedFolderName: "Lumen Shared")
        let xml = try #require(files.first { $0.relativePath == "autounattend.xml" }).contents
        #expect(throws: Never.self) { try XMLDocument(xmlString: xml) }
        #expect(xml.contains("BypassTPMCheck"))
        #expect(xml.contains("BypassSecureBootCheck"))
        #expect(xml.contains("processorArchitecture=\"arm64\""))
        #expect(!(xml.contains("<ProductKey>")))
        #expect(!(xml.contains("<DiskConfiguration>")))
        #expect(files.contains { $0.relativePath == "startup.nsh" && $0.contents.contains("bootaa64.efi") })
        #expect(files.contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") && $0.contents.contains("-EncodedCommand") })
        let plain = WindowsSetupMedia.autounattend(bypassChecks: false)
        #expect(!plain.contains("LabConfig"))
        #expect(throws: Never.self) { try XMLDocument(xmlString: plain) }
        #expect(plain.contains("<DynamicUpdate><Enable>false</Enable>"))
    }

    @Test func testLocalAccountSetupIsOptionalAndPreservesLegacyRecords() throws {
        var record = VirtualMachineRecord(name: "Windows", guest: .windows)
        #expect(record.windowsLocalAccount)
        #expect(!record.windowsCompatibilityDisplay)
        #expect(record.windowsAutomaticDisplaySetup)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "windowsLocalAccount")
        let legacy = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!legacy.windowsLocalAccount)
        record.windowsLocalAccount = false
        #expect(try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record)) == record)
        for local in [true, false] {
            let xml = WindowsSetupMedia.autounattend(bypassChecks: false, preferLocalAccount: local)
            let doc = try XMLDocument(xmlString: xml)
            let nodes = try doc.nodes(forXPath: "//*[local-name()='settings'][@pass='oobeSystem']//*[local-name()='HideOnlineAccountScreens']")
            #expect(nodes.first?.stringValue == (local ? "true" : nil))
            #expect(!(xml.contains("<UserAccounts>")))
            #expect(!(xml.contains("<AutoLogon>")))
            #expect(!xml.contains("SkipMachineOOBE"))
            let commands = try doc.nodes(forXPath: "//*[local-name()='FirstLogonCommands']//*[local-name()='CommandLine']")
            #expect(commands.count == 1)
            #expect(commands.first?.stringValue == #"cmd /d /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\lumen\finish-setup.cmd call %i:\lumen\finish-setup.cmd /setup"#)
        }
    }

    @Test func testDiskGrowsButNeverShrinks() throws {
        let library = try MachineLibrary(root: temporary)
        let record = VirtualMachineRecord(name: "Grow", guest: .debian, diskGiB: 16)
        try library.create(record)
        try library.growDisk(for: record.id, toGiB: 32)
        let usage = try SparseDisk.usage(at: library.location(for: record.id).disk)
        #expect(usage.capacityBytes == 32 * 1_073_741_824)
        #expect(usage.allocatedBytes < 1_048_576)
        #expect(throws: (any Error).self) { try library.growDisk(for: record.id, toGiB: 16) }
        #expect(throws: (any Error).self) { try library.growDisk(for: record.id, toGiB: Int.max) }
    }

    @Test func testWindowsDriverMediaPersistsWithoutChangingLegacyIdentity() throws {
        let original = VirtualMachineRecord(name: "Windows", guest: .windows,
            windowsDriversPath: "/shared/virtio-win.iso", portForwards: [PortForward(hostPort: 2222, guestPort: 22)])
        let restored = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.macAddress == original.macAddress)
        #expect(restored.displayWidth == 2560)
        var invalid = original
        invalid.windowsDriversPath = "/shared/driver.exe"
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func testDriverSetupUsesARM64AndNeverPausesUnattendedInstallation() throws {
        let files = WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: nil)
        let xml = try #require(files.first { $0.relativePath == "autounattend.xml" }).contents
        #expect(throws: Never.self) { try XMLDocument(xmlString: xml) }
        #expect(!xml.contains("BypassSecureBootCheck"))
        #expect(xml.contains("drvload"))
        #expect(xml.contains(#"viogpudo\w11\ARM64\viogpudo.inf"#))
        #expect(xml.contains("install-drivers.cmd /setup"))
        let script = try #require(files.first { $0.relativePath == "lumen/install-drivers.cmd" }).contents
        #expect(script.contains("NetKVM viogpudo Balloon"))
        #expect(script.contains("if /i \"%~1\"==\"/quiet\" exit /b %FAILED%"))
        #expect(!script.lowercased().contains("testsigning"))
        #expect(!script.lowercased().contains("amd64"))
        let graphics = try #require(files.first { $0.relativePath == "lumen/install-graphics-service.cmd" }).contents
        #expect(script.contains("call \"%~dp0install-graphics-service.cmd\""))
        #expect(graphics.contains("Get-AuthenticodeSignature"))
        #expect(graphics.contains("viogpuap.exe"))
        #expect(graphics.contains("sc config vgpusrv"))
        #expect(graphics.contains("WaitForStatus('Running'"))
        let display = try #require(files.first { $0.relativePath == "lumen/configure-display.cmd" }).contents
        #expect(graphics.contains("New-ScheduledTaskTrigger -AtStartup"))
        #expect(graphics.contains("-User SYSTEM -RunLevel Highest"))
        #expect(display.contains("Get-PnpDevice -PresentOnly"))
        #expect(display.contains("$env:LUMEN_DISPLAY_BOOT -ne '1'"))
        #expect(display.contains("PCI\\VEN_1AF4&DEV_1050*"))
        #expect(display.contains("Remove-ItemProperty"))
        #expect(display.contains("shutdown.exe /r /t 0"))
        #expect(!display.contains("shutdown.exe /r /f"))
        #expect(!graphics.contains("Services\\BasicDisplay"))
        // The desktop entry must retain the adjacent resize-service helper and ask for UAC.
        #expect(xml.contains("xcopy"))
        #expect(xml.contains(#"%ProgramData%\Lumen\Tools\"#))
        let desktop = try #require(files.first { $0.relativePath == "lumen/Install Lumen Drivers.cmd" }).contents
        #expect(desktop.contains("-Verb RunAs"))
        #expect(desktop.contains(#"Lumen\Tools\finish-setup.cmd"#))
    }

    @Test func testOlderWindowsMachinesKeepAVisibleRecoveryFramebuffer() throws {
        var record = VirtualMachineRecord(name: "Windows", guest: .windows)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "windowsCompatibilityDisplay")
        object.removeValue(forKey: "windowsAutomaticDisplaySetup")
        let legacy = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.windowsCompatibilityDisplay)
        #expect(!legacy.windowsAutomaticDisplaySetup)
        record.windowsCompatibilityDisplay = false
        let modern = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        #expect(!modern.windowsCompatibilityDisplay)
    }

    @Test func testUnsafeShareNamesAreNeverInsertedIntoBatchCommands() throws {
        for name in ["name\r\ncalc", "quote\"", "path\\child", "path/child", "a|b"] {
            #expect(!WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: name)
                .contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") })
        }
        #expect(WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: "My Shared Folder")
            .contains { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") })
        let name = "O'Brien & %PATH% !shared! é"
        let script = try #require(WindowsSetupMedia.files(bypassChecks: false, sharedFolderName: name)
            .first { $0.relativePath.hasSuffix("Connect Mac Shared Folder.cmd") }).contents
        #expect(!script.contains(name))
        #expect(!script.contains("net use Z:"))
        let payload = try #require(script.components(separatedBy: "-EncodedCommand ").last?.components(separatedBy: "\r\n").first)
        let data = try #require(Data(base64Encoded: payload))
        let command = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(command.contains("$p='\\\\10.0.2.2\\O''Brien & %PATH% !shared! é'"))
        #expect(command.contains("-FilePath explorer.exe"))
    }

    @Test func testLocalFileSelectionRejectsDirectoriesAndNonlocalInstallers() throws {
        let image = temporary.appendingPathComponent("My Windows ARM64.ISO")
        try Data([0]).write(to: image)
        #expect(throws: Never.self) { try LocalFileSelection.validateInstaller(image) }
        #expect(throws: (any Error).self) { try LocalFileSelection.validateFolder(image) }
        let folder = temporary.appendingPathComponent("folder.iso", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try LocalFileSelection.validateInstaller(folder) }
        #expect(throws: Never.self) { try LocalFileSelection.validateFolder(folder) }
        #expect(throws: (any Error).self) { try LocalFileSelection.validateInstaller(URL(string: "https://example.com/windows-arm64.iso")!) }
        #expect(throws: (any Error).self) { try LocalFileSelection.validateInstaller(temporary.appendingPathComponent("missing.iso")) }
        #expect(throws: (any Error).self) { try LocalFileSelection.validateInstaller(temporary.appendingPathComponent("setup.exe")) }
    }

    @Test func testMacSharingUsesPublishedNameAndExactEnabledFolder() throws {
        let data = Data(#"{"First":{"path":"/tmp/LumenFolder","smb_name":"Published Name","smb_shared":1,"smb_read_only":1},"Disabled":{"path":"/tmp/Disabled","smb_name":"Disabled","smb_shared":0}}"#.utf8)
        let share = try #require(try MacSMBShare.configuredShare(for: URL(fileURLWithPath: "/tmp/LumenFolder"), in: data))
        #expect(share.name == "Published Name")
        #expect(share.readOnly)
        #expect(try MacSMBShare.configuredShare(for: URL(fileURLWithPath: "/tmp/Disabled"), in: data) == nil)
        #expect(try MacSMBShare.configuredShare(for: URL(fileURLWithPath: "/tmp/LumenFolder/child"), in: data) == nil)
        #expect(throws: (any Error).self) { try MacSMBShare.configuredShare(for: temporary, in: Data("not json".utf8)) }
    }

    @Test func testPortForwardingValidatesBoundsAndDuplicateEndpoints() throws {
        let rule = PortForward(hostPort: 2222, guestPort: 22)
        #expect(rule.qemuOption == "hostfwd=tcp:127.0.0.1:2222-:22")
        var record = VirtualMachineRecord(name: "Windows", guest: .windows, portForwards: [rule])
        #expect(throws: Never.self) { try record.validate() }
        record.portForwards.append(PortForward(hostPort: 2222, guestPort: 80))
        #expect(throws: (any Error).self) { try record.validate() }
        record.portForwards = [rule, PortForward(transport: .udp, hostPort: 2222, guestPort: 53)]
        #expect(throws: Never.self) { try record.validate() }
        record.portForwards = [PortForward(hostPort: 65536, guestPort: 80)]
        #expect(throws: (any Error).self) { try record.validate() }
        record.portForwards = [rule]
        record.guest = .ubuntu
        #expect(throws: (any Error).self) { try record.validate() }
    }

    @Test func testPasswordInjectionRejectsUnmappableCharactersBeforeTyping() {
        #expect(GuestKeyboard.supports("Test 123!@#$%^&*()_+-=[]{};:'\",.<>/?`~\\|"))
        for password in ["", "pässword", "🔐", "hello\nworld", "tabs\t"] {
            #expect(!GuestKeyboard.supports(password))
        }
    }

    @Test func testISODetectionFindsPrimaryDescriptorAfterBootRecord() throws {
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
        #expect(detected.guest == .windows)
        #expect(detected.architecture == .x86_64)
    }
}
