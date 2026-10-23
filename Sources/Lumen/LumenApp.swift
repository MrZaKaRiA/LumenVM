import AppKit
import SwiftUI
import Virtualization
import LumenCore

@main
@MainActor
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenDelegate.self) private var delegate
    @StateObject private var model = LibraryModel()
    @AppStorage("autoStartMachines") private var autoStartMachines = true
    var body: some Scene {
        WindowGroup("Lumen", id: "library") {
            if model.isGuestProcess {
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear {
                        delegate.attach(model)
                        DispatchQueue.main.async {
                            if let bootstrap = NSApp.windows.first(where: { $0.title == "Lumen" }) {
                                bootstrap.isExcludedFromWindowsMenu = true
                                bootstrap.orderOut(nil)
                            }
                        }
                    }
            } else {
                LibraryView()
                    .environmentObject(model)
                    .frame(minWidth: 860, minHeight: 620)
                    .background(WindowChrome())
                    .preferredColorScheme(.dark)
                    .onAppear { delegate.attach(model) }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: model.isGuestProcess ? 1 : 1060, height: model.isGuestProcess ? 1 : 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                if model.isGuestProcess {
                    Button("Open Lumen Library") { model.showLibrary() }.keyboardShortcut("l")
                } else {
                    Button("New Virtual Machine…") { NotificationCenter.default.post(name: .newMachineRequested, object: nil) }
                        .keyboardShortcut("n")
                }
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste into Linux Terminal") {
                    NSApp.sendAction(#selector(GuestVirtualMachineView.pasteInGuestTerminal(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.focusedGuestClipboardView == nil)
                Toggle("Use Terminal Copy/Paste Shortcuts", isOn: Binding(
                    get: { model.focusedGuestClipboardView?.terminalShortcuts ?? false },
                    set: { model.focusedGuestClipboardView?.terminalShortcuts = $0 }
                ))
                .disabled(model.focusedGuestClipboardView == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("Show Machine Library in Finder") {
                    NSWorkspace.shared.open(model.libraryURL)
                }
            }
            CommandMenu("Virtual Machine") {
                if let machine = model.machines.first(where: { $0.id == model.selectedID }) {
                    Button("Start / Show Display") { model.start(machine) }
                    Button(model.state(for: machine.id) == .paused ? "Resume" : "Pause") { model.pauseOrResume(machine) }
                        .disabled(![.running, .paused].contains(model.state(for: machine.id)))
                    Button("Shut Down") { model.stop(machine) }
                        .disabled(![.running, .paused].contains(model.state(for: machine.id)))
                    Button("Settings…") { model.requestSettings(for: machine) }
                    if machine.guest == .windows {
                        Button("Connect / Open Shared Folders…") { model.connectWindowsFolders(machine) }
                            .disabled(model.state(for: machine.id) != .running || machine.sharedFolders.isEmpty)
                        Button("Install / Repair Guest Tools…") { model.installWindowsDrivers(machine) }
                            .disabled(model.state(for: machine.id) != .running)
                        if machine.windowsCompatibilityDisplay {
                            Button("Enable Retina Display After Installing Drivers…") { model.enableWindowsRetinaDisplay(machine) }
                                .disabled(model.state(for: machine.id).isActive && model.state(for: machine.id) != .running)
                        }
                    }
                    Button("Show Machine in Finder") { model.reveal(machine) }
                    if !model.isGuestProcess {
                        Button("Storage & Reclamation…") { model.showStorageInformation(machine) }
                        if model.reclaimingID == machine.id {
                            Button("Cancel Disk Reclamation") { model.cancelDiskReclamation() }
                        } else {
                            Button("Reclaim Disk Space…") { model.requestDiskReclamation(machine) }
                                .disabled(!model.canReclaimDisk(machine))
                        }
                    }
                    if machine.guest.usesAppleVirtualization && !machine.guest.isMacOS {
                        Button("Install / Repair Linux Guest Tools…") { model.installLinuxTools(machine) }
                            .disabled(model.state(for: machine.id) != .running)
                    }
                    Button("Send Files to Shared Folder…") { model.sendFiles(machine) }
                        .disabled(!machine.sharedFolders.contains { !$0.readOnly })
                    Divider()
                }
                if !model.isGuestProcess {
                    Button("Start All Machines") { model.startAll() }.disabled(model.machines.isEmpty)
                    Button("Shut Down All Machines") { model.stopAll() }.disabled(!model.hasActiveMachines)
                    Divider()
                    Toggle("Start Machines When Lumen Opens", isOn: $autoStartMachines)
                }
            }
        }
    }
}

extension Notification.Name {
    static let newMachineRequested = Notification.Name("LumenNewMachineRequested")
    static let machineSettingsRequested = Notification.Name("LumenMachineSettingsRequested")
}

private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tabbingMode = .disallowed
            window.tabbingIdentifier = "Lumen.Library"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class LumenDelegate: NSObject, NSApplicationDelegate {
    private weak var model: LibraryModel?
    private var attached = false
    private var diagnosticsStarted = false
    private var diagnosticEngine: AppleVirtualMachine?
    private var diagnosticQEMU: QEMUVirtualMachine?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Direct launches of the app executable need a foreground application policy
        // before SwiftUI presents its first scene.
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        model?.refreshGuestDockIcon()
        // Boot diagnostics must not depend on the library window becoming visible. macOS can
        // defer that SwiftUI callback when several test instances launch close together.
        if ["--windows-boot-test", "--boot-test", "--smoke-test"].contains(where: CommandLine.arguments.contains) {
            beginDiagnostics()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshGuestDockIcon()
    }

    func attach(_ model: LibraryModel) {
        self.model = model
        guard !attached else { return }
        attached = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        beginDiagnostics()
        model.startAutomaticallyIfEnabled()
    }

    private func beginDiagnostics() {
        guard !diagnosticsStarted else { return }
        diagnosticsStarted = true
        if CommandLine.arguments.contains("--windows-boot-test") {
            Task { await windowsBootTest(installerPath: argument(after: "--windows-boot-test")) }
        } else if CommandLine.arguments.contains("--boot-test") {
            Task { await bootTest(installerPath: argument(after: "--boot-test")) }
        } else if CommandLine.arguments.contains("--smoke-test") {
            Task { await smokeTest() }
        } else if let destination = argument(after: "--snapshot") {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw LibraryError.invalidConfiguration("Could not capture the app window.")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw LibraryError.invalidConfiguration("Could not encode the preview.")
                    }
                    try png.write(to: URL(fileURLWithPath: destination))
                    print("Saved native window preview: \(destination)")
                } catch { print("Preview failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.reclaimingID != nil {
            let alert = NSAlert()
            alert.messageText = "Disk reclamation is in progress"
            alert.informativeText = "Wait for it to finish, or cancel it in the Virtual Machine menu, before quitting Lumen."
            alert.addButton(withTitle: "Keep Lumen Open")
            alert.runModal()
            return .terminateCancel
        }
        guard model?.hasActiveMachines == true || diagnosticEngine?.state.isActive == true || diagnosticQEMU?.isProcessRunning == true else { return .terminateNow }
        if model?.isGuestProcess == true, let machine = model?.machines.first {
            let alert = NSAlert()
            alert.messageText = "Shut down \(machine.name) before closing?"
            alert.informativeText = "The VM will shut down normally so it can save its work. Lumen's library stays open."
            alert.addButton(withTitle: "Keep VM Open")
            if model?.state(for: machine.id) != .installing { alert.addButton(withTitle: "Shut Down VM") }
            if alert.runModal() == .alertSecondButtonReturn { model?.closeGuestApplication() }
            return .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText = "Your virtual machines are still active"
        alert.informativeText = "Shut down your guests before quitting Lumen so their work is saved. A paused machine still uses memory."
        alert.addButton(withTitle: "Keep Lumen Open")
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model, model.isGuestProcess, let machine = model.machines.first else { return true }
        model.showDisplay(machine)
        return false
    }

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func boundedIntegerArgument(after flag: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard CommandLine.arguments.contains(flag) else { return defaultValue }
        guard let rawValue = argument(after: flag), let value = Int(rawValue), range.contains(value) else {
            throw LibraryError.invalidConfiguration("\(flag) requires an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return value
    }

    private func saveBootSnapshot(of window: NSWindow, to destination: String) throws {
        guard let view = window.contentView else {
            throw LibraryError.invalidConfiguration("The guest display is unavailable for a snapshot.")
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw LibraryError.invalidConfiguration("Could not capture the native guest view.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw LibraryError.invalidConfiguration("Could not encode the guest snapshot.")
        }
        try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }

    private func waitForQEMU(_ engine: QEMUVirtualMachine, state expected: VMRuntimeState, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.state != expected || (expected == .stopped && engine.isProcessRunning) {
            if engine.state == .failed || (!engine.isProcessRunning && expected != .stopped) {
                throw LibraryError.invalidConfiguration(engine.errorMessage ?? "QEMU exited before reaching \(expected.title.lowercased()) state.")
            }
            guard Date() < deadline else {
                throw LibraryError.invalidConfiguration(engine.errorMessage ?? "QEMU did not reach \(expected.title.lowercased()) state within \(Int(timeout)) seconds.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Only boots Windows installation media and exercises runtime controls. No Setup actions or requirement bypasses are automated.
    private func windowsBootTest(installerPath: String?) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenWindowsBoot-" + UUID().uuidString)
        var report: [String: Any] = [
            "backend": "QEMU HVF",
            "guestOSBootTested": false,
            "guestObservation": "Unverified. Inspect the boot snapshot or QEMU window to confirm Windows reached Setup.",
            "installationAutomated": false,
            "installerAttachedReadOnly": true,
            "cpuCount": 4,
            "memoryGiB": 8,
            "diskGiB": 64,
            "snapshotIntervalSeconds": 30
        ]
        report["qemuExecutablePath"] = QEMUVirtualMachine.executableURL?.path
        var testLocation: VMLocation?
        do {
            let bootWait = try boundedIntegerArgument(after: "--boot-wait", default: 120, range: 10...600)
            report["requestedBootWaitSeconds"] = bootWait
            guard let installerPath, !installerPath.hasPrefix("--"),
                  FileManager.default.isReadableFile(atPath: installerPath),
                  URL(fileURLWithPath: installerPath).pathExtension.lowercased() == "iso" else {
                throw LibraryError.invalidConfiguration("Pass a readable Windows ARM64 .iso path after --windows-boot-test.")
            }
            report["installerPath"] = installerPath
            let library = try MachineLibrary(root: directory)
            let record = VirtualMachineRecord(name: "Temporary Windows boot test", guest: .windows,
                                              cpuCount: 4, memoryGiB: 8, diskGiB: 64,
                                              installerPath: installerPath,
                                              windowsTPM: !CommandLine.arguments.contains("--boot-no-tpm"),
                                              windowsCompatibilityDisplay: CommandLine.arguments.contains("--boot-compatibility-display"))
            try library.create(record)
            let location = library.location(for: record.id)
            testLocation = location
            let initialUsage = try SparseDisk.usage(at: location.disk)
            report["diskCapacityBytes"] = initialUsage.capacityBytes
            report["initialAllocatedBytes"] = initialUsage.allocatedBytes

            let engine = QEMUVirtualMachine(record: record, location: location)
            diagnosticQEMU = engine
            try await engine.start(bootInstaller: true)
            try await waitForQEMU(engine, state: .running, timeout: 30)
            report["start"] = "passed"
            report["runtimeConfiguration"] = try await engine.diagnosticStatus()
            if CommandLine.arguments.contains("--boot-menu-test") {
                report["menuIntegration"] = try await engine.testMenuIntegration()
            }
            let startedAt = Date()
            for waitedSeconds in 1...bootWait {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard engine.state == .running, engine.isProcessRunning else {
                    throw LibraryError.invalidConfiguration(engine.errorMessage ?? "QEMU stopped before the boot observation period finished.")
                }
                // Windows media prompts for a key before entering Setup. Space only accepts that boot prompt.
                if [3, 6, 15, 30, 45, 60].contains(waitedSeconds) {
                    do {
                        try await engine.sendBootKey()
                        report["bootKeyAt\(waitedSeconds)Seconds"] = "sent"
                    } catch {
                        report["bootKeyAt\(waitedSeconds)Seconds"] = "failed: \(error.localizedDescription)"
                    }
                }
                if waitedSeconds.isMultiple(of: 10) || waitedSeconds == bootWait {
                    let message = "Windows boot observation: \(waitedSeconds)/\(bootWait) seconds; QEMU running, Windows Setup awaiting visual verification.\n"
                    FileHandle.standardOutput.write(Data(message.utf8))
                }
                if (waitedSeconds.isMultiple(of: 30) || waitedSeconds == bootWait),
                   let destination = argument(after: "--boot-snapshot") {
                    do {
                        try await engine.screenshot(to: URL(fileURLWithPath: destination))
                        report["snapshotPath"] = destination
                        report["snapshotCapturedAtSeconds"] = Date().timeIntervalSince(startedAt)
                        report["snapshotMethod"] = "QEMU QMP framebuffer PNG"
                        report["snapshotNeedsVisualReview"] = true
                        report.removeValue(forKey: "snapshotError")
                    } catch {
                        report["snapshotError"] = error.localizedDescription
                    }
                }
            }
            report["actualBootWaitSeconds"] = Date().timeIntervalSince(startedAt)
            report["runningAfterBootWait"] = true
            if let error = engine.errorMessage { report["runtimeWarning"] = error }

            try engine.pause()
            try await waitForQEMU(engine, state: .paused, timeout: 5)
            report["pause"] = "passed"
            try engine.resume()
            try await waitForQEMU(engine, state: .running, timeout: 5)
            report["resume"] = "passed"
            try engine.forceStop()
            try await waitForQEMU(engine, state: .stopped, timeout: 8)
            report["stop"] = "passed"
            report["result"] = "lifecycle-passed; Windows Setup requires visual verification"
        } catch {
            report["result"] = "failed"
            report["error"] = error.localizedDescription
            if let engine = diagnosticQEMU, engine.isProcessRunning {
                do {
                    try engine.forceStop()
                    try await waitForQEMU(engine, state: .stopped, timeout: 8)
                    report["cleanupStop"] = "passed"
                } catch {
                    report["cleanupStopError"] = error.localizedDescription
                }
            }
        }

        if let testLocation, let finalUsage = try? SparseDisk.usage(at: testLocation.disk) {
            report["finalAllocatedBytes"] = finalUsage.allocatedBytes
        }
        if let engine = diagnosticQEMU, let log = try? FileHandle(forReadingFrom: engine.logURL) {
            defer { try? log.close() }
            if let length = try? log.seekToEnd() {
                try? log.seek(toOffset: length > 8192 ? length - 8192 : 0)
                if let data = try? log.readToEnd(), !data.isEmpty {
                    report["qemuLogTail"] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        if diagnosticQEMU?.isProcessRunning != true {
            diagnosticQEMU = nil
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                report["temporaryMachineRemoved"] = true
            } catch {
                report["temporaryMachineRemoved"] = false
                report["cleanupError"] = error.localizedDescription
            }
        } else {
            report["temporaryMachineRemoved"] = false
            report["cleanupError"] = "QEMU is still running; its temporary disk was retained."
            report["temporaryMachinePath"] = directory.path
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            if let destination = argument(after: "--smoke-report") {
                do { try data.write(to: URL(fileURLWithPath: destination), options: .atomic) }
                catch { print("Could not save Windows boot report: \(error.localizedDescription)") }
            }
        }
        if diagnosticQEMU?.isProcessRunning != true { NSApp.terminate(nil) }
    }

    /// Boots read-only installation media without automating any installation actions.
    /// Lifecycle success is deliberately separate from visual confirmation of guest boot.
    private func bootTest(installerPath: String?) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenBoot-" + UUID().uuidString)
        var report: [String: Any] = [
            "hardwareVirtualizationSupported": VZVirtualMachine.isSupported,
            "guestOSBootTested": false,
            "guestObservation": "Unverified. Inspect the boot snapshot or guest window to confirm the operating system reached its desktop or installer.",
            "installationAutomated": false,
            "installerAttachedReadOnly": true,
            "cpuCount": 4,
            "memoryGiB": 4,
            "diskGiB": 64,
            "requestedBootWaitSeconds": 60
        ]
        var window: NSWindow?
        var testLocation: VMLocation?
        do {
            let bootWait = try boundedIntegerArgument(after: "--boot-wait", default: 60, range: 10...600)
            let bootMemory = try boundedIntegerArgument(after: "--boot-memory", default: 4, range: 2...16)
            report["requestedBootWaitSeconds"] = bootWait
            report["memoryGiB"] = bootMemory
            report["snapshotIntervalSeconds"] = 30
            guard let installerPath, !installerPath.hasPrefix("--"),
                  FileManager.default.isReadableFile(atPath: installerPath) else {
                throw LibraryError.invalidConfiguration("Pass a readable ARM64 ISO path after --boot-test.")
            }
            let installerURL = URL(fileURLWithPath: installerPath)
            guard installerURL.pathExtension.lowercased() == "iso" else {
                throw LibraryError.invalidConfiguration("The boot test requires an ARM64 UEFI installer in .iso format.")
            }
            report["installerPath"] = installerURL.path
            let library = try MachineLibrary(root: directory)
            let record = VirtualMachineRecord(name: "Temporary Ubuntu boot test", guest: .ubuntu,
                                              cpuCount: 4, memoryGiB: bootMemory, diskGiB: 64,
                                              installerPath: installerURL.path)
            try library.create(record)
            let location = library.location(for: record.id)
            testLocation = location
            let initialUsage = try SparseDisk.usage(at: location.disk)
            report["diskCapacityBytes"] = initialUsage.capacityBytes
            report["initialAllocatedBytes"] = initialUsage.allocatedBytes

            let engine = AppleVirtualMachine(record: record, location: location)
            diagnosticEngine = engine
            let guestWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered, defer: false)
            guestWindow.title = "Lumen · Ubuntu boot test · Temporary machine"
            guestWindow.minSize = NSSize(width: 640, height: 400)
            guestWindow.isReleasedWhenClosed = false
            guestWindow.contentView = NSHostingView(rootView: GuestDisplayView(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black))
            guestWindow.center()
            guestWindow.makeKeyAndOrderFront(nil)
            window = guestWindow

            try await engine.start(bootInstaller: true)
            guard engine.state == .running else {
                throw LibraryError.invalidConfiguration("VM did not enter running state with the installer attached.")
            }
            report["start"] = "passed"
            let startedAt = Date()
            var waitedSeconds = 0
            while waitedSeconds < bootWait {
                let interval = min(10, bootWait - waitedSeconds)
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                waitedSeconds += interval
                guard engine.state == .running else {
                    throw LibraryError.invalidConfiguration(engine.errorMessage ?? "The VM stopped before the boot observation period finished.")
                }
                let message = "Boot observation: \(waitedSeconds)/\(bootWait) seconds; VM running, guest boot awaiting visual verification.\n"
                FileHandle.standardOutput.write(Data(message.utf8))
                if (waitedSeconds.isMultiple(of: 30) || waitedSeconds == bootWait),
                   let destination = argument(after: "--boot-snapshot") {
                    do {
                        try saveBootSnapshot(of: guestWindow, to: destination)
                        report["snapshotPath"] = destination
                        report["snapshotCapturedAtSeconds"] = Date().timeIntervalSince(startedAt)
                        report["snapshotMethod"] = "Native NSView cache; inspect for blank hardware-accelerated surfaces."
                        report["snapshotNeedsVisualReview"] = true
                        report.removeValue(forKey: "snapshotError")
                    } catch {
                        // A screenshot failure must not skip lifecycle verification or shutdown.
                        report["snapshotError"] = error.localizedDescription
                    }
                }
            }
            report["actualBootWaitSeconds"] = Date().timeIntervalSince(startedAt)
            report["runningAfterBootWait"] = true
            if let error = engine.errorMessage { report["runtimeWarning"] = error }

            try await engine.pause()
            guard engine.state == .paused else { throw LibraryError.invalidConfiguration("VM did not pause.") }
            report["pause"] = "passed"
            try await engine.resume()
            guard engine.state == .running else { throw LibraryError.invalidConfiguration("VM did not resume.") }
            report["resume"] = "passed"
            try await engine.forceStop()
            guard engine.state == .stopped else { throw LibraryError.invalidConfiguration("VM did not stop.") }
            report["stop"] = "passed"
            report["result"] = "lifecycle-passed; guest boot requires visual verification"
        } catch {
            report["result"] = "failed"
            report["error"] = error.localizedDescription
            if let engine = diagnosticEngine, engine.state.isActive {
                do { try await engine.forceStop(); report["cleanupStop"] = "passed" }
                catch { report["cleanupStopError"] = error.localizedDescription }
            }
        }

        if let testLocation, let finalUsage = try? SparseDisk.usage(at: testLocation.disk) {
            report["finalAllocatedBytes"] = finalUsage.allocatedBytes
        }
        if diagnosticEngine?.state.isActive != true {
            window?.close()
            diagnosticEngine = nil
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                report["temporaryMachineRemoved"] = true
            } catch {
                report["temporaryMachineRemoved"] = false
                report["cleanupError"] = error.localizedDescription
            }
        } else {
            report["temporaryMachineRemoved"] = false
            report["cleanupError"] = "The VM is still active; its temporary disk was retained to avoid deleting an open VM."
            report["temporaryMachinePath"] = directory.path
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            if let destination = argument(after: "--smoke-report") {
                do { try data.write(to: URL(fileURLWithPath: destination), options: .atomic) }
                catch { print("Could not save boot report: \(error.localizedDescription)") }
            }
        }
        if diagnosticEngine?.state.isActive != true { NSApp.terminate(nil) }
    }

    /// Runs actual VZ lifecycle operations against an empty, temporary EFI disk; no OS is installed.
    private func smokeTest() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenSmoke-" + UUID().uuidString)
        var report: [String: Any] = ["hardwareVirtualizationSupported": VZVirtualMachine.isSupported, "guestOSBootTested": false]
        var testEngine: AppleVirtualMachine?
        do {
            let library = try MachineLibrary(root: directory)
            let record = VirtualMachineRecord(name: "Ephemeral EFI smoke test", guest: .linux, cpuCount: 2, memoryGiB: 2, diskGiB: 8)
            try library.create(record)
            let location = library.location(for: record.id)
            report["diskCapacityBytes"] = try SparseDisk.usage(at: location.disk).capacityBytes
            report["initialAllocatedBytes"] = try SparseDisk.usage(at: location.disk).allocatedBytes
            let engine = AppleVirtualMachine(record: record, location: location)
            testEngine = engine
            try await engine.start(bootInstaller: false)
            guard engine.state == .running else { throw LibraryError.invalidConfiguration("VM did not enter running state.") }
            report["start"] = "passed"
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await engine.pause()
            guard engine.state == .paused else { throw LibraryError.invalidConfiguration("VM did not pause.") }
            report["pause"] = "passed"
            try await engine.resume()
            guard engine.state == .running else { throw LibraryError.invalidConfiguration("VM did not resume.") }
            report["resume"] = "passed"
            try await engine.forceStop()
            guard engine.state == .stopped else { throw LibraryError.invalidConfiguration("VM did not stop.") }
            report["stop"] = "passed"
            report["result"] = "passed"
        } catch {
            report["result"] = "failed"
            report["error"] = error.localizedDescription
            if let engine = testEngine, engine.state.isActive { try? await engine.forceStop() }
        }
        try? FileManager.default.removeItem(at: directory)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            if let destination = argument(after: "--smoke-report") {
                try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            }
        }
        NSApp.terminate(nil)
    }
}
