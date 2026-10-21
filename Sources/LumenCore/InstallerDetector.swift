import Foundation

public enum CPUArchitecture: String, Codable {
    case arm64, x86_64, unknown
    public var title: String {
        switch self {
        case .arm64: return "ARM64"
        case .x86_64: return "Intel x86-64"
        case .unknown: return "Unknown architecture"
        }
    }
}

public struct DetectedInstaller: Equatable {
    public var guest: GuestOS?
    public var distribution: LinuxDistribution?
    public var architecture: CPUArchitecture
    public var volumeLabel: String?
    /// True when the media carries an ARM64 UEFI boot loader (`EFI/BOOT/BOOTAA64.EFI`).
    public var hasARM64BootLoader: Bool

    public var isCompatible: Bool { architecture != .x86_64 }

    /// A short, human description such as "Ubuntu Desktop · ARM64".
    public var summary: String {
        let name = distribution?.name ?? guest?.title ?? "Unrecognized installer"
        return architecture == .unknown ? name : "\(name) · \(architecture.title)"
    }
}

/// Recognizes installer media from its filename, ISO 9660 volume label and EFI boot files.
/// Only reads a few sectors; it never mounts or executes the image.
public enum InstallerDetector {
    public static func detect(url: URL) -> DetectedInstaller {
        let filename = url.lastPathComponent
        if url.pathExtension.lowercased() == "ipsw" {
            return DetectedInstaller(guest: .macOS, distribution: nil, architecture: .arm64, volumeLabel: nil, hasARM64BootLoader: false)
        }
        let iso = ISO9660Reader(url: url)
        let label = iso?.volumeLabel
        let bootFiles = iso?.efiBootFiles() ?? []
        let hasARM = bootFiles.contains("BOOTAA64.EFI")
        let hasX64 = bootFiles.contains("BOOTX64.EFI") || bootFiles.contains("BOOTIA32.EFI")
        let text = [filename, label ?? ""].joined(separator: " ")

        var architecture: CPUArchitecture = hasARM ? .arm64 : hasX64 ? .x86_64 : .unknown
        if architecture == .unknown { architecture = Self.architecture(fromText: text) }

        if isWindows(text: text) {
            return DetectedInstaller(guest: .windows, distribution: nil, architecture: architecture, volumeLabel: label, hasARM64BootLoader: hasARM)
        }
        let distribution = LinuxDistribution.match(text)
        return DetectedInstaller(guest: distribution?.family ?? (iso != nil && (hasARM || hasX64) ? .linux : nil),
                                 distribution: distribution, architecture: architecture,
                                 volumeLabel: label, hasARM64BootLoader: hasARM)
    }

    static func isWindows(text: String) -> Bool {
        let lowered = text.lowercased()
        // Microsoft media labels look like CCCOMA_A64FRE_EN-US_DV9 (A64 = ARM64, X64 = Intel).
        return lowered.contains("cccoma") || lowered.contains("windows") || lowered.contains("win11")
            || lowered.contains("win10") || lowered.contains("a64fre") || lowered.contains("x64fre")
    }

    public static func architecture(fromText text: String) -> CPUArchitecture {
        let tokens = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
        let pieces = Set(tokens.flatMap { $0.split(separator: "_").map(String.init) }).union(tokens)
        if !pieces.isDisjoint(with: ["arm64", "aarch64", "a64fre", "a64", "armv8"]) { return .arm64 }
        if !pieces.isDisjoint(with: ["amd64", "x86_64", "x64", "x86", "i386", "i686", "x64fre", "64bit"]) { return .x86_64 }
        return .unknown
    }
}

/// Minimal, bounds-checked ISO 9660 reader for the primary volume descriptor and EFI/BOOT directory.
struct ISO9660Reader {
    private let handle: FileHandle
    private let blockSize: Int
    private let rootExtent: UInt32
    private let rootLength: UInt32
    let volumeLabel: String?

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        // Volume descriptors start at sector 16 (2048-byte logical sectors).
        // A boot record may precede the primary descriptor; sector 16 is not always the PVD.
        var primary: Data?
        for sector in 16..<48 {
            guard let descriptor = Self.read(handle, offset: UInt64(sector * 2048), length: 2048),
                  descriptor.count == 2048, String(decoding: descriptor[1..<6], as: UTF8.self) == "CD001" else { break }
            if descriptor[0] == 1 { primary = descriptor; break }
            if descriptor[0] == 255 { break }
        }
        guard let pvd = primary else {
            try? handle.close()
            return nil
        }
        let label = String(decoding: pvd[40..<72], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        volumeLabel = label.isEmpty ? nil : label
        let size = Int(pvd[128]) | Int(pvd[129]) << 8
        blockSize = (512...4096).contains(size) ? size : 2048
        rootExtent = Self.le32(pvd, 156 + 2)
        rootLength = Self.le32(pvd, 156 + 10)
    }

    func efiBootFiles() -> Set<String> {
        defer { try? handle.close() }
        guard let efi = entries(extent: rootExtent, length: rootLength).first(where: { $0.name == "EFI" && $0.isDirectory }),
              let boot = entries(extent: efi.extent, length: efi.length).first(where: { $0.name == "BOOT" && $0.isDirectory }) else {
            return []
        }
        return Set(entries(extent: boot.extent, length: boot.length).filter { !$0.isDirectory }.map(\.name))
    }

    private struct Entry { let name: String; let extent: UInt32; let length: UInt32; let isDirectory: Bool }

    private func entries(extent: UInt32, length: UInt32) -> [Entry] {
        let bounded = Int(min(length, 256 * 1024))
        guard bounded > 0, let data = Self.read(handle, offset: UInt64(extent) * UInt64(blockSize), length: bounded) else { return [] }
        var result: [Entry] = []
        var offset = 0
        while offset < data.count {
            let recordLength = Int(data[data.startIndex + offset])
            if recordLength == 0 {
                // Records never cross sector boundaries; skip the sector's padding.
                offset = (offset / blockSize + 1) * blockSize
                continue
            }
            guard recordLength >= 34, offset + recordLength <= data.count else { break }
            let record = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + recordLength))
            let nameLength = Int(record[32])
            if nameLength > 0, 33 + nameLength <= record.count {
                let rawName = record[33..<(33 + nameLength)]
                if !(nameLength == 1 && (rawName.first == 0 || rawName.first == 1)) {
                    var name = String(decoding: rawName, as: UTF8.self).uppercased()
                    if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
                    if name.hasSuffix(".") { name.removeLast() }
                    result.append(Entry(name: name, extent: Self.le32(record, 2), length: Self.le32(record, 10),
                                        isDirectory: record[25] & 0x02 != 0))
                }
            }
            offset += recordLength
        }
        return result
    }

    private static func read(_ handle: FileHandle, offset: UInt64, length: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length)
        } catch { return nil }
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return 0 }
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
