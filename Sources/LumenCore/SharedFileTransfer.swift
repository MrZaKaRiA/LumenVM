import Foundation
import Darwin

public enum SharedFileTransfer {
    /// Stage copies under the selected share, then publish without overwriting.
    /// The guest sees these files through its existing SMB/VirtioFS connection.
    public static func copy(_ sources: [URL], to folder: SharedFolder) throws -> [URL] {
        guard !folder.readOnly else { throw LibraryError.invalidConfiguration("Choose a writable shared folder.") }
        guard !sources.isEmpty, sources.count <= 128 else { throw LibraryError.invalidConfiguration("Send between 1 and 128 files or folders at a time.") }
        let manager = FileManager.default
        let target = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath()
        try LocalFileSelection.validateFolder(target)
        var names = Set<String>()
        var pendingSources: [URL] = []
        var visible: [URL] = []
        for source in sources {
            guard source.isFileURL else { throw LibraryError.invalidConfiguration("Only local files can be sent.") }
            let properties = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard properties.isSymbolicLink != true, properties.isRegularFile == true || properties.isDirectory == true else {
                throw LibraryError.invalidConfiguration("Choose regular files or folders rather than symbolic links.")
            }
            let resolved = source.resolvingSymlinksInPath().path
            guard target.path != resolved, !target.path.hasPrefix(resolved + "/") else {
                throw LibraryError.invalidConfiguration("A folder cannot be copied into itself.")
            }
            let name = source.lastPathComponent
            guard !name.isEmpty, names.insert(name.lowercased()).inserted else {
                throw LibraryError.invalidConfiguration("A file named \(name) already exists in the destination or this selection. Rename it before sending.")
            }
            let destination = target.appendingPathComponent(name)
            if destination.path == resolved {
                visible.append(destination)
                continue // Already inside this share; no extra SSD allocation.
            }
            guard !manager.fileExists(atPath: destination.path) else {
                throw LibraryError.invalidConfiguration("A file named \(name) already exists in the destination. Rename it before sending.")
            }
            pendingSources.append(source)
        }
        guard !pendingSources.isEmpty else { return visible }
        let stage = target.appendingPathComponent(".lumen-transfer-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        for source in pendingSources { try manager.copyItem(at: source, to: stage.appendingPathComponent(source.lastPathComponent)) }
        var published: [URL] = []
        do {
            for source in pendingSources {
                let destination = target.appendingPathComponent(source.lastPathComponent)
                guard renamex_np(stage.appendingPathComponent(source.lastPathComponent).path,
                                 destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw LibraryError.invalidConfiguration(String(cString: strerror(errno)))
                }
                published.append(destination)
            }
        } catch {
            throw LibraryError.invalidConfiguration("Transferred \(published.count) of \(pendingSources.count) new items. The remaining copies were cleaned up. \(error.localizedDescription)")
        }
        return visible + published
    }
}
