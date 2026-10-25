import OpenCleanAppModel
import SwiftUI
import SystemMonitor

struct PerformanceOverview: View {
    @Environment(PerformanceModel.self) private var model
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled = true
    @AppStorage(MenuBarSettings.metricKey) private var menuBarMetric = MenuBarMetric.cpuAndMemory.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    MetricCard(
                        title: String(localized: "CPU"), symbol: "cpu", value: formatPercent(model.cpu),
                        detail: String(localized: "Busy across all cores"), points: model.cpuHistory, maxValue: 1)
                    MetricCard(
                        title: String(localized: "Memory"), symbol: "memorychip",
                        value: model.memory.map { formatMemory($0.used) } ?? "–",
                        detail: memoryDetail, points: model.memoryHistory, maxValue: 1,
                        tag: model.memory.map {
                            (String(localized: "Pressure: \(pressureLabel($0.pressure))"), pressureColor($0.pressure))
                        })
                    MetricCard(
                        title: String(localized: "GPU"), symbol: "cube", value: formatPercent(model.gpu?.utilization),
                        detail: model.gpu.map {
                            String(localized: "\(formatMemory($0.inUseBytes)) of shared memory")
                        } ?? "",
                        points: model.gpuHistory, maxValue: 1)
                }
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14
                ) {
                    MetricCard(
                        title: String(localized: "Disk"), symbol: "internaldrive",
                        value: model.disk.map { String(localized: "\(formatCapacity($0.available)) free") } ?? "–",
                        detail: model.disk.map {
                            String(localized: "of \(formatCapacity($0.total)) on your startup disk")
                        } ?? "",
                        fraction: model.disk.map { $0.usedFraction })
                    MetricCard(
                        title: String(localized: "Network"), symbol: "arrow.up.arrow.down",
                        value: "↓ \(formatRate(model.network?.receivedPerSecond))",
                        detail: String(localized: "↑ \(formatRate(model.network?.sentPerSecond)) sent"),
                        points: model.receivedHistory)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Menu bar").font(.system(size: 18, weight: .bold))
                    HStack {
                        Text("Show OpenClean in the menu bar")
                        Spacer()
                        Toggle("Show OpenClean in the menu bar", isOn: $menuBarEnabled)
                            .toggleStyle(.switch)
                            .tint(Theme.accent)
                            .labelsHidden()
                    }
                    HStack {
                        Text("Show next to the icon")
                        Spacer()
                        Picker("Show next to the icon", selection: $menuBarMetric) {
                            ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    .disabled(!menuBarEnabled)
                    Text("The menu bar monitor only samples while it shows a figure or its window is open.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 14))
                .padding(18)
                .glassPanel()
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .task { await model.monitor(.metrics) }
    }

    private var memoryDetail: String {
        guard let memory = model.memory else { return "" }
        return String(localized: "used of \(formatMemory(memory.total))")
    }
}

struct MetricCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var points: [MetricPoint] = []
    var maxValue: Double?
    var fraction: Double?
    var tag: (String, Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Theme.textSecondary)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let tag { StatusTag(text: tag.0, color: tag.1) }
            }
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .rollingNumber(value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent)
                    .frame(height: 44, alignment: .bottom)
            } else {
                Sparkline(points: points, maxValue: maxValue).frame(height: 44)
            }
        }
        .padding(16)
        .glassPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }
}
