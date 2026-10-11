import AppKit
import Combine
import SwiftUI
import LumenCore

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
    private var qemuEngines: [UUID: QEMUVirtualMachine] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private var errorObservations: [UUID: AnyCancellable] = [:]
    private var guestWindows: [UUID: NSWindow] = [:]
    private var pending: Set<UUID> = []
    private var usage: [UUID: Int64] = [:]
    private var usageTimer: AnyCancellable?
    private var sleepingMachineIDs: Set<UUID> = []
    private var sleepWakeCancellables: [AnyCancellable] = []
    let isDemo: Bool

    init() {
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
    }

    var hasActiveMachines: Bool { machines.contains { state(for: $0.id).isActive } }
    var activeMemoryGiB: Int { machines.filter { state(for: $0.id).isActive }.reduce(0) { $0 + $1.memoryGiB } }
    var availableMemoryBudgetGiB: Int { max(0, resourcePolicy.guestMemoryBudgetGiB(on: hostResources) - activeMemoryGiB) }

    func state(for id: UUID) -> VMRuntimeState {
        if pending.contains(id) { return .starting }
        return appleEngines[id]?.state ?? qemuEngines[id]?.state ?? .stopped
    }
    func allocatedBytes(for id: UUID) -> Int64 { usage[id] ?? 0 }
    func progress(for id: UUID) -> Double { appleEngines[id]?.progress ?? 0 }

    func create(_ record: VirtualMachineRecord) throws {
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
        guard !state(for: record.id).isActive else {
            throw LibraryError.invalidConfiguration("Shut down the machine before changing its settings.")
        }
        guard let library, let index = machines.firstIndex(where: { $0.id == record.id }) else { throw LibraryError.missingMachine }
        let original = machines[index]
        guard record.guest == original.guest else {
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
        qemuEngines.removeValue(forKey: record.id)
        machines[index] = updated
    }

    func start(_ record: VirtualMachineRecord, bootInstaller: Bool = false) {
        guard !isDemo else { errorMessage = "This is a visual preview. Open Lumen normally to create and run your own machines."; return }
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
        if record.guest.usesAppleVirtualization {
            let engine = AppleVirtualMachine(record: record, location: location)
            appleEngines[record.id] = engine
            observations[record.id] = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            errorObservations[record.id] = engine.$errorMessage.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }
            pending.insert(record.id)
            showDisplay(record)
            objectWillChange.send()
            Task {
                defer { pending.remove(record.id); objectWillChange.send(); refreshUsage() }
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
            qemuEngines[record.id] = engine
            observations[record.id] = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            errorObservations[record.id] = engine.$errorMessage.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }
            let isInstalled = ((try? SparseDisk.usage(at: location.disk).allocatedBytes) ?? 0) > 2_000_000_000 || FileManager.default.fileExists(atPath: location.installedMarker.path)
            let shouldBootInstaller = bootInstaller || (!isInstalled && record.installerPath != nil)
            do { try engine.start(bootInstaller: shouldBootInstaller) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func startAll() {
        let stopped = machines.filter { !state(for: $0.id).isActive }
        var currentActive = activeMemoryGiB
        let policy = resourcePolicy
        for machine in stopped {
            if policy.canStart(memoryGiB: machine.memoryGiB, alreadyRunningGiB: currentActive, on: hostResources) {
                currentActive += machine.memoryGiB
                start(machine)
            }
        }
    }

    func stopAll() {
        for machine in machines where state(for: machine.id).isActive {
            stop(machine)
        }
    }

    func pauseOrResume(_ record: VirtualMachineRecord) {
        if let engine = appleEngines[record.id] {
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
            if let engine = appleEngines[record.id] { try engine.requestStop() }
            else if let engine = qemuEngines[record.id] { try engine.requestStop() }
        } catch { errorMessage = error.localizedDescription }
    }

    func forceStop(_ record: VirtualMachineRecord) {
        if let engine = appleEngines[record.id] {
            Task { do { try await engine.forceStop() } catch { errorMessage = error.localizedDescription } }
        } else if let engine = qemuEngines[record.id] {
            do { try engine.forceStop() } catch { errorMessage = error.localizedDescription }
        }
    }

    func showDisplay(_ record: VirtualMachineRecord) {
        guard let engine = appleEngines[record.id] else { return }
        if let window = guestWindows[record.id] {
            window.contentView = NSHostingView(rootView: GuestWindowView(engine: engine, record: record).environmentObject(self))
            window.makeKeyAndOrderFront(nil)
            return
        }
        let targetAspect = Double(record.displayWidth) / Double(max(1, record.displayHeight))
        let initialWidth: CGFloat = min(1600, max(1024, CGFloat(record.displayWidth) * 0.75))
        let initialHeight: CGFloat = initialWidth / CGFloat(targetAspect)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(record.name) — \(record.operatingSystemName)"
        window.minSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: GuestWindowView(engine: engine, record: record).environmentObject(self))
        window.center()
        guestWindows[record.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    func reveal(_ record: VirtualMachineRecord) {
        guard let library else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.location(for: record.id).directory])
    }

    func remove(_ record: VirtualMachineRecord) throws {
        guard !state(for: record.id).isActive else { throw LibraryError.invalidConfiguration("Shut down this machine before moving it to the Trash.") }
        guard let library else { throw LibraryError.missingMachine }
        try FileManager.default.trashItem(at: library.location(for: record.id).directory, resultingItemURL: nil)
        guestWindows.removeValue(forKey: record.id)?.close()
        observations.removeValue(forKey: record.id)
        errorObservations.removeValue(forKey: record.id)
        appleEngines.removeValue(forKey: record.id)
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

    // MARK: - Touch ID Biometric VM Login

    func hasTouchIDPassword(for record: VirtualMachineRecord) -> Bool {
        TouchIDService.shared.hasSavedPassword(for: record.id)
    }

    func saveTouchIDPassword(_ password: String, for record: VirtualMachineRecord) throws {
        try TouchIDService.shared.savePassword(password, for: record.id)
        objectWillChange.send()
    }

    func deleteTouchIDPassword(for record: VirtualMachineRecord) {
        TouchIDService.shared.deletePassword(for: record.id)
        objectWillChange.send()
    }

    func unlockWithTouchID(_ record: VirtualMachineRecord) async {
        do {
            let password = try await TouchIDService.shared.authenticateAndRetrievePassword(for: record.id, machineName: record.name)
            if let qemu = qemuEngines[record.id], qemu.state == .running {
                try await qemu.typePassword(password)
            } else if let engine = appleEngines[record.id], engine.state == .running, let window = guestWindows[record.id] {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(nanoseconds: 120_000_000)
                await typeIntoWindow(window, text: password)
            } else {
                errorMessage = "\(record.name) is not currently running."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func typeIntoWindow(_ window: NSWindow, text: String) async {
        for char in text {
            sendCharacterToWindow(window, char: char)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        sendKeyCodeToWindow(window, keyCode: 36, characters: "\r")
    }

    private func sendCharacterToWindow(_ window: NSWindow, char: Character) {
        let (keyCode, shift) = keyCodeForChar(char)
        let flags: NSEvent.ModifierFlags = shift ? .shift : []
        let str = String(char)
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

    private func keyCodeForChar(_ char: Character) -> (keyCode: UInt16, shift: Bool) {
        switch char {
        case "a": return (0, false); case "A": return (0, true)
        case "s": return (1, false); case "S": return (1, true)
        case "d": return (2, false); case "D": return (2, true)
        case "f": return (3, false); case "F": return (3, true)
        case "h": return (4, false); case "H": return (4, true)
        case "g": return (5, false); case "G": return (5, true)
        case "z": return (6, false); case "Z": return (6, true)
        case "x": return (7, false); case "X": return (7, true)
        case "c": return (8, false); case "C": return (8, true)
        case "v": return (9, false); case "V": return (9, true)
        case "b": return (11, false); case "B": return (11, true)
        case "q": return (12, false); case "Q": return (12, true)
        case "w": return (13, false); case "W": return (13, true)
        case "e": return (14, false); case "E": return (14, true)
        case "r": return (15, false); case "R": return (15, true)
        case "y": return (16, false); case "Y": return (16, true)
        case "t": return (17, false); case "T": return (17, true)
        case "1": return (18, false); case "!": return (18, true)
        case "2": return (19, false); case "@": return (19, true)
        case "3": return (20, false); case "#": return (20, true)
        case "4": return (21, false); case "$": return (21, true)
        case "6": return (22, false); case "^": return (22, true)
        case "5": return (23, false); case "%": return (23, true)
        case "=": return (24, false); case "+": return (24, true)
        case "9": return (25, false); case "(": return (25, true)
        case "7": return (26, false); case "&": return (26, true)
        case "-": return (27, false); case "_": return (27, true)
        case "8": return (28, false); case "*": return (28, true)
        case "0": return (29, false); case ")": return (29, true)
        case "]": return (30, false); case "}": return (30, true)
        case "o": return (31, false); case "O": return (31, true)
        case "u": return (32, false); case "U": return (32, true)
        case "[": return (33, false); case "{": return (33, true)
        case "i": return (34, false); case "I": return (34, true)
        case "p": return (35, false); case "P": return (35, true)
        case "l": return (37, false); case "L": return (37, true)
        case "j": return (38, false); case "J": return (38, true)
        case "'": return (39, false); case "\"": return (39, true)
        case "k": return (40, false); case "K": return (40, true)
        case ";": return (41, false); case ":": return (41, true)
        case "\\": return (42, false); case "|": return (42, true)
        case ",": return (43, false); case "<": return (43, true)
        case "/": return (44, false); case "?": return (44, true)
        case "n": return (45, false); case "N": return (45, true)
        case "m": return (46, false); case "M": return (46, true)
        case ".": return (47, false); case ">": return (47, true)
        case "`": return (50, false); case "~": return (50, true)
        case " ": return (49, false)
        case "\t": return (48, false)
        case "\n", "\r": return (36, false)
        default: return (0, false)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Circle().fill(engine.state == .running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(engine.state.title).font(.callout)
                if engine.state == .installing {
                    ProgressView(value: engine.progress).frame(width: 160)
                    Text(engine.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }

                Text("\(record.displayWidth)×\(record.displayHeight)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.06)))

                if record.sharedDirectoryPath != nil, record.guest.isLinux {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("sudo mkdir -p /mnt/lumen && sudo mount -t virtiofs lumen /mnt/lumen", forType: .string)
                        showMountCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showMountCopied = false }
                    } label: {
                        Label(showMountCopied ? "Command copied!" : "Copy mount cmd", systemImage: showMountCopied ? "checkmark" : "folder")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Copies: sudo mkdir -p /mnt/lumen && sudo mount -t virtiofs lumen /mnt/lumen")
                }

                Spacer()

                if record.installerPath != nil && engine.state == .stopped {
                    Button("Eject installer", systemImage: "eject") {
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
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Unlock guest with Touch ID (⌘L)")
                    .keyboardShortcut("l", modifiers: .command)
                }

                Button {
                    showingTouchIDSheet = true
                } label: {
                    Image(systemName: "key.fill")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Configure Touch ID Password")

                Button { model.pauseOrResume(record) } label: { Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill") }
                    .disabled(engine.state != .running && engine.state != .paused)
                    .help(engine.state == .paused ? "Resume" : "Pause")

                Menu {
                    Button("Shut Down") { model.stop(record) }.disabled(engine.state != .running)
                    Button("Force Stop…", role: .destructive) { confirmForceStop = true }.disabled(engine.state == .installing || !engine.state.isActive)
                } label: { Image(systemName: "power") }.menuStyle(.borderlessButton).frame(width: 28)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)

            ZStack {
                Color.black
                GuestDisplayView(engine: engine)
                if engine.state == .failed || engine.state == .stopped {
                    VStack(spacing: 14) {
                        Image(systemName: engine.state == .failed ? "exclamationmark.triangle" : "power").font(.system(size: 34))
                        Text(engine.errorMessage ?? "This machine is shut down.").multilineTextAlignment(.center).frame(maxWidth: 480)
                    }.foregroundStyle(.white.opacity(0.8)).padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .confirmationDialog("Force stop \(record.name)? Unsaved work in the guest will be lost.", isPresented: $confirmForceStop) {
            Button("Force Stop", role: .destructive) { model.forceStop(record) }
        }
        .sheet(isPresented: $showingTouchIDSheet) {
            TouchIDSheet(machine: record).environmentObject(model)
        }
    }
}
