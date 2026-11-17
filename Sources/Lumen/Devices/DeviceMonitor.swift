import DiskArbitration
import Foundation
import LumenCore

/// Watches DiskArbitration for external whole disks (USB sticks, card readers, external drives)
/// that may be offered to a Windows VM, and stops macOS from mounting volumes of disks that a VM
/// currently owns.
///
/// - The DiskArbitration description is used to discover and pre-filter disks; `diskutil info`
///   (`HostDiskOpener.describe`) confirms every disk before it is published, and again right
///   before an attach.
/// - Disks that are present when monitoring starts are listed but never trigger `onArrival`.
@MainActor
final class DeviceMonitor: ObservableObject {
    /// Eligible external whole disks, sorted by BSD name.
    @Published private(set) var disks: [HostDisk] = []
    /// True once the startup enumeration has been processed.
    @Published private(set) var isReady = false

    /// A disk plugged in after launch became eligible.
    var onArrival: ((HostDisk) -> Void)?
    /// A whole disk disappeared from the Mac (unplugged, ejected or yanked).
    var onDisappearance: ((String) -> Void)?
    /// Whole disks currently owned by a VM (attached or being attached). Their volumes must not mount.
    var ownedWholeDisks: () -> Set<String> = { [] }

    /// Test hook: `LUMEN_ALLOW_DISK_IMAGE_DEVICES=1` offers attached disk images
    /// (`hdiutil attach -nomount`) so the feature can be exercised without hardware.
    let allowDiskImages = ProcessInfo.processInfo.environment["LUMEN_ALLOW_DISK_IMAGE_DEVICES"] == "1"

    private let protectedPaths: [String]
    private var session: DASession?
    /// Whole disks reported by DiskArbitration, by BSD name, with volume names merged from slices.
    private var candidates: [String: HostDisk] = [:]
    private var sliceVolumes: [String: String] = [:]
    /// diskutil-confirmed disks, invalidated whenever DiskArbitration reports a change.
    private var verified: [String: HostDisk] = [:]
    private var rejected: Set<String> = []
    /// Disks seen during the startup burst; they are never announced as new arrivals.
    private var presentAtLaunch: Set<String> = []
    private var announced: Set<String> = []
    private var startedAt = Date.distantFuture
    private var protectedDisks: Set<String>?
    private var protectedNeedsRefresh = true
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false

    private static let launchWindow: TimeInterval = 3

    init(protectedPaths: [String]) {
        self.protectedPaths = protectedPaths
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        startedAt = Date()
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            let description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
            MainActor.assumeIsolated { monitor.diskAppeared(description) }
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.diskDisappeared(name) }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            let description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
            MainActor.assumeIsolated { monitor.diskChanged(description) }
        }, context)
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return nil }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            let block = MainActor.assumeIsolated {
                HostDiskMountPolicy.shouldBlockMount(of: name, ownedWholeDisks: monitor.ownedWholeDisks())
            }
            guard block else { return nil }
            // DiskArbitration releases the returned dissenter.
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess),
                                              "This disk is in use by a Lumen virtual machine." as CFString)
            return Unmanaged.passRetained(dissenter)
        }, context)
        // Callbacks arrive on the main queue, matching this class's actor.
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        // Process the startup burst once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchWindow) { [weak self] in
            guard let self else { return }
            self.presentAtLaunch.formUnion(self.candidates.keys)
            self.scheduleRefresh()
        }
    }

    deinit {
        // The session must stop delivering callbacks that point at this object.
        if let session { DASessionSetDispatchQueue(session, nil) }
    }

    /// The disk with this BSD name if it is currently offered.
    func disk(named name: String) -> HostDisk? { disks.first { $0.bsdName == name } }

    /// Freshly computed protected whole disks (startup disk and the VM library's volume).
    func currentProtectedDisks() async throws -> Set<String> {
        let protected = try await HostDiskOpener.protectedWholeDisks(for: protectedPaths)
        protectedDisks = protected
        protectedNeedsRefresh = false
        return protected
    }

    /// Re-reads every candidate with diskutil (for example after a VM releases a disk).
    func invalidate(_ name: String? = nil) {
        if let name { verified[name] = nil; rejected.remove(name) } else { verified.removeAll(); rejected.removeAll() }
        scheduleRefresh()
    }

    // MARK: - DiskArbitration events

    private func diskAppeared(_ description: [String: Any]) {
        guard let disk = HostDisk(diskArbitrationDescription: description) else { return }
        if disk.isWhole {
            if Date().timeIntervalSince(startedAt) < Self.launchWindow { presentAtLaunch.insert(disk.bsdName) }
            candidates[disk.bsdName] = disk
            verified[disk.bsdName] = nil
            rejected.remove(disk.bsdName)
            protectedNeedsRefresh = true
        } else if HostDisk.wholeDiskName(of: disk.bsdName) != nil {
            sliceVolumes[disk.bsdName] = disk.volumeNames.first
        }
        scheduleRefresh()
    }

    private func diskChanged(_ description: [String: Any]) {
        guard let disk = HostDisk(diskArbitrationDescription: description) else { return }
        if disk.isWhole {
            guard candidates[disk.bsdName] != nil else { return diskAppeared(description) }
            candidates[disk.bsdName] = disk
            verified[disk.bsdName] = nil
            rejected.remove(disk.bsdName)
        } else {
            sliceVolumes[disk.bsdName] = disk.volumeNames.first
        }
        scheduleRefresh()
    }

    private func diskDisappeared(_ name: String) {
        if HostDisk.isValidBSDName(name) {
            let wasKnown = candidates.removeValue(forKey: name) != nil
            verified[name] = nil
            rejected.remove(name)
            announced.remove(name)
            presentAtLaunch.remove(name)
            sliceVolumes = sliceVolumes.filter { HostDisk.wholeDiskName(of: $0.key) != name }
            protectedNeedsRefresh = true
            if wasKnown { onDisappearance?(name) }
        } else {
            sliceVolumes[name] = nil
        }
        scheduleRefresh()
    }

    // MARK: - Verification

    private func scheduleRefresh() {
        guard Date().timeIntervalSince(startedAt) >= Self.launchWindow else { return }
        guard refreshTask == nil else { refreshAgain = true; return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func refresh() async {
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
        refreshTask = nil
        isReady = true
    }

    private func refreshOnce() async {
        var protected = protectedDisks
        if protectedNeedsRefresh || protected == nil {
            // An unknown protected set must never be treated as "nothing is protected".
            protected = try? await currentProtectedDisks()
        }
        guard let protected else { publish([]); return }
        for (name, candidate) in candidates.sorted(by: { $0.key < $1.key }) {
            guard verified[name] == nil, !rejected.contains(name) else { continue }
            guard DeviceEligibility.canOffer(candidate, bootDiskParents: protected, allowDiskImages: allowDiskImages) else {
                rejected.insert(name)
                continue
            }
            do {
                let live = try await HostDiskOpener.describe(bsdName: name)
                // The disk may have changed or vanished while diskutil ran.
                guard let current = candidates[name], current.sizeBytes == candidate.sizeBytes else { continue }
                if DeviceEligibility.canOffer(live, bootDiskParents: protected, allowDiskImages: allowDiskImages),
                   live.sizeBytes == current.sizeBytes {
                    verified[name] = live
                } else {
                    rejected.insert(name)
                }
            } catch {
                // Unreadable right now (for example mid-format); try again on the next change.
                continue
            }
        }
        let offered = verified.compactMap { name, live -> HostDisk? in
            guard let candidate = candidates[name], !protected.contains(name) else { return nil }
            var disk = live
            // Prefer DiskArbitration's vendor/model name and the slices' volume names for display.
            if !candidate.mediaName.isEmpty { disk.mediaName = candidate.mediaName }
            disk.volumeNames = sliceVolumes
                .filter { HostDisk.wholeDiskName(of: $0.key) == name && !$0.value.isEmpty }
                .sorted { $0.key < $1.key }.map(\.value)
            return disk
        }.sorted { $0.bsdName < $1.bsdName }
        publish(offered)
    }

    private func publish(_ offered: [HostDisk]) {
        if offered != disks { disks = offered }
        for disk in offered where !announced.contains(disk.bsdName) {
            announced.insert(disk.bsdName)
            if !presentAtLaunch.contains(disk.bsdName) { onArrival?(disk) }
        }
    }
}
