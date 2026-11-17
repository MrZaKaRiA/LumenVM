import Darwin
import Foundation
import LumenCore

/// A `qemu-nbd` child that owns one host disk descriptor (as its stdin) and serves it to QEMU
/// over a private unix socket. It exits by itself when QEMU disconnects (no --persistent).
final class HostDiskExport: @unchecked Sendable {
    let bsdName: String
    let socketPath: String
    private let process: Process
    private let logURL: URL

    private init(bsdName: String, socketPath: String, process: Process, logURL: URL) {
        self.bsdName = bsdName
        self.socketPath = socketPath
        self.process = process
        self.logURL = logURL
    }

    static func start(executable: URL, bsdName: String, disk: FileHandle, runtime: URL, readOnly: Bool) throws -> HostDiskExport {
        let socketPath = runtime.appendingPathComponent("nbd-\(bsdName).sock").path
        guard socketPath.utf8.count < 104 else { throw HostDiskError("The private device socket path is too long.") }
        try? FileManager.default.removeItem(atPath: socketPath)
        let logURL = runtime.appendingPathComponent("nbd-\(bsdName).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HostDiskError("Could not create the disk export log.")
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = QMPMessages.qemuNBDArguments(socketPath: socketPath, readOnly: readOnly)
        process.currentDirectoryURL = runtime
        process.standardInput = disk
        process.standardOutput = log
        process.standardError = log
        do { try process.run() } catch {
            throw HostDiskError("Could not start qemu-nbd: \(error.localizedDescription)")
        }
        return HostDiskExport(bsdName: bsdName, socketPath: socketPath, process: process, logURL: logURL)
    }

    var isRunning: Bool { process.isRunning }

    func waitUntilListening(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: socketPath) {
            guard process.isRunning else {
                throw HostDiskError("qemu-nbd could not open the disk: \(logTail())")
            }
            guard Date() < deadline else { throw HostDiskError("qemu-nbd did not start serving the disk.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits for a graceful exit, then terminates (and finally kills) the process.
    func stop(grace: TimeInterval = 5) async {
        if await waitForExit(timeout: grace) { return }
        process.terminate()
        if await waitForExit(timeout: 3) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(timeout: 3)
    }

    private func waitForExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private func logTail() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exit status \(process.terminationStatus)" : String(trimmed.suffix(1000))
    }
}
