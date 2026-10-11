import Combine
import Darwin
import Foundation
import LumenCore

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

    func start(bootInstaller: Bool) throws {
        guard process == nil else { throw QEMUError("This virtual machine is already active.") }
        try record.validate()
        guard record.guest == .windows else { throw QEMUError("This QEMU profile is for Windows ARM64.") }
        guard record.macAddress.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil else {
            throw QEMUError("The virtual network adapter has an invalid MAC address.")
        }
        guard let executable = Self.executableURL else { throw QEMUError(Self.availabilityDescription) }
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
        let arguments = try makeArguments(firmware: firmware, bootInstaller: bootInstaller)
        errorMessage = nil
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
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = location.directory
        child.standardInput = input
        child.standardOutput = output
        child.standardError = logHandle
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

    private func prepareSetupMedia() throws -> URL? {
        guard record.windowsBypassChecks else { return nil }
        let isoURL = location.windowsSetupMedia
        let staging = location.directory.appendingPathComponent(".setup-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let shareName = record.sharedDirectoryPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let files = WindowsSetupMedia.files(bypassChecks: record.windowsBypassChecks, sharedFolderName: shareName)
        for file in files {
            let dest = staging.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: dest, atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: isoURL.path) {
            try? FileManager.default.removeItem(at: isoURL)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["makehybrid", "-iso", "-default-volume-name", "LUMENSETUP", "-o", isoURL.path, staging.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return FileManager.default.isReadableFile(atPath: isoURL.path) ? isoURL : nil
    }

    private func makeArguments(firmware: (code: URL, variables: URL), bootInstaller: Bool) throws -> [String] {
        var arguments = [
            "-name", record.name.replacingOccurrences(of: ",", with: ",,"),
            "-machine", "virt,highmem=on,gic-version=3,pflash0=uefi-code,pflash1=uefi-vars",
            "-accel", "hvf", "-cpu", "host", "-smp", String(record.cpuCount),
            "-m", String(record.memoryGiB * 1024),
            "-nodefaults", "-display", "cocoa,zoom-to-fit=on", "-device", "ramfb",
            "-device", "qemu-xhci,id=usb", "-device", "usb-kbd", "-device", "usb-tablet",
            "-device", "virtio-balloon-pci"
        ]
        if record.networkEnabled {
            arguments += [
                "-netdev", "user,id=network", "-device", "virtio-net-pci,netdev=network,mac=\(record.macAddress)"
            ]
        }
        if record.audioOutput {
            arguments += [
                "-audiodev", "coreaudio,id=audio0", "-device", "intel-hda", "-device", "hda-duplex,audiodev=audio0"
            ]
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
            }
            arguments += ["-blockdev", try json(block)]
        }
        // Windows has a native NVMe storage driver. Virtio storage would need an extra ARM64 driver.
        arguments += ["-device", "nvme,drive=disk,serial=LUMEN\(record.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)),bootindex=1"]
        if bootInstaller, let path = record.installerPath {
            arguments += ["-blockdev", try json([
                "driver": "raw", "node-name": "installer", "read-only": true,
                "file": ["driver": "file", "filename": path]
            ]), "-device", "usb-bot,id=installer-usb", "-device", "scsi-cd,drive=installer,bus=installer-usb.0,bootindex=0"]
        }
        if bootInstaller, let setupMedia = try? prepareSetupMedia() {
            arguments += ["-blockdev", try json([
                "driver": "raw", "node-name": "lumensetup", "read-only": true,
                "file": ["driver": "file", "filename": setupMedia.path]
            ]), "-device", "usb-bot,id=setup-usb", "-device", "scsi-cd,drive=lumensetup,bus=setup-usb.0"]
        }
        let drivers = location.directory.appendingPathComponent("Drivers.iso")
        if FileManager.default.isReadableFile(atPath: drivers.path) {
            arguments += ["-blockdev", try json([
                "driver": "raw", "node-name": "drivers", "read-only": true,
                "file": ["driver": "file", "filename": drivers.path]
            ]), "-device", "usb-bot,id=drivers-usb", "-device", "scsi-cd,drive=drivers,bus=drivers-usb.0"]
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
                        finishRequest(id, result: .success(object["return"] as? [String: Any] ?? [:]))
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

    private func cleanup() {
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
