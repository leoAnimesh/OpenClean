import AppKit
import OpenCleanAppModel
import SwiftUI
import SystemMonitor

/// Quit and Force Quit go only through `NSRunningApplication`, and only for groups the library's
/// `ForceQuitPolicy` allows, whose running app still matches the bundle we sampled.
@MainActor
enum AppQuitter {
    static func runningApp(for group: ProcessGroup) -> NSRunningApplication? {
        guard group.canQuit, let pid = group.mainPID, let bundlePath = group.bundlePath,
            pid != ProcessInfo.processInfo.processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
            let bundleURL = app.bundleURL,
            bundleURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        else { return nil }
        return app
    }

    static let protectedReason = String(
        localized: "Part of macOS, another user's, or OpenClean itself — it can't be quit from here.")

    /// Apps go through `NSRunningApplication`; a lone background process of the user's own goes
    /// through `ProcessTerminator`, which re-checks its identity before killing it.
    static func canForceQuit(_ group: ProcessGroup) -> Bool {
        runningApp(for: group) != nil || group.killableProcess != nil
    }

    /// Force quits and returns a one-line result for the user.
    static func forceQuit(_ group: ProcessGroup) -> String {
        if let app = runningApp(for: group) {
            return app.forceTerminate()
                ? String(localized: "\(group.name) was force quit.")
                : String(localized: "\(group.name) could not be force quit.")
        }
        guard let process = group.killableProcess else {
            return String(localized: "\(group.name) can't be force quit from OpenClean.")
        }
        switch ProcessTerminator().forceQuit(process) {
        case .killed: return String(localized: "\(group.name) was force quit.")
        case .changed: return String(localized: "\(group.name) had already quit or changed, so nothing was done.")
        case .protected: return String(localized: "\(group.name) can't be force quit from OpenClean.")
        case .failed: return String(localized: "\(group.name) could not be force quit.")
        }
    }
}

enum ConsumerSort: Hashable {
    case cpu, gpu, memory
}

struct HeavyConsumersView: View {
    @Environment(PerformanceModel.self) private var model
    @State private var sort: ConsumerSort = .cpu
    @State private var forceQuitTarget: ProcessGroup?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Sort by", selection: $sort) {
                    Text("CPU").tag(ConsumerSort.cpu)
                    Text("GPU").tag(ConsumerSort.gpu)
                    Text("Memory").tag(ConsumerSort.memory)
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
                Spacer()
                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Theme.gold).lineLimit(1)
                }
            }
            if groups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
                .glassPanel()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ConsumerColumnHeader()
                        ForEach(groups) { group in
                            ConsumerRow(group: group, onQuit: { quit(group) }, onForceQuit: { forceQuitTarget = group })
                            if group.id != groups.last?.id { Divider().overlay(Theme.glassDivider) }
                        }
                    }
                    .glassPanel()
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
            Text(
                "Only your own processes can be measured without administrator rights. System processes are never offered Quit."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 16)
        }
        .task { await model.monitor([.metrics, .processes]) }
        .sheet(item: $forceQuitTarget) { group in
            ForceQuitSheet(group: group) {
                forceQuit(group)
                forceQuitTarget = nil
            } onCancel: {
                forceQuitTarget = nil
            }
        }
    }

    private var groups: [ProcessGroup] {
        switch sort {
        case .cpu: model.topByCPU(25)
        case .gpu: model.topByGPU(25)
        case .memory: model.topByMemory(25)
        }
    }

    private func quit(_ group: ProcessGroup) {
        guard let app = AppQuitter.runningApp(for: group) else {
            notice = String(localized: "\(group.name) can't be quit from OpenClean.")
            return
        }
        notice =
            app.terminate()
            ? String(localized: "Asked \(group.name) to quit.")
            : String(localized: "\(group.name) didn't accept the request to quit.")
    }

    private func forceQuit(_ group: ProcessGroup) {
        notice = AppQuitter.forceQuit(group)
    }
}

struct ConsumerRow: View {
    /// Wide enough for Quit and Force Quit… side by side, so the figures line up from row to row.
    static let actionsWidth: CGFloat = 210

    let group: ProcessGroup
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        let quittable = AppQuitter.runningApp(for: group) != nil
        HStack(spacing: 14) {
            ProcessIcon(bundlePath: group.bundlePath, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(String(format: "%.1f%%", group.cpuPercent))
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
                .accessibilityLabel("CPU \(Int(group.cpuPercent.rounded())) percent")
            Text(String(format: "%.1f%%", group.gpuPercent))
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(group.gpuPercent < 0.05 ? Theme.textTertiary : Theme.textPrimary)
                .frame(minWidth: 64, alignment: .trailing)
                .accessibilityLabel("GPU \(Int(group.gpuPercent.rounded())) percent")
            Text(formatMemory(group.residentBytes))
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(minWidth: 84, alignment: .trailing)
                .accessibilityLabel("Memory \(formatMemory(group.residentBytes))")
            HStack(spacing: 14) {
                if quittable {
                    Button("Quit", action: onQuit).buttonStyle(CapsuleButtonStyle()).fixedSize()
                    Button("Force Quit…", action: onForceQuit).buttonStyle(CapsuleButtonStyle()).fixedSize()
                } else if group.killableProcess != nil {
                    Button("Force Quit…", action: onForceQuit).buttonStyle(CapsuleButtonStyle()).fixedSize()
                } else {
                    StatusTag(
                        text: group.bundlePath == nil ? String(localized: "Process") : String(localized: "Protected")
                    )
                    .help("OpenClean only offers Quit for apps, never for macOS components or itself.")
                }
            }
            .frame(minWidth: Self.actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let count = group.processes.count
        return count == 1 ? (group.processes.first?.name ?? "") : String(localized: "\(count) processes")
    }
}

/// Names the figures in `ConsumerRow`; the widths match the row's columns.
struct ConsumerColumnHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("CPU").frame(minWidth: 64, alignment: .trailing)
            Text("GPU").frame(minWidth: 64, alignment: .trailing)
            Text("Memory").frame(minWidth: 84, alignment: .trailing)
            Color.clear.frame(width: ConsumerRow.actionsWidth, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .accessibilityHidden(true)
    }
}

struct ForceQuitSheet: View {
    let group: ProcessGroup
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProcessIcon(bundlePath: group.bundlePath, size: 40)
                Text("Force quit \(group.name)?").font(.title2.bold())
            }
            Text(
                "Force quitting stops the app immediately. Anything you haven’t saved in it will be lost. Try Quit first if the app is still responding."
            )
            .foregroundStyle(.secondary)
            .lineLimit(4)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Force Quit", role: .destructive, action: onConfirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
