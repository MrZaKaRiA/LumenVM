import Foundation

/// Give the external engine a real macOS application identity without changing Homebrew's binary.
enum VMProcessBundle {
    static func prepare(executable: URL, name: String, id: UUID) throws -> (root: URL, executable: URL) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("lumen-host-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Lumen VM.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        do {
            let destination = macOS.appendingPathComponent("LumenVM")
            // A hard link shares existing SSD blocks. Never re-sign or modify this linked executable.
            // Cross-volume installs fall back to a copy, which is removed after the guest exits.
            do { try manager.linkItem(at: executable.resolvingSymlinksInPath(), to: destination) }
            catch { try manager.copyItem(at: executable.resolvingSymlinksInPath(), to: destination) }
            let info: [String: Any] = [
                "CFBundleName": "Lumen VM", "CFBundleDisplayName": "\(name) — Lumen",
                "CFBundleIdentifier": "app.lumen.guest.\(id.uuidString.lowercased())",
                "CFBundleExecutable": "LumenVM", "CFBundlePackageType": "APPL",
                "NSHighResolutionCapable": true,
                "NSMicrophoneUsageDescription": "Microphone input for this virtual machine, when enabled in Lumen."
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
            return (root, destination)
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }
}
