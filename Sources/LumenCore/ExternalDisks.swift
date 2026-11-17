import Foundation

// Pure helpers for the external-disk user interface: DiskArbitration descriptions, menu
// payloads exchanged with the QEMU window helper, and the menu commands it sends back.

extension HostDisk {
    /// Builds a disk from a DiskArbitration description (`DADiskCopyDescription`), whose keys are
    /// the string values of the `kDADiskDescription…Key` constants. Returns nil without a BSD name.
    /// Missing booleans are read conservatively (internal, not removable, not whole).
    public init?(diskArbitrationDescription info: [String: Any]) {
        guard let identifier = info["DAMediaBSDName"] as? String else { return nil }
        let model = info["DADeviceModel"] as? String ?? ""
        let busProtocol = info["DADeviceProtocol"] as? String ?? ""
        let mediaPath = info["DAMediaPath"] as? String ?? ""
        let mediaName = info["DAMediaName"] as? String ?? ""
        let content = info["DAMediaContent"] as? String ?? ""
        let whole = Self.bool(info["DAMediaWhole"]) ?? false
        let volume = info["DAVolumeName"] as? String ?? ""
        let isImage = model == "Disk Image" || busProtocol == "Virtual Interface" || busProtocol == "Disk Image"
            || mediaPath.contains("IOHDIXController")
        // APFS synthesized containers are whole disks named "AppleAPFSMedia" with APFS container content.
        let synthesized = whole && (mediaName == "AppleAPFSMedia" || content.uppercased() == "EF57347C-0000-11AA-AA11-00306543ECAC")
        let vendor = (info["DADeviceVendor"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let friendly = [vendor, trimmedModel].filter { !$0.isEmpty }.joined(separator: " ")
        self.init(bsdName: identifier,
                  mediaName: isImage || friendly.isEmpty ? mediaName : friendly,
                  volumeNames: volume.isEmpty ? [] : [volume],
                  sizeBytes: (info["DAMediaSize"] as? NSNumber)?.uint64Value ?? 0,
                  isRemovable: Self.bool(info["DAMediaRemovable"]) ?? false,
                  isEjectable: Self.bool(info["DAMediaEjectable"]) ?? false,
                  isInternal: Self.bool(info["DADeviceInternal"]) ?? true,
                  isDiskImage: isImage,
                  isWhole: whole,
                  busProtocol: isImage ? "Disk Image" : busProtocol,
                  isSynthesized: synthesized)
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    /// The most recognisable name: media name, else first volume name, else the BSD name.
    public var displayName: String {
        let media = mediaName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !media.isEmpty { return media }
        if let volume = volumeNames.first(where: { !$0.isEmpty }) { return volume }
        return bsdName
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: sizeBytes), countStyle: .file)
    }

    /// "SanDisk Ultra (STICK) — 62 GB"
    public var displayTitle: String {
        let volumes = volumeNames.filter { !$0.isEmpty && $0 != displayName }
        let label = volumes.isEmpty ? displayName : "\(displayName) (\(volumes.joined(separator: ", ")))"
        return "\(label) — \(sizeDescription)"
    }
}

/// One disk entry in the status payload sent to a Windows VM window's helper.
public struct ExternalDiskMenuItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var attachedHere: Bool
    public var attachedElsewhere: Bool

    public init(id: String, title: String, attachedHere: Bool, attachedElsewhere: Bool) {
        self.id = id
        self.title = title
        self.attachedHere = attachedHere
        self.attachedElsewhere = attachedElsewhere
    }

    /// Property-list form for a distributed notification's userInfo.
    public var dictionary: [String: Any] {
        ["id": id, "title": title, "attachedHere": attachedHere, "attachedElsewhere": attachedElsewhere]
    }
}

/// A disk command received from a VM window menu: `disk-attach:<bsd>`, `disk-attach-ro:<bsd>`,
/// `disk-return:<bsd>` or `disk-eject:<bsd>`.
public enum DiskMenuAction: Equatable, Sendable {
    case attach(bsdName: String, readOnly: Bool)
    case returnToMac(bsdName: String)
    case eject(bsdName: String)

    public var bsdName: String {
        switch self {
        case let .attach(name, _), let .returnToMac(name), let .eject(name): return name
        }
    }

    public var command: String {
        switch self {
        case let .attach(name, readOnly): return (readOnly ? "disk-attach-ro:" : "disk-attach:") + name
        case let .returnToMac(name): return "disk-return:" + name
        case let .eject(name): return "disk-eject:" + name
        }
    }

    /// Strict parser: exact prefix, a valid whole-disk BSD name, and only disks the app last
    /// published to that VM's menu. Anything else is ignored (nil).
    public static func parse(_ action: String, published: Set<String>) -> DiskMenuAction? {
        let prefixes: [(String, (String) -> DiskMenuAction)] = [
            ("disk-attach:", { .attach(bsdName: $0, readOnly: false) }),
            ("disk-attach-ro:", { .attach(bsdName: $0, readOnly: true) }),
            ("disk-return:", { .returnToMac(bsdName: $0) }),
            ("disk-eject:", { .eject(bsdName: $0) })
        ]
        for (prefix, make) in prefixes where action.hasPrefix(prefix) {
            let name = String(action.dropFirst(prefix.count))
            guard HostDisk.isValidBSDName(name), published.contains(name) else { return nil }
            return make(name)
        }
        return nil
    }
}

public enum HostDiskMountPolicy {
    /// Whether macOS must be stopped from mounting `bsdName` (a whole disk or a slice such as
    /// "disk4s1") because its whole disk is owned by a virtual machine.
    public static func shouldBlockMount(of bsdName: String, ownedWholeDisks: Set<String>) -> Bool {
        guard let whole = HostDisk.wholeDiskName(of: bsdName) else { return false }
        return ownedWholeDisks.contains(whole)
    }
}
