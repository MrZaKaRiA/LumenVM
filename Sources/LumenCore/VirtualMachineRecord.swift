import Foundation

public enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case macOS, ubuntu, debian, arch, voidLinux, abyssLinux, linux, windows, android, chromeOS

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .macOS: return "macOS"
        case .ubuntu: return "Ubuntu"
        case .debian: return "Debian"
        case .arch: return "Arch Linux ARM"
        case .voidLinux: return "Void Linux"
        case .abyssLinux: return "Abyss Linux"
        case .linux: return "Linux"
        case .windows: return "Windows 11 ARM"
        case .android: return "Android"
        case .chromeOS: return "ChromeOS"
        }
    }
    public var subtitle: String {
        switch self {
        case .macOS: return "Apple Silicon · IPSW restore image"
        case .ubuntu, .debian, .linux: return "ARM64 · UEFI installer"
        case .arch: return "Advanced · ARM64 UEFI image required"
        case .voidLinux: return "Advanced · ARM64 UEFI image required"
        case .abyssLinux: return "Void-based · dwm · AArch64 UEFI ISO"
        case .windows: return "QEMU · TPM 2.0 · ARM64 ISO"
        case .android: return "A dedicated emulator backend is needed"
        case .chromeOS: return "No supported generic ARM64 installer"
        }
    }
    public var symbol: String {
        switch self {
        case .macOS: return "apple.logo"
        case .ubuntu: return "sun.max.fill"
        case .debian: return "hurricane"
        case .arch: return "triangle.fill"
        case .voidLinux: return "circle.hexagongrid.fill"
        case .abyssLinux: return "tornado"
        case .linux: return "terminal.fill"
        case .windows: return "square.grid.2x2.fill"
        case .android: return "antenna.radiowaves.left.and.right"
        case .chromeOS: return "globe"
        }
    }
    public var isMacOS: Bool { self == .macOS }
    public var isLinux: Bool { [.ubuntu, .debian, .arch, .voidLinux, .abyssLinux, .linux].contains(self) }
    public var isAvailable: Bool { self != .android && self != .chromeOS }
    public var usesAppleVirtualization: Bool { self != .windows && isAvailable }
    public var minimumMemoryGiB: Int { (self == .macOS || self == .windows) ? 4 : 2 }
    public var minimumDiskGiB: Int { (self == .macOS || self == .windows) ? 64 : 16 }
}

public enum VMRuntimeState: String, Codable {
    case stopped, starting, running, paused, stopping, installing, failed
    public var title: String { rawValue.capitalized }
    public var isActive: Bool { self != .stopped && self != .failed }
}

/// How strictly guest disk flushes are forwarded to the Mac's SSD.
public enum DiskSyncMode: String, Codable, CaseIterable, Identifiable {
    /// fsync: survives app crashes, fast enough for installers. Recommended.
    case balanced
    /// F_FULLFSYNC: survives power loss, but stalls guests during heavy writes (installers freeze).
    case safest
    /// No host flushes. Fastest; a host crash can corrupt the guest disk.
    case fastest

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .safest: return "Maximum safety"
        case .fastest: return "Fastest"
        }
    }
    public var detail: String {
        switch self {
        case .balanced: return "Recommended. Cached writes with disk flushes preserved for fast installation and normal use."
        case .safest: return "Also flushes the SSD hardware cache on every guest sync. Installation can take longer."
        case .fastest: return "No flushes. A Mac crash or power loss may corrupt the guest."
        }
    }
}

public struct VirtualMachineRecord: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var guest: GuestOS
    /// Catalog identifier from `LinuxDistribution.catalog`, when known.
    public var distribution: String?
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var installerPath: String?
    /// A shared, read-only driver disc; never copied into each machine's disk.
    public var windowsDriversPath: String?
    public var sharedDirectoryPath: String?
    public var additionalSharedFolders: [SharedFolder]
    public var sharedFolders: [SharedFolder] {
        get { (sharedDirectoryPath.map { [SharedFolder(path: $0, readOnly: sharedFolderReadOnly)] } ?? []) + additionalSharedFolders }
        set {
            sharedDirectoryPath = newValue.first?.path
            sharedFolderReadOnly = newValue.first?.readOnly ?? false
            additionalSharedFolders = Array(newValue.dropFirst())
        }
    }
    public var sharedFolderReadOnly: Bool
    public var macAddress: String
    public var createdAt: Date
    // Display
    public var displayWidth: Int
    public var displayHeight: Int
    /// When on, the guest display follows the window's pixel size (needs HiDPI scaling in the guest).
    public var autoResizeDisplay: Bool
    // Devices and integration
    public var clipboardSharing: Bool
    public var audioOutput: Bool
    public var microphone: Bool
    public var networkEnabled: Bool
    public var captureSystemKeys: Bool
    public var diskSyncMode: DiskSyncMode
    /// Eject the installer automatically once the guest restarts after installing.
    public var autoEjectInstaller: Bool
    // Windows
    public var windowsTPM: Bool
    public var windowsBypassChecks: Bool
    /// Requests local account creation during a new Windows installation.
    public var windowsLocalAccount: Bool
    public var windowsCompatibilityDisplay: Bool
    public var windowsAutomaticDisplaySetup: Bool
    public var portForwards: [PortForward]
    // Apple Virtualization (Linux guests)
    /// Shares Rosetta with the guest so it can run x86_64 Linux binaries.
    public var linuxRosetta: Bool
    /// Exposes virtualization extensions to the guest (macOS 15+, M3 or later).
    public var nestedVirtualization: Bool

    public init(id: UUID = UUID(), name: String, guest: GuestOS, distribution: String? = nil,
                cpuCount: Int = 4, memoryGiB: Int = 4, diskGiB: Int = 64, installerPath: String? = nil,
                sharedDirectoryPath: String? = nil, sharedFolderReadOnly: Bool = false,
                macAddress: String? = nil, createdAt: Date = Date(),
                displayWidth: Int? = nil, displayHeight: Int? = nil, autoResizeDisplay: Bool? = nil,
                clipboardSharing: Bool = true, audioOutput: Bool = true, microphone: Bool = false,
                networkEnabled: Bool = true, captureSystemKeys: Bool = true,
                diskSyncMode: DiskSyncMode = .balanced, autoEjectInstaller: Bool = true,
                windowsTPM: Bool = true, windowsBypassChecks: Bool = true, windowsDriversPath: String? = nil,
                portForwards: [PortForward] = [], windowsCompatibilityDisplay: Bool? = nil, additionalSharedFolders: [SharedFolder] = [], windowsLocalAccount: Bool = true, windowsAutomaticDisplaySetup: Bool = true,
                linuxRosetta: Bool = false, nestedVirtualization: Bool = false) {
        self.id = id
        self.name = name
        self.guest = guest
        self.distribution = distribution
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.installerPath = installerPath
        self.windowsDriversPath = windowsDriversPath
        self.sharedDirectoryPath = sharedDirectoryPath
        self.sharedFolderReadOnly = sharedFolderReadOnly
        self.additionalSharedFolders = additionalSharedFolders
        self.macAddress = macAddress ?? Self.defaultMACAddress(for: id)
        self.createdAt = createdAt
        let display = Self.defaultDisplay(for: guest)
        self.displayWidth = displayWidth ?? display.width
        self.displayHeight = displayHeight ?? display.height
        self.autoResizeDisplay = autoResizeDisplay ?? true
        self.clipboardSharing = clipboardSharing
        self.audioOutput = audioOutput
        self.microphone = microphone
        self.networkEnabled = networkEnabled
        self.captureSystemKeys = captureSystemKeys
        self.diskSyncMode = diskSyncMode
        self.autoEjectInstaller = autoEjectInstaller
        self.windowsTPM = windowsTPM
        self.windowsBypassChecks = windowsBypassChecks
        self.windowsLocalAccount = windowsLocalAccount
        self.windowsCompatibilityDisplay = windowsCompatibilityDisplay ?? false
        self.windowsAutomaticDisplaySetup = guest == .windows && windowsAutomaticDisplaySetup
        self.portForwards = portForwards
        self.linuxRosetta = linuxRosetta
        self.nestedVirtualization = nestedVirtualization
    }

    /// Machines created by earlier versions only store a subset of these keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let guest = try c.decode(GuestOS.self, forKey: .guest)
        let display = Self.defaultDisplay(for: guest)
        self.id = id
        self.guest = guest
        name = try c.decode(String.self, forKey: .name)
        distribution = try c.decodeIfPresent(String.self, forKey: .distribution)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryGiB = try c.decode(Int.self, forKey: .memoryGiB)
        diskGiB = try c.decode(Int.self, forKey: .diskGiB)
        installerPath = try c.decodeIfPresent(String.self, forKey: .installerPath)
        windowsDriversPath = try c.decodeIfPresent(String.self, forKey: .windowsDriversPath)
        sharedDirectoryPath = try c.decodeIfPresent(String.self, forKey: .sharedDirectoryPath)
        sharedFolderReadOnly = try c.decodeIfPresent(Bool.self, forKey: .sharedFolderReadOnly) ?? false
        additionalSharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .additionalSharedFolders) ?? []
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? Self.defaultMACAddress(for: id)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        displayWidth = try c.decodeIfPresent(Int.self, forKey: .displayWidth) ?? display.width
        displayHeight = try c.decodeIfPresent(Int.self, forKey: .displayHeight) ?? display.height
        autoResizeDisplay = try c.decodeIfPresent(Bool.self, forKey: .autoResizeDisplay) ?? guest.isMacOS
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? true
        audioOutput = try c.decodeIfPresent(Bool.self, forKey: .audioOutput) ?? true
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        captureSystemKeys = try c.decodeIfPresent(Bool.self, forKey: .captureSystemKeys) ?? true
        diskSyncMode = try c.decodeIfPresent(DiskSyncMode.self, forKey: .diskSyncMode) ?? .balanced
        autoEjectInstaller = try c.decodeIfPresent(Bool.self, forKey: .autoEjectInstaller) ?? true
        windowsTPM = try c.decodeIfPresent(Bool.self, forKey: .windowsTPM) ?? true
        windowsBypassChecks = try c.decodeIfPresent(Bool.self, forKey: .windowsBypassChecks) ?? true
        windowsLocalAccount = try c.decodeIfPresent(Bool.self, forKey: .windowsLocalAccount) ?? false
        // Older Windows disks may have no display driver. Keep them visible for driver staging.
        windowsCompatibilityDisplay = try c.decodeIfPresent(Bool.self, forKey: .windowsCompatibilityDisplay) ?? (guest == .windows)
        windowsAutomaticDisplaySetup = try c.decodeIfPresent(Bool.self, forKey: .windowsAutomaticDisplaySetup) ?? false
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        linuxRosetta = try c.decodeIfPresent(Bool.self, forKey: .linuxRosetta) ?? false
        nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
    }

    public static func defaultMACAddress(for id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return ([UInt8(0x02)] + bytes.prefix(5)).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func defaultDisplay(for guest: GuestOS) -> (width: Int, height: Int) {
        switch guest {
        case .macOS: return (2560, 1600)   // 1280×800 points at 2×: crisp and readable.
        case .windows: return (2560, 1600) // 1280×800 points on a Retina screen; needs ARM64 display drivers.
        default: return (1920, 1200)
        }
    }

    /// Human name of the operating system, including the Linux distribution when known.
    public var operatingSystemName: String {
        if let distribution, let entry = LinuxDistribution.entry(id: distribution) { return entry.name }
        return guest.title
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else {
            throw LibraryError.invalidConfiguration("Choose a name between 1 and 100 characters.")
        }
        guard guest.isAvailable else { throw LibraryError.invalidConfiguration("\(guest.title) does not have a supported runtime yet.") }
        guard (1...128).contains(cpuCount), (1...512).contains(memoryGiB), (8...8192).contains(diskGiB) else {
            throw LibraryError.invalidConfiguration("Choose 1–128 CPUs, 1–512 GiB of memory and 8–8192 GiB of disk capacity.")
        }
        guard (640...7680).contains(displayWidth), (480...4320).contains(displayHeight) else {
            throw LibraryError.invalidConfiguration("Choose a display between 640×480 and 7680×4320.")
        }
        if let path = windowsDriversPath, URL(fileURLWithPath: path).pathExtension.lowercased() != "iso" {
            throw LibraryError.invalidConfiguration("Choose a VirtIO Windows driver disc in .iso format.")
        }
        guard portForwards.count <= 16, portForwards.isEmpty || guest == .windows else {
            throw LibraryError.invalidConfiguration("Up to 16 port forwarding rules are supported for Windows QEMU guests.")
        }
        guard sharedFolders.count <= 32, Set(sharedFolders.map(\.path)).count == sharedFolders.count,
              sharedFolders.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else {
            throw LibraryError.invalidConfiguration("Choose up to 32 distinct folders with valid absolute paths.")
        }
        var endpoints: Set<String> = []
        for rule in portForwards {
            try rule.validate()
            guard endpoints.insert("\(rule.transport.rawValue):\(rule.hostPort)").inserted else {
                throw LibraryError.invalidConfiguration("Two forwarding rules cannot listen on the same host port and protocol.")
            }
        }
        if let path = installerPath {
            let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if InstallerDetector.architecture(fromText: filename) == .x86_64 {
                throw LibraryError.invalidConfiguration("This looks like an Intel installer. Choose an ARM64 / aarch64 image for Apple Silicon.")
            }
            if guest.isMacOS && !filename.hasSuffix(".ipsw") {
                throw LibraryError.invalidConfiguration("macOS installation requires an Apple Silicon .ipsw restore image.")
            }
        }
    }
}

public struct VMLocation {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var disk: URL { directory.appendingPathComponent("Disk.img") }
    public var configuration: URL { directory.appendingPathComponent("Machine.json") }
    public var efi: URL { directory.appendingPathComponent("EFI.nvram") }
    public var hardwareModel: URL { directory.appendingPathComponent("HardwareModel.bin") }
    public var machineIdentifier: URL { directory.appendingPathComponent("MachineIdentifier.bin") }
    public var auxiliaryStorage: URL { directory.appendingPathComponent("AuxiliaryStorage.bin") }
    public var installedMarker: URL { directory.appendingPathComponent("Installed") }
    public var tpmState: URL { directory.appendingPathComponent("TPM", isDirectory: true) }
    public var windowsSetupMedia: URL { directory.appendingPathComponent("LumenSetup.iso") }
}

public enum LibraryError: LocalizedError {
    case invalidConfiguration(String)
    case diskCreation(String)
    case missingMachine
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .diskCreation(let message): return message
        case .missingMachine: return "This virtual machine could not be found in the library."
        }
    }
}
