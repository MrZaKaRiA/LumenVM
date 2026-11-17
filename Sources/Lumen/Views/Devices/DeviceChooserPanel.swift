import AppKit
import SwiftUI
import LumenCore

/// Small floating, non-activating panels offering a newly connected disk to running Windows VMs.
@MainActor
final class DeviceChooserController {
    private var panels: [String: NSPanel] = [:]

    /// `choice` receives the chosen VM (nil = keep the disk on this Mac) and the read-only flag.
    func show(disk: HostDisk, targets: [VirtualMachineRecord],
              choice: @escaping (VirtualMachineRecord?, Bool) -> Void) {
        dismiss(disk.bsdName)
        let name = disk.bsdName
        let view = DeviceChooserView(disk: disk, targets: targets) { [weak self] target, readOnly in
            self?.dismiss(name)
            choice(target, readOnly)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .hudWindow],
                            backing: .buffered, defer: false)
        panel.title = "External Disk"
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let offset = CGFloat(panels.count) * 24
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 20,
                                               y: visible.maxY - 20 - offset))
        }
        panels[name] = panel
        // Shown without activating Lumen or taking keyboard focus from the VM window.
        panel.orderFrontRegardless()
    }

    func dismiss(_ bsdName: String) {
        panels.removeValue(forKey: bsdName)?.close()
    }

    func dismissAll(where predicate: (String) -> Bool) {
        for name in panels.keys where predicate(name) { dismiss(name) }
    }
}

private struct DeviceChooserView: View {
    let disk: HostDisk
    let targets: [VirtualMachineRecord]
    let choose: (VirtualMachineRecord?, Bool) -> Void
    @State private var readOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(disk.displayName) (\(disk.sizeDescription)) connected")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if !disk.volumeNames.isEmpty {
                        Text(disk.volumeNames.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(targets) { target in
                Button("Connect to \(target.name)") { choose(target, readOnly) }
                    .frame(maxWidth: .infinity)
            }
            Button("Use on This Mac") { choose(nil, false) }
            Toggle("Read-only", isOn: $readOnly)
                .font(.system(size: 11))
                .help("Windows can read the disk but cannot change it.")
        }
        .controlSize(.regular)
        .padding(14)
        .frame(width: 300)
    }
}

/// Menu content for external disks, used by the app's Devices menu and the library row menu.
/// With `machine` set, only actions for that VM are shown.
struct ExternalDiskMenuContent: View {
    @ObservedObject var model: LibraryModel
    var machine: VirtualMachineRecord?

    var body: some View {
        let entries = model.externalDisks()
        if entries.isEmpty {
            Button("No External Disks") {}.disabled(true)
        }
        ForEach(entries) { entry in
            Menu(entry.disk.displayTitle) { actions(for: entry) }
        }
    }

    @ViewBuilder
    private func actions(for entry: ExternalDiskEntry) -> some View {
        let busy = model.isDiskBusy(entry.id)
        if let owner = entry.owner {
            if machine == nil || machine?.id == owner.id {
                Button("Disconnect from \(owner.name) and Return to This Mac") {
                    Task { await model.detach(bsdName: entry.id, from: owner, afterwards: .remountOnMac) }
                }.disabled(busy)
                Button("Disconnect and Eject") {
                    Task { await model.detach(bsdName: entry.id, from: owner, afterwards: .eject) }
                }.disabled(busy)
            } else {
                Button("In Use by \(owner.name)") {}.disabled(true)
            }
        } else {
            let targets = model.attachTargets().filter { machine == nil || $0.id == machine?.id }
            if targets.isEmpty {
                Button("Start a Windows VM to Connect This Disk") {}.disabled(true)
            }
            ForEach(targets) { target in
                Button("Connect to \(target.name)") {
                    Task { await model.attach(entry.disk, to: target, readOnly: false) }
                }.disabled(busy)
            }
            ForEach(targets) { target in
                Button("Connect to \(target.name) (Read-Only)") {
                    Task { await model.attach(entry.disk, to: target, readOnly: true) }
                }.disabled(busy)
            }
        }
    }
}
