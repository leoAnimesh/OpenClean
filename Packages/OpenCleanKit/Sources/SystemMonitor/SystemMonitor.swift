import Foundation

/// Derived, display-ready figures for one sampling interval.
public struct MonitorSnapshot: Sendable, Equatable {
    public var time: TimeInterval
    /// 0…1 across all cores; nil on the first sample (no interval yet).
    public var cpu: Double?
    public var memory: MemoryUsage?
    public var network: NetworkRates?
    public var disk: DiskSnapshot?
    public var gpu: GPUSnapshot?
    /// Grouped by app; nil when processes weren't requested or on the first process sample.
    public var groups: [ProcessGroup]?

    public init(
        time: TimeInterval, cpu: Double? = nil, memory: MemoryUsage? = nil, network: NetworkRates? = nil,
        disk: DiskSnapshot? = nil, gpu: GPUSnapshot? = nil, groups: [ProcessGroup]? = nil
    ) {
        self.time = time
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.disk = disk
        self.gpu = gpu
        self.groups = groups
    }
}

/// Turns successive raw samples into snapshots. Keeps only the previous metrics sample and the
/// previous process sample. Process sampling is a session: a request without `.processes` ends it, and
/// the next request with `.processes` starts a fresh baseline, so figures are never averaged over a gap
/// while only metrics were being sampled (e.g. the menu bar kept running while the process list closed).
public final class SystemMonitor: @unchecked Sendable {
    let sampler: any SystemSampler
    let policy: ForceQuitPolicy
    private let lock = NSLock()
    private var previousMetrics: RawSample?
    private var previousProcesses: RawSample?
    private var lastRequestHadProcesses = false

    public init(sampler: any SystemSampler = DarwinSampler(), policy: ForceQuitPolicy = ForceQuitPolicy()) {
        self.sampler = sampler
        self.policy = policy
    }

    /// Samples now and derives figures against the previous sample of each kind.
    public func next(_ request: SampleRequest) -> MonitorSnapshot {
        let current = sampler.sample(request)
        return lock.withLock {
            let sessionStarts = request.contains(.processes) && !lastRequestHadProcesses
            lastRequestHadProcesses = request.contains(.processes)
            if sessionStarts { previousProcesses = nil }
            let snapshot = Self.snapshot(
                previousMetrics: previousMetrics, previousProcesses: previousProcesses, current: current,
                policy: policy)
            if current.cpu != nil || current.network != nil { previousMetrics = current }
            if current.processes != nil { previousProcesses = current }
            return snapshot
        }
    }

    /// Forget previous samples, e.g. after a pause, so the next figures aren't averaged over it.
    public func reset() {
        lock.withLock {
            previousMetrics = nil
            previousProcesses = nil
            lastRequestHadProcesses = false
        }
    }

    /// Pure: figures for `current` relative to the previous samples.
    public static func snapshot(
        previousMetrics: RawSample?, previousProcesses: RawSample?, current: RawSample, policy: ForceQuitPolicy
    ) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot(time: current.time)
        if let cpu = current.cpu, let old = previousMetrics?.cpu {
            snapshot.cpu = MetricsCalculator.cpuUsage(from: old, to: cpu)
        }
        snapshot.memory = current.memory.map(MetricsCalculator.memoryUsage)
        if let network = current.network, let previousMetrics, let old = previousMetrics.network {
            let interval = current.time - previousMetrics.time
            if interval > 0 {
                snapshot.network = MetricsCalculator.networkRates(from: old, to: network, interval: interval)
            }
        }
        snapshot.disk = current.disk
        snapshot.gpu = current.gpu
        if let processes = current.processes, let previousProcesses, let old = previousProcesses.processes {
            let interval = current.time - previousProcesses.time
            if interval > 0 {
                let usage = ProcessUsageCalculator.usage(previous: old, current: processes, interval: interval)
                snapshot.groups = ProcessUsageCalculator.group(usage, policy: policy)
            }
        }
        return snapshot
    }
}
