import OpenCleanAppModel
import SwiftUI
import SystemMonitor

/// How the integrated GPU shares physical memory with everything else, and who is using it.
struct MemoryGPUView: View {
    @Environment(PerformanceModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14
                ) {
                    MetricCard(
                        title: String(localized: "GPU"), symbol: "cube",
                        value: formatPercent(model.gpu?.utilization),
                        detail: String(localized: "Busy with graphics and compute work"), points: model.gpuHistory,
                        maxValue: 1)
                    MetricCard(
                        title: String(localized: "GPU memory"), symbol: "memorychip.fill",
                        value: model.gpu.map { formatMemory($0.inUseBytes) } ?? "–",
                        detail: gpuMemoryDetail, fraction: gpuMemoryFraction)
                }
                SharedMemoryPanel(memory: model.memory, gpu: model.gpu)
                GPUConsumersPanel(groups: model.topByGPU(5), measured: !model.groups.isEmpty)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .task { await model.monitor([.metrics, .processes]) }
    }

    private var gpuMemoryDetail: String {
        guard let limit = model.gpu?.workingSetLimit else { return "" }
        return String(localized: "Up to \(formatMemory(limit)) available to the GPU")
    }

    private var gpuMemoryFraction: Double? {
        guard let gpu = model.gpu, let limit = gpu.workingSetLimit, limit > 0 else { return nil }
        return min(1, Double(gpu.inUseBytes) / Double(limit))
    }
}

/// One bar for all of the Mac's memory: what the GPU uses, what apps and macOS use, and what is free,
/// with a mark where the GPU's limit sits.
struct SharedMemoryPanel: View {
    let memory: MemoryUsage?
    let gpu: GPUSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared memory").font(.system(size: 18, weight: .bold))
            if let memory, memory.total > 0 {
                let parts = SharedMemoryParts(memory: memory, gpu: gpu)
                SharedMemoryBar(parts: parts)
                    .frame(height: 14)
                    .padding(.top, gpu?.workingSetLimit == nil ? 0 : 14)
                HStack(spacing: 20) {
                    legend(String(localized: "GPU"), bytes: parts.gpu, color: Theme.gpu)
                    legend(String(localized: "Apps and macOS"), bytes: parts.other, color: Theme.accent)
                    legend(String(localized: "Free"), bytes: parts.free, color: Theme.glassStroke)
                    Spacer()
                }
                Text(caption(total: memory.total))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Measuring…").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private func legend(_ title: String, bytes: UInt64, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).foregroundStyle(Theme.textSecondary)
            Text(formatMemory(bytes)).monospacedDigit().rollingNumber(formatMemory(bytes))
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }

    private func caption(total: UInt64) -> String {
        if let limit = gpu?.workingSetLimit {
            return String(
                localized:
                    "The GPU has no memory of its own. It uses the same \(formatMemory(total)) as your apps, up to about \(formatMemory(limit))."
            )
        }
        return String(
            localized: "The GPU has no memory of its own. It uses the same \(formatMemory(total)) as your apps.")
    }
}

/// Splits physical memory into GPU, everything else in use, and free. Memory the GPU holds is wired,
/// so it is already part of `used`; it is taken out of the other share rather than added on top.
struct SharedMemoryParts: Equatable {
    let total: UInt64
    let gpu: UInt64
    let other: UInt64
    let free: UInt64
    let gpuLimit: UInt64?

    init(memory: MemoryUsage, gpu snapshot: GPUSnapshot?) {
        total = memory.total
        let used = min(memory.used, memory.total)
        gpu = min(snapshot?.inUseBytes ?? 0, used)
        other = used - gpu
        free = memory.total - used
        gpuLimit = snapshot?.workingSetLimit.map { min($0, memory.total) }
    }
}

struct SharedMemoryBar: View {
    let parts: SharedMemoryParts

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = parts.total > 0 ? width / CGFloat(parts.total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.glassStroke)
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.gpu).frame(width: CGFloat(parts.gpu) * scale)
                    Rectangle().fill(Theme.accent).frame(width: CGFloat(parts.other) * scale)
                }
                .clipShape(Capsule())
                if let limit = parts.gpuLimit {
                    let x = min(max(CGFloat(limit) * scale, 1), width - 1)
                    Rectangle()
                        .fill(Theme.textPrimary)
                        .frame(width: 2, height: geometry.size.height + 6)
                        .position(x: x, y: geometry.size.height / 2)
                    Text("GPU limit")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                        .position(x: min(max(x, 32), width - 32), y: -12)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: parts)
        .accessibilityElement()
        .accessibilityLabel("Shared memory")
        .accessibilityValue(
            "GPU \(formatMemory(parts.gpu)), apps and macOS \(formatMemory(parts.other)), free \(formatMemory(parts.free))"
        )
    }
}

struct GPUConsumersPanel: View {
    let groups: [ProcessGroup]
    let measured: Bool

    var body: some View {
        let busy = groups.filter { $0.gpuPercent >= 0.1 }
        VStack(alignment: .leading, spacing: 0) {
            Text("Using the GPU").font(.system(size: 18, weight: .bold)).padding(.bottom, 8)
            if !measured {
                Text("Measuring…").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            } else if busy.isEmpty {
                Text("None of your apps is using the GPU right now.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(busy) { group in
                HStack(spacing: 12) {
                    ProcessIcon(bundlePath: group.bundlePath, size: 24)
                    Text(group.name).font(.system(size: 14)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", group.gpuPercent))
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .accessibilityLabel("GPU \(Int(group.gpuPercent.rounded())) percent")
                }
                .frame(minHeight: 40)
                if group.id != busy.last?.id { Divider().overlay(Theme.glassDivider) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}
