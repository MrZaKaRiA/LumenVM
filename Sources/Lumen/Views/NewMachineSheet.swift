import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumenCore

struct NewMachineSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

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
    @State private var sharedDirectoryURL: URL?
    @State private var sharedFolderReadOnly = false

    // Per-machine display and device settings
    @State private var displayResolutionIndex = 0
    @State private var displayWidth = 1920
    @State private var displayHeight = 1200
    @State private var autoResizeDisplay = false
    @State private var clipboardSharing = true
    @State private var audioOutput = true
    @State private var microphone = false
    @State private var networkEnabled = true
    @State private var captureSystemKeys = true
    @State private var diskSyncMode: DiskSyncMode = .balanced
    @State private var windowsTPM = true
    @State private var windowsBypassChecks = true

    @State private var activeTab = 0
    @State private var errorMessage: String?
    @State private var creating = false
    private let editingMachine: VirtualMachineRecord?

    private static let resolutions: [(title: String, width: Int, height: Int)] = [
        ("1920 × 1200 (16:10 standard)", 1920, 1200),
        ("1920 × 1080 (16:9 full HD)", 1920, 1080),
        ("2560 × 1600 (16:10 Retina)", 2560, 1600),
        ("2560 × 1440 (16:9 QHD)", 2560, 1440),
        ("1280 × 800 (Compact)", 1280, 800),
        ("3840 × 2160 (4K UHD)", 3840, 2160)
    ]

    init(machine: VirtualMachineRecord? = nil) {
        editingMachine = machine
        let guest = machine?.guest ?? .ubuntu
        _selectedGuest = State(initialValue: guest)
        _selectedDistro = State(initialValue: machine?.distribution.flatMap { LinuxDistribution.entry(id: $0) })
        _configuring = State(initialValue: machine != nil)
        _name = State(initialValue: machine?.name ?? "Ubuntu")
        _cpuCount = State(initialValue: machine?.cpuCount ?? 4)
        _memoryGiB = State(initialValue: machine?.memoryGiB ?? 8)
        _diskGiB = State(initialValue: machine?.diskGiB ?? 64)
        _installerURL = State(initialValue: machine?.installerPath.map { URL(fileURLWithPath: $0) })
        _sharedDirectoryURL = State(initialValue: machine?.sharedDirectoryPath.map { URL(fileURLWithPath: $0) })
        _sharedFolderReadOnly = State(initialValue: machine?.sharedFolderReadOnly ?? false)

        let initialWidth = machine?.displayWidth ?? 1920
        let initialHeight = machine?.displayHeight ?? 1200
        _displayWidth = State(initialValue: initialWidth)
        _displayHeight = State(initialValue: initialHeight)
        let matchIndex = Self.resolutions.firstIndex { $0.width == initialWidth && $0.height == initialHeight } ?? 0
        _displayResolutionIndex = State(initialValue: matchIndex)
        _autoResizeDisplay = State(initialValue: machine?.autoResizeDisplay ?? (guest == .macOS))
        _clipboardSharing = State(initialValue: machine?.clipboardSharing ?? true)
        _audioOutput = State(initialValue: machine?.audioOutput ?? true)
        _microphone = State(initialValue: machine?.microphone ?? false)
        _networkEnabled = State(initialValue: machine?.networkEnabled ?? true)
        _captureSystemKeys = State(initialValue: machine?.captureSystemKeys ?? true)
        _diskSyncMode = State(initialValue: machine?.diskSyncMode ?? .balanced)
        _windowsTPM = State(initialValue: machine?.windowsTPM ?? true)
        _windowsBypassChecks = State(initialValue: machine?.windowsBypassChecks ?? true)
    }

    private var host: HostResources { model.hostResources }
    private var policy: ResourcePolicy { model.resourcePolicy }
    private var cpuLimit: Int { policy.maxCPUsPerMachine(on: host) }
    private var memoryLimit: Int { policy.guestMemoryBudgetGiB(on: host) }
    private var memoryMinimum: Int { selectedGuest.minimumMemoryGiB }
    private var diskMinimum: Int { editingMachine?.diskGiB ?? selectedGuest.minimumDiskGiB }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (editingMachine != nil || installerURL != nil)
            && !creating
    }
    private let primaryGuests: [GuestOS] = [.ubuntu, .macOS, .windows, .debian, .arch, .linux]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 20)

            if configuring {
                configurationView
            } else {
                osSelectionView
            }

            Spacer(minLength: 12)
            Divider().overlay(LumenStyle.line)
                .padding(.vertical, 14)
            footer
        }
        .padding(26)
        .frame(minWidth: 860, idealWidth: 890, minHeight: 700, idealHeight: 730)
        .background { LumenBackground() }
        .preferredColorScheme(.dark)
        .alert(editingMachine == nil ? "Could not create machine" : "Could not save changes",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear {
            if let path = installerURL?.path {
                detectedInstaller = InstallerDetector.detect(url: URL(fileURLWithPath: path))
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

    // MARK: - Operating System Selection

    private var osSelectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Select Operating System")
                    .font(.system(size: 26, weight: .medium)).tracking(-0.8)
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
                        if guest != .ubuntu && guest != .debian && guest != .linux {
                            selectedDistro = nil
                        }
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
                        Text(detected.isCompatible ? "Compatible with Apple Silicon" : "Intel image (not supported)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(detected.isCompatible ? LumenStyle.mint : .red)
                    }
                    if let label = detected.volumeLabel {
                        Text("Volume: \(label)").font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                    }
                } else {
                    Text("Select an installer (.iso or .ipsw) to automatically detect it")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Supported: ARM64/AArch64 Linux ISOs, Windows 11 ARM64 ISO, Apple Silicon macOS IPSWs")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
            }
            Spacer()
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
                            Button {
                                NSWorkspace.shared.open(distro.downloadURL)
                            } label: {
                                Label("Get ISO", systemImage: "arrow.down.circle")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(LumenStyle.mint)
                            .help("Open official download page: \(distro.downloadURL.absoluteString)")

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
            .frame(minHeight: 280, maxHeight: 360)
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
                Text("Windows 11 ARM64 Integration Ready")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Lumen automatically prepares setup media with TPM 2.0 and Secure Boot compatibility settings (LabConfig autounattend) so Windows 11 installs smoothly without the requirement wall.")
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
            HStack(spacing: 14) {
                GuestBadge(guest: selectedGuest, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(editingMachine == nil ? "Configure \(selectedDistro?.name ?? selectedGuest.title)" : "Settings for \(name)")
                        .font(.system(size: 22, weight: .medium)).tracking(-0.6)
                    Text(editingMachine == nil ? "Adjust resources, display resolution and folder sharing before creation." : "Changes apply when the virtual machine starts.")
                        .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary)
                }
                Spacer()
                // Configuration Tabs
                Picker("", selection: $activeTab) {
                    Text("Hardware & Display").tag(0)
                    Text("Sharing & Devices").tag(1)
                    Text("Storage & System").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
            }

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
                .padding(.top, 4)
            }
            .frame(maxHeight: 460)
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

            // Resources Sliders
            VStack(alignment: .leading, spacing: 14) {
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
                }

                Picker("Resolution Preset", selection: $displayResolutionIndex) {
                    ForEach(0..<Self.resolutions.count, id: \.self) { i in
                        Text(Self.resolutions[i].title).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: displayResolutionIndex) { _, newIndex in
                    displayWidth = Self.resolutions[newIndex].width
                    displayHeight = Self.resolutions[newIndex].height
                }

                Text(autoResizeDisplay ?
                     "The guest desktop dynamically reconfigures as you resize its window." :
                     "The guest renders at a fixed resolution (\(displayWidth)×\(displayHeight)) with integer aspect ratio, preventing tiny UI text.")
                    .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
        }
    }

    private var sharingAndDevicesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Shared Folder Section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TinyLabel(text: "SHARED FOLDER BETWEEN MAC & VM")
                    Spacer()
                    if sharedDirectoryURL != nil {
                        Toggle("Read Only", isOn: $sharedFolderReadOnly)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                    }
                }

                Button(action: chooseSharedFolder) {
                    HStack {
                        Image(systemName: sharedDirectoryURL == nil ? "folder.badge.plus" : "folder.fill")
                            .foregroundStyle(sharedDirectoryURL == nil ? .secondary : LumenStyle.mint)
                        Text(sharedDirectoryURL?.path ?? "Choose a folder on your Mac to share…")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                }
                .buttonStyle(.plain)

                if sharedDirectoryURL != nil {
                    Button("Remove shared folder") { sharedDirectoryURL = nil }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(LumenStyle.secondary)
                }

                Text(selectedGuest.isMacOS ?
                     "macOS guests automatically mount this folder in Finder." :
                     selectedGuest.isLinux ?
                     "VirtIO-FS shared folder. In Linux, mount it via: sudo mount -t virtiofs lumen /mnt/lumen" :
                     "Windows connects to your Mac via local network file sharing (Z: drive script is placed on desktop).")
                    .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary).lineSpacing(3)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

            // Devices & Integration toggles
            VStack(alignment: .leading, spacing: 12) {
                TinyLabel(text: "INPUT & DEVICE INTEGRATION")

                Toggle("Shared Clipboard (Copy & Paste between Mac and VM)", isOn: $clipboardSharing)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle("Virtual Network & Internet (NAT shared connection)", isOn: $networkEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle("Audio Output (Guest sound to Mac speakers)", isOn: $audioOutput)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle("Microphone Input", isOn: $microphone)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Toggle("Forward System Keys (Cmd, Tab, Mission Control)", isOn: $captureSystemKeys)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            .padding(16)
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
                       in: Double(diskMinimum)...1024, step: 16)
                    .tint(LumenStyle.mint)

                Text(editingMachine == nil ?
                     "No space is reserved upfront. The disk file starts small and grows as your guest writes files, up to this capacity." :
                     "You can grow this disk anytime. Shrinking is disabled to protect guest data.")
                    .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

            // Installer Selection
            VStack(alignment: .leading, spacing: 10) {
                TinyLabel(text: selectedGuest == .macOS ? "RESTORE IMAGE (IPSW)" : "INSTALLER IMAGE (ISO)")

                Button(action: chooseInstaller) {
                    HStack(spacing: 10) {
                        Image(systemName: installerURL == nil ? "opticaldisc" : "checkmark.circle.fill")
                            .foregroundStyle(installerURL == nil ? .secondary : LumenStyle.mint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(installerURL?.lastPathComponent ?? (selectedGuest == .macOS ? "Select Apple Silicon .ipsw…" : "Select ARM64 .iso…"))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            if let detected = detectedInstaller {
                                Text(detected.summary).font(.system(size: 9)).foregroundStyle(LumenStyle.mint)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.doc").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                }
                .buttonStyle(.plain)

                if editingMachine != nil && installerURL != nil {
                    Button("Eject installer image") { installerURL = nil; detectedInstaller = nil }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(LumenStyle.secondary)
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
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))

            // Windows-specific options
            if selectedGuest == .windows {
                VStack(alignment: .leading, spacing: 10) {
                    TinyLabel(text: "WINDOWS 11 COMPATIBILITY SETTINGS")

                    Toggle("Bypass TPM 2.0 & Secure Boot checks during Windows Setup", isOn: $windowsBypassChecks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))

                    Text("Attaches a helper disc with autounattend.xml LabConfig settings so Windows 11 installs on ARM without the requirement wall.")
                        .font(.system(size: 10)).foregroundStyle(LumenStyle.secondary)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.025)))
            }
        }
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
        if panel.runModal() == .OK, let url = panel.url {
            installerURL = url
            let detected = InstallerDetector.detect(url: url)
            detectedInstaller = detected
            if let guest = detected.guest {
                selectedGuest = guest
            }
            if let distro = detected.distribution {
                selectedDistro = distro
            }
            if editingMachine == nil {
                if let distro = detected.distribution {
                    name = distro.name
                } else if let guest = detected.guest {
                    name = guest.title
                }
            }
        }
    }

    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share with this virtual machine"
        panel.prompt = "Share folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { sharedDirectoryURL = panel.url }
    }

    private func saveMachine() {
        guard canCreate else { return }
        creating = true
        do {
            if var machine = editingMachine {
                machine.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                machine.cpuCount = min(cpuCount, cpuLimit)
                machine.memoryGiB = min(memoryGiB, memoryLimit)
                machine.diskGiB = max(machine.diskGiB, diskGiB)
                machine.installerPath = installerURL?.path
                machine.sharedDirectoryPath = sharedDirectoryURL?.path
                machine.sharedFolderReadOnly = sharedFolderReadOnly
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
                try model.update(record: machine)
            } else {
                let record = VirtualMachineRecord(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    guest: selectedGuest,
                    distribution: selectedDistro?.id,
                    cpuCount: min(cpuCount, cpuLimit),
                    memoryGiB: min(memoryGiB, memoryLimit),
                    diskGiB: diskGiB,
                    installerPath: installerURL?.path,
                    sharedDirectoryPath: sharedDirectoryURL?.path,
                    sharedFolderReadOnly: sharedFolderReadOnly,
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
                    windowsBypassChecks: windowsBypassChecks
                )
                try model.create(record)
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
        case .popular: return ["ubuntu", "debian", "fedora", "kali"].contains(distro.id)
        case .server: return !distro.desktop || ["ubuntu-server", "fedora-server", "rocky", "almalinux", "alpine"].contains(distro.id)
        case .security: return ["kali", "parrot"].contains(distro.id)
        case .rolling: return ["arch", "opensuse-tumbleweed", "void", "nixos", "gentoo"].contains(distro.id)
        }
    }
}

