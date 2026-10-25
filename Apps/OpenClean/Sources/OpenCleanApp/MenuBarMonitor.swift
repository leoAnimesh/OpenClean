import AppKit
import OpenCleanAppModel
import SwiftUI
import SystemMonitor

enum MenuBarSettings {
    static let enabledKey = "menuBarMonitorEnabled"
    static let metricKey = "menuBarMetric"
    static let mainWindowID = "main"
}

/// The status item: the logo glyph as a template image plus, optionally, one live figure.
/// Samples only while a figure is shown (or the popover is open).
struct MenuBarLabel: View {
    @Environment(PerformanceModel.self) private var model
    @AppStorage(MenuBarSettings.metricKey) private var metricRaw = MenuBarMetric.cpuAndMemory.rawValue

    var body: some View {
        let metric = MenuBarMetric(rawValue: metricRaw) ?? .cpuAndMemory
        HStack(spacing: 4) {
            if metric == .cpuAndMemory || metric == .cpuMemoryAndGPU {
                // A menu bar label keeps only one image and one text (extra and inline images are dropped),
                // so the icons and figures are drawn into a single template image.
                Image(
                    nsImage: MenuBarFiguresImage.render(
                        cpu: formatPercent(model.cpu), memory: formatPercent(model.memory?.usedFraction),
                        gpu: metric == .cpuMemoryAndGPU ? formatPercent(model.gpu?.utilization) : nil))
            } else {
                Image(nsImage: MenuBarGlyph.image)
                if metric != .none {
                    Text(text(for: metric)).monospacedDigit()
                }
            }
        }
        .accessibilityLabel("OpenClean, \(metric == .none ? "monitor" : text(for: metric))")
        .task(id: metricRaw) {
            guard metric != .none else { return }
            await model.monitor(.metrics)
        }
    }

    private func text(for metric: MenuBarMetric) -> String {
        switch metric {
        case .none: ""
        case .cpu: formatPercent(model.cpu)
        case .memory: formatPercent(model.memory?.usedFraction)
        case .cpuAndMemory:
            String(localized: "CPU \(formatPercent(model.cpu)), memory \(formatPercent(model.memory?.usedFraction))")
        case .gpu: String(localized: "GPU \(formatPercent(model.gpu?.utilization))")
        case .cpuMemoryAndGPU:
            String(
                localized:
                    "CPU \(formatPercent(model.cpu)), memory \(formatPercent(model.memory?.usedFraction)), GPU \(formatPercent(model.gpu?.utilization))"
            )
        case .network: "↓" + formatRate(model.network?.receivedPerSecond)
        }
    }
}

/// The window-style popover: live figures, the top three apps and two ways into the main window.
struct MenuBarPopover: View {
    @Environment(PerformanceModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var forceQuitNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppIconView(size: 22)
                Wordmark(size: 15)
                Spacer()
            }

            VStack(spacing: 10) {
                meterRow(String(localized: "CPU"), value: formatPercent(model.cpu), fraction: model.cpu ?? 0)
                meterRow(
                    String(localized: "Memory"),
                    value: model.memory.map { "\(formatMemory($0.used)) · \(pressureLabel($0.pressure))" } ?? "–",
                    fraction: model.memory?.usedFraction ?? 0,
                    color: model.memory.map { pressureColor($0.pressure) } ?? Theme.accent)
                meterRow(
                    String(localized: "GPU"),
                    value: model.gpu.map {
                        "\(formatPercent($0.utilization)) · \(formatMemory($0.inUseBytes))"
                    } ?? "–",
                    fraction: model.gpu?.utilization ?? 0, color: Theme.gpu)
                meterRow(
                    String(localized: "Disk"),
                    value: model.disk.map { String(localized: "\(formatCapacity($0.available)) free") } ?? "–",
                    fraction: model.disk?.usedFraction ?? 0)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Network").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(
                            "↓ \(formatRate(model.network?.receivedPerSecond))  ↑ \(formatRate(model.network?.sentPerSecond))"
                        )
                        .monospacedDigit()
                    }
                    Sparkline(points: model.receivedHistory).frame(height: 24)
                }
                .accessibilityElement(children: .combine)
            }
            .font(.system(size: 12))
            .padding(12)
            .glassPanel(radius: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Heavy apps").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                let top = model.topByCPU(3)
                if top.isEmpty {
                    Text("Measuring…").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(top) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProcessIcon(bundlePath: group.bundlePath, size: 18)
                            Text(group.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", group.cpuPercent)).monospacedDigit()
                            Text(formatMemory(group.residentBytes))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                                .frame(minWidth: 64, alignment: .trailing)
                            let allowed = AppQuitter.canForceQuit(group)
                            Button {
                                confirmForceQuit(group)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(allowed ? Theme.textSecondary : Theme.textTertiary.opacity(0.5))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!allowed)
                            .help(allowed ? String(localized: "Force Quit \(group.name)…") : AppQuitter.protectedReason)
                            .accessibilityLabel("Force quit \(group.name)")
                        }
                    }
                    .font(.system(size: 12))
                }
                if let forceQuitNotice {
                    Text(forceQuitNotice).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }

            ScanReminderNotice(review: startSmartScan)

            HStack(spacing: 8) {
                Button("Open OpenClean") { showMainWindow() }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                Button("Smart Scan") { startSmartScan() }
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(16)
        .frame(width: 320)
        .background(Backdrop.performance.gradient)
        .preferredColorScheme(.dark)
        .task { await model.monitor([.metrics, .processes]) }
    }

    private func meterRow(_ title: String, value: String, fraction: Double, color: Color = Theme.accent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).monospacedDigit().lineLimit(1)
            }
            MeterBar(fraction: fraction, color: color)
        }
        .accessibilityElement(children: .combine)
    }

    private func startSmartScan() {
        navigation.selection = .smartScan
        showMainWindow()
        // Never throw away results the user hasn't acted on, or interrupt a cleanup.
        if app.phase == .idle || app.phase == .finished { app.startScan() }
    }

    /// Brings the existing main window forward, or opens one if it was closed.
    /// Asks with a standard alert first. The group is captured when the button is pressed, so the list
    /// re-sorting meanwhile can't change which app is quit.
    private func confirmForceQuit(_ group: ProcessGroup) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Force quit \(group.name)?")
        alert.informativeText = String(localized: "Any unsaved changes in \(group.name) will be lost.")
        alert.addButton(withTitle: String(localized: "Force Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { forceQuit(group) }
    }

    private func forceQuit(_ group: ProcessGroup) {
        forceQuitNotice = AppQuitter.forceQuit(group)
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(MenuBarSettings.mainWindowID) == true && $0.canBecomeMain
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MenuBarSettings.mainWindowID)
        }
    }
}

/// Draws "CPU icon · CPU% · memory icon · memory%", and optionally "GPU icon · GPU%", into one
/// template image for the menu bar.
@MainActor
enum MenuBarFiguresImage {
    static func render(cpu: String, memory: String, gpu: String? = nil) -> NSImage {
        let font = Font.system(size: 12, weight: .medium)
        let content = HStack(spacing: 4) {
            Image(systemName: "cpu").font(font)
            Text(cpu).font(font).monospacedDigit()
            Image(systemName: "memorychip").font(font).padding(.leading, 3)
            Text(memory).font(font).monospacedDigit()
            if let gpu {
                Image(systemName: "cube").font(font).padding(.leading, 3)
                Text(gpu).font(font).monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        .frame(height: 18)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? MenuBarGlyph.image
        image.isTemplate = true
        image.accessibilityDescription =
            if let gpu {
                String(localized: "OpenClean, CPU \(cpu), memory \(memory), GPU \(gpu)")
            } else {
                String(localized: "OpenClean, CPU \(cpu), memory \(memory)")
            }
        return image
    }
}
