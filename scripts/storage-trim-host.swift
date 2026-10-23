import Foundation
import Virtualization

/// Headless Apple-Virtualization half of validate-storage-trim.py. Uses only its
/// newly-created scratch disk and read-only live ISO, with no network or shares.
@main
@MainActor
final class StorageTrimHost: NSObject, VZVirtualMachineDelegate {
    private static var host: StorageTrimHost?
    private var machine: VZVirtualMachine?

    static func main() async {
        do {
            guard CommandLine.arguments.count == 5 else { throw NSError(domain: "StorageTrim", code: 1) }
            let paths = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
            let configuration = VZVirtualMachineConfiguration()
            let boot = VZLinuxBootLoader(kernelURL: paths[0])
            boot.initialRamdiskURL = paths[1]
            boot.commandLine = "console=hvc0 rdinit=/lumen-storage-init panic=1"
            configuration.bootLoader = boot
            configuration.cpuCount = 2
            configuration.memorySize = 2 * 1_073_741_824
            configuration.platform = VZGenericPlatformConfiguration()
            configuration.storageDevices = try [
                VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(
                    url: paths[2], readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)),
                VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: paths[3], readOnly: true))
            ]
            let console = VZVirtioConsoleDeviceSerialPortConfiguration()
            console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: .standardInput, fileHandleForWriting: .standardOutput)
            configuration.serialPorts = [console]
            try configuration.validate()
            let runtime = StorageTrimHost()
            host = runtime
            runtime.machine = VZVirtualMachine(configuration: configuration)
            runtime.machine?.delegate = runtime
            try await runtime.machine?.start()
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        } catch {
            FileHandle.standardError.write(Data("Storage test failed: \(error)\n".utf8))
            exit(1)
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) { exit(0) }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Storage test stopped: \(error)\n".utf8))
        exit(1)
    }
}
