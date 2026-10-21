import Foundation
import Virtualization

/// Downloads the newest macOS restore image this Mac supports into Application Support.
@MainActor
final class RestoreImageDownloader: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: String?

    private var task: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen/RestoreImages", isDirectory: true)
    }

    func downloadLatest() async throws -> URL {
        guard !isDownloading else { throw DownloadError("A macOS download is already in progress.") }
        isDownloading = true
        progress = 0
        status = "Finding the latest supported macOS…"
        defer {
            isDownloading = false
            status = nil
            task = nil
            progressObservation = nil
        }

        let latest: (url: URL, name: String) = try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                continuation.resume(with: result.map { image in
                    let version = image.operatingSystemVersion
                    let name = "UniversalMac_\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)_\(image.buildVersion)_Restore.ipsw"
                    return (image.url, name)
                })
            }
        }
        guard latest.url.scheme == "https" else { throw DownloadError("Apple returned an unexpected restore image address.") }
        let destination = Self.directory.appendingPathComponent(latest.name)
        if FileManager.default.isReadableFile(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        status = "Downloading \(latest.name)…"
        return try await withCheckedThrowingContinuation { continuation in
            let download = URLSession.shared.downloadTask(with: latest.url) { temporary, response, error in
                // The temporary file is removed when this handler returns; move it first.
                do {
                    if let error { throw error }
                    guard let temporary, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw DownloadError("Apple's server did not return the restore image. Try again later.")
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor [weak self] in self?.progress = fraction }
            }
            task = download
            download.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    struct DownloadError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
