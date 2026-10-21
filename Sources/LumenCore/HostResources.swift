import Foundation

/// The Mac's capacity and how much of it Lumen must leave for macOS itself.
public struct HostResources: Equatable {
    public let memoryGiB: Int
    public let cpuCount: Int
    public let performanceCores: Int

    public init(memoryGiB: Int, cpuCount: Int, performanceCores: Int? = nil) {
        self.memoryGiB = max(1, memoryGiB)
        self.cpuCount = max(1, cpuCount)
        self.performanceCores = max(1, performanceCores ?? cpuCount)
    }

    public static var current: HostResources {
        var performance: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let hasPerformance = sysctlbyname("hw.perflevel0.physicalcpu", &performance, &size, nil, 0) == 0 && performance > 0
        return HostResources(memoryGiB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
                             cpuCount: ProcessInfo.processInfo.activeProcessorCount,
                             performanceCores: hasPerformance ? Int(performance) : nil)
    }

    /// A quarter of RAM, between 4 and 16 GiB, keeps macOS, the window server and apps fluid.
    public var defaultMemoryReserveGiB: Int { min(16, max(4, memoryGiB / 4)) }
    public var defaultCPUReserve: Int { cpuCount >= 8 ? 2 : 1 }
}

public struct ResourcePolicy: Equatable {
    public var memoryReserveGiB: Int
    public var cpuReserve: Int

    public init(memoryReserveGiB: Int, cpuReserve: Int) {
        self.memoryReserveGiB = max(2, memoryReserveGiB)
        self.cpuReserve = max(0, cpuReserve)
    }

    public init(defaultsFor host: HostResources) {
        self.init(memoryReserveGiB: host.defaultMemoryReserveGiB, cpuReserve: host.defaultCPUReserve)
    }

    /// Memory all running guests may share.
    public func guestMemoryBudgetGiB(on host: HostResources) -> Int { max(2, host.memoryGiB - memoryReserveGiB) }
    /// Virtual CPUs per machine. Guests share cores, but one VM must never be able to saturate every core.
    public func maxCPUsPerMachine(on host: HostResources) -> Int { max(1, host.cpuCount - cpuReserve) }

    public func canStart(memoryGiB: Int, alreadyRunningGiB: Int, on host: HostResources) -> Bool {
        alreadyRunningGiB + memoryGiB <= guestMemoryBudgetGiB(on: host)
    }

    /// Sensible starting values for a new machine on this Mac.
    public func recommended(for guest: GuestOS, distribution: LinuxDistribution? = nil, on host: HostResources) -> (cpus: Int, memoryGiB: Int, diskGiB: Int) {
        let cpuCap = maxCPUsPerMachine(on: host)
        let memoryCap = guestMemoryBudgetGiB(on: host)
        // Windows Setup decompresses large WIM images. Use the performance-core
        // budget for Windows instead of the smaller interactive Linux default.
        let cpus = guest == .windows
            ? min(cpuCap, max(2, host.performanceCores))
            : min(cpuCap, max(2, min(host.performanceCores / 2 + 2, 6)))
        let memory: Int
        let disk: Int
        switch guest {
        case .macOS: memory = 8; disk = 96
        case .windows: memory = 8; disk = 96
        default:
            memory = distribution?.recommendedMemoryGiB ?? 8
            disk = distribution?.recommendedDiskGiB ?? 64
        }
        return (cpus, max(guest.minimumMemoryGiB, min(memory, memoryCap)), max(guest.minimumDiskGiB, disk))
    }
}
