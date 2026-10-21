import Foundation

public enum LocalFileSelection {
    public static func validateInstaller(_ url: URL) throws {
        guard url.isFileURL else { throw LibraryError.invalidConfiguration("Choose an installer file stored on your Mac.") }
        guard ["iso", "ipsw", "img"].contains(url.pathExtension.lowercased()) else {
            throw LibraryError.invalidConfiguration("Choose an ISO, IPSW or supported ARM64 IMG installer.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw LibraryError.invalidConfiguration("This installer is missing or cannot be read. Choose another file.")
        }
    }

    public static func validateFolder(_ url: URL) throws {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw LibraryError.invalidConfiguration("Choose a readable folder on your Mac.")
        }
    }
}
