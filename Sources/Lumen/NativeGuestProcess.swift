import AppKit
import Combine
import Foundation
import LumenCore
import Darwin

/// The VM runs in another instance of the signed app, with its own Dock tile.
/// Reuse the existing executable/resources rather than duplicating an app per VM.
@MainActor
final class NativeGuestProcess: ObservableObject {
    @Published private(set) var state: VMRuntimeState = .stopped
    @Published private(set) var progress: Double = 0
    @Published private(set) var errorMessage: String?
    var onLibraryAction: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var frames = GuestProcessFrames()
    private var startupTimeout: Task<Void, Never>?
    private var outputEnded = false
    private var exitStatus: Int32?
    var isProcessRunning: Bool { process?.isRunning == true }

    func start(record: VirtualMachineRecord, library: URL, bootInstaller: Bool) throws {
        guard !isProcessRunning, let executable = Bundle.main.executableURL else {
            throw LibraryError.invalidConfiguration("The native guest app cannot be launched.")
        }
        let child = Process(), commands = Pipe(), events = Pipe()
        child.executableURL = executable
        child.arguments = ["--native-guest", record.id.uuidString] + (bootInstaller ? ["--boot-installer"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["LUMEN_LIBRARY_PATH"] = library.path
        child.environment = environment
        child.standardInput = commands
        child.standardOutput = events
        child.standardError = FileHandle.standardError
        process = child
        input = commands.fileHandleForWriting
        output = events.fileHandleForReading
        frames = GuestProcessFrames()
        outputEnded = false
        exitStatus = nil
        state = .starting
        errorMessage = nil
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        events.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // FIFO delivery preserves the final state before pipe EOF. Process
            // termination can arrive independently, before its last status read.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if data.isEmpty { self.outputEnded = true; self.finishIfExited() }
                else { self.receive(data) }
            }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async { [weak self] in
                self?.exitStatus = child.terminationStatus
                self?.finishIfExited()
            }
        }
        do { try child.run() }
        catch {
            events.fileHandleForReading.readabilityHandler = nil
            process = nil; input = nil; output = nil; state = .failed
            throw error
        }
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.state == .starting else { return }
            self.errorMessage = "The guest app has not reported its state. Open its Dock icon to check for a macOS permission prompt."
        }
    }

    func send(_ command: GuestProcessCommand) throws {
        guard isProcessRunning, let input else { throw LibraryError.invalidConfiguration("This guest app is not running.") }
        try input.write(contentsOf: GuestProcessFrames.encode(GuestProcessMessage(command: command)))
    }
    func show() {
        try? send(.show)
        if let process { NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateAllWindows]) }
    }
    private func receive(_ data: Data) {
        guard process != nil else { return }
        do {
            for message in try frames.append(data) {
                if let status = message.status {
                    startupTimeout?.cancel()
                    state = status.state; progress = status.progress; errorMessage = status.error
                }
                if let action = message.libraryAction, ["library", "settings"].contains(action) { onLibraryAction?(action) }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func exited(status: Int32) {
        startupTimeout?.cancel()
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil
        if status == 0 && state != .failed { state = .stopped }
        else {
            state = .failed
            if errorMessage == nil { errorMessage = "The guest app exited unexpectedly (\(status)). Its disk was retained." }
        }
        objectWillChange.send()
    }

    private func finishIfExited() {
        guard outputEnded, let exitStatus else { return }
        exited(status: exitStatus)
    }
}

/// Inherited pipes are private to the launching library and this guest process.
@MainActor
final class NativeGuestBridge {
    private var frames = GuestProcessFrames()
    private var connected = true
    var onCommand: ((GuestProcessCommand) -> Void)?
    func start() {
        _ = fcntl(FileHandle.standardOutput.fileDescriptor, F_SETNOSIGPIPE, 1)
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if data.isEmpty { self.connected = false; return }
                do {
                    for message in try self.frames.append(data) {
                        if let command = message.command { self.onCommand?(command) }
                    }
                } catch { self.connected = false; handle.readabilityHandler = nil }
            }
        }
    }
    func status(_ status: GuestProcessStatus) { send(GuestProcessMessage(status: status)) }
    func library(_ action: String) { send(GuestProcessMessage(libraryAction: action)) }
    private func send(_ message: GuestProcessMessage) {
        guard connected else { return }
        do { try FileHandle.standardOutput.write(contentsOf: GuestProcessFrames.encode(message)) }
        catch { connected = false }
    }
}
