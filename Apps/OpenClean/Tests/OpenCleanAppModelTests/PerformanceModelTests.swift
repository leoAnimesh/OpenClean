import Foundation
import Maintenance
import OpenCleanKit
import ScanEngine
import SystemMonitor
import TestSupport
import Testing

@testable import OpenCleanAppModel

/// Counts samples; returns steadily increasing counters.
final class CountingSampler: SystemSampler, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var requested: [SampleRequest] = []

    var samples: Int { lock.withLock { count } }
    var requests: [SampleRequest] { lock.withLock { requested } }

    func sample(_ request: SampleRequest) -> RawSample {
        lock.withLock {
            count += 1
            requested.append(request)
            let n = UInt64(count)
            return RawSample(
                time: Double(count), cpu: CPUTicks(user: n * 10, system: 0, idle: n * 30, nice: 0),
                network: NetworkCounters(received: n * 1_000, sent: n * 100))
        }
    }
}

/// Polls until `condition` holds or 5 s pass, so timing-based tests don't flake on slow machines.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
struct PerformanceModelTests {
    func makeModel(
        _ home: TempDirectory, sampler: CountingSampler = CountingSampler(),
        admin: FakeMaintenanceAdminExecutor = FakeMaintenanceAdminExecutor(),
        runner: FakeCommandRunner = FakeCommandRunner(), interval: Duration = .milliseconds(50)
    ) throws -> PerformanceModel {
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]), processChecker: FakeProcessChecker(),
            openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
        let agents = try home.directory("Library/LaunchAgents")
        let empty = try home.directory("empty")
        let roots = LaunchItemRoots(userAgents: agents, systemAgents: empty, systemDaemons: empty)
        return PerformanceModel(
            coordinator: coordinator, monitor: SystemMonitor(sampler: sampler),
            loginItems: { coordinator.loginItemsService(runner: runner, roots: roots, installedApps: []) },
            maintenance: coordinator.maintenanceRunner(runner: runner, admin: admin),
            availableTasks: MaintenanceTask.allCases, interval: interval)
    }

    @Test func newDemandIsSampledWithoutWaitingForTheNextTick() async throws {
        let home = try TempDirectory()
        let sampler = CountingSampler()
        let model = try makeModel(home, sampler: sampler, interval: .seconds(10))
        let metrics = Task { await model.monitor(.metrics) }
        defer { metrics.cancel() }
        try await waitUntil { model.cpu != nil }

        // The menu bar keeps CPU going on a long interval; opening the process list must not wait for it.
        let started = Date()
        let processes = Task { await model.monitor([.metrics, .processes]) }
        defer { processes.cancel() }
        try await waitUntil { sampler.requests.filter { $0.contains(.processes) }.count >= 2 }
        #expect(sampler.requests.filter { $0.contains(.processes) }.count >= 2)
        #expect(Date().timeIntervalSince(started) < 3, "two process samples, not two 10 s ticks")
    }

    @Test func samplesOnlyWhileSomethingIsObserving() async throws {
        let home = try TempDirectory()
        let sampler = CountingSampler()
        let model = try makeModel(home, sampler: sampler)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sampler.samples == 0, "no observers, no work")

        let observer = Task { await model.monitor(.metrics) }
        try await waitUntil { model.cpu != nil }
        #expect(model.isSampling)
        #expect(sampler.samples >= 2)
        #expect(model.cpu == 0.25)
        #expect(!model.cpuHistory.isEmpty)
        #expect(sampler.requests.allSatisfy { $0 == .metrics }, "processes are only sampled when asked for")

        observer.cancel()
        try await waitUntil { !model.isSampling }
        #expect(!model.isSampling)
        try await Task.sleep(for: .milliseconds(100))
        let stopped = sampler.samples
        try await Task.sleep(for: .milliseconds(200))
        #expect(sampler.samples == stopped)
    }

    @Test func combinesDemandsFromSeveralObservers() async throws {
        let home = try TempDirectory()
        let sampler = CountingSampler()
        let model = try makeModel(home, sampler: sampler)
        let label = Task { await model.monitor(.metrics) }
        let list = Task { await model.monitor(.processes) }
        try await waitUntil { model.combinedRequest == [.metrics, .processes] }
        #expect(model.combinedRequest == [.metrics, .processes])
        list.cancel()
        try await waitUntil { model.combinedRequest == .metrics }
        #expect(model.combinedRequest == .metrics)
        #expect(model.isSampling)
        label.cancel()
        try await waitUntil { !model.isSampling }
        #expect(!model.isSampling)
    }

    @Test func maintenanceRunRecordsOutcomeAndLastRun() async throws {
        let home = try TempDirectory()
        let admin = FakeMaintenanceAdminExecutor()
        let model = try makeModel(home, admin: admin)
        await model.run(.flushDNSCache)
        #expect(admin.commands == [.flushDNSCache])
        #expect(model.lastResult?.outcome == .succeeded)
        #expect(model.records[.flushDNSCache]?.succeeded == true)
        #expect(model.runningTask == nil)

        // A user task whose command isn't stubbed fails, and that is what gets recorded.
        await model.run(.rebuildLaunchServices)
        #expect(model.records[.rebuildLaunchServices]?.succeeded == false)
    }

    @Test func removingAUserAgentQuarantinesItAndRefreshes() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        let model = try makeModel(home, runner: runner)
        let path = home.path + "/Library/LaunchAgents/com.example.agent.plist"
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.agent"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path))
        await model.refreshLoginItems()
        let item = try #require(model.inventory?.items.first)
        await model.remove(item)
        #expect(model.loginItemsNotice?.isError == false)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(model.inventory?.items.isEmpty == true)
        #expect(model.busyItems.isEmpty)
    }
}
