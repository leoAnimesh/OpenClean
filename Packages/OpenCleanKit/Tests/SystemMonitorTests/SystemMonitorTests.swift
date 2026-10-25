import Foundation
import Testing

@testable import SystemMonitor

struct MetricsCalculatorTests {
    @Test func cpuUsageIsBusyOverTotalTicks() throws {
        let before = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let after = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        // busy = 60 + 20 + 20 = 100, idle = 100
        let usage = try #require(MetricsCalculator.cpuUsage(from: before, to: after))
        #expect(abs(usage - 0.5) < 0.0001)
    }

    @Test func cpuUsageIsNilWithoutElapsedTicks() {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        #expect(MetricsCalculator.cpuUsage(from: ticks, to: ticks) == nil)
    }

    @Test func cpuCounterWrapCountsAsZeroNotHuge() throws {
        let before = CPUTicks(user: UInt64(UInt32.max) - 5, system: 10, idle: 100, nice: 0)
        let after = CPUTicks(user: 3, system: 20, idle: 110, nice: 0)
        let usage = try #require(MetricsCalculator.cpuUsage(from: before, to: after))
        #expect(usage >= 0 && usage <= 1)
        #expect(abs(usage - 0.5) < 0.0001)
    }

    @Test func memoryUsedMatchesActivityMonitorFormula() {
        let gib: UInt64 = 1 << 30
        let snapshot = MemorySnapshot(
            physical: 16 * gib, wired: 2 * gib, compressed: 1 * gib, internal: 6 * gib, purgeable: 1 * gib,
            pressure: .normal)
        let usage = MetricsCalculator.memoryUsage(snapshot)
        #expect(usage.appMemory == 5 * gib)
        #expect(usage.used == 8 * gib)
        #expect(usage.total == 16 * gib)
        #expect(abs(usage.usedFraction - 0.5) < 0.0001)
    }

    @Test func memoryUsedNeverExceedsPhysicalOrUnderflows() {
        let snapshot = MemorySnapshot(
            physical: 100, wired: 80, compressed: 80, internal: 10, purgeable: 50, pressure: .warning)
        let usage = MetricsCalculator.memoryUsage(snapshot)
        #expect(usage.appMemory == 0)
        #expect(usage.used == 100)
        #expect(usage.usedFraction == 1)
    }

    @Test func networkRatesAreBytesPerSecond() {
        let rates = MetricsCalculator.networkRates(
            from: NetworkCounters(received: 1_000, sent: 500), to: NetworkCounters(received: 5_000, sent: 1_500),
            interval: 2)
        #expect(rates == NetworkRates(receivedPerSecond: 2_000, sentPerSecond: 500))
    }

    @Test func networkResetGivesZeroNotNegative() {
        let rates = MetricsCalculator.networkRates(
            from: NetworkCounters(received: 9_000, sent: 9_000), to: NetworkCounters(received: 100, sent: 9_100),
            interval: 2)
        #expect(rates.receivedPerSecond == 0)
        #expect(rates.sentPerSecond == 50)
        #expect(
            MetricsCalculator.networkRates(
                from: NetworkCounters(received: 0, sent: 0), to: NetworkCounters(received: 10, sent: 10), interval: 0)
                == .zero)
    }

    @Test func pressureLevelsMapFromSysctl() {
        #expect(MemoryPressure(sysctlLevel: 1) == .normal)
        #expect(MemoryPressure(sysctlLevel: 2) == .warning)
        #expect(MemoryPressure(sysctlLevel: 4) == .critical)
        #expect(MemoryPressure(sysctlLevel: 0) == .unknown)
    }
}

/// Returns queued samples in order.
final class FakeSampler: SystemSampler, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [RawSample]
    private(set) var requests: [SampleRequest] = []

    init(_ samples: [RawSample]) { queue = samples }

    func sample(_ request: SampleRequest) -> RawSample {
        lock.withLock {
            requests.append(request)
            return queue.isEmpty ? RawSample(time: 0) : queue.removeFirst()
        }
    }
}

struct SystemMonitorTests {
    let policy = ForceQuitPolicy(ownPID: 999, currentUID: 501)

    @Test func firstSampleHasNoRatesThenSecondDoes() {
        let gib: UInt64 = 1 << 30
        let memory = MemorySnapshot(
            physical: 8 * gib, wired: gib, compressed: 0, internal: gib, purgeable: 0, pressure: .normal)
        let sampler = FakeSampler([
            RawSample(
                time: 10, cpu: CPUTicks(user: 0, system: 0, idle: 0, nice: 0), memory: memory,
                network: NetworkCounters(received: 0, sent: 0)),
            RawSample(
                time: 12, cpu: CPUTicks(user: 25, system: 0, idle: 75, nice: 0), memory: memory,
                network: NetworkCounters(received: 4_000, sent: 2_000)),
        ])
        let monitor = SystemMonitor(sampler: sampler, policy: policy)
        let first = monitor.next(.metrics)
        #expect(first.cpu == nil)
        #expect(first.network == nil)
        #expect(first.memory?.used == 2 * gib)
        let second = monitor.next(.metrics)
        #expect(second.cpu == 0.25)
        #expect(second.network == NetworkRates(receivedPerSecond: 2_000, sentPerSecond: 1_000))
    }

    @Test func gpuFiguresPassThroughFromTheFirstSample() {
        let gpu = GPUSnapshot(utilization: 0.4, inUseBytes: 1_000, allocatedBytes: 2_000, workingSetLimit: 8_000)
        let monitor = SystemMonitor(sampler: FakeSampler([RawSample(time: 0, gpu: gpu)]), policy: policy)
        #expect(monitor.next(.metrics).gpu == gpu)
    }

    @Test func processIntervalIsTrackedSeparatelyFromMetrics() throws {
        let app = "/Applications/Editor.app/Contents/MacOS/Editor"
        let ticks = CPUTicks(user: 0, system: 0, idle: 1, nice: 0)
        let sampler = FakeSampler([
            RawSample(time: 0, cpu: ticks),
            RawSample(
                time: 2, cpu: ticks,
                processes: [ProcessSample(pid: 10, name: "Editor", path: app, cpuTimeNanoseconds: 0, residentBytes: 1)]
            ),
            RawSample(
                time: 6, cpu: ticks,
                processes: [
                    ProcessSample(
                        pid: 10, name: "Editor", path: app, cpuTimeNanoseconds: 2_000_000_000, residentBytes: 1)
                ]),
        ])
        let monitor = SystemMonitor(sampler: sampler, policy: policy)
        _ = monitor.next(.metrics)
        #expect(monitor.next([.metrics, .processes]).groups == nil, "first process sample has no baseline")
        let groups = try #require(monitor.next([.metrics, .processes]).groups)
        // 2 s of CPU over the 4 s since the previous process sample (not the metrics one) = 50 %.
        #expect(groups.first?.cpuPercent == 50)
    }

    @Test func restartingProcessSamplingStartsAFreshBaseline() throws {
        let app = "/Applications/Editor.app/Contents/MacOS/Editor"
        func editor(_ seconds: UInt64) -> [ProcessSample] {
            [
                ProcessSample(
                    pid: 10, name: "Editor", path: app, cpuTimeNanoseconds: seconds * 1_000_000_000, residentBytes: 1)
            ]
        }
        let ticks = CPUTicks(user: 0, system: 0, idle: 1, nice: 0)
        let sampler = FakeSampler([
            RawSample(time: 0, cpu: ticks, processes: editor(0)),
            RawSample(time: 2, cpu: ticks, processes: editor(2)),
            // Process list closed; the menu bar keeps sampling metrics for a long time.
            RawSample(time: 50, cpu: ticks),
            RawSample(time: 100, cpu: ticks),
            // Reopened: the Editor was busy just now, idle before.
            RawSample(time: 102, cpu: ticks, processes: editor(10)),
            RawSample(time: 104, cpu: ticks, processes: editor(11)),
        ])
        let monitor = SystemMonitor(sampler: sampler, policy: policy)
        let both: SampleRequest = [.metrics, .processes]
        _ = monitor.next(both)
        #expect(try #require(monitor.next(both).groups).first?.cpuPercent == 100)
        _ = monitor.next(.metrics)
        _ = monitor.next(.metrics)
        #expect(monitor.next(both).groups == nil, "no figure averaged over the 100 s gap")
        #expect(try #require(monitor.next(both).groups).first?.cpuPercent == 50)
    }
}

struct ProcessUsageTests {
    let policy = ForceQuitPolicy(ownPID: 999, currentUID: 501)

    @Test func cpuPercentFromCPUTimeDelta() {
        let previous = [
            ProcessSample(pid: 1_000, name: "a", path: "/x/a", cpuTimeNanoseconds: 1_000_000_000, residentBytes: 10),
            ProcessSample(pid: 1_001, name: "b", path: "/x/b", cpuTimeNanoseconds: 5_000_000_000, residentBytes: 10),
        ]
        let current = [
            ProcessSample(pid: 1_000, name: "a", path: "/x/a", cpuTimeNanoseconds: 4_000_000_000, residentBytes: 20),
            // pid reused by a different process: no delta for this interval
            ProcessSample(pid: 1_001, name: "c", path: "/x/c", cpuTimeNanoseconds: 9_000_000_000, residentBytes: 10),
            // new process
            ProcessSample(pid: 1_002, name: "d", path: "/x/d", cpuTimeNanoseconds: 7_000_000_000, residentBytes: 10),
        ]
        let usage = ProcessUsageCalculator.usage(previous: previous, current: current, interval: 2)
        #expect(usage.map(\.cpuPercent) == [150, 0, 0])
        #expect(usage[0].residentBytes == 20)
    }

    @Test func gpuPercentFromGPUTimeDelta() {
        let previous = [
            ProcessSample(
                pid: 1_000, name: "a", path: "/x/a", cpuTimeNanoseconds: 0, residentBytes: 0,
                gpuTimeNanoseconds: 1_000_000_000),
            ProcessSample(
                pid: 1_001, name: "b", path: "/x/b", cpuTimeNanoseconds: 0, residentBytes: 0,
                gpuTimeNanoseconds: 5_000_000_000),
        ]
        let current = [
            ProcessSample(
                pid: 1_000, name: "a", path: "/x/a", cpuTimeNanoseconds: 0, residentBytes: 0,
                gpuTimeNanoseconds: 1_500_000_000),
            // A Metal client closed, so the sum went down: 0, not a wrapped value.
            ProcessSample(
                pid: 1_001, name: "b", path: "/x/b", cpuTimeNanoseconds: 0, residentBytes: 0,
                gpuTimeNanoseconds: 1_000_000_000),
        ]
        let usage = ProcessUsageCalculator.usage(previous: previous, current: current, interval: 2)
        #expect(usage.map(\.gpuPercent) == [25, 0])
    }

    @Test func helpersGroupUnderTheirOutermostApp() throws {
        let usages = [
            ProcessUsage(
                pid: 10, uid: 501, name: "Google Chrome",
                path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpuPercent: 5,
                residentBytes: 100),
            ProcessUsage(
                pid: 11, uid: 501, name: "Google Chrome Helper (Renderer)",
                path:
                    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                cpuPercent: 30, residentBytes: 400),
            ProcessUsage(
                pid: 12, uid: 501, name: "node", path: "/opt/homebrew/bin/node", cpuPercent: 80, residentBytes: 50),
        ]
        let groups = ProcessUsageCalculator.group(usages, policy: policy)
        #expect(groups.count == 2)
        let chrome = try #require(groups.first { $0.name == "Google Chrome" })
        #expect(chrome.bundlePath == "/Applications/Google Chrome.app")
        #expect(chrome.mainPID == 10)
        #expect(chrome.cpuPercent == 35)
        #expect(chrome.residentBytes == 500)
        #expect(chrome.processes.first?.pid == 11)
        #expect(chrome.canQuit)
        let node = try #require(groups.first { $0.name == "node" })
        #expect(node.id == "pid:12")
        #expect(node.bundlePath == nil)
        #expect(!node.canQuit, "bundle-less processes are never offered Quit")

        #expect(ProcessUsageCalculator.topByCPU(groups, limit: 1).map(\.name) == ["node"])
        #expect(ProcessUsageCalculator.topByMemory(groups, limit: 1).map(\.name) == ["Google Chrome"])
    }

    @Test func gpuPercentSumsOverTheGroup() throws {
        let usages = [
            ProcessUsage(
                pid: 10, uid: 501, name: "Game", path: "/Applications/Game.app/Contents/MacOS/Game", cpuPercent: 5,
                residentBytes: 100, gpuPercent: 30),
            ProcessUsage(
                pid: 11, uid: 501, name: "Game Helper",
                path: "/Applications/Game.app/Contents/Helpers/Game Helper.app/Contents/MacOS/Game Helper",
                cpuPercent: 1, residentBytes: 10, gpuPercent: 12),
            ProcessUsage(
                pid: 12, uid: 501, name: "node", path: "/opt/homebrew/bin/node", cpuPercent: 80, residentBytes: 50),
        ]
        let groups = ProcessUsageCalculator.group(usages, policy: policy)
        let game = try #require(groups.first { $0.name == "Game" })
        #expect(game.gpuPercent == 42)
        #expect(ProcessUsageCalculator.topByGPU(groups, limit: 1).map(\.name) == ["Game"])
    }

    @Test func helpersOnlyGroupHasNoMainProcessAndCannotQuit() throws {
        let usages = [
            ProcessUsage(
                pid: 20, uid: 501, name: "Helper",
                path: "/Applications/Tool.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper",
                cpuPercent: 1, residentBytes: 1)
        ]
        let group = try #require(ProcessUsageCalculator.group(usages, policy: policy).first)
        #expect(group.bundlePath == "/Applications/Tool.app")
        #expect(group.mainPID == nil)
        #expect(!group.canQuit)
    }

    @Test func outermostBundleIsByteLevel() {
        #expect(
            ProcessUsageCalculator.outermostAppBundle("/Applications/A.app/Contents/MacOS/A") == "/Applications/A.app")
        #expect(ProcessUsageCalculator.outermostAppBundle("/usr/bin/top") == nil)
        #expect(ProcessUsageCalculator.outermostAppBundle("relative/A.app/x") == nil)
        #expect(ProcessUsageCalculator.outermostAppBundle("/x/.app/y") == nil, "a folder named .app is not a bundle")
        #expect(ProcessUsageCalculator.outermostAppBundle("/x/A.application/y") == nil)
    }
}

struct ForceQuitPolicyTests {
    let policy = ForceQuitPolicy(ownPID: 999, currentUID: 501)

    func process(_ name: String, path: String?, pid: Int32 = 2_000, uid: UInt32 = 501) -> ProcessUsage {
        ProcessUsage(pid: pid, uid: uid, name: name, path: path, cpuPercent: 0, residentBytes: 0)
    }

    @Test func criticalSystemProcessesAreProtected() {
        for name in ["kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer"] {
            #expect(
                policy.isProtected(process(name, path: "/Applications/\(name).app/Contents/MacOS/\(name)")), "\(name)")
        }
        #expect(policy.isProtected(process("WindowServer", path: nil, uid: 88)))
        #expect(policy.isProtected(process("kernel_task", path: nil, pid: 0, uid: 0)))
        #expect(policy.isProtected(process("x", path: "/sbin/launchd", pid: 1)))
    }

    @Test func openCleanItselfIsProtected() {
        #expect(policy.isProtected(process("Anything", path: "/Applications/Anything.app/Contents/MacOS/A", pid: 999)))
        #expect(policy.isProtected(process("OpenClean", path: "/Applications/OpenClean.app/Contents/MacOS/OpenClean")))
        #expect(policy.isProtected(process("x", path: "/Users/u/OpenClean.app/Contents/MacOS/OpenCleanApp")))
    }

    @Test func otherUsersAndSystemLocationsAreProtected() {
        #expect(policy.isProtected(process("Editor", path: "/Applications/Editor.app/Contents/MacOS/Editor", uid: 0)))
        #expect(policy.isProtected(process("helperd", path: "/usr/libexec/helperd")))
        #expect(
            policy.isProtected(process("Thing", path: "/System/Library/CoreServices/Thing.app/Contents/MacOS/Thing")))
        #expect(policy.isProtected(process("unknown", path: nil)), "no path means we can't tell: protected")
    }

    @Test func ordinaryAppsIncludingAppleAppsInApplicationsAreAllowed() {
        #expect(!policy.isProtected(process("Editor", path: "/Applications/Editor.app/Contents/MacOS/Editor")))
        #expect(!policy.isProtected(process("Music", path: "/System/Applications/Music.app/Contents/MacOS/Music")))
        #expect(
            !policy.isProtected(
                process(
                    "Activity Monitor",
                    path: "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor")))
        #expect(!policy.isProtected(process("node", path: "/opt/homebrew/bin/node")))
    }
}

struct GPUStatisticsTests {
    @Test func snapshotReadsDriverStatistics() {
        let statistics: [String: Any] = [
            "Device Utilization %": NSNumber(value: 30),
            "In use system memory": NSNumber(value: 1_013_137_408),
            "Alloc system memory": NSNumber(value: 3_865_821_184),
        ]
        let snapshot = GPUStatistics.snapshot(statistics: statistics, workingSetLimit: 17_179_869_184)
        #expect(snapshot.utilization == 0.3)
        #expect(snapshot.inUseBytes == 1_013_137_408)
        #expect(snapshot.allocatedBytes == 3_865_821_184)
        #expect(snapshot.workingSetLimit == 17_179_869_184)
    }

    @Test func missingOrOutOfRangeFiguresStayInBounds() {
        let empty = GPUStatistics.snapshot(statistics: [:], workingSetLimit: nil)
        #expect(empty == GPUSnapshot(utilization: nil, inUseBytes: 0, allocatedBytes: 0))
        let over = GPUStatistics.snapshot(
            statistics: ["Device Utilization %": NSNumber(value: 140)], workingSetLimit: nil)
        #expect(over.utilization == 1)
    }

    @Test func pidComesFromTheClientCreator() {
        #expect(GPUStatistics.pid(fromCreator: "pid 171, WindowServer") == 171)
        #expect(GPUStatistics.pid(fromCreator: "pid 42") == 42)
        #expect(GPUStatistics.pid(fromCreator: "WindowServer") == nil)
        #expect(GPUStatistics.pid(fromCreator: "pid , x") == nil)
    }

    @Test func gpuTimeSumsEveryQueue() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 70_700_371_987_250)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 522_832_708)],
            ["API": "Metal"],
        ]
        #expect(GPUStatistics.gpuTime(appUsage: usage) == 70_700_894_819_958)
    }
}

struct DarwinSamplerSmokeTests {
    /// Read-only: the real sampler returns counters for this machine and our own process.
    @Test func realSamplerReadsCountersAndOwnProcess() throws {
        let sample = DarwinSampler().sample([.metrics, .processes])
        #expect(sample.cpu != nil)
        let memory = try #require(sample.memory)
        #expect(memory.physical > 0)
        #expect(sample.disk.map { $0.total > 0 } == true)
        let processes = try #require(sample.processes)
        #expect(processes.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}
