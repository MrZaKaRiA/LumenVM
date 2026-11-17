import Darwin
import Foundation
import LumenCore

/// Host removable disks presented to the Windows guest as USB mass-storage drives.
///
/// Sequence (verified by scripts/validate-device-hotplug.py on QEMU 11.1.2):
/// attach: diskutil unmountDisk → open /dev/rdiskN (plain, else authopen) → qemu-nbd (fd as stdin)
///         → blockdev-add nbd → device_add usb-storage
/// detach: device_del → DEVICE_DELETED → blockdev-del → qemu-nbd exits → remount / eject / leave
extension QEMUVirtualMachine {
    static var qemuNBDURL: URL? {
        guard let qemu = executableURL else { return nil }
        return [qemu, qemu.resolvingSymlinksInPath()]
            .map { $0.deletingLastPathComponent().appendingPathComponent("qemu-nbd") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Creates the per-launch private directory that holds the device monitor and NBD sockets.
    /// Darwin limits socket paths to 104 bytes, so this lives in /tmp like the TPM socket.
    func prepareDeviceRuntime() throws -> URL {
        let runtime = URL(fileURLWithPath: "/tmp/lumen-dev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        deviceRuntimeDirectory = runtime
        return runtime
    }

    /// Presents a whole host disk to the guest as a removable USB drive.
    /// The VM must be running or paused. Every completed step is rolled back on failure.
    func attachHostDisk(_ disk: HostDisk, readOnly: Bool, allowDiskImages: Bool = false) async throws {
        let name = disk.bsdName
        guard HostDisk.isValidBSDName(name) else { throw HostDiskError("“\(name)” is not a whole-disk name.") }
        guard state == .running || state == .paused, isProcessRunning, let runtime = deviceRuntimeDirectory else {
            throw HostDiskError("Start the virtual machine before connecting a disk.")
        }
        guard !attachedDisks.contains(where: { $0.bsdName == name }) else {
            throw HostDiskError("\(disk.mediaName.isEmpty ? name : disk.mediaName) is already connected to this virtual machine.")
        }
        guard hostDiskOperations.isEmpty else { throw HostDiskError("Another disk is being connected or disconnected. Try again in a moment.") }
        guard let nbd = Self.qemuNBDURL else { throw HostDiskError("qemu-nbd was not found next to qemu-system-aarch64.") }
        hostDiskOperations.insert(name)
        defer { hostDiskOperations.remove(name) }

        func ensureSameLaunch() throws {
            guard deviceRuntimeDirectory == runtime, isProcessRunning else {
                throw HostDiskError("The virtual machine stopped while the disk was being connected.")
            }
        }

        // Re-check against live system state; never trust only the caller's snapshot.
        let protected = try await HostDiskOpener.protectedWholeDisks(for: ["/", location.directory.path, location.disk.path])
        let live = try await HostDiskOpener.describe(bsdName: name)
        guard live.sizeBytes == disk.sizeBytes,
              DeviceEligibility.canOffer(disk, bootDiskParents: protected, allowDiskImages: allowDiskImages),
              DeviceEligibility.canOffer(live, bootDiskParents: protected, allowDiskImages: allowDiskImages) else {
            throw HostDiskError("\(disk.mediaName.isEmpty ? name : disk.mediaName) cannot be connected: only removable or external whole disks other than the Mac’s startup disk are allowed.")
        }
        try ensureSameLaunch()

        let ids = AttachedHostDisk.identifiers(for: name)
        var rollback: [() async -> Void] = []
        do {
            try await HostDiskOpener.unmount(bsdName: name)
            rollback.append { try? await HostDiskOpener.mount(bsdName: name) }
            try ensureSameLaunch()

            let handle = try await HostDiskOpener.open(bsdName: name, readOnly: readOnly)
            // qemu-nbd inherits its own copy; Lumen's copy is closed when this scope ends.
            defer { try? handle.close() }
            try ensureSameLaunch()

            let export = try HostDiskExport.start(executable: nbd, bsdName: name, disk: handle, runtime: runtime, readOnly: readOnly)
            hostDiskExports[name] = export
            rollback.append { [weak self] in
                await export.stop(grace: 2)
                if self?.hostDiskExports[name] === export { self?.hostDiskExports[name] = nil }
            }
            try await export.waitUntilListening()
            try ensureSameLaunch()

            let monitor = try await deviceMonitor()
            try await monitor.execute("blockdev-add", arguments: QMPMessages.blockdevAddNBD(
                nodeName: ids.nodeName, socketPath: export.socketPath, readOnly: readOnly))
            rollback.append { _ = try? await monitor.execute("blockdev-del", arguments: QMPMessages.blockdevDel(nodeName: ids.nodeName)) }
            try ensureSameLaunch()

            monitor.forgetDeletion(of: ids.deviceID)
            try await monitor.execute("device_add", arguments: QMPMessages.deviceAddUSBStorage(
                id: ids.deviceID, drive: ids.nodeName, serial: ids.serial))
            try ensureSameLaunch()
            attachedDisks.append(AttachedHostDisk(bsdName: name, deviceID: ids.deviceID, nodeName: ids.nodeName,
                                                  readOnly: readOnly, mediaName: live.mediaName.isEmpty ? disk.mediaName : live.mediaName,
                                                  sizeBytes: live.sizeBytes))
        } catch {
            for step in rollback.reversed() { await step() }
            throw error
        }
    }

    /// Removes a host disk from the guest. Throws if the guest did not release it; the disk then
    /// stays attached. Returns a notice when the guest released it but the Mac-side follow-up
    /// (remount or eject) failed.
    @discardableResult
    func detachHostDisk(bsdName: String, afterwards: HostDiskDetachAction) async throws -> String? {
        guard HostDisk.isValidBSDName(bsdName) else { throw HostDiskError("“\(bsdName)” is not a whole-disk name.") }
        guard let attached = attachedDisks.first(where: { $0.bsdName == bsdName }) else {
            throw HostDiskError("\(bsdName) is not connected to this virtual machine.")
        }
        guard hostDiskOperations.isEmpty else { throw HostDiskError("Another disk is being connected or disconnected. Try again in a moment.") }
        hostDiskOperations.insert(bsdName)
        defer { hostDiskOperations.remove(bsdName) }

        let monitor = try await deviceMonitor()
        do {
            try await monitor.execute("device_del", arguments: QMPMessages.deviceDel(id: attached.deviceID))
            try await monitor.waitForDeviceDeleted(attached.deviceID, timeout: 10)
        } catch let error as QMPCommandError where error.errorClass == "DeviceNotFound" {
            // An earlier detach already removed the device; continue with the backend.
        }
        try await monitor.execute("blockdev-del", arguments: QMPMessages.blockdevDel(nodeName: attached.nodeName))
        attachedDisks.removeAll { $0.bsdName == bsdName }
        if let export = hostDiskExports.removeValue(forKey: bsdName) { await export.stop() }

        do {
            switch afterwards {
            case .remountOnMac: try await HostDiskOpener.mount(bsdName: bsdName)
            case .eject: try await HostDiskOpener.eject(bsdName: bsdName)
            case .leave: break
            }
        } catch {
            return "The disk was disconnected from Windows. \(error.localizedDescription)"
        }
        return nil
    }

    /// Releases every host disk when QEMU stops or exits. Called from `cleanup()`.
    func tearDownHostDevices() {
        deviceMonitorSocket?.close()
        deviceMonitorSocket = nil
        let exports = Array(hostDiskExports.values)
        hostDiskExports.removeAll()
        attachedDisks.removeAll()
        let runtime = deviceRuntimeDirectory
        deviceRuntimeDirectory = nil
        guard !exports.isEmpty || runtime != nil else { return }
        Task.detached {
            for export in exports {
                // qemu-nbd exits once QEMU's connection drops; then the Mac may mount the disk again.
                await export.stop()
                try? await HostDiskOpener.mount(bsdName: export.bsdName)
            }
            if let runtime { try? FileManager.default.removeItem(at: runtime) }
        }
    }

    private func deviceMonitor() async throws -> QMPSocket {
        if let socket = deviceMonitorSocket, socket.isConnected { return socket }
        guard isProcessRunning, let runtime = deviceRuntimeDirectory else {
            throw HostDiskError("The virtual machine is not running.")
        }
        deviceMonitorSocket?.close()
        let socket = QMPSocket(path: runtime.appendingPathComponent("qmp.sock").path)
        deviceMonitorSocket = socket
        do {
            try await socket.connect()
        } catch {
            socket.close()
            if deviceMonitorSocket === socket { deviceMonitorSocket = nil }
            throw error
        }
        guard deviceRuntimeDirectory == runtime else {
            socket.close()
            throw HostDiskError("The virtual machine stopped while connecting to its device monitor.")
        }
        return socket
    }
}
