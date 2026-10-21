import Foundation

/// Reads the names macOS actually publishes, which can differ from folder names.
public struct MacSMBShare: Equatable {
    public let name: String
    public let path: String
    public let readOnly: Bool

    public static func configuredShare(for folder: URL, in data: Data) throws -> MacSMBShare? {
        struct Entry: Decodable {
            let path: String
            let smb_name: String
            let smb_shared: Int
            let smb_read_only: Int?
        }
        let entries = try JSONDecoder().decode([String: Entry].self, from: data)
        let selectedPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return entries.values
            .filter { $0.smb_shared == 1 && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == selectedPath }
            .sorted { $0.smb_name < $1.smb_name }
            .first.map { MacSMBShare(name: $0.smb_name, path: $0.path, readOnly: $0.smb_read_only == 1) }
    }
}
