import Foundation
import Maintenance
import Observation
import OpenCleanKit
import Quarantine
import SystemMonitor

/// One point on a sparkline.
public struct MetricPoint: Identifiable, Sendable, Equatable {
    public let id: Int
    public let value: Double

    public init(id: Int, value: Double) {
        self.id = id
        self.value = value
    }
}

/// What the menu bar label shows next to the glyph.
public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case none, cpu, memory, gpu, cpuAndMemory, cpuMemoryAndGPU, network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: String(localized: "Icon only", bundle: .appModel)
        case .cpu: String(localized: "CPU", bundle: .appModel)
        case .memory: String(localized: "Memory", bundle: .appModel)
        case .gpu: String(localized: "GPU", bundle: .appModel)
        case .cpuAndMemory: String(localized: "CPU and memory", bundle: .appModel)
        case .cpuMemoryAndGPU: String(localized: "CPU, memory and GPU", bundle: .appModel)
        case .network: String(localized: "Network", bundle: .appModel)
        }
    }
}

/// State behind the Performance module and the menu bar monitor. Views read it and call its actions;
/// it never touches files itself (launch agent removal goes through Quarantine via `LoginItemsService`).
@MainActor
@Observable
public final class PerformanceModel {
    @ObservationIgnored let coordinator: OpenCleanCoordinator
    @ObservationIgnored let monitor: SystemMonitor
    @ObservationIgnored let makeLoginItems: @Sendable () -> LoginItemsService
    @ObservationIgnored let maintenance: MaintenanceRunner
    @ObservationIgnored let history: MaintenanceHistoryStore
    @ObservationIgnored let interval: Duration
    @ObservationIgnored private var loginItems: LoginItemsService?

    public static let historyLength = 60

    // MARK: Live metrics

    public private(set) var cpu: Double?
    public private(set) var memory: MemoryUsage?
    public private(set) var network: NetworkRates?
    public private(set) var disk: DiskSnapshot?
    public private(set) var gpu: GPUSnapshot?
    public private(set) var groups: [ProcessGroup] = []
    public private(set) var cpuHistory: [MetricPoint] = []
    public private(set) var memoryHistory: [MetricPoint] = []
    public private(set) var gpuHistory: [MetricPoint] = []
    public private(set) var receivedHistory: [MetricPoint] = []
    public private(set) var sentHistory: [MetricPoint] = []
    public private(set) var isSampling = false
    @ObservationIgnored private var demands: [UUID: SampleRequest] = [:]
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var pointCounter = 0

    // MARK: Login items

    public private(set) var inventory: LoginItemsInventory?
    public private(set) var isLoadingInventory = false
    public private(set) var busyItems: Set<String> = []
    /// The latest action result or error, shown under the list.
    public var loginItemsNotice: Notice?

    public struct Notice: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    // MARK: Maintenance

    public let availableTasks: [MaintenanceTask]
    public private(set) var records: [MaintenanceTask: MaintenanceRecord] = [:]
    public private(set) var runningTask: MaintenanceTask?
    public private(set) var lastResult: (task: MaintenanceTask, outcome: MaintenanceOutcome)?

    public init(
        coordinator: OpenCleanCoordinator, monitor: SystemMonitor? = nil,
        loginItems: (@Sendable () -> LoginItemsService)? = nil, maintenance: MaintenanceRunner? = nil,
        availableTasks: [MaintenanceTask]? = nil, interval: Duration = .seconds(2)
    ) {
        self.coordinator = coordinator
        self.monitor = monitor ?? coordinator.makeSystemMonitor()
        makeLoginItems = loginItems ?? { coordinator.loginItemsService() }
        self.maintenance = maintenance ?? coordinator.maintenanceRunner()
        history = coordinator.maintenanceHistory
        self.availableTasks = availableTasks ?? MaintenanceTask.available()
        self.interval = interval
        records = history.load()
    }

    public var retentionDays: Int { coordinator.settingsStore.load().clampedRetentionDays }

    // MARK: Sampling

    /// Registers demand for samples until the calling task is cancelled (use from `.task {}`).
    /// Sampling runs only while at least one caller is waiting here.
    public func monitor(_ request: SampleRequest) async {
        let id = UUID()
        demands[id] = request
        updateSampling()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
        demands[id] = nil
        updateSampling()
    }

    var combinedRequest: SampleRequest { demands.values.reduce(into: SampleRequest()) { $0.formUnion($1) } }

    private func updateSampling() {
        if combinedRequest.isEmpty {
            samplingTask?.cancel()
            samplingTask = nil
            isSampling = false
            monitor.reset()
        } else if samplingTask == nil {
            isSampling = true
            samplingTask = Task { [weak self] in await self?.sampleLoop() }
        }
    }

    private func sampleLoop() async {
        var primed = false
        while !Task.isCancelled {
            let request = combinedRequest
            guard !request.isEmpty else { return }
            let monitor = self.monitor
            let snapshot = await Task.detached(priority: .utility) { monitor.next(request) }.value
            guard !Task.isCancelled else { return }
            apply(snapshot)
            // The first figures need two samples; take the second one quickly.
            let wait: Duration = primed ? interval : .milliseconds(500)
            primed = true
            try? await Task.sleep(for: wait)
        }
    }

    func apply(_ snapshot: MonitorSnapshot) {
        pointCounter += 1
        if let value = snapshot.cpu {
            cpu = value
            append(&cpuHistory, value)
        }
        if let value = snapshot.memory {
            memory = value
            append(&memoryHistory, value.usedFraction)
        }
        if let value = snapshot.network {
            network = value
            append(&receivedHistory, value.receivedPerSecond)
            append(&sentHistory, value.sentPerSecond)
        }
        if let value = snapshot.disk { disk = value }
        if let value = snapshot.gpu {
            gpu = value
            if let utilization = value.utilization { append(&gpuHistory, utilization) }
        }
        if let value = snapshot.groups { groups = value }
    }

    private func append(_ series: inout [MetricPoint], _ value: Double) {
        series.append(MetricPoint(id: pointCounter, value: value))
        if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
    }

    public func topByCPU(_ limit: Int) -> [ProcessGroup] { ProcessUsageCalculator.topByCPU(groups, limit: limit) }
    public func topByMemory(_ limit: Int) -> [ProcessGroup] {
        ProcessUsageCalculator.topByMemory(groups, limit: limit)
    }
    public func topByGPU(_ limit: Int) -> [ProcessGroup] { ProcessUsageCalculator.topByGPU(groups, limit: limit) }

    // MARK: Login items

    private func service() -> LoginItemsService {
        if let loginItems { return loginItems }
        let made = makeLoginItems()
        loginItems = made
        return made
    }

    public func refreshLoginItems() async {
        guard !isLoadingInventory else { return }
        isLoadingInventory = true
        let service = service()
        inventory = await Task.detached(priority: .userInitiated) { service.inventory() }.value
        isLoadingInventory = false
    }

    public func disable(_ item: LaunchItem) async {
        await perform(
            item,
            success: String(
                localized: "\(item.label) is turned off and won't start again until you turn it on.", bundle: .appModel)
        ) {
            try $0.disable(item)
        }
    }

    public func enable(_ item: LaunchItem) async {
        await perform(item, success: String(localized: "\(item.label) is turned on.", bundle: .appModel)) {
            try $0.enable(item)
        }
    }

    public func remove(_ item: LaunchItem) async {
        let days = retentionDays
        await perform(
            item,
            success:
                String(
                    localized:
                        "\(item.label) was moved to quarantine. You can restore it from History for \(days) days; it loads again at your next login.",
                    bundle: .appModel)
        ) { service in
            try service.remove(item)
            return .done
        }
    }

    private func perform(
        _ item: LaunchItem, success: String,
        _ action: @escaping @Sendable (LoginItemsService) throws -> LaunchItemActionResult
    ) async {
        busyItems.insert(item.path)
        let service = service()
        let result = await Task.detached(priority: .userInitiated) { () -> Result<LaunchItemActionResult, Error> in
            Result { try action(service) }
        }.value
        busyItems.remove(item.path)
        switch result {
        case .success(.done): loginItemsNotice = Notice(text: success, isError: false)
        case .success(.doneWithNote(let note)): loginItemsNotice = Notice(text: note, isError: false)
        case .failure(let error):
            let text = (error as? LoginItemsError)?.description ?? error.localizedDescription
            loginItemsNotice = Notice(text: text, isError: true)
        }
        await refreshLoginItems()
    }

    // MARK: Maintenance

    public func run(_ task: MaintenanceTask) async {
        guard runningTask == nil else { return }
        runningTask = task
        lastResult = nil
        let runner = maintenance
        let outcome = await Task.detached(priority: .userInitiated) { runner.run(task) }.value
        try? history.record(task, outcome: outcome)
        records = history.load()
        lastResult = (task, outcome)
        runningTask = nil
    }

    public func dismissResult() { lastResult = nil }
}
