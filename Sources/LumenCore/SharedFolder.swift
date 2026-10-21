import Foundation

public struct SharedFolder: Codable, Equatable, Identifiable {
    public var path: String
    public var readOnly: Bool
    public var id: String { path }
    public init(path: String, readOnly: Bool = false) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.readOnly = readOnly
    }

    /// Stable, distinct names usable by both VirtioFS and Windows Explorer.
    public static func named(_ folders: [SharedFolder]) -> [(name: String, folder: SharedFolder)] {
        var used: Set<String> = []
        return folders.map { folder in
            let invalid = CharacterSet(charactersIn: "\"\\/:*?<>|").union(.controlCharacters)
            let raw = URL(fileURLWithPath: folder.path).lastPathComponent
            var base = String(String.UnicodeScalarView(raw.unicodeScalars.map { invalid.contains($0) ? "_" : $0 }))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if base.isEmpty { base = "Shared Folder" }
            base = String(base.prefix(48))
            if ["IPC$", "ADMIN$"].contains(base.uppercased()) { base = "Shared_" + base }
            var name = base
            var number = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(base) (\(number))"
                number += 1
            }
            return (name, folder)
        }
    }
}
