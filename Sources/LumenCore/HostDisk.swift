import Foundation

/// A whole host disk (USB stick, SD card, external drive) that may be handed to a guest.
/// Pure value type: filled by a DiskArbitration monitor or from `diskutil info -plist`.
public struct HostDisk: Codable, Hashable, Sendable {
    /// BSD name of the whole disk, e.g. "disk4". Always check `isValidBSDName` before building a /dev path.
    public var bsdName: String
    public var mediaName: String
    public var volumeNames: [String]
    public var sizeBytes: UInt64
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isDiskImage: Bool
    public var isWhole: Bool
    public var busProtocol: String
    /// An APFS synthesized container (a virtual whole disk backed by a physical store) is never a real device.
    public var isSynthesized: Bool

    public init(bsdName: String, mediaName: String = "", volumeNames: [String] = [], sizeBytes: UInt64,
                isRemovable: Bool, isEjectable: Bool, isInternal: Bool, isDiskImage: Bool, isWhole: Bool,
                busProtocol: String = "", isSynthesized: Bool = false) {
        self.bsdName = bsdName
        self.mediaName = mediaName
        self.volumeNames = volumeNames
        self.sizeBytes = sizeBytes
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isDiskImage = isDiskImage
        self.isWhole = isWhole
        self.busProtocol = busProtocol
        self.isSynthesized = isSynthesized
    }

    /// Only names of the form `disk<N>` (whole disks) are accepted; no slices, paths or other characters.
    public static func isValidBSDName(_ name: String) -> Bool {
        name.range(of: "^disk[0-9]+$", options: .regularExpression) != nil && name.count <= 16
    }

    /// The whole-disk name of a BSD name such as "disk0s2" or "disk3s1s1", or nil if it is not a disk name.
    public static func wholeDiskName(of name: String) -> String? {
        guard let range = name.range(of: "^disk[0-9]+", options: .regularExpression),
              name[range.upperBound...].range(of: "^(s[0-9]+)*$", options: .regularExpression) != nil else { return nil }
        return String(name[range])
    }

    /// Builds a disk from a `diskutil info -plist <disk>` dictionary. Returns nil if the identifier is missing.
    public init?(diskutilInfo info: [String: Any]) {
        guard let identifier = info["DeviceIdentifier"] as? String else { return nil }
        let bus = info["BusProtocol"] as? String ?? ""
        let volume = info["VolumeName"] as? String ?? ""
        self.init(bsdName: identifier,
                  mediaName: info["MediaName"] as? String ?? "",
                  volumeNames: volume.isEmpty ? [] : [volume],
                  sizeBytes: (info["Size"] as? NSNumber)?.uint64Value ?? (info["TotalSize"] as? NSNumber)?.uint64Value ?? 0,
                  isRemovable: (info["Removable"] as? Bool ?? false) || (info["RemovableMedia"] as? Bool ?? false),
                  isEjectable: info["Ejectable"] as? Bool ?? false,
                  isInternal: info["Internal"] as? Bool ?? true,
                  isDiskImage: bus == "Disk Image",
                  isWhole: info["WholeDisk"] as? Bool ?? false,
                  busProtocol: bus,
                  isSynthesized: info["APFSPhysicalStores"] != nil && (info["WholeDisk"] as? Bool ?? false))
    }

    /// Whole disks that back a volume, from its `diskutil info -plist` dictionary:
    /// the parent whole disk plus, for APFS, the whole disks holding its physical stores.
    public static func backingWholeDisks(diskutilInfo info: [String: Any]) -> Set<String> {
        var result = Set<String>()
        for key in ["ParentWholeDisk", "DeviceIdentifier"] {
            if let name = info[key] as? String, let whole = wholeDiskName(of: name) { result.insert(whole) }
        }
        for store in info["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
            if let name = store["APFSPhysicalStore"] as? String, let whole = wholeDiskName(of: name) { result.insert(whole) }
        }
        return result
    }
}

public enum DeviceEligibility {
    /// Whether a host disk may be offered to (and attached to) a guest.
    /// `bootDiskParents` must contain every whole disk backing the Mac's system volume and the VM's own storage.
    public static func canOffer(_ disk: HostDisk, bootDiskParents: Set<String>, allowDiskImages: Bool = false) -> Bool {
        HostDisk.isValidBSDName(disk.bsdName)
            && disk.isWhole
            && !disk.isSynthesized
            && (disk.isRemovable || disk.isEjectable || !disk.isInternal)
            && (allowDiskImages || !disk.isDiskImage)
            && !bootDiskParents.contains(disk.bsdName)
            && disk.sizeBytes > 0
    }
}

/// A host disk currently presented to the guest as a USB mass-storage device.
public struct AttachedHostDisk: Codable, Hashable, Sendable {
    public var bsdName: String
    /// QEMU qdev id of the usb-storage device.
    public var deviceID: String
    /// QEMU block node name (an NBD client node).
    public var nodeName: String
    public var readOnly: Bool
    public var mediaName: String
    public var sizeBytes: UInt64

    public init(bsdName: String, deviceID: String, nodeName: String, readOnly: Bool, mediaName: String = "", sizeBytes: UInt64 = 0) {
        self.bsdName = bsdName
        self.deviceID = deviceID
        self.nodeName = nodeName
        self.readOnly = readOnly
        self.mediaName = mediaName
        self.sizeBytes = sizeBytes
    }

    /// Deterministic QEMU identifiers for a validated BSD name.
    public static func identifiers(for bsdName: String) -> (deviceID: String, nodeName: String, serial: String) {
        ("lumen-usb-\(bsdName)", "lumen-hd-\(bsdName)", "LUMEN" + bsdName.uppercased())
    }
}

/// What happens to a host disk on the Mac after it is detached from the guest.
public enum HostDiskDetachAction: String, Codable, Sendable {
    case remountOnMac
    case eject
    case leave
}
