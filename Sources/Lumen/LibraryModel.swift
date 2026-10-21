import AppKit
import Combine
import SwiftUI
import LumenCore
import Virtualization

@MainActor
final class LibraryModel: ObservableObject {
    @Published var machines: [VirtualMachineRecord] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?
    let libraryURL: URL
    let hostResources = HostResources.current
    var hostMemoryGiB: Int { hostResources.memoryGiB }
    var hostCPUCount: Int { hostResources.cpuCount }
    var resourcePolicy: ResourcePolicy { ResourcePolicy(defaultsFor: hostResources) }

    private var library: MachineLibrary?
    private var appleEngines: [UUID: AppleVirtualMachine] = [:]
    private var nativeProcesses: [UUID: NativeGuestProcess] = [:]
    let guestProcessID: UUID?
    var isGuestProcess: Bool { guestProcessID != nil }
    private var guestLease: GuestRuntimeLease?
    private var guestBridge: NativeGuestBridge?
    private var guestRuntimeStarted = false
    private var qemuEngines: [UUID: QEMUVirtualMachine] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private var errorObservations: [UUID: AnyCancellable] = [:]
    private var guestWindows: [UUID: NSWindow] = [:]
    private var pending: Set<UUID> = []
    private var usage: [UUID: Int64] = [:]
    private var usageTimer: AnyCancellable?
    private var guestClipboardFocusObservation: AnyCancellable?
    private var sleepingMachineIDs: Set<UUID> = []
    private var sleepWakeCancellables: [AnyCancellable] = []
    let isDemo: Bool

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--native-guest"), index + 1 < CommandLine.arguments.count {
            guestProcessID = UUID(uuidString: CommandLine.arguments[index + 1])
        } else { guestProcessID = nil }
        isDemo = CommandLine.arguments.contains("--demo")
        if let override = ProcessInfo.processInfo.environment["LUMEN_LIBRARY_PATH"] {
            libraryURL = URL(fileURLWithPath: override, isDirectory: true)
        } else if isDemo || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--boot-test") || CommandLine.arguments.contains("--windows-boot-test") {
            libraryURL = FileManager.default.temporaryDirectory.appendingPathComponent("LumenPreview-" + UUID().uuidString)
        } else {
            libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lumen/Machines", isDirectory: true)
        }
        do {
            let storage = try MachineLibrary(root: libraryURL)
            library = storage
            machines = try storage.load()
            if let guestProcessID {
                machines = machines.filter { $0.id == guestProcessID }
                selectedID = guestProcessID
                guard machines.count == 1 else { throw LibraryError.missingMachine }
            }
            if isDemo && machines.isEmpty {
                // Preview fixtures are confined to an explicitly requested, separate preview library.
                for (name, guest, memory, disk) in [("Ubuntu Studio", GuestOS.ubuntu, 8, 64), ("macOS workspace", .macOS, 8, 80), ("Debian lab", .debian, 4, 32)] {
                    let record = VirtualMachineRecord(name: name, guest: guest, memoryGiB: memory, diskGiB: disk)
                    try storage.create(record)
                }
                machines = try storage.load()
                selectedID = machines.first?.id
            }
            refreshUsage()
        } catch { errorMessage = error.localizedDescription }
        usageTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshUsage()
        }
        setupSleepWakeObservers()
        if isGuestProcess {
            let bridge = NativeGuestBridge()
            guestBridge = bridge
            bridge.onCommand = { [weak self] in self?.handleGuestProcessCommand($0) }
            bridge.start()
        }
        guestClipboardFocusObservation = NotificationCenter.default.publisher(for: GuestVirtualMachineView.focusChanged).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var focusedGuestClipboardView: GuestVirtualMachineView? {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil,
              let view = window.firstResponder as? GuestVirtualMachineView,
              view.supportsGuestEditing else { return nil }
        return view
    }

    var hasActiveMachines: Bool { machines.contains { state(for: $0.id).isActive } }
    var activeMemoryGiB: Int { machines.filter { state(for: $0.id).isActive }.reduce(0) { $0 + $1.memoryGiB } }
    var availableMemoryBudgetGiB: Int { max(0, resourcePolicy.guestMemoryBudgetGiB(on: hostResources) - activeMemoryGiB) }

    func state(for id: UUID) -> VMRuntimeState {
        if pending.contains(id) { return .starting }
        return nativeProcesses[id]?.state ?? appleEngines[id]?.state ?? qemuEngines[id]?.state ?? .stopped
    }
    func allocatedBytes(for id: UUID) -> Int64 { usage[id] ?? 0 }
    func progress(for id: UUID) -> Double { nativeProcesses[id]?.progress ?? appleEngines[id]?.progress ?? 0 }

    func create(_ record: VirtualMachineRecord) throws {
        try record.validate()
        try validateMedia(record)
        guard let library else { throw LibraryError.invalidConfiguration("The library is unavailable. Check its folder permissions.") }
        let policy = resourcePolicy
        guard record.cpuCount <= policy.maxCPUsPerMachine(on: hostResources),
              record.memoryGiB <= policy.guestMemoryBudgetGiB(on: hostResources) else {
            throw LibraryError.invalidConfiguration("Leave at least \(policy.memoryReserveGiB) GiB memory for your Mac and use no more than \(policy.maxCPUsPerMachine(on: hostResources)) CPUs per machine.")
        }
        guard let installerPath = record.installerPath, FileManager.default.isReadableFile(atPath: installerPath) else {
            throw LibraryError.invalidConfiguration("Choose a readable installer before creating the machine.")
        }
        let ext = URL(fileURLWithPath: installerPath).pathExtension.lowercased()
        if !record.guest.isMacOS && !["iso", "img"].contains(ext) {
            throw LibraryError.invalidConfiguration("Choose an ARM64 UEFI bootable ISO. Root filesystem archives and board-specific images cannot boot here.")
        }
        guard record.memoryGiB >= record.guest.minimumMemoryGiB, record.diskGiB >= record.guest.minimumDiskGiB else {
            throw LibraryError.invalidConfiguration("Use at least \(record.guest.minimumMemoryGiB) GiB RAM and \(record.guest.minimumDiskGiB) GiB disk capacity for \(record.guest.title). Disk capacity is not reserved on your SSD.")
        }
        if record.guest == .windows, QEMUVirtualMachine.executableURL == nil {
            throw LibraryError.invalidConfiguration(QEMUVirtualMachine.availabilityDescription)
        }
        try library.create(record)
        machines.append(record)
        selectedID = record.id
        refreshUsage()
    }

    func create(name: String, guest: GuestOS, cpuCount: Int, memoryGiB: Int, diskGiB: Int,
                installerURL: URL?, sharedDirectoryURL: URL?) throws {
        let record = VirtualMachineRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                          guest: guest, cpuCount: cpuCount, memoryGiB: memoryGiB,
                                          diskGiB: diskGiB, installerPath: installerURL?.path,
                                          sharedDirectoryPath: sharedDirectoryURL?.path)
        try create(record)
    }

    func update(record: VirtualMachineRecord) throws {
        try record.validate()
        try validateMedia(record)
        guard !state(for: record.id).isActive else {
            throw LibraryError.invalidConfiguration("Shut down the machine before changing its settings.")
        }
        guard let library, let index = machines.firstIndex(where: { $0.id == record.id }) else { throw LibraryError.missingMachine }
        let original = machines[index]
        // Linux guests share one backend, so a machine may be relabelled (e.g. Void → Abyss).
        guard record.guest == original.guest || (record.guest.isLinux && original.guest.isLinux) else {
            throw LibraryError.invalidConfiguration("The operating system cannot be changed after creation.")
        }
        if record.diskGiB < original.diskGiB {
            throw LibraryError.invalidConfiguration("Disks can grow but never shrink; shrinking would corrupt the virtual machine.")
        }
        let policy = resourcePolicy
        guard record.cpuCount <= policy.maxCPUsPerMachine(on: hostResources),
              record.memoryGiB <= policy.guestMemoryBudgetGiB(on: hostResources) else {
            throw LibraryError.invalidConfiguration("Leave at least \(policy.memoryReserveGiB) GiB of memory for your Mac and use no more than \(policy.maxCPUsPerMachine(on: hostResources)) CPUs.")
        }
        guard record.memoryGiB >= record.guest.minimumMemoryGiB else {
            throw LibraryError.invalidConfiguration("Use at least \(record.guest.minimumMemoryGiB) GiB RAM for \(record.guest.title).")
        }
        if let installer = record.installerPath, !FileManager.default.isReadableFile(atPath: installer) {
            throw LibraryError.invalidConfiguration("The selected installer cannot be read. Choose another file or eject it.")
        }
        if record.diskGiB > original.diskGiB {
            try library.growDisk(for: record.id, toGiB: record.diskGiB)
        }
        var updated = record
        updated.macAddress = original.macAddress
        updated.createdAt = original.createdAt
        try library.save(updated)
        guestWindows.removeValue(forKey: record.id)?.close()
        observations.removeValue(forKey: record.id)
        errorObservations.removeValue(forKey: record.id)
        appleEngines.removeValue(forKey: record.id)
        nativeProcesses.removeValue(forKey: record.id)
        qemuEngines.removeValue(forKey: record.id)
        machines[index] = updated
    }

    private func validateMedia(_ record: VirtualMachineRecord) throws {
        if let path = record.windowsDriversPath, !FileManager.default.isReadableFile(atPath: path) {
            throw LibraryError.invalidConfiguration("The Windows driver disc cannot be read. Choose another ISO.")
        }
        if let path = record.installerPath, !record.guest.isMacOS {
            let detected = InstallerDetector.detect(url: URL(fileURLWithPath: path))
            guard detected.architecture != .x86_64 else {
                throw LibraryError.invalidConfiguration("This installer contains an Intel bootloader. Choose ARM64 / AArch64 media.")
            }
            if let guest = detected.guest, (guest == .windows) != (record.guest == .windows) {
                throw LibraryError.invalidConfiguration("This installer is for a different operating system. Choose media for \(record.guest.title).")
            }
        }
    }

    func start(_ record: VirtualMachineRecord, bootInstaller: Bool = false) {
        guard !isDemo else { errorMessage = "This is a visual preview. Open Lumen normally to create and run your own machines."; return }
        selectedID = record.id
        if nativeProcesses[record.id]?.isProcessRunning == true && !state(for: record.id).isActive {
            nativeProcesses[record.id]?.show()
            return
        }
        if state(for: record.id) == .paused { pauseOrResume(record); showDisplay(record); return }
        guard !state(for: record.id).isActive else { showDisplay(record); return }
        guard let library else { return }
        let policy = resourcePolicy
        let activeMemory = activeMemoryGiB
        guard policy.canStart(memoryGiB: record.memoryGiB, alreadyRunningGiB: activeMemory, on: hostResources) else {
            errorMessage = "Starting \(record.name) (\(record.memoryGiB) GiB) would exceed the memory budget for virtual machines. Lumen reserves \(policy.memoryReserveGiB) GiB of RAM so macOS stays completely smooth. Shut down another machine first."
            return
        }
        let location = library.location(for: record.id)
        do { _ = try SparseDisk.usage(at: location.disk) } catch { errorMessage = error.localizedDescription; return }
        if record.guest.usesAppleVirtualization && !isGuestProcess {
            let engine = NativeGuestProcess()
            nativeProcesses[record.id] = engine
            engine.onLibraryAction = { [weak self] action in
                if action == "settings" { self?.requestSettings(for: record) }
                else { self?.showLibrary() }
            }
            observations[record.id] = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            errorObservations[record.id] = engine.$errorMessage.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }
            do { try engine.start(record: record, library: libraryURL, bootInstaller: bootInstaller) }
            catch { errorMessage = error.localizedDescription; nativeProcesses.removeValue(forKey: record.id) }
        } else if record.guest.usesAppleVirtualization {
            do { guestLease = try GuestRuntimeLease(directory: location.directory) }
            catch {
                errorMessage = error.localizedDescription
                guestBridge?.status(GuestProcessStatus(state: .failed, progress: 0, error: error.localizedDescription))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                return
            }
            guestRuntimeStarted = true
            refreshGuestDockIcon()
            let engine = AppleVirtualMachine(record: record, location: location)
            appleEngines[record.id] = engine
            observations[record.id] = engine.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
                Task { @MainActor [weak self] in self?.publishGuestProcessStatus() }
            }
            errorObservations[record.id] = engine.$errorMessage.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }
            pending.insert(record.id)
            publishGuestProcessStatus()
            showDisplay(record)
            objectWillChange.send()
            Task {
                defer { pending.remove(record.id); objectWillChange.send(); refreshUsage(); publishGuestProcessStatus() }
                do {
                    pending.remove(record.id)
                    let isInstalled = ((try? SparseDisk.usage(at: location.disk).allocatedBytes) ?? 0) > 2_000_000_000 || FileManager.default.fileExists(atPath: location.installedMarker.path)
                    if record.guest.isMacOS && !FileManager.default.fileExists(atPath: location.installedMarker.path) {
                        guard let installer = record.installerPath else {
                            throw LibraryError.invalidConfiguration("This Mac needs an IPSW restore image before its first start.")
                        }
                        try await engine.installMacOS(restoreImageURL: URL(fileURLWithPath: installer))
                    } else {
                        let shouldBootInstaller = bootInstaller || (!isInstalled && !record.guest.isMacOS && record.installerPath != nil)
                        try await engine.start(bootInstaller: shouldBootInstaller)
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        } else if record.guest == .windows {
            let engine = QEMUVirtualMachine(record: record, location: location)
            engine.onFilesDrop = { [weak self] urls in self?.sendFiles(record, sources: urls) }
            engine.onLibraryAction = { [weak self] action in
                guard let self else { return }
                switch action {
                case "settings": self.requestSettings(for: record)
                case "enable-retina": self.enableWindowsRetinaDisplay(record)
                case "automatic-retina": self.enableWindowsRetinaDisplay(record, automatic: true)
                case "start-all": self.startAll()
                case "stop-all": self.stopAll()
                default: self.showLibrary()
                }
            }
            qemuEngines[record.id] = engine
            observations[record.id] = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            errorObservations[record.id] = engine.$errorMessage.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }
            let isInstalled = ((try? SparseDisk.usage(at: location.disk).allocatedBytes) ?? 0) > 2_000_000_000 || FileManager.default.fileExists(atPath: location.installedMarker.path)
            let shouldBootInstaller = bootInstaller || (!isInstalled && record.installerPath != nil)
            pending.insert(record.id)
            Task {
                defer { pending.remove(record.id); objectWillChange.send(); refreshUsage() }
                do { try await engine.start(bootInstaller: shouldBootInstaller) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func startAll() {
        let stopped = machines.filter { !state(for: $0.id).isActive }
        var currentActive = activeMemoryGiB
        let policy = resourcePolicy
        var skipped: [String] = []
        for machine in stopped {
            if policy.canStart(memoryGiB: machine.memoryGiB, alreadyRunningGiB: currentActive, on: hostResources) {
                currentActive += machine.memoryGiB
                start(machine)
            } else {
                skipped.append(machine.name)
            }
        }
        if !skipped.isEmpty {
            errorMessage = "The memory budget left these machines stopped: \(skipped.joined(separator: ", ")). Shut down another machine or reduce their RAM, then start them again."
        }
    }

    func startAutomaticallyIfEnabled() {
        if isGuestProcess {
            if let record = machines.first, record.guest.usesAppleVirtualization {
                start(record, bootInstaller: CommandLine.arguments.contains("--boot-installer"))
            } else {
                guestBridge?.status(GuestProcessStatus(state: .failed, progress: 0, error: errorMessage ?? "The native guest configuration is unavailable."))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
            return
        }
        guard !isDemo,
              !["--smoke-test", "--boot-test", "--windows-boot-test", "--snapshot"].contains(where: CommandLine.arguments.contains),
              (UserDefaults.standard.object(forKey: "autoStartMachines") == nil || UserDefaults.standard.bool(forKey: "autoStartMachines")) else { return }
        startAll()
    }

    func showLibrary() {
        if isGuestProcess { guestBridge?.library("library"); return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Lumen" })?.makeKeyAndOrderFront(nil)
    }

    func requestSettings(for record: VirtualMachineRecord) {
        if isGuestProcess { guestBridge?.library("settings"); return }
        selectedID = record.id
        showLibrary()
        NotificationCenter.default.post(name: .machineSettingsRequested, object: record.id)
    }

    func installWindowsDrivers(_ record: VirtualMachineRecord) {
        guard let engine = qemuEngines[record.id] else { errorMessage = "Start Windows and log in before installing drivers."; return }
        Task {
            do { try await engine.installWindowsDrivers() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func installLinuxTools(_ record: VirtualMachineRecord) {
        if let process = nativeProcesses[record.id] {
            process.show()
            do { try process.send(.installTools) } catch { errorMessage = error.localizedDescription }
            return
        }
        guard record.guest.usesAppleVirtualization, !record.guest.isMacOS else { return }
        let alert = NSAlert()
        alert.messageText = "Install Linux guest tools"
        alert.informativeText = "Start this VM using the updated Lumen app and open Terminal inside Linux first. Type in Guest Terminal sends this command and presses Enter; it requires a US guest keyboard layout. The installer uses your Linux repositories and asks for your Linux administrator password. It starts clipboard services and the desktop agent, and mounts folders selected in this VM’s settings at /mnt/lumen. Its log is /var/log/lumen-guest-tools.log."
        let field = NSTextField(wrappingLabelWithString: LinuxGuestTools.installCommand)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 520, height: 90)
        alert.accessoryView = field
        alert.addButton(withTitle: "Type in Guest Terminal")
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            guard appleEngines[record.id]?.state == .running, let window = guestWindows[record.id] else {
                errorMessage = "Start the Linux VM and open its Terminal before installing guest tools."
                return
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task {
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    guard let view = guestDisplay(in: window.contentView), window.makeFirstResponder(view) else {
                        throw LibraryError.invalidConfiguration("Select the Linux Terminal and try installing guest tools again.")
                    }
                    try await typeIntoWindow(window, text: LinuxGuestTools.installCommand)
                } catch { errorMessage = error.localizedDescription }
            }
        } else if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(LinuxGuestTools.installCommand, forType: .string)
            showDisplay(record)
        }
    }

    func sendFiles(_ record: VirtualMachineRecord, sources: [URL]? = nil) {
        let destinations = SharedFolder.named(record.sharedFolders).filter { !$0.folder.readOnly }
        guard !destinations.isEmpty else {
            errorMessage = "Select a writable shared folder in this VM’s settings and restart it before sending files."
            return
        }
        var urls = sources ?? []
        if sources == nil {
            let panel = NSOpenPanel()
            panel.title = "Send files to \(record.name)’s shared folder"
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            guard panel.runModal() == .OK else { return }
            urls = panel.urls
        }
        let alert = NSAlert()
        alert.messageText = "Send \(urls.count) items to a shared folder?"
        let items = urls.prefix(5).map(\.path).joined(separator: "\n") + (urls.count > 5 ? "\n…" : "")
        alert.informativeText = "The files will appear in the guest’s shared folder. Existing files are never overwritten. Open /mnt/lumen in Linux or \\\\10.0.2.4 in Windows after connecting shared folders.\n\n\(items)"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        picker.addItems(withTitles: destinations.map(\.name))
        alert.accessoryView = picker
        alert.addButton(withTitle: "Send Files")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let folder = destinations[picker.indexOfSelectedItem].folder
        Task {
            do {
                _ = try await Task.detached {
                    let accesses = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
                    defer { for (url, active) in accesses where active { url.stopAccessingSecurityScopedResource() } }
                    return try SharedFileTransfer.copy(urls, to: folder)
                }.value
                NSWorkspace.shared.open(URL(fileURLWithPath: folder.path))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func connectWindowsFolders(_ record: VirtualMachineRecord) {
        guard let engine = qemuEngines[record.id] else { errorMessage = "Start Windows and log in before connecting shared folders."; return }
        Task {
            do { try await engine.connectSharedFolders() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func enableWindowsRetinaDisplay(_ record: VirtualMachineRecord, automatic: Bool = false) {
        guard record.guest == .windows, (record.windowsCompatibilityDisplay || record.windowsAutomaticDisplaySetup),
              !pending.contains(record.id) else { return }
        if !automatic {
            showLibrary()
            let alert = NSAlert()
            alert.messageText = "Enable Retina display for \(record.name)?"
            alert.informativeText = "First finish Install / Repair Windows Drivers in Windows, including its administrator prompt. Save your work. Lumen will shut down Windows normally, switch from the fixed compatibility screen to VirtIO graphics, and start Windows again. If the driver is missing, enable Compatibility display in Settings to recover."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Shut Down & Enable Retina")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let engine = qemuEngines[record.id]
        pending.insert(record.id)
        Task {
            var ownsPending = true
            defer { if ownsPending { pending.remove(record.id) }; objectWillChange.send() }
            do {
                if let engine, engine.isProcessRunning {
                    guard engine.state == .running else {
                        throw LibraryError.invalidConfiguration("Resume Windows before switching its display.")
                    }
                    try engine.requestStop()
                    let deadline = Date().addingTimeInterval(90)
                    while engine.isProcessRunning {
                        guard Date() < deadline else {
                            throw LibraryError.invalidConfiguration("Windows has not shut down. Save or close its open apps and try again. Its display settings were retained.")
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard engine.state == .stopped else {
                        throw LibraryError.invalidConfiguration("Windows did not shut down cleanly. Its display settings were retained.")
                    }
                }
                guard var updated = machines.first(where: { $0.id == record.id }) else { throw LibraryError.missingMachine }
                updated.windowsCompatibilityDisplay = false
                updated.windowsAutomaticDisplaySetup = false
                pending.remove(record.id)
                ownsPending = false
                try update(record: updated)
                start(updated)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stopAll() {
        for machine in machines where state(for: machine.id).isActive {
            stop(machine)
        }
    }

    func pauseOrResume(_ record: VirtualMachineRecord) {
        if let process = nativeProcesses[record.id] {
            do { try process.send(process.state == .paused ? .resume : .pause) }
            catch { errorMessage = error.localizedDescription }
        } else if let engine = appleEngines[record.id] {
            Task {
                do {
                    if engine.state == .paused { try await engine.resume() }
                    else if engine.state == .running { try await engine.pause() }
                } catch { errorMessage = error.localizedDescription }
            }
        } else if let engine = qemuEngines[record.id] {
            do {
                if engine.state == .paused { try engine.resume() }
                else if engine.state == .running { try engine.pause() }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stop(_ record: VirtualMachineRecord) {
        do {
            if let process = nativeProcesses[record.id] { try process.send(.shutdown) }
            else if let engine = appleEngines[record.id] { try engine.requestStop() }
            else if let engine = qemuEngines[record.id] { try engine.requestStop() }
        } catch { errorMessage = error.localizedDescription }
    }

    func forceStop(_ record: VirtualMachineRecord) {
        if let process = nativeProcesses[record.id] {
            do { try process.send(.forceStop) } catch { errorMessage = error.localizedDescription }
        } else if let engine = appleEngines[record.id] {
            Task { do { try await engine.forceStop() } catch { errorMessage = error.localizedDescription } }
        } else if let engine = qemuEngines[record.id] {
            do { try engine.forceStop() } catch { errorMessage = error.localizedDescription }
        }
    }

    func showDisplay(_ record: VirtualMachineRecord) {
        selectedID = record.id
        if let process = nativeProcesses[record.id] { process.show(); return }
        if let qemu = qemuEngines[record.id] { qemu.showDisplay(); return }
        guard let engine = appleEngines[record.id] else { return }
        let guestIcon = GuestIconGenerator.icon(for: record.guest)
        if let window = guestWindows[record.id] {
            window.contentView = NSHostingView(rootView: GuestWindowView(engine: engine, record: record).environmentObject(self))
            window.miniwindowImage = guestIcon
            window.miniwindowTitle = record.name
            window.standardWindowButton(.documentIconButton)?.image = guestIcon
            window.standardWindowButton(.documentIconButton)?.isHidden = false
            window.makeKeyAndOrderFront(nil)
            return
        }
        let targetAspect = Double(record.displayWidth) / Double(max(1, record.displayHeight))
        let initialWidth: CGFloat = min(1600, max(1024, CGFloat(record.displayWidth) * 0.75))
        let initialHeight: CGFloat = initialWidth / CGFloat(targetAspect)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(record.name) — \(record.operatingSystemName)"
        window.representedURL = library?.location(for: record.id).directory
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = "Lumen.Guest.\(record.id.uuidString)"
        window.standardWindowButton(.documentIconButton)?.image = guestIcon
        window.standardWindowButton(.documentIconButton)?.isHidden = false
        window.minSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.miniwindowImage = guestIcon
        window.miniwindowTitle = record.name
        window.contentView = NSHostingView(rootView: GuestWindowView(engine: engine, record: record).environmentObject(self))
        window.center()
        guestWindows[record.id] = window
        window.makeKeyAndOrderFront(nil)

        let recordID = record.id
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectedID = recordID }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.guestWindows.removeValue(forKey: recordID)
            }
        }
    }

    func reveal(_ record: VirtualMachineRecord) {
        guard let library else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.location(for: record.id).directory])
    }

    func remove(_ record: VirtualMachineRecord, permanently: Bool = false) throws {
        guard !state(for: record.id).isActive, qemuEngines[record.id]?.isProcessRunning != true, nativeProcesses[record.id]?.isProcessRunning != true else {
            throw LibraryError.invalidConfiguration("Shut down this machine before deleting it.")
        }
        guard let library else { throw LibraryError.missingMachine }
        guard machines.contains(where: { $0.id == record.id }) else { throw LibraryError.missingMachine }
        let directory = library.location(for: record.id).directory
        if permanently {
            try library.deletePermanently(record.id)
        } else {
            let lease = try GuestRuntimeLease(directory: directory)
            defer { withExtendedLifetime(lease) {} }
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
        TouchIDService.shared.deletePassword(for: record.id)
        guestWindows.removeValue(forKey: record.id)?.close()
        observations.removeValue(forKey: record.id)
        errorObservations.removeValue(forKey: record.id)
        appleEngines.removeValue(forKey: record.id)
        nativeProcesses.removeValue(forKey: record.id)
        qemuEngines.removeValue(forKey: record.id)
        machines.removeAll { $0.id == record.id }
        if selectedID == record.id { selectedID = nil }
        refreshUsage()
    }

    func ejectInstaller(_ record: VirtualMachineRecord) throws {
        guard !state(for: record.id).isActive else { throw LibraryError.invalidConfiguration("Shut down the machine before ejecting its installer.") }
        guard let library, let index = machines.firstIndex(where: { $0.id == record.id }) else { throw LibraryError.missingMachine }
        if record.guest.isMacOS && !FileManager.default.fileExists(atPath: library.location(for: record.id).installedMarker.path) {
            throw LibraryError.invalidConfiguration("Finish installing macOS before removing its restore image reference.")
        }
        var updated = record
        updated.installerPath = nil
        try library.save(updated)
        machines[index] = updated
        observations.removeValue(forKey: record.id)
        errorObservations.removeValue(forKey: record.id)
        appleEngines.removeValue(forKey: record.id)
        nativeProcesses.removeValue(forKey: record.id)
        qemuEngines.removeValue(forKey: record.id)
    }

    private func refreshUsage() {
        guard let library else { return }
        usage = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, (try? SparseDisk.usage(at: library.location(for: $0.id).disk).allocatedBytes) ?? 0) })
        objectWillChange.send()
    }

    // MARK: - Sleep / Wake Observers

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.handleSystemWillSleep() }
            .store(in: &sleepWakeCancellables)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.handleSystemDidWake() }
            .store(in: &sleepWakeCancellables)
    }

    private func handleSystemWillSleep() {
        var running: Set<UUID> = []
        for machine in machines {
            if state(for: machine.id) == .running {
                running.insert(machine.id)
                if let apple = appleEngines[machine.id] {
                    Task { do { try await apple.pause() } catch {} }
                } else if let qemu = qemuEngines[machine.id] {
                    try? qemu.pause()
                }
            }
        }
        sleepingMachineIDs = running
    }

    private func handleSystemDidWake() {
        guard !sleepingMachineIDs.isEmpty else { return }
        let toResume = sleepingMachineIDs
        sleepingMachineIDs.removeAll()
        // Wait 800ms for host GPU, audio, and network devices to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            for id in toResume {
                if let apple = self.appleEngines[id], apple.state == .paused {
                    Task { do { try await apple.resume() } catch {} }
                } else if let qemu = self.qemuEngines[id], qemu.state == .paused {
                    try? qemu.resume()
                }
            }
        }
    }

    private func handleGuestProcessCommand(_ command: GuestProcessCommand) {
        guard isGuestProcess, let record = machines.first else { return }
        switch command {
        case .show: showDisplay(record)
        case .pause: if state(for: record.id) == .running { pauseOrResume(record) }
        case .resume: if state(for: record.id) == .paused { pauseOrResume(record) }
        case .shutdown: closeGuestApplication()
        case .forceStop: forceStop(record)
        case .installTools: installLinuxTools(record)
        case .unlock: Task { await unlockWithTouchID(record) }
        case .refresh: publishGuestProcessStatus()
        }
    }

    func refreshGuestDockIcon() {
        guard isGuestProcess, let record = machines.first else { return }
        ProcessInfo.processInfo.processName = record.name
        let icon = GuestIconGenerator.icon(for: record.guest)
        NSApp.applicationIconImage = icon
        // Give this process its own tile content even when Launch Services has
        // cached the shared app bundle's library icon.
        let view = NSImageView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
        view.image = icon
        view.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = view
        NSApp.dockTile.display()
    }

    private func publishGuestProcessStatus() {
        guard isGuestProcess, let record = machines.first else { return }
        let state = state(for: record.id)
        guestBridge?.status(GuestProcessStatus(state: state, progress: progress(for: record.id), error: appleEngines[record.id]?.errorMessage ?? errorMessage))
        if guestRuntimeStarted && !state.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard self?.hasActiveMachines == false else { return }
                NSApp.terminate(nil)
            }
        }
    }

    func closeGuestApplication() {
        guard isGuestProcess, let record = machines.first, let engine = appleEngines[record.id] else { return }
        Task {
            do {
                if engine.state == .paused { try await engine.resume() }
                try engine.requestStop()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Touch ID Biometric VM Login

    func hasTouchIDPassword(for record: VirtualMachineRecord) -> Bool {
        TouchIDService.shared.hasSavedPassword(for: record.id)
    }

    func saveTouchIDPassword(_ password: String, for record: VirtualMachineRecord) throws {
        guard GuestKeyboard.supports(password) else {
            throw LibraryError.invalidConfiguration("Automatic password typing supports printable ASCII passwords and requires a US keyboard layout in the guest.")
        }
        try TouchIDService.shared.savePassword(password, for: record.id)
        objectWillChange.send()
    }

    func deleteTouchIDPassword(for record: VirtualMachineRecord) {
        TouchIDService.shared.deletePassword(for: record.id)
        objectWillChange.send()
    }

    func unlockWithTouchID(_ record: VirtualMachineRecord) async {
        if let process = nativeProcesses[record.id] {
            process.show()
            do { try process.send(.unlock) } catch { errorMessage = error.localizedDescription }
            return
        }
        do {
            let password = try await TouchIDService.shared.authenticateAndRetrievePassword(for: record.id, machineName: record.name)
            guard GuestKeyboard.supports(password) else {
                throw LibraryError.invalidConfiguration("This password cannot be typed with the guest's supported US key mapping. Enter it directly in the guest.")
            }
            if let qemu = qemuEngines[record.id], qemu.state == .running {
                try await qemu.typePassword(password)
            } else if let engine = appleEngines[record.id], engine.state == .running, let window = guestWindows[record.id] {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(nanoseconds: 120_000_000)
                guard window.attachedSheet == nil, let view = guestDisplay(in: window.contentView),
                      window.makeFirstResponder(view) else {
                    throw LibraryError.invalidConfiguration("Close the password settings sheet, select the guest password field, and try Unlock again.")
                }
                try await typeIntoWindow(window, text: password)
            } else {
                errorMessage = "\(record.name) is not currently running."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func guestDisplay(in view: NSView?) -> VZVirtualMachineView? {
        if let display = view as? VZVirtualMachineView { return display }
        return view?.subviews.lazy.compactMap { self.guestDisplay(in: $0) }.first
    }

    private func typeIntoWindow(_ window: NSWindow, text: String) async throws {
        guard GuestKeyboard.supports(text) else {
            throw LibraryError.invalidConfiguration("This text cannot be entered using the guest's US keyboard layout.")
        }
        for char in text {
            try Task.checkCancellation()
            guard window.isKeyWindow, window.firstResponder is VZVirtualMachineView, window.attachedSheet == nil else {
                throw LibraryError.invalidConfiguration("Typing stopped because the guest display lost focus.")
            }
            sendCharacterToWindow(window, char: char)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard window.isKeyWindow, window.firstResponder is VZVirtualMachineView, window.attachedSheet == nil else {
            throw LibraryError.invalidConfiguration("The guest display lost focus before the typed command was submitted.")
        }
        sendKeyCodeToWindow(window, keyCode: 36, characters: "\r")
    }

    private func sendCharacterToWindow(_ window: NSWindow, char: Character) {
        let (keyCode, shift) = GuestKeyboard.key(for: char)
        let flags: NSEvent.ModifierFlags = shift ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2) : []
        let str = String(char)
        // VZVirtualMachineView forwards physical keys. modifierFlags on keyDown
        // alone do not press Shift in the guest ("&" would arrive as "7").
        // VZ also requires NX_DEVICELSHIFTKEYMASK (0x2) on the modifier event.
        if shift { sendShiftToWindow(window, pressed: true) }
        defer { if shift { sendShiftToWindow(window, pressed: false) } }
        if let down = NSEvent.keyEvent(with: .keyDown,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber,
                                      context: nil,
                                      characters: str,
                                      charactersIgnoringModifiers: str,
                                      isARepeat: false,
                                      keyCode: keyCode) {
            window.sendEvent(down)
        }
        if let up = NSEvent.keyEvent(with: .keyUp,
                                    location: .zero,
                                    modifierFlags: flags,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber,
                                    context: nil,
                                    characters: str,
                                    charactersIgnoringModifiers: str,
                                    isARepeat: false,
                                    keyCode: keyCode) {
            window.sendEvent(up)
        }
    }

    private func sendShiftToWindow(_ window: NSWindow, pressed: Bool) {
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                       modifierFlags: pressed ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2) : [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: 56) {
            window.sendEvent(event)
        }
    }

    private func sendKeyCodeToWindow(_ window: NSWindow, keyCode: UInt16, characters: String) {
        if let down = NSEvent.keyEvent(with: .keyDown,
                                      location: .zero,
                                      modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber,
                                      context: nil,
                                      characters: characters,
                                      charactersIgnoringModifiers: characters,
                                      isARepeat: false,
                                      keyCode: keyCode) {
            window.sendEvent(down)
        }
        if let up = NSEvent.keyEvent(with: .keyUp,
                                    location: .zero,
                                    modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber,
                                    context: nil,
                                    characters: characters,
                                    charactersIgnoringModifiers: characters,
                                    isARepeat: false,
                                    keyCode: keyCode) {
            window.sendEvent(up)
        }
    }


}

private struct MouseTopEdgeTracker: NSViewRepresentable {
    var onHoverTop: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverTop = onHoverTop
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHoverTop = onHoverTop
    }

    class TrackingView: NSView {
        var onHoverTop: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?
        private var isNearTop = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Return nil so mouse clicks and drags pass directly to the VM display view!
            return nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingAreaRef { removeTrackingArea(existing) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let nearTop = loc.y >= bounds.height - 48
            if nearTop != isNearTop {
                isNearTop = nearTop
                onHoverTop?(nearTop)
            }
        }

        override func mouseExited(with event: NSEvent) {
            if isNearTop {
                isNearTop = false
                onHoverTop?(false)
            }
        }
    }
}

private struct GuestWindowView: View {
    @ObservedObject var engine: AppleVirtualMachine
    let record: VirtualMachineRecord
    @EnvironmentObject var model: LibraryModel
    @State private var confirmForceStop = false
    @State private var showMountCopied = false
    @State private var showingTouchIDSheet = false
    @State private var showControls = false
    @State private var isHoveringHUD = false
    @State private var isPinned = false
    @State private var hideTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .ignoresSafeArea()

            GuestDisplayView(engine: engine)
                .ignoresSafeArea()
                .guestFilesDrop(enabled: engine.state == .running && record.sharedFolders.contains { !$0.readOnly }) {
                    model.sendFiles(record, sources: $0)
                } failed: { model.errorMessage = $0 }

            if engine.state == .failed || engine.state == .stopped {
                VStack(spacing: 14) {
                    Image(systemName: engine.state == .failed ? "exclamationmark.triangle" : "power")
                        .font(.system(size: 34))
                    Text(engine.errorMessage ?? "This machine is shut down.")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(30)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Top-edge tracking overlay that forwards all clicks directly to the guest
            MouseTopEdgeTracker { nearTop in
                if nearTop {
                    hideTask?.cancel()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showControls = true
                    }
                } else if !isPinned && !isHoveringHUD {
                    scheduleAutoHide()
                }
            }
            .ignoresSafeArea()

            // Floating auto-hiding control HUD
            if showControls || isPinned {
                floatingControlHUD
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 10)
                    .zIndex(100)
            }
        }
        .confirmationDialog("Force stop \(record.name)? Unsaved work in the guest will be lost.", isPresented: $confirmForceStop) {
            Button("Force Stop", role: .destructive) { model.forceStop(record) }
        }
        .sheet(isPresented: $showingTouchIDSheet) {
            TouchIDSheet(machine: record).environmentObject(model)
        }
    }

    private var floatingControlHUD: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(engine.state == .running ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)

            Text(engine.state.title)
                .font(.system(size: 12, weight: .medium))

            if engine.state == .installing {
                ProgressView(value: engine.progress)
                    .frame(width: 120)
                Text(engine.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, design: .monospaced))
            }

            Text("\(record.displayWidth)×\(record.displayHeight)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))

            if record.sharedDirectoryPath != nil, record.guest.isLinux {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo mkdir -p /mnt/lumen && sudo mount -t virtiofs lumen /mnt/lumen", forType: .string)
                    showMountCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showMountCopied = false }
                } label: {
                    Label(showMountCopied ? "Copied!" : "Mount cmd", systemImage: showMountCopied ? "checkmark" : "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copies: sudo mkdir -p /mnt/lumen && sudo mount -t virtiofs lumen /mnt/lumen")
            }

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            if record.installerPath != nil && engine.state == .stopped {
                Button("Eject", systemImage: "eject") {
                    try? model.ejectInstaller(record)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            if engine.state == .running && model.hasTouchIDPassword(for: record) {
                Button {
                    Task { await model.unlockWithTouchID(record) }
                } label: {
                    Label("Touch ID", systemImage: "touchid")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Unlock guest with Touch ID (⌘L)")
                .keyboardShortcut("l", modifiers: .command)
            }

            Button {
                showingTouchIDSheet = true
            } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Configure Touch ID Password")

            Button { model.pauseOrResume(record) } label: {
                Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(engine.state != .running && engine.state != .paused)
            .help(engine.state == .paused ? "Resume" : "Pause")

            Menu {
                Button("Shut Down") { model.stop(record) }.disabled(engine.state != .running)
                Button("Force Stop…", role: .destructive) { confirmForceStop = true }.disabled(engine.state == .installing || !engine.state.isActive)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            // Pin / Unpin HUD button
            Button {
                withAnimation { isPinned.toggle() }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "Unpin controls (auto-hide)" : "Pin controls to stay visible")

            // Toggle Full Screen button
            Button {
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title.contains(record.name) }) {
                    window.toggleFullScreen(nil)
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle Full Screen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
        )
        .onHover { hovering in
            isHoveringHUD = hovering
            if hovering {
                hideTask?.cancel()
            } else if !isPinned {
                scheduleAutoHide()
            }
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, !isHoveringHUD, !isPinned else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = false
            }
        }
    }
}
