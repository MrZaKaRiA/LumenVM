import AppKit
import Combine
import Foundation
import LumenCore

/// An external disk as shown in menus: an eligible disk on the Mac, or one owned by a VM.
struct ExternalDiskEntry: Identifiable {
    var id: String { disk.bsdName }
    let disk: HostDisk
    let owner: VirtualMachineRecord?
}

/// External storage (USB sticks, SD cards, external drives) for running Windows (QEMU) VMs.
extension LibraryModel {
    func startDeviceMonitoring() {
        guard deviceMonitor == nil, !isGuestProcess,
              !["--smoke-test", "--boot-test", "--windows-boot-test", "--snapshot"].contains(where: CommandLine.arguments.contains)
        else { return }
        let monitor = DeviceMonitor(protectedPaths: ["/", libraryURL.path])
        monitor.ownedWholeDisks = { [weak self] in self?.ownedWholeDisks() ?? [] }
        monitor.onArrival = { [weak self] disk in self?.diskArrived(disk) }
        monitor.onDisappearance = { [weak self] name in self?.diskDisappeared(name) }
        deviceMonitor = monitor
        deviceChooser = DeviceChooserController()
        deviceCancellables.append(monitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        deviceCancellables.append(monitor.$disks.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] disks in
            guard let self else { return }
            self.republishDiskMenus()
            let present = Set(disks.map(\.bsdName))
            self.deviceChooser?.dismissAll { !present.contains($0) }
        })
        monitor.start()
    }

    /// Called when a Windows engine is created.
    func wireExternalDisks(_ engine: QEMUVirtualMachine, record: VirtualMachineRecord) {
        let id = record.id
        engine.externalDiskItems = { [weak self] in self?.diskMenuItems(for: id) ?? [] }
        engine.onDiskMenuAction = { [weak self] action in
            guard let self else { return }
            let current = self.machines.first { $0.id == id } ?? record
            self.handleDiskMenuAction(action, record: current)
        }
        diskObservations[id] = engine.$attachedDisks.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.republishDiskMenus()
            self?.objectWillChange.send()
        }
    }

    // MARK: - Queries

    /// Running or paused Windows (QEMU) VMs that can receive a disk.
    func attachTargets() -> [VirtualMachineRecord] {
        machines.filter { machine in
            guard machine.guest == .windows, let engine = qemuEngines[machine.id], engine.isProcessRunning else { return false }
            return engine.state == .running || engine.state == .paused
        }
    }

    /// The VM whose QEMU engine currently has this whole disk attached.
    func owner(of bsdName: String) -> VirtualMachineRecord? {
        for (id, engine) in qemuEngines where engine.attachedDisks.contains(where: { $0.bsdName == bsdName }) {
            return machines.first { $0.id == id } ?? engine.record
        }
        return nil
    }

    func ownedWholeDisks() -> Set<String> {
        Set(qemuEngines.values.flatMap { $0.attachedDisks.map(\.bsdName) }).union(attachingDisks)
    }

    /// Eligible disks plus any disk a VM still owns (so it can always be disconnected).
    func externalDisks() -> [ExternalDiskEntry] {
        var entries = (deviceMonitor?.disks ?? []).map { ExternalDiskEntry(disk: $0, owner: owner(of: $0.bsdName)) }
        let listed = Set(entries.map(\.id))
        for (id, engine) in qemuEngines {
            for attached in engine.attachedDisks where !listed.contains(attached.bsdName) {
                let disk = HostDisk(bsdName: attached.bsdName, mediaName: attached.mediaName, sizeBytes: attached.sizeBytes,
                                    isRemovable: true, isEjectable: true, isInternal: false, isDiskImage: false, isWhole: true)
                entries.append(ExternalDiskEntry(disk: disk, owner: machines.first { $0.id == id } ?? engine.record))
            }
        }
        return entries.sorted { $0.id < $1.id }
    }

    func diskMenuItems(for machineID: UUID) -> [ExternalDiskMenuItem] {
        externalDisks().map { entry in
            ExternalDiskMenuItem(id: entry.id, title: entry.disk.displayTitle,
                                 attachedHere: entry.owner?.id == machineID,
                                 attachedElsewhere: entry.owner != nil && entry.owner?.id != machineID)
        }
    }

    func isDiskBusy(_ bsdName: String) -> Bool {
        diskOperationsInFlight.contains(bsdName) || attachingDisks.contains(bsdName)
    }

    // MARK: - Actions

    /// Connects a disk to a running Windows VM after a fresh eligibility check and a confirmation.
    func attach(_ disk: HostDisk, to record: VirtualMachineRecord, readOnly: Bool) async {
        let name = disk.bsdName
        guard HostDisk.isValidBSDName(name), let monitor = deviceMonitor else {
            return presentDeviceError("“\(name)” is not an external disk Lumen can connect.")
        }
        guard record.guest == .windows, let engine = qemuEngines[record.id], engine.isProcessRunning,
              engine.state == .running || engine.state == .paused else {
            return presentDeviceError("Start \(record.name) before connecting \(disk.displayName).")
        }
        if let owner = owner(of: name) {
            return presentDeviceError("\(disk.displayName) is already connected to \(owner.name). Disconnect it there first.")
        }
        guard !isDiskBusy(name) else { return presentDeviceError("\(disk.displayName) is already being connected or disconnected.") }
        diskOperationsInFlight.insert(name)
        defer { diskOperationsInFlight.remove(name) }

        // Fresh check against live system state (diskutil runs off the main thread).
        let live: HostDisk
        do {
            let protected = try await monitor.currentProtectedDisks()
            live = try await HostDiskOpener.describe(bsdName: name)
            guard live.sizeBytes == disk.sizeBytes,
                  DeviceEligibility.canOffer(live, bootDiskParents: protected, allowDiskImages: monitor.allowDiskImages) else {
                return presentDeviceError("\(disk.displayName) cannot be connected: only removable or external disks other than the Mac’s startup disk and the disk holding the Lumen library are allowed.")
            }
        } catch {
            return presentDeviceError("\(disk.displayName) is no longer available: \(error.localizedDescription)")
        }

        guard confirmAttach(disk, to: record, readOnly: readOnly) else { return }
        // The world may have changed while the alert was open.
        guard qemuEngines[record.id] === engine, engine.isProcessRunning,
              engine.state == .running || engine.state == .paused else {
            return presentDeviceError("\(record.name) is no longer running.")
        }
        if let owner = owner(of: name) {
            return presentDeviceError("\(disk.displayName) is already connected to \(owner.name).")
        }
        var target = live
        target.mediaName = disk.mediaName.isEmpty ? live.mediaName : disk.mediaName
        attachingDisks.insert(name)
        defer { attachingDisks.remove(name); republishDiskMenus() }
        do {
            try await engine.attachHostDisk(target, readOnly: readOnly, allowDiskImages: monitor.allowDiskImages)
            deviceChooser?.dismiss(name)
        } catch {
            presentDeviceError("Could not connect \(disk.displayName) to \(record.name): \(error.localizedDescription)")
        }
        monitor.invalidate(name)
    }

    /// Disconnects a disk from a VM, then remounts it on the Mac, ejects it, or leaves it.
    func detach(bsdName: String, from record: VirtualMachineRecord, afterwards: HostDiskDetachAction) async {
        guard HostDisk.isValidBSDName(bsdName), let engine = qemuEngines[record.id],
              let attached = engine.attachedDisks.first(where: { $0.bsdName == bsdName }) else {
            return presentDeviceError("That disk is not connected to \(record.name).")
        }
        let title = attached.mediaName.isEmpty ? bsdName : attached.mediaName
        guard !isDiskBusy(bsdName) else { return presentDeviceError("\(title) is already being connected or disconnected.") }
        if afterwards != .leave {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = afterwards == .eject ? "Disconnect and eject \(title)?" : "Return \(title) to this Mac?"
            alert.informativeText = "First eject the drive inside Windows (Safely Remove Hardware and Eject Media in the taskbar, or Eject in File Explorer) so Windows finishes writing. Disconnecting a drive Windows is still writing to can lose or corrupt data."
                + (afterwards == .eject ? "\n\nAfterwards macOS ejects it and you can unplug it." : "\n\nAfterwards macOS mounts it again if it can read its format. macOS cannot write to NTFS drives.")
            alert.addButton(withTitle: afterwards == .eject ? "Disconnect and Eject" : "Disconnect")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        diskOperationsInFlight.insert(bsdName)
        defer { diskOperationsInFlight.remove(bsdName); republishDiskMenus() }
        do {
            if let notice = try await engine.detachHostDisk(bsdName: bsdName, afterwards: afterwards) {
                presentDeviceError(notice)
            }
        } catch {
            presentDeviceError("Could not disconnect \(title) from \(record.name): \(error.localizedDescription) Eject it inside Windows first, then try again.")
        }
        deviceMonitor?.invalidate(bsdName)
    }

    func handleDiskMenuAction(_ action: DiskMenuAction, record: VirtualMachineRecord) {
        // DiskMenuAction.parse already required a valid, published BSD name; re-check anyway.
        guard HostDisk.isValidBSDName(action.bsdName) else { return }
        switch action {
        case let .attach(name, readOnly):
            guard let disk = deviceMonitor?.disk(named: name) else {
                return presentDeviceError("That disk is no longer available on this Mac.")
            }
            Task { await attach(disk, to: record, readOnly: readOnly) }
        case let .returnToMac(name):
            Task { await detach(bsdName: name, from: record, afterwards: .remountOnMac) }
        case let .eject(name):
            Task { await detach(bsdName: name, from: record, afterwards: .eject) }
        }
    }

    // MARK: - Events

    private func diskArrived(_ disk: HostDisk) {
        let targets = attachTargets()
        guard !targets.isEmpty, owner(of: disk.bsdName) == nil else { return }
        deviceChooser?.show(disk: disk, targets: targets) { [weak self] target, readOnly in
            guard let self, let target else { return }
            guard let current = self.deviceMonitor?.disk(named: disk.bsdName) else {
                return self.presentDeviceError("\(disk.displayName) is no longer available on this Mac.")
            }
            Task { await self.attach(current, to: target, readOnly: readOnly) }
        }
    }

    private func diskDisappeared(_ name: String) {
        deviceChooser?.dismiss(name)
        guard let record = owner(of: name), let engine = qemuEngines[record.id],
              let attached = engine.attachedDisks.first(where: { $0.bsdName == name }) else { return }
        let title = attached.mediaName.isEmpty ? name : attached.mediaName
        Task {
            do { try await engine.detachHostDisk(bsdName: name, afterwards: .leave) }
            catch { NSLog("Lumen: cleanup after removal of \(name) failed: \(error.localizedDescription)") }
            presentDeviceError("\(title) was disconnected from the Mac while \(record.name) was using it. Data that Windows had not finished writing may be lost. Next time, eject it inside Windows and choose Disconnect before unplugging it.")
            republishDiskMenus()
        }
    }

    func republishDiskMenus() {
        for engine in qemuEngines.values { engine.refreshMenuStatus() }
    }

    // MARK: - Presentation

    private func confirmAttach(_ disk: HostDisk, to record: VirtualMachineRecord, readOnly: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect \(disk.displayName) (\(disk.sizeDescription)) to \(record.name)?"
        alert.informativeText = """
        The Mac will unmount the disk and \(record.name) will see it as a USB drive\(readOnly ? " it can only read" : ""). macOS will ask for an administrator password to give Lumen access to the disk.

        While connected, only Windows uses this disk; macOS will not mount it. Before disconnecting or unplugging it, eject it inside Windows, then choose Disconnect in Lumen’s Devices menu.
        """
        alert.addButton(withTitle: readOnly ? "Connect Read-Only" : "Connect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentDeviceError(_ message: String) {
        errorMessage = message
        showLibrary()
    }
}
