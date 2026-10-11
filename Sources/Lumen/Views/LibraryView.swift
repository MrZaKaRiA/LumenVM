import SwiftUI
import AppKit
import LumenCore

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var showingNewMachine = false
    @State private var showingCompatibility = false
    @State private var machineToRemove: VirtualMachineRecord?
    @State private var machineToForceStop: VirtualMachineRecord?
    @State private var machineToEdit: VirtualMachineRecord?

    private var allocatedBytes: Int64 {
        model.machines.reduce(0) { $0 + model.allocatedBytes(for: $1.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .firstTextBaseline) {
                Text("Your machines")
                    .font(.system(size: 24, weight: .medium))
                    .tracking(-0.6)
                if !model.machines.isEmpty {
                    Text(String(model.machines.count))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LumenStyle.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                }
                Spacer()
                TinyLabel(text: "A SPACE FOR EVERY OS")
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 22)

            if model.machines.isEmpty {
                EmptyLibraryView { showingNewMachine = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.machines) { machine in
                            MachineRow(machine: machine, onRemove: { machineToRemove = machine }, onForceStop: { machineToForceStop = machine }, onEdit: { machineToEdit = machine })
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 2)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
            }

            footer
        }
        .background { LumenBackground() }
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 620)
        .sheet(isPresented: $showingNewMachine) { NewMachineSheet().environmentObject(model) }
        .sheet(isPresented: $showingCompatibility) { CompatibilitySheet() }
        .sheet(item: $machineToEdit) { machine in NewMachineSheet(machine: machine).environmentObject(model) }
        .alert("Something needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Move \(machineToRemove?.name ?? "this machine") to Trash?", isPresented: Binding(get: { machineToRemove != nil }, set: { if !$0 { machineToRemove = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let machine = machineToRemove else { return }
                do { try model.remove(machine) } catch { model.errorMessage = error.localizedDescription }
                machineToRemove = nil
            }
            Button("Cancel", role: .cancel) { machineToRemove = nil }
        } message: {
            Text("This moves the virtual machine and its disk to the Trash. Your original installer is kept.")
        }
        .confirmationDialog("Force stop \(machineToForceStop?.name ?? "this machine")?", isPresented: Binding(get: { machineToForceStop != nil }, set: { if !$0 { machineToForceStop = nil } }), titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) {
                if let machine = machineToForceStop { model.forceStop(machine) }
                machineToForceStop = nil
            }
            Button("Cancel", role: .cancel) { machineToForceStop = nil }
        } message: {
            Text("Unsaved work in the guest will be lost. Shut down from inside the guest when possible.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMachineRequested)) { _ in showingNewMachine = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            LumenMark(size: 27)
            Text("LUMEN")
                .font(.system(size: 12, weight: .semibold))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.9))
            Rectangle().fill(LumenStyle.line).frame(width: 1, height: 15).padding(.horizontal, 6)
            Text(model.isDemo ? "Visual preview" : "Virtual worlds. Naturally.")
                .font(.system(size: 11))
                .foregroundStyle(LumenStyle.secondary)
            Spacer()
            if model.hasActiveMachines {
                Button("Stop All", systemImage: "stop.fill") { model.stopAll() }
                    .buttonStyle(CapsuleButtonStyle())
            } else if !model.machines.isEmpty {
                Button("Start All", systemImage: "play.fill") { model.startAll() }
                    .buttonStyle(CapsuleButtonStyle())
            }
            Menu {
                if !model.machines.isEmpty {
                    Button("Start all virtual machines", systemImage: "play.circle") { model.startAll() }
                    Button("Stop all virtual machines", systemImage: "power") { model.stopAll() }
                    Divider()
                }
                Button("Open library in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(model.libraryURL)
                }
                Button("Guest compatibility", systemImage: "info.circle") { showingCompatibility = true }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 35, height: 35)
                    .background(Circle().fill(Color.white.opacity(0.045)))
                    .overlay { Circle().strokeBorder(LumenStyle.line, lineWidth: 1) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Library options")
            Button { showingNewMachine = true } label: {
                Label("New machine", systemImage: "plus")
            }
            .buttonStyle(CapsuleButtonStyle(prominent: true))
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 36)
        .padding(.top, 42)
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) { Rectangle().fill(LumenStyle.line).frame(height: 1).padding(.horizontal, 36) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 12))
                .foregroundStyle(LumenStyle.mint.opacity(0.65))
            if model.machines.isEmpty {
                Text("Room for more. Disks grow as you use them.")
            } else {
                Text("\(ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file)) on host SSD")
                Text("·").foregroundStyle(.white.opacity(0.2))
                Text("VM RAM: \(model.activeMemoryGiB)/\(model.resourcePolicy.guestMemoryBudgetGiB(on: model.hostResources)) GiB")
            }
            Spacer()
            Circle().fill(LumenStyle.mint.opacity(0.8)).frame(width: 4, height: 4)
            Text("Reserved for macOS: \(model.resourcePolicy.memoryReserveGiB) GiB")
            Rectangle().fill(LumenStyle.line).frame(width: 1, height: 12).padding(.horizontal, 7)
            Button("Compatibility") { showingCompatibility = true }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.57))
        }
        .font(.system(size: 10))
        .foregroundStyle(LumenStyle.secondary)
        .padding(.horizontal, 36)
        .padding(.vertical, 21)
        .overlay(alignment: .top) { Rectangle().fill(LumenStyle.line).frame(height: 1).padding(.horizontal, 36) }
    }
}

private struct EmptyLibraryView: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse()
                    .fill(LumenStyle.mint.opacity(0.08))
                    .frame(width: 200, height: 65)
                    .blur(radius: 28)
                    .offset(y: 36)
                miniCard(guest: .ubuntu, label: "LINUX")
                    .rotationEffect(.degrees(-13))
                    .offset(x: -86, y: 8)
                miniCard(guest: .windows, label: "WINDOWS")
                    .rotationEffect(.degrees(13))
                    .offset(x: 86, y: 8)
                miniCard(guest: .macOS, label: "macOS")
                    .offset(y: -3)
            }
            .frame(height: 135)
            .padding(.bottom, 22)

            Text("Different worlds.\nOne beautiful home.")
                .font(.system(size: 31, weight: .medium))
                .tracking(-1)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.93))
            Text("Bring your favorite operating systems to your Mac.\nFast, local, and light on your storage.")
                .font(.system(size: 12))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(LumenStyle.secondary)
                .padding(.top, 13)
            Button(action: create) {
                Label("Create your first machine", systemImage: "plus")
            }
            .buttonStyle(CapsuleButtonStyle(prominent: true))
            .padding(.top, 24)
            HStack(spacing: 19) {
                Label("No subscription", systemImage: "checkmark")
                Label("Your Mac. Your data.", systemImage: "lock")
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.32))
            .padding(.top, 17)
        }
        .padding(.top, 2)
        .padding(.bottom, 28)
    }

    private func miniCard(guest: GuestOS, label: String) -> some View {
        VStack(spacing: 15) {
            GuestGlyph(guest: guest, size: 31)
            Text(label).font(.system(size: 7, weight: .semibold, design: .monospaced)).tracking(1.7).foregroundStyle(.white.opacity(0.38))
        }
        .frame(width: 87, height: 110)
        .background {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.20, blue: 0.21), Color(red: 0.095, green: 0.12, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 16, y: 10)
        }
        .accessibilityHidden(true)
    }
}

private struct MachineRow: View {
    @EnvironmentObject private var model: LibraryModel
    let machine: VirtualMachineRecord
    let onRemove: () -> Void
    let onForceStop: () -> Void
    let onEdit: () -> Void
    @State private var hovered = false

    private var state: VMRuntimeState { model.state(for: machine.id) }
    private var selected: Bool { model.selectedID == machine.id }
    private var busy: Bool { state == .starting || state == .stopping || state == .installing }

    var body: some View {
        HStack(spacing: 19) {
            ZStack(alignment: .bottomTrailing) {
                GuestBadge(guest: machine.guest)
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().strokeBorder(Color(red: 0.10, green: 0.13, blue: 0.15), lineWidth: 2) }
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text(machine.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.93))
                        .lineLimit(1)
                    if machine.guest == .windows {
                        Text("EXPERIMENTAL")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(machine.guest.tint.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(machine.guest.tint.opacity(0.09)))
                    }
                }
                if state == .installing {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Installing macOS · \(Int(model.progress(for: machine.id) * 100))%")
                            .font(.system(size: 11)).foregroundStyle(LumenStyle.secondary)
                        ProgressView(value: model.progress(for: machine.id))
                            .tint(LumenStyle.mint)
                            .frame(maxWidth: 270)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("\(machine.cpuCount) CPU · \(machine.memoryGiB) GiB RAM · \(machine.operatingSystemName) · \(machine.displayWidth)×\(machine.displayHeight)")
                            .font(.system(size: 11))
                            .foregroundStyle(LumenStyle.secondary)
                            .lineLimit(1)
                        if machine.sharedDirectoryPath != nil {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(LumenStyle.mint.opacity(0.75))
                                .help("Shared folder connected: \(machine.sharedDirectoryPath ?? "")")
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                Text(ByteCountFormatter.string(fromByteCount: model.allocatedBytes(for: machine.id), countStyle: .file))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Text("of \(machine.diskGiB) GiB max")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.34))
            }
            .padding(.trailing, 17)
            .help("Space currently allocated to the disk image, followed by its maximum guest capacity.")

            if busy {
                ProgressView().controlSize(.small).frame(width: 34, height: 34)
                    .help(state.title)
            } else {
                Button {
                    if state == .running || state == .paused { model.pauseOrResume(machine) }
                    else { model.start(machine) }
                } label: {
                    Image(systemName: state == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(IconButtonStyle())
                .help(state == .running ? "Pause \(machine.name)" : state == .paused ? "Resume \(machine.name)" : "Start \(machine.name)")
            }
            Menu {
                if state.isActive && machine.guest.usesAppleVirtualization {
                    Button("Show display", systemImage: "display") { model.showDisplay(machine) }
                }
                if state == .running || state == .paused {
                    Button(state == .paused ? "Resume" : "Pause", systemImage: state == .paused ? "play" : "pause") { model.pauseOrResume(machine) }
                    Button("Shut down", systemImage: "power") { model.stop(machine) }
                }
                if state.isActive {
                    Button("Force stop", role: .destructive, action: onForceStop)
                        .disabled(state == .installing || state == .starting)
                    Divider()
                }
                if !state.isActive && machine.installerPath != nil && machine.guest != .macOS {
                    Button("Boot from installer", systemImage: "opticaldisc") { model.start(machine, bootInstaller: true) }
                }
                if !state.isActive && machine.installerPath != nil {
                    Button("Eject installer", systemImage: "eject") {
                        do { try model.ejectInstaller(machine) } catch { model.errorMessage = error.localizedDescription }
                    }
                }
                Button("Settings…", systemImage: "slider.horizontal.3", action: onEdit).disabled(state.isActive)
                Button("Show in Finder", systemImage: "folder") { model.reveal(machine) }
                Divider()
                Button("Move to Trash", role: .destructive, action: onRemove).disabled(state.isActive)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 25, height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Machine options")
        }
        .padding(.horizontal, 21)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.085 : hovered ? 0.055 : 0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.12 : 0.055), lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture(count: 2) {
            model.selectedID = machine.id
            if state.isActive {
                if machine.guest.usesAppleVirtualization { model.showDisplay(machine) }
            } else { model.start(machine) }
        }
        .onTapGesture { model.selectedID = machine.id }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(machine.name), \(state.title)")
    }

    private var stateColor: Color {
        switch state {
        case .running: return LumenStyle.mint
        case .paused: return .orange
        case .failed: return .red
        case .starting, .installing, .stopping: return .blue
        case .stopped: return Color.white.opacity(0.3)
        }
    }
}

struct CompatibilitySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                LumenMark(size: 26)
                TinyLabel(text: "MADE FOR APPLE SILICON")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("A good guest makes all the difference.")
                    .font(.system(size: 25, weight: .medium)).tracking(-0.7)
                Text("Lumen runs ARM guests on your Apple silicon Mac. Integration depends on the operating system and its guest drivers.")
                    .font(.system(size: 12)).foregroundStyle(LumenStyle.secondary).lineSpacing(4)
            }
            VStack(spacing: 0) {
                compatibilityRow(.macOS, title: "macOS", detail: "Native Apple virtualization, keyboard and pointer, shared networking, and a resizable display. Install from a compatible Apple silicon IPSW.", status: "NATIVE")
                Divider().overlay(LumenStyle.line).padding(.vertical, 15)
                compatibilityRow(.ubuntu, title: "Linux", detail: "ARM64 UEFI guests with VirtIO graphics and networking. Dynamic display resizing needs a supported guest driver. Arch and Void may need a prepared ARM64 UEFI installer.", status: "NATIVE")
                Divider().overlay(LumenStyle.line).padding(.vertical, 15)
                compatibilityRow(.windows, title: "Windows on ARM", detail: "Experimental QEMU backend with a separate display window. Requires local QEMU and ARM64 media. Automatic resizing, shared clipboard, and a virtual TPM are not included.", status: "EXPERIMENTAL")
            }
            .padding(21)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.035)))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(LumenStyle.mint.opacity(0.75))
                Text("Android and ChromeOS are not supported yet. Intel installers (x86_64 / amd64) cannot use this app’s ARM virtualization path.")
                    .foregroundStyle(LumenStyle.secondary)
            }
            .font(.system(size: 11)).lineSpacing(4)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(LumenStyle.mint.opacity(0.75))
                Text("A 64 GiB disk is a capacity limit. Sparse disks allocate space as the guest writes data. Deleting files inside a guest may require TRIM or compaction before macOS reclaims that space.")
                    .foregroundStyle(LumenStyle.secondary)
            }
            .font(.system(size: 11)).lineSpacing(4)
            HStack {
                Spacer()
                Button("Got it") { dismiss() }.buttonStyle(CapsuleButtonStyle(prominent: true))
            }
        }
        .padding(30)
        .frame(width: 650)
        .background { LumenBackground() }
        .preferredColorScheme(.dark)
    }

    private func compatibilityRow(_ guest: GuestOS, title: String, detail: String, status: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            GuestBadge(guest: guest, size: 39)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    TinyLabel(text: status, color: guest.tint.opacity(0.8))
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(LumenStyle.secondary).lineSpacing(4)
            }
        }
    }
}
