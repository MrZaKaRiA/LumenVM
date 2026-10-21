import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumenCore

struct NewMachineSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var filePanels = FilePanelCoordinator()

    @State private var selectedGuest: GuestOS = .ubuntu
    @State private var selectedDistro: LinuxDistribution?
    @State private var distroSearchText: String = ""
    @State private var selectedDistroCategory: DistroCategory = .all
    @State private var configuring = false
    @State private var name = "Ubuntu"
    @State private var cpuCount = 4
    @State private var memoryGiB = 8
    @State private var diskGiB = 64
    @State private var installerURL: URL?
    @State private var detectedInstaller: DetectedInstaller?
    @State private var sharedFolders: [SharedFolder] = []

    // Per-machine display and device settings
    @State private var displayResolutionIndex = 0
    @State private var displayWidth = 1920
    @State private var displayHeight = 1200
    @State private var autoResizeDisplay = true
    @State private var clipboardSharing = true
    @State private var audioOutput = true
    @State private var microphone = false
    @State private var networkEnabled = true
    @State private var captureSystemKeys = true
    @State private var diskSyncMode: DiskSyncMode = .balanced
    @State private var windowsTPM = true
    @State private var windowsBypassChecks = true
    @State private var windowsLocalAccount = true
    @State private var windowsDriversURL: URL?
    @State private var windowsCompatibilityDisplay = false
    @State private var portForwards: [PortForward] = []

    @State private var activeTab = 0
    @State private var errorMessage: String?
    @State private var creating = false
    @State private var startAfterCreation = true
    /// Set when the user picks another Linux distribution for an existing machine.
    @State private var distributionEdited = false
    private let editingMachine: VirtualMachineRecord?
    private let initialInstaller: URL?

    private static let resolutions: [(title: String, width: Int, height: Int)] = [
        ("1920 × 1200 (16:10 standard)", 1920, 1200),
        ("1920 × 1080 (16:9 full HD)", 1920, 1080),
        ("2560 × 1600 (16:10 Retina)", 2560, 1600),
        ("2560 × 1440 (16:9 QHD)", 2560, 1440),
        ("3024 × 1964 (Retina; choose 200% in guest)", 3024, 1964),
        ("2880 × 1800 (Retina; choose 200% in guest)", 2880, 1800),
        ("1512 × 982 (Compact; choose 100% in guest)", 1512, 982),
        ("1280 × 800 (Compact)", 1280, 800),
        ("3840 × 2160 (4K UHD)", 3840, 2160),
        ("5120 × 2880 (5K)", 5120, 2880)
    ]

    init(machine: VirtualMachineRecord? = nil, installer: URL? = nil) {
        editingMachine = machine
        initialInstaller = installer
        let guest = machine?.guest ?? .ubuntu
        _selectedGuest = State(initialValue: guest)
        _selectedDistro = State(initialValue: machine?.distribution.flatMap { LinuxDistribution.entry(id: $0) })
        _configuring = State(initialValue: machine != nil)
        _name = State(initialValue: machine?.name ?? "Ubuntu")
        _cpuCount = State(initialValue: machine?.cpuCount ?? 4)
        _memoryGiB = State(initialValue: machine?.memoryGiB ?? 8)
        _diskGiB = State(initialValue: machine?.diskGiB ?? 64)
        _installerURL = State(initialValue: installer ?? machine?.installerPath.map { URL(fileURLWithPath: $0) })
        _sharedFolders = State(initialValue: machine?.sharedFolders ?? [])

        let initialWidth = machine?.displayWidth ?? 1920
        let initialHeight = machine?.displayHeight ?? 1200
        _displayWidth = State(initialValue: initialWidth)
        _displayHeight = State(initialValue: initialHeight)
        let matchIndex = Self.resolutions.firstIndex { $0.width == initialWidth && $0.height == initialHeight } ?? 0
        _displayResolutionIndex = State(initialValue: matchIndex)
        _autoResizeDisplay = State(initialValue: machine?.autoResizeDisplay ?? true)
        _clipboardSharing = State(initialValue: machine?.clipboardSharing ?? true)
        _audioOutput = State(initialValue: machine?.audioOutput ?? true)
        _microphone = State(initialValue: machine?.microphone ?? false)
        _networkEnabled = State(initialValue: machine?.networkEnabled ?? true)
        _captureSystemKeys = State(initialValue: machine?.captureSystemKeys ?? true)
        _diskSyncMode = State(initialValue: machine?.diskSyncMode ?? .balanced)
        _windowsTPM = State(initialValue: machine?.windowsTPM ?? true)
        _windowsBypassChecks = State(initialValue: machine?.windowsBypassChecks ?? true)
        _windowsLocalAccount = State(initialValue: machine?.windowsLocalAccount ?? true)
        _windowsDriversURL = State(initialValue: machine?.windowsDriversPath.map { URL(fileURLWithPath: $0) })
        _windowsCompatibilityDisplay = State(initialValue: machine?.windowsCompatibilityDisplay ?? false)
        _portForwards = State(initialValue: machine?.portForwards ?? [])
    }

    private var host: HostResources { model.hostResources }
    private var policy: ResourcePolicy { model.resourcePolicy }
    private var cpuLimit: Int { policy.maxCPUsPerMachine(on: host) }
    private var memoryLimit: Int { policy.guestMemoryBudgetGiB(on: host) }
    private var memoryMinimum: Int { selectedGuest.minimumMemoryGiB }
    private var diskMinimum: Int { editingMachine?.diskGiB ?? selectedGuest.minimumDiskGiB }
    private var creationBlockReason: String? {
        if editingMachine.map({ model.state(for: $0.id).isActive }) == true {
            return "Shut down this machine before saving hardware changes."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give your machine a name." }
        if !(diskMinimum...8192).contains(diskGiB) { return "Choose a disk capacity from \(diskMinimum) to 8192 GiB." }
        if editingMachine == nil && installerURL == nil { return "Choose or drop an installer to create your machine." }
        if let installerURL {
            do { try LocalFileSelection.validateInstaller(installerURL) }
            catch { return error.localizedDescription }
            if detectedInstaller?.architecture == .x86_64 { return "Choose an ARM64 installer for this Apple Silicon Mac." }
            if selectedGuest.isMacOS && installerURL.pathExtension.lowercased() != "ipsw" { return "Choose an Apple Silicon IPSW for macOS." }
            if !selectedGuest.isMacOS && installerURL.pathExtension.lowercased() == "ipsw" { return "IPSW images install macOS. Choose an ARM64 ISO for this guest." }
            if let guest = detectedInstaller?.guest, guest.isMacOS != selectedGuest.isMacOS || (guest == .windows) != (selectedGuest == .windows) {
                return "The selected installer is for \(guest.title). Choose matching media or go back to change the operating system."
            }
        }
        return nil
    }
    private var canCreate: Bool { creationBlockReason == nil && !creating }
    private let primaryGuests: [GuestOS] = [.ubuntu, .macOS, .windows, .debian, .arch, .linux]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)

            if configuring {
                configurationView
            } else {
                osSelectionView
            }

            Divider().overlay(LumenStyle.line)
                .padding(.vertical, 10)
            footer
        }
        .padding(24)
        .frame(width: 840, height: min(700, max(540, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .background { LumenBackground() }
        .background { FilePanelAnchor(coordinator: filePanels) }
        .installerDrop(selected: useInstaller, failed: { errorMessage = $0 })
        .preferredColorScheme(.dark)
        .alert(editingMachine == nil ? "Could not create machine" : "Could not save changes",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear {
            if let initialInstaller { useInstaller(initialInstaller) }
            else if let url = installerURL {
                Task {
                    let detected = await Task.detached(priority: .userInitiated) { InstallerDetector.detect(url: url) }.value
                    if installerURL == url { detectedInstaller = detected }
                }
            }
        }

    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                LumenMark(size: 24)
                TinyLabel(text: editingMachine == nil ? "NEW VIRTUAL MACHINE" : "VM CONFIGURATION")
            }
            Spacer()
            if editingMachine == nil {
                HStack(spacing: 5) {
                    Capsule().fill(configuring ? Color.white.opacity(0.18) : LumenStyle.mint).frame(width: 21, height: 3)
                    Capsule().fill(configuring ? LumenStyle.mint : Color.white.opacity(0.12)).frame(width: 21, height: 3)
                }
                .padding(.trailing, 17)
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if configuring, let reason = creationBlockReason {
                HStack(spacing: 8) {
                    Label(reason, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(LumenStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if installerURL == nil {
                        Button("Choose installer…", action: chooseInstaller).buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                if configuring {
                    if editingMachine != nil {
                        Button("Cancel") { dismiss() }.buttonStyle(CapsuleButtonStyle())
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { configuring = false }
                        } label: { Label("Back", systemImage: "arrow.left") }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(LumenStyle.mint.opacity(0.7)).frame(width: 5, height: 5)
                        Text("Host Mac reserve: \(policy.memoryReserveGiB) GiB memory & \(policy.cpuReserve) core(s) kept for macOS.")
                            .font(.system(size: 11))
                            .foregroundStyle(LumenStyle.secondary)
                    }
                }
                Spacer()
                if configuring {
                    if editingMachine == nil {
                        Toggle("Start after creation", isOn: $startAfterCreation)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .padding(.trailing, 12)
                    }
                    Button(action: saveMachine) {
                        if creating { Label("Saving…", systemImage: "hourglass") }
                        else { Label(editingMachine == nil ? "Create machine" : "Save changes",
                                     systemImage: editingMachine == nil ? "plus" : "checkmark") }
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.38)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        let recommended = policy.recommended(for: selectedGuest, distribution: selectedDistro, on: host)
                        cpuCount = min(recommended.cpus, cpuLimit)
                        memoryGiB = min(recommended.memoryGiB, memoryLimit)
                        if editingMachine == nil {
                            diskGiB = max(recommended.diskGiB, selectedGuest.minimumDiskGiB)
                        }
                        if name.isEmpty || name == "Ubuntu" || name == "Windows 11 ARM" || name == "macOS" {
                            name = selectedDistro?.name ?? selectedGuest.title
                        }
                        withAnimation(.easeInOut(duration: 0.15)) { configuring = true }
                    } label: { Label("Continue to Settings", systemImage: "arrow.right") }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: - Operating System Selection

    private var osSelectionView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select Operating System")
                        .font(.system(size: 24, weight: .medium)).tracking(-0.8)
                    Text("Choose an operating system, or pick a specific Linux distribution below. Drop or select an installer to detect it automatically.")
                        .font(.system(size: 12)).foregroundStyle(LumenStyle.secondary)
                }

                // Quick installer drop / select banner
                installerDetectionBanner

                // Primary OS Cards
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(primaryGuests) { guest in
                        Button {
                            selectedGuest = guest
                            selectedDistro = nil
                            let resolution = VirtualMachineRecord.defaultDisplay(for: guest)
                            displayWidth = resolution.width
                            displayHeight = resolution.height
                            displayResolutionIndex = Self.resolutions.firstIndex { $0.width == displayWidth && $0.height == displayHeight } ?? 0
                        } label: { guestCard(guest) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(guest.title), \(guest.shortDescription)")
                    }
                }

                // Linux Distribution Catalog section
                if selectedGuest.isLinux {
                    distroCatalogSection
                } else if selectedGuest == .windows {
                    windowsGuidanceSection
                } else if selectedGuest == .macOS {
                    macOSGuidanceSection
                }
            }
            .padding(.trailing, 2)
            .padding(.bottom, 6)
        }
    }

    private var installerDetectionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: installerURL == nil ? "opticaldisc" : "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(detectedInstaller?.isCompatible == true ? LumenStyle.mint : Color.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 3) {
                if let detected = detectedInstaller {
                    HStack(spacing: 8) {
                        Text(detected.summary)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(detected.architecture == .unknown ? "Architecture not identified" : detected.isCompatible ? "Apple Silicon" : "Intel image (not supported)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(detected.isCompatible ? LumenStyle.mint : .red)
                    }
                    Text(installerURL?.lastPathComponent ?? "")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let label = detected.volumeLabel {
                        Text("Volume: \(label)").font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                    }
                } else {
                    Text("Drop an ISO or IPSW here, or choose an installer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("ARM64 Linux · Windows 11 ARM · Apple Silicon macOS")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
            }
            Spacer()
            if editingMachine != nil, installerURL != nil {
                Button("Eject") {
                    installerURL = nil
                    detectedInstaller = nil
                }
                .buttonStyle(CapsuleButtonStyle())
                .help("Remove the saved installer attachment. Applies on the next start.")
            }
            Button(installerURL == nil ? "Browse…" : "Change…") { chooseInstaller() }
                .buttonStyle(CapsuleButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(detectedInstaller?.isCompatible == true ? LumenStyle.mint.opacity(0.4) : LumenStyle.line, lineWidth: 1) }
    }

    private func guestCard(_ guest: GuestOS) -> some View {
        let isSelected = selectedGuest == guest
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                GuestGlyph(guest: guest, size: 22)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? LumenStyle.mint : Color.white.opacity(0.14))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(guest.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text(guest.shortDescription).font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? LumenStyle.mint.opacity(0.07) : Color.white.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? LumenStyle.mint.opacity(0.55) : LumenStyle.line, lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var distroCatalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Known ARM64 Linux Distributions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Search distributions…", text: $distroSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 160)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            }

            // Category filter pills
            HStack(spacing: 6) {
                ForEach(DistroCategory.allCases) { cat in
                    Button {
                        selectedDistroCategory = cat
                    } label: {
                        Text(cat.rawValue)
                            .font(.system(size: 10, weight: selectedDistroCategory == cat ? .semibold : .regular))
                            .foregroundStyle(selectedDistroCategory == cat ? Color(red: 0.08, green: 0.18, blue: 0.15) : .white.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selectedDistroCategory == cat ? LumenStyle.mint : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredDistros) { distro in
                        let isSelected = selectedDistro?.id == distro.id
                        HStack(spacing: 12) {
                            GuestBadge(guest: distro.family, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(distro.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                    distroSupportBadge(distro.support)
                                }
                                Text(distro.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumenStyle.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let downloadURL = distro.downloadURL {
                                Button {
                                    NSWorkspace.shared.open(downloadURL)
                                } label: {
                                    Label("Get ISO", systemImage: "arrow.down.circle")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(LumenStyle.mint)
                                .help("Open official download page: \(downloadURL.absoluteString)")
                            }

                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? LumenStyle.mint : Color.white.opacity(0.2))
                                .font(.system(size: 13))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? LumenStyle.mint.opacity(0.08) : Color.white.opacity(0.02)))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? LumenStyle.mint.opacity(0.4) : Color.clear, lineWidth: 1) }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture {
                            selectedDistro = distro
                            selectedGuest = distro.family
                            name = distro.name
                            let rec = policy.recommended(for: distro.family, distribution: distro, on: host)
                            cpuCount = min(rec.cpus, cpuLimit)
                            memoryGiB = min(rec.memoryGiB, memoryLimit)
                            if editingMachine == nil { diskGiB = max(rec.diskGiB, distro.family.minimumDiskGiB) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180, maxHeight: 220)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.02)))
    }

    private var filteredDistros: [LinuxDistribution] {
        var base = LinuxDistribution.catalog.filter { $0.support != .none }
        if selectedDistroCategory != .all {
            base = base.filter { selectedDistroCategory.matches($0) }
        }
        if !distroSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let query = distroSearchText.lowercased()
            base = base.filter { $0.name.lowercased().contains(query) || $0.summary.lowercased().contains(query) }
        }
        return base
    }

    private func distroSupportBadge(_ support: ARMSupport) -> some View {
        Text(support.title)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(supportColor(support).opacity(0.15)))
            .foregroundStyle(supportColor(support))
    }

    private func supportColor(_ support: ARMSupport) -> Color {
        switch support {
        case .official: return LumenStyle.mint
        case .limited: return Color.orange
        case .none: return Color.red
        }
    }

    private var windowsGuidanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(LumenStyle.mint)
                Text("Windows 11 ARM64 · Experimental")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Runs through QEMU + Apple HVF. Choose ARM64 driver media for network and display support. Optional setup bypasses do not provide Secure Boot or Windows certification.")
                .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary).lineSpacing(3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.025)))
    }

    private var macOSGuidanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "applelogo").foregroundStyle(LumenStyle.mint)
                Text("macOS on Apple Silicon")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    if let url = URL(string: "https://mrmacintosh.com/apple-silicon-m1-full-macos-restore-ipsw-firmware-files-database/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Find macOS IPSWs", systemImage: "arrow.up.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LumenStyle.mint)
            }
            Text("Uses Apple’s native Virtualization framework. Choose a compatible Apple Silicon IPSW restore image. Installation will start automatically on first boot.")
                .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary).lineSpacing(3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.025)))
    }

    // MARK: - Machine Configuration View

    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                GuestBadge(guest: selectedGuest, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(editingMachine == nil ? "Configure \(selectedDistro?.name ?? selectedGuest.title)" : "Settings for \(name)")
                        .font(.system(size: 22, weight: .medium)).tracking(-0.6)
                    Text(editingMachine == nil ? "Adjust resources, display resolution and folder sharing before creation." : model.state(for: editingMachine!.id).isActive ? "Shut down this machine to save hardware changes. You can review its settings now." : "Changes apply when the virtual machine starts.")
                        .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }

            installerDetectionBanner

            Picker("Settings section", selection: $activeTab) {
                Text("Hardware & Display").tag(0)
                Text("Sharing & Devices").tag(1)
                Text("Storage & System").tag(2)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if activeTab == 0 {
                        hardwareAndDisplayTab
                    } else if activeTab == 1 {
                        sharingAndDevicesTab
                    } else {
                        storageAndSystemTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.trailing, 8)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hardwareAndDisplayTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TinyLabel(text: "MACHINE NAME")
                TextField("Name your virtual machine", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(LumenStyle.line, lineWidth: 1) }
            }

            if let editing = editingMachine, editing.guest.isLinux {
                VStack(alignment: .leading, spacing: 8) {
                    TinyLabel(text: "LINUX DISTRIBUTION")
                    HStack(spacing: 10) {
                        GuestGlyph(guest: selectedGuest, size: 18)
                        Picker("Linux distribution", selection: distributionSelection) {
                            ForEach(LinuxDistribution.catalog.filter { $0.family.isLinux }) { distro in
                                Text(distro.name).tag(distro.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    Text("Sets the name, logo and Dock icon Lumen shows for this machine. The virtual disk is not changed.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
            }

            // Resources Sliders
            VStack(alignment: .leading, spacing: 14) {
                if selectedGuest == .windows {
                    HStack {
                        Text("Installation resources").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button("Use recommended") {
                            let values = policy.recommended(for: selectedGuest, on: host)
                            cpuCount = values.cpus
                            memoryGiB = values.memoryGiB
                        }
                        .font(.system(size: 11))
                    }
                }
                resourceSlider(title: "Virtual CPUs", symbol: "cpu", value: $cpuCount,
                               range: 1...Double(max(2, cpuLimit)), suffix: "cores")
                resourceSlider(title: "RAM Memory", symbol: "memorychip", value: $memoryGiB,
                               range: Double(memoryMinimum)...Double(max(memoryMinimum + 1, memoryLimit)), suffix: "GiB")

                HStack(spacing: 6) {
                    Circle().fill(LumenStyle.mint.opacity(0.7)).frame(width: 4, height: 4)
                    Text("Host Mac: \(host.cpuCount) cores · \(host.memoryGiB) GiB RAM · Leaving \(policy.memoryReserveGiB) GiB reserved for host macOS.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

            // Display Resolution Configuration
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TinyLabel(text: "DISPLAY RESOLUTION")
                    Spacer()
                    Toggle("Follow window size (Auto-resize)", isOn: $autoResizeDisplay)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .disabled(selectedGuest == .windows && windowsCompatibilityDisplay)
                }

                if selectedGuest == .windows {
                    Toggle("Compatibility display (800 × 600 recovery mode)", isOn: $windowsCompatibilityDisplay)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                }

                Picker("Resolution Preset", selection: $displayResolutionIndex) {
                    ForEach(0..<Self.resolutions.count, id: \.self) { i in
                        Text(Self.resolutions[i].title).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .disabled(selectedGuest == .windows && windowsCompatibilityDisplay)
                .onChange(of: displayResolutionIndex) { _, newIndex in
                    displayWidth = Self.resolutions[newIndex].width
                    displayHeight = Self.resolutions[newIndex].height
                }

                Text(selectedGuest == .windows && windowsCompatibilityDisplay ?
                     "Recovery mode stays at 800 × 600 and disables automatic resizing. Turn it off to use the bundled VirtIO display driver and Retina resolution." : selectedGuest == .windows ?
                     autoResizeDisplay ? "Setup installs ARM64 drivers, then Lumen restarts Windows with VirtIO graphics. The preset is the initial target; after setup the display follows the window’s pixel size. Choose 200% scaling inside Windows for readable Retina text. This backend provides 2D graphics." : "Setup installs ARM64 drivers, then Lumen restarts Windows with VirtIO graphics at the selected pixel resolution. Choose 200% scaling inside Windows for Retina presets, or 100% for compact presets. This backend provides 2D graphics." :
                     autoResizeDisplay ? "The guest follows the window’s pixel size when its display driver supports resizing. Use guest display scaling for readable Retina text." :
                     "The guest keeps its configured pixel resolution. Adjust desktop scaling inside the guest for readable text.")
                    .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
        }
    }

    private var sharingAndDevicesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if selectedGuest == .windows {
                portForwardingSection
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TinyLabel(text: "SHARED FOLDERS")
                    Spacer()
                    Button("Add folders…", action: chooseSharedFolder)
                        .buttonStyle(CapsuleButtonStyle()).disabled(sharedFolders.count >= 32)
                }
                if sharedFolders.isEmpty {
                    Button(action: chooseSharedFolder) {
                        Label("Choose folders on your Mac to share…", systemImage: "folder.badge.plus")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                ForEach($sharedFolders) { $folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(LumenStyle.mint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                            Text(folder.path).font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Toggle("Read only", isOn: $folder.readOnly).toggleStyle(.checkbox).font(.system(size: 11))
                        Button {
                            sharedFolders.removeAll { $0.id == folder.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove shared folder")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                }
                Text(selectedGuest.isMacOS ?
                     "Shared folders appear automatically in Finder. Read-only folders cannot be changed by the guest." : selectedGuest.isLinux ?
                     "In Linux, run: sudo mkdir -p /mnt/lumen && sudo mount -t virtiofs lumen /mnt/lumen. With multiple folders, each appears inside this mount." :
                     "Lumen provides a private connection to these folders. Mac File Sharing and your Mac password are not required. Install Lumen Tools once in an existing Windows guest; new installations set them up automatically. Folders connect when you sign in to Windows.")
                    .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary).fixedSize(horizontal: false, vertical: true)
                if selectedGuest == .windows, !networkEnabled, !sharedFolders.isEmpty {
                    Text("Enable Virtual Network below to use shared folders.").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
            .sharedFolderDrop(selected: useSharedFolder, installer: useInstaller, failed: { errorMessage = $0 })

            // Devices & Integration toggles
            VStack(alignment: .leading, spacing: 12) {
                TinyLabel(text: "INPUT & DEVICE INTEGRATION")

                if selectedGuest.isLinux || selectedGuest == .windows {
                    Toggle("Shared Clipboard (Copy & Paste between Mac and VM)", isOn: $clipboardSharing)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    if selectedGuest == .windows {
                        Text("Text copy and paste uses Lumen Guest Tools over a private VirtIO channel. New installations install the agent automatically; existing guests need Install / Repair Guest Tools once. Restart the VM after changing this setting.")
                            .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                    }
                } else {
                    Text("Clipboard integration for this guest requires additional guest tools and is not implemented.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }

                Toggle("Virtual Network & Internet (NAT shared connection)", isOn: $networkEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle("Audio Output (Guest sound to Mac speakers)", isOn: $audioOutput)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle("Microphone Input", isOn: $microphone)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle(selectedGuest == .windows ? "Forward left Command key to Windows" : "Forward System Keys (Cmd, Tab, Mission Control)", isOn: $captureSystemKeys)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
        }
    }

    private var storageAndSystemTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Disk Capacity with Growth Support
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "internaldrive").foregroundStyle(LumenStyle.mint)
                    Text("Maximum Disk Capacity: \(diskGiB) GiB")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    TinyLabel(text: "SPARSE DISK · NO ADVANCE RESERVATION", color: LumenStyle.mint)
                }

                Slider(value: Binding(get: { Double(diskGiB) }, set: { diskGiB = Int($0) }),
                       in: Double(diskMinimum)...Double(max(1024, diskGiB)), step: 1)
                    .tint(LumenStyle.mint)

                HStack {
                    Text("\(diskMinimum) GiB minimum")
                    Spacer()
                    TextField("Capacity", value: $diskGiB, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("GiB capacity")
                }
                .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary)

                Text(editingMachine == nil ?
                     "No space is reserved upfront. The disk file starts small and grows as your guest writes files, up to this capacity." :
                     "You can grow this disk anytime. Shrinking is disabled to protect guest data.")
                    .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                if selectedGuest == .windows && editingMachine == nil {
                    Text("Windows 11 requires a 64 GB or larger disk. This capacity is available to Windows; it does not reserve 64 GiB on your SSD.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.mint)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

            // Disk Sync & Stability
            VStack(alignment: .leading, spacing: 10) {
                TinyLabel(text: "DISK FLUSH & INSTALLER STABILITY")
                Picker("Disk Sync Mode", selection: $diskSyncMode) {
                    ForEach(DiskSyncMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(diskSyncMode.detail)
                    .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

            // Windows-specific options
            if selectedGuest == .windows {
                VStack(alignment: .leading, spacing: 10) {
                    TinyLabel(text: "WINDOWS 11 COMPATIBILITY SETTINGS")

                    Toggle("Bypass TPM 2.0 & Secure Boot checks during Windows Setup", isOn: $windowsBypassChecks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))

                    Toggle("Use a local Windows account during installation", isOn: $windowsLocalAccount)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    Text("Requests local account setup for a new installation. Choose your username and password inside Windows. This does not change an existing account.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)

                    Toggle("TPM 2.0 (requires swtpm)", isOn: $windowsTPM)
                        .toggleStyle(.checkbox).font(.system(size: 11))

                    Text("TPM keys persist with the VM. Turning TPM off can prevent BitLocker or Windows Hello from unlocking. Secure Boot is not provided by the standard QEMU ARM firmware.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)

                    Text("Attaches a helper disc with autounattend.xml LabConfig settings so Windows 11 installs on ARM without the requirement wall.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

                VStack(alignment: .leading, spacing: 10) {
                    TinyLabel(text: "WINDOWS ARM64 GUEST DRIVERS")
                    HStack {
                        Image(systemName: "opticaldisc").foregroundStyle(LumenStyle.mint)
                        Text(windowsDriversURL?.lastPathComponent ?? QEMUVirtualMachine.defaultDriversURL?.lastPathComponent ?? "No driver disc selected")
                            .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose ISO…", action: chooseWindowsDrivers).buttonStyle(CapsuleButtonStyle())
                    }
                    HStack {
                        if windowsDriversURL != nil {
                            Button("Use bundled drivers") { windowsDriversURL = nil }.buttonStyle(.borderless)
                        }
                        Link("Official VirtIO downloads", destination: URL(string: "https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md")!)
                    }.font(.system(size: 10))
                    Text("The disc is attached read-only. Setup installs ARM64 network, display and device drivers automatically. For an existing Windows VM, run install-drivers.cmd as administrator from the LUMENSETUP disc, then restart Windows. Signing is enforced by Windows; no test mode is enabled.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
            }
        }
    }

    private var portForwardingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TinyLabel(text: "PORT FORWARDING")
                Spacer()
                Button("Add rule") { portForwards.append(PortForward(hostPort: 8080 + portForwards.count)) }
                    .buttonStyle(.borderless).disabled(portForwards.count >= 16)
            }
            ForEach($portForwards) { $rule in
                HStack(spacing: 10) {
                    Picker("Protocol", selection: $rule.transport) {
                        ForEach(PortForward.Transport.allCases, id: \.self) { value in
                            Text(value.rawValue.uppercased()).tag(value)
                        }
                    }.frame(width: 110)
                    Text("Mac localhost:")
                    TextField("8080", value: $rule.hostPort, format: .number.grouping(.never)).frame(width: 70)
                    Image(systemName: "arrow.right")
                    Text("Guest:")
                    TextField("80", value: $rule.guestPort, format: .number.grouping(.never)).frame(width: 70)
                    Spacer()
                    Button { portForwards.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }.font(.system(size: 11))
            }
            Text("Reach guest services through 127.0.0.1 on your Mac. Windows needs its network driver and firewall permission for the guest port. Changes apply on the next start.")
                .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
        .disabled(!networkEnabled)
    }

    private func resourceSlider(title: String, symbol: String, value: Binding<Int>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.white.opacity(0.4))
                Text(title).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(value.wrappedValue) \(suffix)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
            }
            .font(.system(size: 11))
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), in: range, step: 1)
                .tint(LumenStyle.mint)
                .controlSize(.small)
        }
    }

    /// Catalog entry shown for an existing Linux machine that predates per-distribution records.
    private var distributionSelection: Binding<String> {
        Binding(
            get: {
                if let id = selectedDistro?.id { return id }
                switch selectedGuest {
                case .ubuntu: return "ubuntu"
                case .debian: return "debian"
                case .arch: return "arch"
                case .voidLinux: return "void"
                case .abyssLinux: return "abyss"
                default: return "other"
                }
            },
            set: { id in
                if let distro = LinuxDistribution.entry(id: id) { selectDistribution(distro) }
            }
        )
    }

    private func selectDistribution(_ distro: LinuxDistribution) {
        let previousName = selectedDistro?.name ?? selectedGuest.title
        selectedDistro = distro
        selectedGuest = distro.family
        distributionEdited = true
        // Follow the OS in the machine name unless the user chose their own.
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name == previousName { name = distro.name }
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.title = selectedGuest == .macOS ? "Choose a macOS restore image" : "Choose an ARM64 installer"
        panel.prompt = "Use image"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "iso") ?? .data,
            UTType(filenameExtension: "ipsw") ?? .data,
            UTType(filenameExtension: "img") ?? .data
        ]
        filePanels.present(panel, selected: useInstaller)
    }

    private func useInstaller(_ url: URL) {
        do {
            try LocalFileSelection.validateInstaller(url)
        } catch { errorMessage = error.localizedDescription; return }
        let previousName = selectedDistro?.name ?? selectedGuest.title
        installerURL = url
        Task {
            // Reading ISO sectors can block on slow or network volumes; keep it off the main thread.
            let detected = await Task.detached(priority: .userInitiated) { InstallerDetector.detect(url: url) }.value
            guard installerURL == url else { return }
            applyDetectedInstaller(detected, previousName: previousName)
        }
    }

    private func applyDetectedInstaller(_ detected: DetectedInstaller, previousName: String) {
        do {
            detectedInstaller = detected
            if editingMachine == nil, let guest = detected.guest {
                selectedGuest = guest
                let resolution = VirtualMachineRecord.defaultDisplay(for: guest)
                displayWidth = resolution.width
                displayHeight = resolution.height
                displayResolutionIndex = Self.resolutions.firstIndex { $0.width == displayWidth && $0.height == displayHeight } ?? 0
            }
            if let editing = editingMachine {
                // An existing Linux machine adopts a recognized Linux distribution (e.g. Void → Abyss).
                if let distro = detected.distribution, editing.guest.isLinux, distro.family.isLinux,
                   distro.id != selectedDistro?.id {
                    selectDistribution(distro)
                }
            } else {
                selectedDistro = detected.distribution
            }
            memoryGiB = max(memoryGiB, memoryMinimum)
            diskGiB = max(diskGiB, diskMinimum)
            if editingMachine == nil && (name == previousName || name.isEmpty) {
                if let distro = detected.distribution {
                    name = distro.name
                } else if let guest = detected.guest {
                    name = guest.title
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders to share with this virtual machine"
        panel.prompt = "Share folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        filePanels.presentMultiple(panel) { urls in
            for url in urls { useSharedFolder(url) }
        }
    }

    private func useSharedFolder(_ url: URL) {
        do {
            try LocalFileSelection.validateFolder(url)
            let folder = SharedFolder(path: url.resolvingSymlinksInPath().path)
            guard !sharedFolders.contains(where: { $0.path == folder.path }) else { return }
            guard sharedFolders.count < 32 else { throw LibraryError.invalidConfiguration("Choose up to 32 shared folders.") }
            sharedFolders.append(folder)
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseWindowsDrivers() {
        let panel = NSOpenPanel()
        panel.title = "Choose an ARM64 VirtIO Windows driver disc"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        filePanels.present(panel) { windowsDriversURL = $0 }
    }

    private func saveMachine() {
        guard canCreate else { return }
        creating = true
        Task { await performSave() }
    }

    private func performSave() async {
        do {
            if var machine = editingMachine {
                machine.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                machine.cpuCount = min(cpuCount, cpuLimit)
                machine.memoryGiB = min(memoryGiB, memoryLimit)
                machine.diskGiB = max(machine.diskGiB, diskGiB)
                machine.installerPath = installerURL?.path
                machine.sharedFolders = sharedFolders
                machine.displayWidth = displayWidth
                machine.displayHeight = displayHeight
                machine.autoResizeDisplay = autoResizeDisplay
                machine.clipboardSharing = clipboardSharing
                machine.audioOutput = audioOutput
                machine.microphone = microphone
                machine.networkEnabled = networkEnabled
                machine.captureSystemKeys = captureSystemKeys
                machine.diskSyncMode = diskSyncMode
                machine.windowsTPM = windowsTPM
                machine.windowsBypassChecks = windowsBypassChecks
                machine.windowsLocalAccount = windowsLocalAccount
                machine.windowsDriversPath = windowsDriversURL?.path
                machine.windowsCompatibilityDisplay = windowsCompatibilityDisplay
                machine.portForwards = portForwards
                if distributionEdited, machine.guest.isLinux, let distro = selectedDistro {
                    machine.guest = distro.family
                    machine.distribution = distro.id
                }
                try await model.update(record: machine)
            } else {
                let record = VirtualMachineRecord(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    guest: selectedGuest,
                    distribution: selectedDistro?.id,
                    cpuCount: min(cpuCount, cpuLimit),
                    memoryGiB: min(memoryGiB, memoryLimit),
                    diskGiB: diskGiB,
                    installerPath: installerURL?.path,
                    sharedDirectoryPath: sharedFolders.first?.path,
                    sharedFolderReadOnly: sharedFolders.first?.readOnly ?? false,
                    displayWidth: displayWidth,
                    displayHeight: displayHeight,
                    autoResizeDisplay: autoResizeDisplay,
                    clipboardSharing: clipboardSharing,
                    audioOutput: audioOutput,
                    microphone: microphone,
                    networkEnabled: networkEnabled,
                    captureSystemKeys: captureSystemKeys,
                    diskSyncMode: diskSyncMode,
                    windowsTPM: windowsTPM,
                    windowsBypassChecks: windowsBypassChecks,
                    windowsDriversPath: windowsDriversURL?.path,
                    portForwards: selectedGuest == .windows ? portForwards : [],
                    windowsCompatibilityDisplay: windowsCompatibilityDisplay,
                    additionalSharedFolders: Array(sharedFolders.dropFirst()),
                    windowsLocalAccount: windowsLocalAccount
                )
                try await model.create(record)
                if startAfterCreation { DispatchQueue.main.async { model.start(record) } }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            creating = false
        }
    }
}

enum DistroCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case popular = "Popular"
    case server = "Server"
    case security = "Security"
    case rolling = "Rolling"

    var id: String { rawValue }

    func matches(_ distro: LinuxDistribution) -> Bool {
        switch self {
        case .all: return true
        case .popular: return ["abyss", "ubuntu", "debian", "fedora", "kali"].contains(distro.id)
        case .server: return !distro.desktop || ["ubuntu-server", "fedora-server", "rocky", "almalinux", "alpine"].contains(distro.id)
        case .security: return ["kali", "parrot"].contains(distro.id)
        case .rolling: return ["abyss", "arch", "opensuse-tumbleweed", "void", "nixos", "gentoo"].contains(distro.id)
        }
    }
}

