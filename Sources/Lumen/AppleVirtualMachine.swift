import AppKit
import Combine
import Foundation
import LumenCore
import SwiftUI
import Virtualization

/// Owns a single Apple Virtualization VM. All VZ operations use its default main queue.
@MainActor
final class AppleVirtualMachine: NSObject, ObservableObject, VZVirtualMachineDelegate {
    @Published private(set) var state: VMRuntimeState = .stopped
    @Published private(set) var progress: Double = 0
    @Published var errorMessage: String?
    @Published private(set) var virtualMachine: VZVirtualMachine?

    let record: VirtualMachineRecord
    private let location: VMLocation
    private var installer: VZMacOSInstaller?
    private var progressObservation: NSKeyValueObservation?
    private var operationInProgress = false

    init(record: VirtualMachineRecord, location: VMLocation) {
        self.record = record
        self.location = location
        super.init()
    }

    func start(bootInstaller: Bool = false) async throws {
        guard !operationInProgress, state == .stopped || state == .failed else {
            throw EngineError.message("Shut down this virtual machine before starting it again.")
        }
        guard record.guest.usesAppleVirtualization else {
            throw EngineError.message("This guest needs the QEMU engine. Apple Virtualization supports macOS and compatible ARM Linux guests here.")
        }
        if record.guest.isMacOS, bootInstaller {
            guard let path = record.installerPath else {
                throw EngineError.message("Choose a macOS IPSW restore image first.")
            }
            try await installMacOS(restoreImageURL: URL(fileURLWithPath: path))
            return
        }

        operationInProgress = true
        defer { operationInProgress = false }
        state = .starting
        errorMessage = nil
        do {
            let configuration = try makeConfiguration(bootInstaller: bootInstaller)
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            virtualMachine = machine
            try await machine.start()
            synchronizeState()
        } catch {
            fail(error)
            throw error
        }
    }

    func installMacOS(restoreImageURL: URL) async throws {
        guard record.guest.isMacOS else {
            throw EngineError.message("IPSW restore images can only install a macOS guest.")
        }
        guard !operationInProgress, state == .stopped || state == .failed else {
            throw EngineError.message("Shut down the virtual machine before installing macOS.")
        }
        guard restoreImageURL.isFileURL, FileManager.default.isReadableFile(atPath: restoreImageURL.path) else {
            throw EngineError.message("The macOS restore image is missing or unreadable. Choose a local .ipsw file.")
        }

        operationInProgress = true
        defer {
            operationInProgress = false
            progressObservation = nil
            installer = nil
        }
        state = .installing
        progress = 0
        errorMessage = nil
        do {
            let image = try await VZMacOSRestoreImage.image(from: restoreImageURL)
            guard image.isSupported, let requirements = image.mostFeaturefulSupportedConfiguration else {
                throw EngineError.message("This macOS restore image is not supported by this Mac. Use a compatible Apple Silicon IPSW.")
            }
            let requiredMemory = Int((requirements.minimumSupportedMemorySize + (1 << 30) - 1) >> 30)
            guard record.cpuCount >= requirements.minimumSupportedCPUCount, record.memoryGiB >= requiredMemory else {
                throw EngineError.message("This macOS image requires at least \(requirements.minimumSupportedCPUCount) CPUs and \(requiredMemory) GB of memory. Create a VM with those resources.")
            }
            try prepareMacPlatform(hardwareModel: requirements.hardwareModel)
            let machine = VZVirtualMachine(configuration: try makeConfiguration(bootInstaller: false))
            machine.delegate = self
            virtualMachine = machine
            let installation = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreImageURL)
            installer = installation
            progressObservation = installation.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor [weak self] in
                    guard self?.state == .installing else { return }
                    self?.progress = fraction
                }
            }
            try await installation.install()
            try Data("Installed by Lumen\n".utf8).write(to: location.installedMarker, options: .atomic)
            progress = 1
            // The installer normally leaves a stopped VM; ask VZ instead of assuming.
            synchronizeState()
        } catch {
            fail(error)
            throw error
        }
    }

    func pause() async throws {
        guard !operationInProgress, state != .installing, let machine = virtualMachine, machine.canPause else {
            throw EngineError.message("This virtual machine cannot be paused right now.")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            try await machine.pause()
            synchronizeState()
        } catch {
            errorMessage = error.localizedDescription
            synchronizeState()
            throw error
        }
    }

    func resume() async throws {
        guard !operationInProgress, let machine = virtualMachine, machine.canResume else {
            throw EngineError.message("This virtual machine cannot be resumed right now.")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            try await machine.resume()
            synchronizeState()
        } catch {
            errorMessage = error.localizedDescription
            synchronizeState()
            throw error
        }
    }

    func requestStop() throws {
        guard !operationInProgress, state != .installing, let machine = virtualMachine, machine.canRequestStop else {
            throw EngineError.message("The guest cannot accept a shutdown request right now. Resume a paused VM first.")
        }
        try machine.requestStop()
        state = .stopping
    }

    /// The caller must confirm this destructive action with the user.
    func forceStop() async throws {
        guard !operationInProgress, state != .installing, let machine = virtualMachine, machine.canStop else {
            throw EngineError.message("This virtual machine cannot be powered off right now. Wait for installation or startup to finish.")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        state = .stopping
        do {
            try await machine.stop()
            synchronizeState()
        } catch {
            errorMessage = error.localizedDescription
            synchronizeState()
            throw error
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        // VZ invokes delegates on the queue used at initialization: the main queue here.
        MainActor.assumeIsolated {
            guard self.virtualMachine === virtualMachine, !operationInProgress, state != .installing else { return }
            state = .stopped
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            guard self.virtualMachine === virtualMachine else { return }
            // Leave the operation's active state visible until its async completion unwinds.
            // A premature .failed state would let the library remove or restart its disk.
            if operationInProgress {
                errorMessage = error.localizedDescription
                return
            }
            fail(error)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        MainActor.assumeIsolated {
            guard self.virtualMachine === virtualMachine else { return }
            errorMessage = "The guest's network connection failed: \(error.localizedDescription)"
        }
    }

    private func makeConfiguration(bootInstaller: Bool) throws -> VZVirtualMachineConfiguration {
        guard VZVirtualMachine.isSupported else {
            throw EngineError.message("Hardware virtualization is unavailable on this Mac.")
        }
        guard FileManager.default.isReadableFile(atPath: location.disk.path) else {
            throw EngineError.message("The virtual disk is missing or unreadable.")
        }
        guard (VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount).contains(record.cpuCount),
              record.memoryGiB > 0, record.memoryGiB <= Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize >> 30) else {
            throw EngineError.message("The CPU or memory allocation is outside this Mac's supported range.")
        }
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = record.cpuCount
        configuration.memorySize = UInt64(record.memoryGiB) * 1_073_741_824

        if record.guest.isMacOS {
            configuration.bootLoader = VZMacOSBootLoader()
            configuration.platform = try loadMacPlatform()
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: record.displayWidth, heightInPixels: record.displayHeight, pixelsPerInch: 144)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZMacKeyboardConfiguration(), VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        } else {
            let bootLoader = VZEFIBootLoader()
            if FileManager.default.fileExists(atPath: location.efi.path) {
                bootLoader.variableStore = VZEFIVariableStore(url: location.efi)
            } else {
                bootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: location.efi)
            }
            configuration.bootLoader = bootLoader
            let platform = VZGenericPlatformConfiguration()
            if FileManager.default.fileExists(atPath: location.machineIdentifier.path) {
                guard let identifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: location.machineIdentifier)) else {
                    throw EngineError.message("This Linux VM's hardware identity is invalid. Restore its original MachineIdentifier.bin file.")
                }
                platform.machineIdentifier = identifier
            } else {
                let identifier = VZGenericMachineIdentifier()
                try identifier.dataRepresentation.write(to: location.machineIdentifier, options: .atomic)
                platform.machineIdentifier = identifier
            }
            configuration.platform = platform
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: record.displayWidth, heightInPixels: record.displayHeight)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            if record.clipboardSharing {
                let clipboard = VZSpiceAgentPortAttachment()
                clipboard.sharesClipboard = true
                let port = VZVirtioConsolePortConfiguration()
                port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
                port.attachment = clipboard
                let console = VZVirtioConsoleDeviceConfiguration()
                console.ports[0] = port
                configuration.consoleDevices = [console]
            }
        }

        let syncMode: VZDiskImageSynchronizationMode = (record.diskSyncMode == .safest) ? .full : .none
        let cachingMode: VZDiskImageCachingMode = (record.diskSyncMode == .fastest) ? .cached : .automatic
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: location.disk, readOnly: false, cachingMode: cachingMode, synchronizationMode: syncMode)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        if bootInstaller, !record.guest.isMacOS {
            guard let path = record.installerPath, FileManager.default.isReadableFile(atPath: path) else {
                throw EngineError.message("Choose a readable ARM64 / AArch64 Linux ISO to boot the installer.")
            }
            let iso = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: true)
            configuration.storageDevices.insert(VZUSBMassStorageDeviceConfiguration(attachment: iso), at: 0)
        }

        if record.networkEnabled {
            let network = VZVirtioNetworkDeviceConfiguration()
            guard let macAddress = VZMACAddress(string: record.macAddress), macAddress.isLocallyAdministeredAddress, !macAddress.isMulticastAddress else {
                throw EngineError.message("The VM's network address is invalid. Use a locally administered unicast MAC address.")
            }
            network.macAddress = macAddress
            network.attachment = VZNATNetworkDeviceAttachment()
            configuration.networkDevices = [network]
        }
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        if record.audioOutput || record.microphone {
            let sound = VZVirtioSoundDeviceConfiguration()
            if record.audioOutput {
                let output = VZVirtioSoundDeviceOutputStreamConfiguration()
                output.sink = VZHostAudioOutputStreamSink()
                sound.streams.append(output)
            }
            if record.microphone {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                sound.streams.append(input)
            }
            configuration.audioDevices = [sound]
        }

        if let path = record.sharedDirectoryPath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw EngineError.message("The shared folder is missing. Restore it or remove the folder from this VM's settings.")
            }
            let tag = record.guest.isMacOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "lumen"
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            fileSystem.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: record.sharedFolderReadOnly))
            configuration.directorySharingDevices = [fileSystem]
        }

        try configuration.validate()
        return configuration
    }

    private func prepareMacPlatform(hardwareModel: VZMacHardwareModel) throws {
        let fileManager = FileManager.default
        let files = [location.hardwareModel, location.machineIdentifier, location.auxiliaryStorage]
        let existing = files.filter { fileManager.fileExists(atPath: $0.path) }
        if existing.count == files.count {
            let platform = try loadMacPlatform()
            guard platform.hardwareModel.dataRepresentation == hardwareModel.dataRepresentation else {
                throw EngineError.message("This VM was created with a different Mac hardware model. Create a new VM for this restore image to keep its existing identity safe.")
            }
            return
        }
        guard existing.isEmpty else {
            throw EngineError.message("The Mac's hardware identity is incomplete. Restore the VM's original metadata or create a new VM.")
        }

        let identifier = VZMacMachineIdentifier()
        do {
            try hardwareModel.dataRepresentation.write(to: location.hardwareModel, options: .atomic)
            try identifier.dataRepresentation.write(to: location.machineIdentifier, options: .atomic)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: location.auxiliaryStorage, hardwareModel: hardwareModel)
        } catch {
            // All paths were absent on entry; remove only this attempt's incomplete identity.
            for url in files { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    private func loadMacPlatform() throws -> VZMacPlatformConfiguration {
        let fileManager = FileManager.default
        guard [location.hardwareModel, location.machineIdentifier, location.auxiliaryStorage].allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw EngineError.message("Install macOS from an IPSW restore image before starting this VM.")
        }
        guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: location.hardwareModel)), hardware.isSupported,
              let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: location.machineIdentifier)) else {
            throw EngineError.message("This VM's Mac hardware identity is invalid or unsupported by this host.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: location.auxiliaryStorage)
        return platform
    }

    private func synchronizeState() {
        guard let virtualMachine else { state = .stopped; return }
        switch virtualMachine.state {
        case .stopped: state = .stopped
        case .running: state = .running
        case .paused, .pausing, .saving: state = .paused
        case .starting, .resuming, .restoring: state = .starting
        case .stopping: state = .stopping
        case .error: state = .failed
        @unknown default: state = .failed
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        if let virtualMachine, virtualMachine.state != .stopped, virtualMachine.state != .error {
            // A failed API request does not necessarily mean the VM stopped.
            synchronizeState()
        } else {
            state = .failed
        }
    }

    private enum EngineError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }
}

/// The native view forwards absolute pointer input, keyboard events, and display-size changes.
struct GuestDisplayView: NSViewRepresentable {
    @ObservedObject var engine: AppleVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = engine.record.captureSystemKeys
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = engine.virtualMachine
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== engine.virtualMachine {
            view.virtualMachine = engine.virtualMachine
        }
        view.capturesSystemKeys = engine.record.captureSystemKeys
        view.automaticallyReconfiguresDisplay = true
    }
}
