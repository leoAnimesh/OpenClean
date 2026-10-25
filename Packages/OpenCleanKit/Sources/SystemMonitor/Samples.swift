import Foundation

/// Cumulative CPU ticks across all cores since boot (`HOST_CPU_LOAD_INFO`).
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// macOS memory pressure as reported by `kern.memorystatus_vm_pressure_level`.
public enum MemoryPressure: String, Sendable, Equatable {
    case normal, warning, critical, unknown

    /// 1 = normal, 2 = warning, 4 = critical (`kVMPressure*` values); anything else is unknown.
    public init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// Memory counters in bytes (`HOST_VM_INFO64` pages × page size).
public struct MemorySnapshot: Sendable, Equatable {
    public var physical: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// Anonymous (app) memory, `internal_page_count`.
    public var `internal`: UInt64
    public var purgeable: UInt64
    public var pressure: MemoryPressure

    public init(
        physical: UInt64, free: UInt64 = 0, active: UInt64 = 0, inactive: UInt64 = 0, wired: UInt64,
        compressed: UInt64, internal: UInt64, purgeable: UInt64, pressure: MemoryPressure
    ) {
        self.physical = physical
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.internal = `internal`
        self.purgeable = purgeable
        self.pressure = pressure
    }
}

/// Bytes received and sent since boot, summed over non-loopback interfaces.
public struct NetworkCounters: Sendable, Equatable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

public struct DiskSnapshot: Sendable, Equatable {
    public var available: Int64
    public var total: Int64

    public init(available: Int64, total: Int64) {
        self.available = available
        self.total = total
    }

    public var usedFraction: Double { total > 0 ? Double(total - available) / Double(total) : 0 }
}

/// The integrated GPU at one moment. On Apple silicon it has no memory of its own: what it uses comes
/// out of the same physical memory as everything else.
public struct GPUSnapshot: Sendable, Equatable {
    /// 0…1, the driver's own "Device Utilization %".
    public var utilization: Double?
    /// Physical memory the GPU is using right now.
    public var inUseBytes: UInt64
    /// Physical memory the GPU driver has allocated, in use or not.
    public var allocatedBytes: UInt64
    /// Metal's `recommendedMaxWorkingSetSize`: how much memory the GPU can use before performance suffers.
    public var workingSetLimit: UInt64?

    public init(utilization: Double?, inUseBytes: UInt64, allocatedBytes: UInt64, workingSetLimit: UInt64? = nil) {
        self.utilization = utilization
        self.inUseBytes = inUseBytes
        self.allocatedBytes = allocatedBytes
        self.workingSetLimit = workingSetLimit
    }
}

/// One process at one moment: cumulative CPU time and resident memory.
public struct ProcessSample: Sendable, Equatable {
    public var pid: Int32
    public var uid: UInt32
    public var name: String
    /// Absolute executable path, if readable.
    public var path: String?
    public var cpuTimeNanoseconds: UInt64
    public var residentBytes: UInt64
    /// Cumulative GPU time of the process's Metal clients; 0 when it never used the GPU.
    public var gpuTimeNanoseconds: UInt64

    public init(
        pid: Int32, uid: UInt32 = 501, name: String, path: String?, cpuTimeNanoseconds: UInt64,
        residentBytes: UInt64, gpuTimeNanoseconds: UInt64 = 0
    ) {
        self.pid = pid
        self.uid = uid
        self.name = name
        self.path = path
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.residentBytes = residentBytes
        self.gpuTimeNanoseconds = gpuTimeNanoseconds
    }
}

/// What a sampler should collect. Process sampling is the expensive part, so it's opt-in.
public struct SampleRequest: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let metrics = SampleRequest(rawValue: 1 << 0)
    public static let processes = SampleRequest(rawValue: 1 << 1)
}

/// Everything captured in one sampling pass. Fields are nil when not requested or unreadable.
public struct RawSample: Sendable, Equatable {
    public var time: TimeInterval
    public var cpu: CPUTicks?
    public var memory: MemorySnapshot?
    public var network: NetworkCounters?
    public var disk: DiskSnapshot?
    public var gpu: GPUSnapshot?
    public var processes: [ProcessSample]?

    public init(
        time: TimeInterval, cpu: CPUTicks? = nil, memory: MemorySnapshot? = nil, network: NetworkCounters? = nil,
        disk: DiskSnapshot? = nil, gpu: GPUSnapshot? = nil, processes: [ProcessSample]? = nil
    ) {
        self.time = time
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.disk = disk
        self.gpu = gpu
        self.processes = processes
    }
}

/// Source of raw counters. The real one reads mach/sysctl/libproc; tests use fakes.
public protocol SystemSampler: Sendable {
    func sample(_ request: SampleRequest) -> RawSample
}
