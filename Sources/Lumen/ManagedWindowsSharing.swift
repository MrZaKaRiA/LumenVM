import Foundation
import Security
import LumenCore
import Darwin

/// An authenticated SMB2 server bound only to loopback, forwarded into this VM
/// at 10.0.2.4. It never modifies macOS sharing, accounts or firewall settings.
@MainActor
final class ManagedWindowsSharing {
    private var process: Process?
    private(set) var port: Int = 0
    private(set) var connection: WindowsFolderConnection?

    static var pythonURL: URL? {
        ["/opt/homebrew/opt/python@3.14/bin/python3.14", "/opt/homebrew/bin/python3.14", "/usr/local/bin/python3.14"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var resources: URL? {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("WindowsSharing"),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("server.py").path) else { return nil }
        return resources
    }

    func start(folders: [SharedFolder], location: VMLocation, setupShare: (name: String, directory: URL)? = nil) async throws {
        guard !folders.isEmpty || setupShare != nil else { return }
        guard let python = Self.pythonURL, let runtime = Self.resources else {
            throw LibraryError.invalidConfiguration("Windows folder sharing needs Lumen’s bundled sharing runtime and Homebrew Python 3.14. Run the project build script to prepare them.")
        }
        for folder in folders { try LocalFileSelection.validateFolder(URL(fileURLWithPath: folder.path)) }
        let password = try credentials(in: location.directory)
        let shares = SharedFolder.named(folders)
        connection = WindowsFolderConnection(password: password, shares: shares.map(\.name))
        var exported: [[String: Any]] = shares.map {
            ["name": $0.name, "path": $0.folder.path, "readOnly": $0.folder.readOnly]
        }
        if let setupShare { exported.append(["name": setupShare.name, "path": setupShare.directory.path, "readOnly": false]) }
        let config: [String: Any] = ["password": password, "folders": exported]
        let child = Process()
        let input = Pipe(), output = Pipe()
        child.executableURL = python
        // Bytecode caches would mutate the signed app bundle at runtime.
        child.arguments = ["-I", "-B", runtime.appendingPathComponent("server.py").path]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        process = child
        try child.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: config) + Data([10]))
            try input.fileHandleForWriting.close()
            port = try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    var line = Data()
                    while line.count < 512, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                        if byte.first == 10 { break }
                        line.append(byte)
                    }
                    guard let ready = try JSONSerialization.jsonObject(with: line) as? [String: Int],
                          let port = ready["port"], (1024...65535).contains(port) else {
                        throw LibraryError.invalidConfiguration("The private Windows sharing service could not start.")
                    }
                    return port
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    if child.isRunning { child.terminate() }
                    throw LibraryError.invalidConfiguration("The private Windows sharing service did not become ready.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch { stop(); throw error }
    }

    // `cmd:` spawns nc per guest connection. `tcp:` (QEMU 11.1) opens one chardev connection at
    // launch and cannot reconnect, so SMB reconnects after a guest drop would fail.
    var forwardingOption: String { "guestfwd=tcp:10.0.2.4:445-cmd:/usr/bin/nc 127.0.0.1 \(port)" }

    func stop() {
        if let child = process, child.isRunning { child.terminate() }
        process = nil
        port = 0
        connection = nil
    }

    private func credentials(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("SharingAccount.json")
        let existing = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 {
            let handle = FileHandle(fileDescriptor: existing, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(existing, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= 4096 else {
                throw LibraryError.invalidConfiguration("The VM sharing account file must be a regular file.")
            }
            let stored = try JSONDecoder().decode([String: String].self, from: handle.read(upToCount: 4097) ?? Data())
            guard let password = stored["password"], password.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw LibraryError.invalidConfiguration("The VM sharing account file is invalid.")
            }
            guard fchmod(existing, 0o600) == 0 else { throw LibraryError.invalidConfiguration("Could not protect the VM sharing account file.") }
            return password
        }
        guard errno == ENOENT else { throw LibraryError.invalidConfiguration("Could not safely read the VM sharing account file.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LibraryError.invalidConfiguration("Could not create the private VM sharing account.")
        }
        let password = bytes.map { String(format: "%02x", $0) }.joined()
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LibraryError.invalidConfiguration("Could not save the private VM sharing account.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: JSONEncoder().encode(["password": password]))
            try handle.synchronize()
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        return password
    }
}
