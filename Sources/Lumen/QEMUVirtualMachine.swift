import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import LumenCore
import Security
import UniformTypeIdentifiers

/// Optional Windows ARM64 backend. QEMU owns the guest display in a separate Cocoa window.
/// This is an experimental hardware profile, not a claim of Windows certification.
@MainActor
final class QEMUVirtualMachine: ObservableObject {
    @Published private(set) var state: VMRuntimeState = .stopped
    @Published private(set) var errorMessage: String?

    let record: VirtualMachineRecord
    let location: VMLocation
    var logURL: URL { location.directory.appendingPathComponent("qemu.log") }
    var isProcessRunning: Bool { process?.isRunning == true }

    private var displayReceiptDirectory: URL?
    private var displaySetup: WindowsDisplaySetup?
    /// Identifies the helper disc Lumen built most recently, for fixed Run commands.
    private var setupDiscMarker = WindowsGuestCommands.makeDiscMarker()
    private var displaySetupTask: Task<Void, Never>?
    private var needsAutomaticDisplaySetup: Bool { record.windowsAutomaticDisplaySetup && !record.windowsCompatibilityDisplay }
    private var usesCompatibilityDisplay: Bool { record.windowsCompatibilityDisplay || needsAutomaticDisplaySetup }
    private var managedSharing: ManagedWindowsSharing?
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var logHandle: FileHandle?
    private var incoming = Data()
    private var pending: [String: String] = [:]
    private var replies: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var replyTimeouts: [String: Task<Void, Never>] = [:]
    private var monitorReady = false
    private var expectedExit = false
    private var launchID: UUID?
    private var startupTimeout: Task<Void, Never>?
    private var stopTimeout: Task<Void, Never>?
    private var tpmProcess: Process?
    private var tpmRuntimeDirectory: URL?
    private var processBundleRoot: URL?
    private let controlToken = UUID().uuidString
    private var menuControlObserver: NSObjectProtocol?
    private var menuStatusObservation: AnyCancellable?
    private var menuBridgeReady = false
    private var isSendingGuestCommand = false
    var onLibraryAction: ((String) -> Void)?
    var onFilesDrop: (([URL]) -> Void)?

    static var tpmExecutableURL: URL? {
        ["/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0) }
    }

    static var defaultDriversURL: URL? {
        if let path = UserDefaults.standard.string(forKey: "windowsDriversPath"),
           FileManager.default.isReadableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return Bundle.main.url(forResource: "WindowsDrivers", withExtension: "iso")
    }

    var driversURL: URL? {
        if let path = record.windowsDriversPath { return URL(fileURLWithPath: path) }
        let legacy = location.directory.appendingPathComponent("Drivers.iso")
        return FileManager.default.isReadableFile(atPath: legacy.path) ? legacy : Self.defaultDriversURL
    }

    init(record: VirtualMachineRecord, location: VMLocation) {
        self.record = record
        self.location = location
    }

    static var executableURL: URL? {
        var candidates: [String] = []
        if let configured = UserDefaults.standard.string(forKey: "qemuExecutablePath"), !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += ["/opt/homebrew/bin/qemu-system-aarch64", "/usr/local/bin/qemu-system-aarch64"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").filter { $0.hasPrefix("/") }
            .map { String($0) + "/qemu-system-aarch64" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static var availabilityDescription: String {
        guard let executableURL else {
            return "Install QEMU with Cocoa display, HVF and EDK2 firmware to enable the experimental Windows backend."
        }
        guard firmwareDirectory(for: executableURL) != nil else {
            return "QEMU is installed, but its ARM64 EDK2 firmware files could not be found."
        }
        return "QEMU is available. Windows ARM64 is experimental and opens in a separate window."
    }

    func start(bootInstaller: Bool) async throws {
        guard process == nil, !state.isActive else { throw QEMUError("This virtual machine is already active.") }
        try record.validate()
        guard record.guest == .windows else { throw QEMUError("This QEMU profile is for Windows ARM64.") }
        guard record.macAddress.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil else {
            throw QEMUError("The virtual network adapter has an invalid MAC address.")
        }
        guard let executable = Self.executableURL else { throw QEMUError(Self.availabilityDescription) }
        if !record.windowsCompatibilityDisplay, driversURL == nil {
            throw QEMUError("Choose an ARM64 VirtIO driver ISO or enable Compatibility display. Windows needs its display driver to keep refreshing after firmware boot.")
        }
        #if !arch(arm64)
        throw QEMUError("The Windows backend requires an Apple silicon Mac.")
        #else
        guard FileManager.default.fileExists(atPath: location.disk.path) else {
            throw QEMUError("The virtual disk is missing. Restore it before starting this machine.")
        }
        if bootInstaller {
            guard let path = record.installerPath, FileManager.default.isReadableFile(atPath: path) else {
                throw QEMUError("Choose a readable Windows ARM64 ISO before starting the installer.")
            }
        }
        let firmware = try prepareFirmware(executable: executable)
        var launchSucceeded = false
        defer {
            if !launchSucceeded { cleanup(); state = .failed }
        }
        errorMessage = nil
        state = .starting
        let arguments: [String]
        do {
            if record.windowsTPM { try await startTPM() }
            if !record.sharedFolders.isEmpty || needsAutomaticDisplaySetup {
                guard record.networkEnabled || record.sharedFolders.isEmpty else { throw QEMUError("Enable networking to connect the selected shared folders.") }
                var setupShare: (name: String, directory: URL)?
                if needsAutomaticDisplaySetup {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-display-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    displayReceiptDirectory = directory
                    setupShare = ("LumenSetup_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "$", directory)
                }
                let sharing = ManagedWindowsSharing()
                managedSharing = sharing
                try await sharing.start(folders: record.sharedFolders, location: location, setupShare: setupShare)
                if let setupShare, let connection = sharing.connection {
                    displaySetup = WindowsDisplaySetup(password: connection.password, share: setupShare.name, ticket: UUID().uuidString)
                }
            }
            let setupMedia = try await prepareSetupMedia()
            arguments = try makeArguments(firmware: firmware, setupMedia: setupMedia, bootInstaller: bootInstaller)
                + (Self.firmwareDirectory(for: executable).map { ["-L", $0.path] } ?? [])
        } catch {
            cleanup()
            state = .failed
            errorMessage = error.localizedDescription
            throw error
        }
        expectedExit = false
        monitorReady = false
        incoming.removeAll()
        pending.removeAll()

        // Rotate a single previous log; avoid collecting one log for every boot forever.
        let previousLog = location.directory.appendingPathComponent("qemu-previous.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.removeItem(at: previousLog)
            try FileManager.default.moveItem(at: logURL, to: previousLog)
        }
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw QEMUError("Could not create the QEMU diagnostic log.")
        }
        logHandle = try FileHandle(forWritingTo: logURL)
        let child = Process()
        let currentLaunch = UUID()
        launchID = currentLaunch
        let input = Pipe()
        let output = Pipe()
        let host = try VMProcessBundle.prepare(executable: executable, name: record.name, id: record.id)
        processBundleRoot = host.root
        child.executableURL = host.executable
        child.arguments = arguments
        child.currentDirectoryURL = location.directory
        child.standardInput = input
        child.standardOutput = output
        child.standardError = logHandle

        var env = ProcessInfo.processInfo.environment
        env["LUMEN_VM_CONTROL_TOKEN"] = controlToken
        env["LUMEN_VM_MENU_REPORT"] = location.directory.appendingPathComponent("guest-menu.json").path
        if let helper = helperDylibURL() {
            env["DYLD_INSERT_LIBRARIES"] = helper.path
            env["LUMEN_VM_NAME"] = record.name
            env["LUMEN_VM_WIDTH"] = String(record.displayWidth)
            env["LUMEN_VM_HEIGHT"] = String(record.displayHeight)
            env["LUMEN_VM_AUTO_RESIZE"] = record.autoResizeDisplay ? "1" : "0"
            env["LUMEN_VM_DISK_SYNC"] = record.diskSyncMode.rawValue
            env["LUMEN_VM_DISK_PATH"] = location.disk.path
            if let iconURL = try? prepareGuestIcon() {
                env["LUMEN_VM_ICON"] = iconURL.path
            }
        }
        child.environment = env
        installMenuBridge()

        // A dead child must report an error, rather than deliver SIGPIPE to the application.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.receive(data, launchID: currentLaunch) }
        }
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor [weak self] in self?.didTerminate(status: status, launchID: currentLaunch) }
        }
        process = child
        inputPipe = input
        outputPipe = output
        state = .starting
        do {
            try child.run()
            launchSucceeded = true
            watchDisplaySetup()
        } catch {
            cleanup()
            state = .failed
            errorMessage = "Could not launch QEMU: \(error.localizedDescription)"
            throw error
        }
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, !self.monitorReady, self.process?.isRunning == true else { return }
            self.errorMessage = "QEMU did not initialize its control connection. See qemu.log in this machine’s folder."
            self.process?.terminate()
        }
        #endif
    }

    private func watchDisplaySetup() {
        guard let directory = displayReceiptDirectory, let setup = displaySetup else { return }
        displaySetupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.isProcessRunning else { return }
                guard self.state == .running,
                      let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("display-ready")) else { continue }
                let data = try? handle.read(upToCount: 128)
                try? handle.close()
                guard let data, setup.acceptsReceipt(data) else { continue }
                self.onLibraryAction?("automatic-retina")
                return
            }
        }
    }

    func showDisplay() {
        guard let process, process.isRunning else { return }
        NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateAllWindows])
    }

    private func installMenuBridge() {
        let center = DistributedNotificationCenter.default()
        menuControlObserver = center.addObserver(forName: Notification.Name("app.lumen.control.\(controlToken)"),
                                                object: nil, queue: .main) { [weak self] notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isProcessRunning else { return }
                if action == "drop-files" {
                    guard self.state == .running,
                          let values = notification.userInfo?["urls"] as? [String],
                          !values.isEmpty, values.count <= 128 else { return }
                    let urls = values.compactMap { URL(string: $0) }
                    guard urls.count == values.count, urls.allSatisfy(\.isFileURL) else { return }
                    self.onFilesDrop?(urls)
                    return
                }
                do { try await self.handleMenuAction(action) }
                catch {
                    self.errorMessage = error.localizedDescription
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        menuStatusObservation = $state.sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.publishMenuStatus() }
        }
    }

    private func mediaBlocks() async throws -> [[String: Any]] {
        try await request("query-block", arguments: [:])["items"] as? [[String: Any]] ?? []
    }

    private func block(for role: String, in blocks: [[String: Any]]) -> [String: Any]? {
        blocks.first { item in
            let name = item["qdev"] as? String ?? ""
            return name == "lumen-\(role)" || name.hasSuffix("/lumen-\(role)")
        }
    }

    private func publishMenuStatus() async {
        guard isProcessRunning else { return }
        var media: [String: Bool] = [:]
        if monitorReady, let blocks = try? await mediaBlocks() {
            for role in ["installer", "drivers", "setup"] {
                media["eject-\(role)"] = block(for: role, in: blocks)?["inserted"] != nil
            }
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.lumen.status.\(controlToken)"), object: nil,
            userInfo: ["state": state.rawValue, "typing": isSendingGuestCommand, "media": media,
                       "compatibilityDisplay": usesCompatibilityDisplay,
                       "canReceiveFiles": record.sharedFolders.contains { !$0.readOnly },
                       "sharedFolders": managedSharing != nil && !record.sharedFolders.isEmpty], deliverImmediately: true)
    }

    /// All removable drives have explicit qdev identities. Modern QEMU's legacy device field is blank.
    private func changeMedia(role: String, url: URL?, reload: Bool = false) async throws {
        guard state == .running || state == .paused else { throw QEMUError("Start the machine before changing its discs.") }
        let blocks = try await mediaBlocks()
        guard let item = block(for: role, in: blocks), let id = item["qdev"] as? String else {
            throw QEMUError("The \(role) drive is unavailable. Restart this VM with the updated Lumen app.")
        }
        if let url {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw QEMUError("The selected disc cannot be read.") }
            if !reload, let inserted = item["inserted"] as? [String: Any], inserted["file"] as? String == url.path,
               item["tray_open"] as? Bool != true { return }
            _ = try await request("blockdev-change-medium", arguments: [
                "id": id, "filename": url.path, "format": "raw", "read-only-mode": "read-only"
            ])
        } else {
            _ = try await request("eject", arguments: ["id": id])
        }
        await publishMenuStatus()
    }

    private func confirm(_ title: String, message: String, action: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    func installWindowsDrivers() async throws {
        guard state == .running, !isSendingGuestCommand else { throw QEMUError("Windows must be running and ready for input.") }
        guard confirm("Install / repair Windows guest tools?",
                      message: "Log in to the Windows desktop first. Lumen will attach its discs and type a fixed command into Windows Run using a US keyboard layout. Approve the administrator prompt in Windows. The installer logs results in %TEMP%\\Lumen-drivers.log.",
                      action: "Install Tools") else { return }
        guard let drivers = driversURL else { throw QEMUError("Choose an ARM64 driver ISO in this VM’s settings first.") }
        try await changeMedia(role: "drivers", url: drivers)
        try await insertFreshSetupMedia()
        try await openWindowsCommand(WindowsGuestCommands.installDrivers(marker: setupDiscMarker))
    }

    private func openWindowsCommand(_ text: String) async throws {
        guard state == .running, !isSendingGuestCommand, GuestKeyboard.supports(text) else {
            throw QEMUError("Windows must be running and ready for a US keyboard command.")
        }
        isSendingGuestCommand = true
        await publishMenuStatus()
        defer { isSendingGuestCommand = false; Task { await publishMenuStatus() } }
        showDisplay()
        try await Task.sleep(nanoseconds: 350_000_000)
        _ = try await request("send-key", arguments: ["keys": [
            ["type": "qcode", "data": "meta_l"], ["type": "qcode", "data": "r"]
        ], "hold-time": 100])
        // A cold Windows shell can take over a second to create Run; sending earlier
        // loses the first characters and launches a truncated command.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = try await request("send-key", arguments: ["keys": [
            ["type": "qcode", "data": "ctrl"], ["type": "qcode", "data": "a"]
        ], "hold-time": 100])
        try await Task.sleep(nanoseconds: 150_000_000)
        for char in text {
            try Task.checkCancellation()
            guard state == .running, let process,
                  NSRunningApplication(processIdentifier: process.processIdentifier)?.isActive == true else {
                throw QEMUError("Command typing stopped because Windows lost focus. Close Windows Run and try again from the Windows desktop.")
            }
            // USB polling under guest load can miss very short presses. Use the
            // same deliberate cadence for fixed commands as for guest passwords.
            try await sendCharacter(char, holdTime: 80)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        guard state == .running, let process,
              NSRunningApplication(processIdentifier: process.processIdentifier)?.isActive == true else {
            throw QEMUError("Windows lost focus before the command was submitted. Close Run and try again.")
        }
        try await sendKey("ret")
    }

    func connectSharedFolders() async throws {
        guard managedSharing != nil, !record.sharedFolders.isEmpty else { throw QEMUError("Select folders in this VM’s settings, then restart the VM to share them.") }
        try await insertFreshSetupMedia()
        try await openWindowsCommand(WindowsGuestCommands.connectFolders(marker: setupDiscMarker))
    }

    /// A guest user who read this launch's disc could copy its marker onto their own
    /// LUMENSETUP ISO, so rebuild the disc with a new marker right before typing a command.
    private func insertFreshSetupMedia() async throws {
        setupDiscMarker = WindowsGuestCommands.makeDiscMarker()
        let media = try await prepareSetupMedia()
        try await changeMedia(role: "setup", url: media, reload: true)
    }

    private func handleMenuAction(_ action: String) async throws {
        switch action {
        case "ready": menuBridgeReady = true; await publishMenuStatus()
        case "refresh": await publishMenuStatus()
        case "pause": try pause()
        case "resume": try resume()
        case "shutdown": try requestStop()
        case "force-stop":
            if confirm("Force stop \(record.name)?", message: "Unsaved work in Windows will be lost. Use Shut Down when possible.", action: "Force Stop") { try forceStop() }
        case "reset":
            if confirm("Restart \(record.name) immediately?", message: "This resets the virtual hardware. Unsaved work in Windows will be lost.", action: "Restart") {
                _ = try await request("system_reset", arguments: [:])
            }
        case "secure-attention":
            guard state == .running else { return }
            _ = try await request("send-key", arguments: ["keys": ["ctrl", "alt", "delete"].map { ["type": "qcode", "data": $0] }, "hold-time": 100])
        case "install-drivers": try await installWindowsDrivers()
        case "guest-folders": try await connectSharedFolders()
        case "guest-display": try await openWindowsCommand(WindowsGuestCommands.displaySettings)
        case "guest-network": try await openWindowsCommand(WindowsGuestCommands.networkSettings)
        case "guest-devices": try await openWindowsCommand(WindowsGuestCommands.deviceManager)
        case "guest-windows-key": if state == .running { try await sendKey("meta_l") }
        case "guest-escape": if state == .running { try await sendKey("esc") }
        case "mount-drivers":
            guard let url = driversURL else { throw QEMUError("Choose a Windows driver disc in Settings first.") }
            try await changeMedia(role: "drivers", url: url)
        case "mount-setup": try await changeMedia(role: "setup", url: location.windowsSetupMedia)
        case "mount-installer":
            guard let path = record.installerPath else { throw QEMUError("No installer is configured. Use Choose ISO to insert one for this session.") }
            try await changeMedia(role: "installer", url: URL(fileURLWithPath: path))
        case "change-installer":
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "Insert an ARM64 installer ISO for this session"
            panel.allowedContentTypes = [.init(filenameExtension: "iso") ?? .data]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                guard InstallerDetector.detect(url: url).architecture != .x86_64 else { throw QEMUError("Choose ARM64 installation media.") }
                try await changeMedia(role: "installer", url: url)
            }
        case "eject-installer", "eject-drivers", "eject-setup":
            try await changeMedia(role: String(action.dropFirst(6)), url: nil)
        case "screenshot":
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Windows Screenshot.png"
            if panel.runModal() == .OK, let url = panel.url { try await screenshot(to: url) }
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting([location.directory])
        case "log": NSWorkspace.shared.open(logURL)
        case "about":
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(record.name) — Lumen VM"
            alert.informativeText = "Windows ARM64 • \(record.cpuCount) CPUs • \(record.memoryGiB) GiB RAM\nPowered by the QEMU open-source engine and Apple Hypervisor. Driver installation results remain inside Windows."
            alert.runModal()
        case "driver-guide", "compatibility":
            let name = action == "driver-guide" ? "feature-audit" : "compatibility"
            if let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Documentation") { NSWorkspace.shared.open(url) }
        case "engine-docs": NSWorkspace.shared.open(URL(string: "https://www.qemu.org/docs/master/")!)
        case "library", "settings", "start-all", "stop-all", "enable-retina": onLibraryAction?(action)
        default: break // Never execute arbitrary commands received through the menu bridge.
        }
    }

    /// Disposable diagnostic guest only: verifies bridge, branding and both read-only tool drives.
    func testMenuIntegration() async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(8)
        while !menuBridgeReady {
            guard Date() < deadline else { throw QEMUError("The guest menu bridge did not become ready.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        func waitForMenuState(_ expected: VMRuntimeState) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let data = try? Data(contentsOf: location.directory.appendingPathComponent("guest-menu.json")),
                   let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = report["status"] as? [String: Any], status["state"] as? String == expected.rawValue {
                    return report
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw QEMUError("The menu did not reflect \(expected.title.lowercased()) state.")
        }
        func commands(in items: [[String: Any]]) -> [String: Bool] {
            var result: [String: Bool] = [:]
            for item in items {
                if let action = item["command"] as? String { result[action] = item["enabled"] as? Bool ?? false }
                if let children = item["items"] as? [[String: Any]] { result.merge(commands(in: children)) { first, _ in first } }
            }
            return result
        }
        let runningMenu = try await waitForMenuState(.running)
        let menus = runningMenu["menus"] as? [[String: Any]] ?? []
        let titles = menus.compactMap { $0["title"] as? String }
        guard runningMenu["bundleName"] as? String == "Lumen VM",
              runningMenu["processName"] as? String == "Lumen VM",
              titles == ["Lumen VM", "Virtual Machine", "View", "Devices", "Window", "Help"],
              commands(in: menus)["install-drivers"] == true else {
            throw QEMUError("The branded menu inventory or driver action is incorrect.")
        }
        try pause()
        let pausedMenu = try await waitForMenuState(.paused)
        let pausedCommands = commands(in: pausedMenu["menus"] as? [[String: Any]] ?? [])
        guard pausedCommands["pause"] == false, pausedCommands["resume"] == true,
              pausedCommands["install-drivers"] == false else { throw QEMUError("Paused menu validation is incorrect.") }
        try resume()
        _ = try await waitForMenuState(.running)
        for (role, url) in [("drivers", driversURL), ("setup", Optional(location.windowsSetupMedia))] {
            guard let url else { throw QEMUError("The test driver disc is missing.") }
            try await changeMedia(role: role, url: nil)
            let empty = block(for: role, in: try await mediaBlocks())
            guard empty?["inserted"] == nil else { throw QEMUError("The \(role) disc did not eject.") }
            try await changeMedia(role: role, url: url)
            guard block(for: role, in: try await mediaBlocks())?["inserted"] != nil else { throw QEMUError("The \(role) disc did not reinsert.") }
        }
        await publishMenuStatus()
        try await Task.sleep(nanoseconds: 250_000_000)
        var result = try await diagnosticStatus()
        result["brandingAndMenuInventory"] = "passed"
        result["pausedMenuValidation"] = "passed"
        result["toolDiscEjectAndReinsert"] = "passed"
        return result
    }

    private func startTPM() async throws {
        guard let executable = Self.tpmExecutableURL else {
            throw QEMUError("TPM 2.0 is enabled. Install swtpm with Homebrew, or turn off TPM in this VM’s settings. Existing TPM state is always preserved.")
        }
        try FileManager.default.createDirectory(at: location.tpmState, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Darwin socket paths are limited to 104 bytes. Keep runtime sockets separate from persistent keys.
        let runtime = URL(fileURLWithPath: "/tmp/lumen-tpm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        tpmRuntimeDirectory = runtime
        let socket = runtime.appendingPathComponent("ctrl")
        let child = Process()
        child.executableURL = executable
        child.currentDirectoryURL = location.tpmState
        child.arguments = ["socket", "--tpm2", "--tpmstate", "dir=.,mode=0600,lock",
                           "--ctrl", "type=unixio,path=\(socket.path),mode=0600,terminate",
                           "--flags", "not-need-init"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        tpmProcess = child
        try child.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket.path) {
            guard child.isRunning else { throw QEMUError("The TPM emulator could not initialize. Its stored keys were retained.") }
            guard Date() < deadline else { throw QEMUError("The TPM emulator did not create its control socket.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func pause() throws {
        guard state == .running else { throw QEMUError("Only a running machine can be paused.") }
        try command("stop")
    }

    func resume() throws {
        guard state == .paused else { throw QEMUError("Only a paused machine can be resumed.") }
        try command("cont")
    }

    /// Captures only the guest framebuffer, without requiring macOS screen-recording access.
    func screenshot(to destination: URL) async throws {
        guard destination.isFileURL else { throw QEMUError("Choose a local PNG destination.") }
        let temporary = location.directory.appendingPathComponent(".capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var pngData: Data?
        do {
            _ = try await request("screendump", arguments: ["filename": temporary.path, "format": "png"])
            let candidate = try Data(contentsOf: temporary)
            guard candidate.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw QEMUError("QEMU did not return a PNG framebuffer capture.")
            }
            pngData = candidate
        } catch {
            // Older QEMU builds and builds without libpng still support the default PPM format.
            try? FileManager.default.removeItem(at: temporary)
            _ = try await request("screendump", arguments: ["filename": temporary.path])
            pngData = try QEMUScreenshot.png(fromPPM: Data(contentsOf: temporary))
        }
        guard let finalData = pngData else { throw QEMUError("Could not capture screenshot.") }
        try finalData.write(to: destination, options: .atomic)
    }

    func sendBootKey() async throws { try await sendKey("spc") }

    func diagnosticStatus() async throws -> [String: Any] {
        let status = try await request("query-status", arguments: [:])
        let tpm = try await request("query-tpm", arguments: [:])
        var result: [String: Any] = ["status": status, "tpm": tpm["items"] ?? [],
                "driversPath": driversURL?.path ?? "none",
                "compatibilityDisplay": usesCompatibilityDisplay,
                "configuredDisplayWidth": record.displayWidth,
                "configuredDisplayHeight": record.displayHeight]
        result["menuBridgeReady"] = menuBridgeReady
        if let data = try? Data(contentsOf: location.directory.appendingPathComponent("guest-menu.json")),
           let menu = try? JSONSerialization.jsonObject(with: data) { result["guestMenus"] = menu }
        return result
    }

    /// Uses a QEMU qcode (for example spc, ret, tab or esc); QEMU validates the key name.
    func sendKey(_ qcode: String) async throws {
        _ = try await request("send-key", arguments: [
            "keys": [["type": "qcode", "data": qcode]], "hold-time": 100
        ])
    }

    func requestStop() throws {
        guard state == .running || state == .paused else {
            throw QEMUError("The machine is not ready to receive a shutdown request.")
        }
        if state == .paused { try command("cont") }
        try command("system_powerdown")
        // The guest may decline the power-button request. Force Stop remains available.
        state = .stopping
    }

    func forceStop() throws {
        guard let child = process, child.isRunning else { return }
        expectedExit = true
        state = .stopping
        if monitorReady {
            do { try command("quit") } catch { child.terminate() }
        } else {
            child.terminate()
        }
        stopTimeout?.cancel()
        stopTimeout = Task { [weak self, weak child] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let child, child.isRunning, self?.process === child else { return }
            kill(child.processIdentifier, SIGKILL)
        }
    }

    private static func firmwareDirectory(for executable: URL) -> URL? {
        var directories: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: "qemuFirmwareDirectory"), !custom.isEmpty {
            directories.append(URL(fileURLWithPath: custom, isDirectory: true))
        }
        directories += [executable, executable.resolvingSymlinksInPath()].map {
            $0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/qemu")
        }
        directories += ["/opt/homebrew/share/qemu", "/usr/local/share/qemu"].map { URL(fileURLWithPath: $0) }
        return directories.first { directory in
            FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("edk2-aarch64-code.fd").path)
                && variablesTemplate(in: directory) != nil
        }
    }

    private static func variablesTemplate(in directory: URL) -> URL? {
        ["edk2-aarch64-vars.fd", "edk2-arm-vars.fd"].map { directory.appendingPathComponent($0) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func prepareFirmware(executable: URL) throws -> (code: URL, variables: URL) {
        let code = location.directory.appendingPathComponent("qemu-uefi-code.fd")
        let variables = location.directory.appendingPathComponent("qemu-uefi-vars.fd")
        if FileManager.default.fileExists(atPath: code.path), FileManager.default.fileExists(atPath: variables.path) {
            return (code, variables)
        }
        guard let source = Self.firmwareDirectory(for: executable), let template = Self.variablesTemplate(in: source) else {
            throw QEMUError(Self.availabilityDescription)
        }
        // Firmware and NVRAM belong to this VM; subsequent boots never reset its boot entries.
        for (original, destination) in [(source.appendingPathComponent("edk2-aarch64-code.fd"), code), (template, variables)] {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: original, to: destination)
            }
        }
        return (code, variables)
    }

    private func prepareSetupMedia() async throws -> URL {
        let sharingConnection = managedSharing?.connection
        let displaySetup = self.displaySetup
        let discMarker = setupDiscMarker
        let clipboardResources = Bundle.main.resourceURL?.appendingPathComponent("WindowsClipboard")
        return try await Task.detached { [record, location, sharingConnection, clipboardResources, displaySetup, discMarker] in
        let isoURL = location.windowsSetupMedia
        let staging = location.directory.appendingPathComponent(".setup-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let files = WindowsSetupMedia.files(bypassChecks: record.windowsBypassChecks, sharedFolderName: nil, managedSharing: sharingConnection, preferLocalAccount: record.windowsLocalAccount, displaySetup: displaySetup, discMarker: discMarker)
        for file in files {
            let dest = staging.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: dest, atomically: true, encoding: .utf8)
        }
        if let clipboardResources {
            let destination = staging.appendingPathComponent("lumen/agent")
            try FileManager.default.copyItem(at: clipboardResources, to: destination)
        }
        // Skip hdiutil when the staged contents match the disc built last time.
        let hashURL = isoURL.appendingPathExtension("sha256")
        let contentHash = try Self.contentHash(of: staging)
        if FileManager.default.fileExists(atPath: isoURL.path),
           (try? String(contentsOf: hashURL, encoding: .utf8)) == contentHash {
            return isoURL
        }
        try? FileManager.default.removeItem(at: hashURL)
        let temporaryISO = location.directory.appendingPathComponent(".setup-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: temporaryISO) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["makehybrid", "-iso", "-joliet", "-default-volume-name", "LUMENSETUP", "-o", temporaryISO.path, staging.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw QEMUError("Could not build the Windows helper disc. See available space and folder permissions.") }
        if FileManager.default.fileExists(atPath: isoURL.path) {
            _ = try FileManager.default.replaceItemAt(isoURL, withItemAt: temporaryISO)
        } else {
            try FileManager.default.moveItem(at: temporaryISO, to: isoURL)
        }
        try? contentHash.write(to: hashURL, atomically: true, encoding: .utf8)
        return isoURL
        }.value
    }

    /// SHA-256 over every regular file's relative path and bytes, in sorted path order.
    nonisolated private static func contentHash(of directory: URL) throws -> String {
        let root = directory.standardizedFileURL.path
        var entries: [(String, URL)] = []
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                entries.append((String(url.standardizedFileURL.path.dropFirst(root.count)), url))
            }
        }
        var hasher = SHA256()
        for (relative, url) in entries.sorted(by: { $0.0 < $1.0 }) {
            let data = try Data(contentsOf: url)
            hasher.update(data: Data(relative.utf8) + Data([0]) + withUnsafeBytes(of: UInt64(data.count).littleEndian) { Data($0) })
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func makeArguments(firmware: (code: URL, variables: URL), setupMedia: URL, bootInstaller: Bool) throws -> [String] {
        let memMB = record.memoryGiB * 1024
        var arguments = [
            "-name", record.name.replacingOccurrences(of: ",", with: ",,"),
            "-machine", "virt,highmem=on,gic-version=3,pflash0=uefi-code,pflash1=uefi-vars",
            "-accel", "hvf", "-cpu", "host",
            // Present one socket of N single-threaded cores so Windows schedules them as a single package.
            "-smp", "\(record.cpuCount),sockets=1,cores=\(record.cpuCount),threads=1",
            "-m", String(memMB),
            "-nodefaults", "-display", "cocoa,zoom-to-fit=on,left-command-key=\(record.captureSystemKeys ? "on" : "off")",
            "-device", usesCompatibilityDisplay ? "ramfb" : "virtio-gpu-pci,edid=on,xres=\(record.displayWidth),yres=\(record.displayHeight)",
            "-fw_cfg", "name=opt/org.tianocore/X-GOP-Resolution,string=\(record.displayWidth)x\(record.displayHeight)",
            "-device", "qemu-xhci,id=usb", "-device", "usb-kbd", "-device", "usb-tablet",
            "-device", "virtio-balloon-pci"
        ]
        if record.networkEnabled || needsAutomaticDisplaySetup {
            arguments += [
                "-netdev", (["user", "id=network"] + (record.networkEnabled ? [] : ["restrict=on"]) + record.portForwards.map(\.qemuOption) + (managedSharing.map { [$0.forwardingOption] } ?? [])).joined(separator: ","),
                "-device", "virtio-net-pci,netdev=network,mac=\(record.macAddress)"
            ]
        }
        if record.audioOutput || record.microphone {
            arguments += [
                "-audiodev", "coreaudio,id=audio0,in.voices=\(record.microphone ? 1 : 0),out.voices=\(record.audioOutput ? 1 : 0)",
                "-device", "intel-hda", "-device",
                "\(record.microphone ? "hda-micro" : "hda-output"),audiodev=audio0"
            ]
        }
        if let runtime = tpmRuntimeDirectory {
            arguments += ["-chardev", "socket,id=tpmchar,path=\(runtime.appendingPathComponent("ctrl").path)",
                          "-tpmdev", "emulator,id=tpm0,chardev=tpmchar",
                          // QEMU's PPI RAM region is 4 KiB; HVF on 16 KiB-page Macs rejects that mapping.
                          // The TPM command interface remains available with PPI disabled.
                          "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off"]
        }
        arguments += [
            "-qmp", "stdio", "-monitor", "none", "-serial", "none"
        ]
        for (name, path, readOnly) in [
            ("uefi-code", firmware.code, true), ("uefi-vars", firmware.variables, false),
            ("disk", location.disk, false)
        ] {
            // JSON block options handle spaces, commas and Unicode in user-selected paths safely.
            var block: [String: Any] = [
                "driver": "raw", "node-name": name, "read-only": readOnly,
                "discard": "unmap", "file": ["driver": "file", "filename": path.path]
            ]
            if name == "disk" {
                block["cache"] = ["direct": false, "no-flush": record.diskSyncMode == .fastest]
                // Request efficient zero writes/discard when the host supports it.
                // QEMU falls back to zero writes when hole punching is unavailable.
                block["detect-zeroes"] = "unmap"
            }
            arguments += ["-blockdev", try json(block)]
        }
        // Windows has a native NVMe storage driver. Virtio storage would need an extra ARM64 driver.
        // QEMU's nvme device has no iothread property (checked on 11.1), so it stays on the main loop.
        let nvmeBootIndex = bootInstaller ? 1 : 0
        arguments += ["-device", "nvme,drive=disk,serial=LUMEN\(record.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)),bootindex=\(nvmeBootIndex)"]
        if let path = record.installerPath {
            let installerBootIndex = bootInstaller ? 0 : 2
            arguments += ["-blockdev", try json([
                "driver": "raw", "node-name": "installer", "read-only": true,
                "file": ["driver": "file", "filename": path]
            ]), "-device", "usb-bot,id=installer-usb", "-device", "scsi-cd,id=lumen-installer,drive=installer,bus=installer-usb.0,bootindex=\(installerBootIndex)"]
        } else {
            arguments += ["-device", "usb-bot,id=installer-usb", "-device", "scsi-cd,id=lumen-installer,bus=installer-usb.0"]
        }
        do {
            arguments += ["-blockdev", try json([
                "driver": "raw", "node-name": "lumensetup", "read-only": true,
                "file": ["driver": "file", "filename": setupMedia.path]
            ]), "-device", "usb-bot,id=setup-usb", "-device", "scsi-cd,id=lumen-setup,drive=lumensetup,bus=setup-usb.0"]
        }
        if let drivers = driversURL {
            guard FileManager.default.isReadableFile(atPath: drivers.path) else {
                throw QEMUError("The Windows driver ISO is missing. Choose it again in Settings.")
            }
            arguments += ["-blockdev", try json([
                "driver": "raw", "node-name": "drivers", "read-only": true,
                "file": ["driver": "file", "filename": drivers.path]
            ]), "-device", "usb-bot,id=drivers-usb", "-device", "scsi-cd,id=lumen-drivers,drive=drivers,bus=drivers-usb.0"]
        } else {
            arguments += ["-device", "usb-bot,id=drivers-usb", "-device", "scsi-cd,id=lumen-drivers,bus=drivers-usb.0"]
        }
        if record.clipboardSharing {
            // Append after existing PCI devices to preserve their addresses.
            // Cocoa and qemu-vdagent share QEMU's clipboard bus directly.
            arguments += ["-device", "virtio-serial-pci,id=lumen-serial",
                          "-chardev", "qemu-vdagent,id=lumen-clipboard,clipboard=on,mouse=off",
                          "-device", "virtserialport,bus=lumen-serial.0,chardev=lumen-clipboard,name=com.redhat.spice.0"]
        }
        return arguments
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func command(_ name: String, arguments: [String: Any] = [:], requireReady: Bool = true, id: String = UUID().uuidString) throws {
        guard let handle = inputPipe?.fileHandleForWriting, process?.isRunning == true,
              monitorReady || !requireReady else { throw QEMUError("QEMU’s control connection is not ready.") }
        var message: [String: Any] = ["execute": name, "id": id]
        if !arguments.isEmpty { message["arguments"] = arguments }
        let payload = try json(message) + "\n"
        pending[id] = name
        do { try handle.write(contentsOf: Data(payload.utf8)) }
        catch { pending.removeValue(forKey: id); throw error }
    }

    private func request(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            do {
                try command(name, arguments: arguments, id: id)
                replyTimeouts[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishRequest(id, result: .failure(QEMUError("QEMU timed out while executing \(name).")))
                }
            } catch { finishRequest(id, result: .failure(error)) }
        }
    }

    private func finishRequest(_ id: String, result: Result<[String: Any], Error>) {
        pending.removeValue(forKey: id)
        replyTimeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(with: result)
    }

    private func receive(_ data: Data, launchID: UUID) {
        guard process != nil, self.launchID == launchID else { return }
        incoming.append(data)
        // Only QMP is routed here; limit buffering if an incompatible binary emits malformed output.
        if incoming.count > 1_048_576 {
            errorMessage = "QEMU returned an invalid control response. See qemu.log for details."
            process?.terminate()
            incoming.removeAll()
            return
        }
        while let newline = incoming.firstIndex(of: 10) {
            let line = incoming[..<newline]
            incoming.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            do {
                if object["QMP"] != nil { try command("qmp_capabilities", requireReady: false) }
                if let event = object["event"] as? String {
                    switch event {
                    case "STOP": if state != .stopping { state = .paused }
                    case "RESUME": if state != .stopping { state = .running }
                    case "SHUTDOWN": expectedExit = true; state = .stopping
                    case "GUEST_PANICKED": errorMessage = "The guest reported a kernel panic."
                    default: break
                    }
                }
                guard let id = object["id"] as? String, let commandName = pending.removeValue(forKey: id) else { continue }
                if replies[id] != nil {
                    if let failure = object["error"] as? [String: Any] {
                        finishRequest(id, result: .failure(QEMUError("QEMU \(commandName): \(failure["desc"] as? String ?? "command failed")")))
                    } else {
                        let returned = object["return"]
                        finishRequest(id, result: .success(returned as? [String: Any] ?? ["items": returned ?? []]))
                    }
                    continue
                }
                if let failure = object["error"] as? [String: Any] {
                    errorMessage = "QEMU \(commandName): \(failure["desc"] as? String ?? "command failed")"
                    if commandName == "qmp_capabilities" { process?.terminate() }
                    if commandName == "system_powerdown" { try command("query-status") }
                    continue
                }
                switch commandName {
                case "qmp_capabilities":
                    monitorReady = true
                    startupTimeout?.cancel()
                    try command("query-status")
                case "query-status":
                    if let result = object["return"] as? [String: Any], let running = result["running"] as? Bool {
                        state = running ? .running : .paused
                    }
                case "stop": if state != .stopping { state = .paused }
                case "cont": if state != .stopping { state = .running }
                default: break
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func didTerminate(status: Int32, launchID: UUID) {
        guard self.launchID == launchID else { return }
        let wasExpected = expectedExit
        cleanup()
        if status == 0 || wasExpected {
            state = .stopped
        } else {
            state = .failed
            let detail = logTail()
            errorMessage = [errorMessage, "QEMU exited with code \(status).", detail.isEmpty ? nil : detail]
                .compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    private func logTail() -> String {
        guard let file = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return "" }
        try? file.seek(toOffset: length > 4096 ? length - 4096 : 0)
        return String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func typePassword(_ text: String) async throws {
        guard state == .running else { throw QEMUError("The machine must be running to receive input.") }
        guard !isSendingGuestCommand else { throw QEMUError("Wait for the Windows command to finish typing.") }
        guard GuestKeyboard.supports(text) else {
            throw QEMUError("Password typing currently requires printable ASCII and a US keyboard layout in the guest. No keys were sent.")
        }
        for char in text {
            try Task.checkCancellation()
            guard state == .running else { throw QEMUError("The guest stopped accepting input.") }
            try await sendCharacter(char)
            try await Task.sleep(nanoseconds: 65_000_000)
        }
        try await sendKey("ret")
    }

    private func sendCharacter(_ char: Character, holdTime: Int = 50) async throws {
        let (qcode, shift) = qcodeForChar(char)
        let keys = (shift ? ["shift"] : []) + [qcode]
        func events(_ down: Bool) -> [[String: Any]] {
            (down ? keys : keys.reversed().map { $0 }).map {
                ["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": $0]]]
            }
        }
        // send-key uses a shared release timer. Under load, consecutive characters can
        // overlap and leave a key repeating. Acknowledge each explicit release instead.
        do {
            _ = try await request("input-send-event", arguments: ["events": events(true)])
            try await Task.sleep(nanoseconds: UInt64(holdTime) * 1_000_000)
            _ = try await request("input-send-event", arguments: ["events": events(false)])
        } catch {
            _ = try? await request("input-send-event", arguments: ["events": events(false)])
            throw error
        }
    }

    private func qcodeForChar(_ char: Character) -> (code: String, shift: Bool) {
        switch char {
        case "a"..."z": return (String(char), false)
        case "A"..."Z": return (String(char).lowercased(), true)
        case "0"..."9": return (String(char), false)
        case " ": return ("spc", false)
        case "\t": return ("tab", false)
        case "\n", "\r": return ("ret", false)
        case "!": return ("1", true)
        case "@": return ("2", true)
        case "#": return ("3", true)
        case "$": return ("4", true)
        case "%": return ("5", true)
        case "^": return ("6", true)
        case "&": return ("7", true)
        case "*": return ("8", true)
        case "(": return ("9", true)
        case ")": return ("0", true)
        case "-": return ("minus", false)
        case "_": return ("minus", true)
        case "=": return ("equal", false)
        case "+": return ("equal", true)
        case "[": return ("bracket_left", false)
        case "{": return ("bracket_left", true)
        case "]": return ("bracket_right", false)
        case "}": return ("bracket_right", true)
        case ";": return ("semicolon", false)
        case ":": return ("semicolon", true)
        case "'": return ("apostrophe", false)
        case "\"": return ("apostrophe", true)
        case ",": return ("comma", false)
        case "<": return ("comma", true)
        case ".": return ("dot", false)
        case ">": return ("dot", true)
        case "/": return ("slash", false)
        case "?": return ("slash", true)
        case "\\": return ("backslash", false)
        case "|": return ("backslash", true)
        case "`": return ("grave_accent", false)
        case "~": return ("grave_accent", true)
        default: return (String(char).lowercased(), false)
        }
    }

    /// QEMU loads this library through DYLD_INSERT_LIBRARIES, so release builds accept only
    /// the copy sealed into Lumen's own signature. Development fallbacks exist in DEBUG only.
    private func helperDylibURL() -> URL? {
        if let bundled = Self.sealedHelperDylib {
            return bundled
        }
        #if DEBUG
        let local = URL(fileURLWithPath: "Resources/LumenQEMUHelper.dylib")
        if FileManager.default.isReadableFile(atPath: local.path) {
            return local
        }
        let built = URL(fileURLWithPath: "build/Lumen.app/Contents/Resources/LumenQEMUHelper.dylib")
        if FileManager.default.isReadableFile(atPath: built.path) {
            return built
        }
        let target = location.directory.appendingPathComponent("LumenQEMUHelper.dylib")
        if FileManager.default.isReadableFile(atPath: target.path) {
            return target
        }
        let source = URL(fileURLWithPath: "Sources/LumenHelper/LumenQEMUHelper.m")
        if FileManager.default.isReadableFile(atPath: source.path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            proc.arguments = ["-dynamiclib", "-arch", "arm64", "-O2", "-framework", "AppKit", "-framework", "Foundation", "-o", target.path, source.path]
            try? proc.run()
            proc.waitUntilExit()
            if FileManager.default.isReadableFile(atPath: target.path) {
                return target
            }
        }
        #endif
        return nil
    }

    private static let sealedHelperDylib: URL? = {
        guard let helper = Bundle.main.url(forResource: "LumenQEMUHelper", withExtension: "dylib") else { return nil }
        var app: SecStaticCode?
        var library: SecStaticCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &app) == errSecSuccess, let app,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &library) == errSecSuccess, let library,
              SecStaticCodeCheckValidity(library, strict, nil) == errSecSuccess,
              // The app's sealed resources record the library's hash, including for ad-hoc builds.
              SecStaticCodeCheckValidity(app, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(app, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return helper }
        // A Developer ID build also requires the library to come from the same team.
        var requirement: SecRequirement?
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(library, strict, requirement) == errSecSuccess else { return nil }
        return helper
    }()

    private func prepareGuestIcon() throws -> URL {
        let iconURL = location.directory.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: iconURL.path) {
            return iconURL
        }
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()

        let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 54, yRadius: 54)
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.19, alpha: 1.0).setFill()
        bgPath.fill()

        let border = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 252, height: 252), xRadius: 52, yRadius: 52)
        border.lineWidth = 3
        NSColor(calibratedRed: 0.46, green: 0.71, blue: 1.0, alpha: 0.35).setStroke()
        border.stroke()

        let tileWidth: CGFloat = 82
        let tileHeight: CGFloat = 82
        let gap: CGFloat = 14
        let originX: CGFloat = 39
        let originY: CGFloat = 39

        NSColor(calibratedRed: 0.35, green: 0.68, blue: 1.0, alpha: 1.0).setFill()
        NSRect(x: originX, y: originY, width: tileWidth, height: tileHeight).fill()
        NSRect(x: originX + tileWidth + gap, y: originY, width: tileWidth, height: tileHeight).fill()
        NSRect(x: originX, y: originY + tileHeight + gap, width: tileWidth, height: tileHeight).fill()
        NSRect(x: originX + tileWidth + gap, y: originY + tileHeight + gap, width: tileWidth, height: tileHeight).fill()

        image.unlockFocus()

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: iconURL, options: .atomic)
        }
        return iconURL
    }

    private func cleanup() {
        displaySetupTask?.cancel()
        displaySetupTask = nil
        if let directory = displayReceiptDirectory { try? FileManager.default.removeItem(at: directory) }
        displayReceiptDirectory = nil
        displaySetup = nil
        managedSharing?.stop()
        managedSharing = nil
        if let observer = menuControlObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        menuControlObserver = nil
        menuStatusObservation = nil
        menuBridgeReady = false
        isSendingGuestCommand = false
        if let root = processBundleRoot, process?.isRunning != true { try? FileManager.default.removeItem(at: root) }
        processBundleRoot = nil
        if let tpm = tpmProcess, tpm.processIdentifier > 0 {
            if tpm.isRunning { tpm.terminate() }
            let runtime = tpmRuntimeDirectory
            // Reap after termination; never delete persistent TPM state or leave a live helper behind.
            Task.detached {
                for _ in 0..<30 {
                    if !tpm.isRunning { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if tpm.isRunning { kill(tpm.processIdentifier, SIGKILL) }
                tpm.waitUntilExit()
                if let runtime { try? FileManager.default.removeItem(at: runtime) }
            }
        } else if let runtime = tpmRuntimeDirectory { try? FileManager.default.removeItem(at: runtime) }
        tpmProcess = nil
        tpmRuntimeDirectory = nil
        startupTimeout?.cancel()
        stopTimeout?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? logHandle?.close()
        logHandle = nil
        inputPipe = nil
        outputPipe = nil
        process = nil
        launchID = nil
        monitorReady = false
        for id in Array(replies.keys) {
            finishRequest(id, result: .failure(QEMUError("QEMU stopped before replying to the request.")))
        }
        pending.removeAll()
        incoming.removeAll()
    }
}

private struct QEMUError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
