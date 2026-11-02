import Maintenance
import OpenCleanAppModel
import SwiftUI

struct MaintenanceListView: View {
    @Environment(PerformanceModel.self) private var model
    @State private var confirmTarget: MaintenanceTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(model.availableTasks) { task in
                        MaintenanceRow(task: task, record: model.records[task]) { confirmTarget = task }
                        if task != model.availableTasks.last { Divider().overlay(Theme.glassDivider) }
                    }
                }
                .glassPanel()
                Text(
                    "Tasks marked “Needs admin” ask for your password once per run. OpenClean can only run these exact commands as administrator."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .alert(
            "Run “\(confirmTarget?.localizedTitle ?? "")”?", isPresented: confirmBinding, presenting: confirmTarget
        ) { task in
            Button("Cancel", role: .cancel) {}
            Button(task.needsAdmin ? "Continue" : "Run") { Task { await model.run(task) } }
        } message: { task in
            Text(confirmMessage(task))
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirmTarget != nil }, set: { if !$0 { confirmTarget = nil } })
    }

    private func confirmMessage(_ task: MaintenanceTask) -> String {
        let command = (task.adminCommand?.steps ?? task.userCommand.map { [$0] } ?? [])
            .map { $0.joined(separator: " ") }
            .joined(separator: " && ")
        let runs = String(localized: "Runs: \(command)")
        guard task.needsAdmin else { return "\(task.localizedExplanation)\n\n\(runs)" }
        let admin = String(localized: "macOS will ask for your administrator password.")
        return "\(task.localizedExplanation)\n\n\(admin) \(runs)"
    }
}

struct MaintenanceRow: View {
    let task: MaintenanceTask
    let record: MaintenanceRecord?
    let onRun: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.localizedTitle).font(.system(size: 15, weight: .semibold))
                    if task.needsAdmin { StatusTag(text: String(localized: "Needs admin"), color: Theme.gold) }
                }
                Text(task.localizedExplanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(lastRunText)
                    .font(.system(size: 12))
                    .foregroundStyle(record?.succeeded == false ? Theme.coral : Theme.textTertiary)
            }
            Button("Run", action: onRun)
                .buttonStyle(CapsuleButtonStyle())
                .fixedSize()
                .accessibilityLabel("Run \(task.localizedTitle)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private var lastRunText: String {
        guard let record else { return String(localized: "Not run from OpenClean yet") }
        let when = formatRelativeDay(record.date)
        return record.succeeded
            ? String(localized: "Last run \(when)") : String(localized: "Last attempt \(when) didn’t finish")
    }
}

/// Full screen while a task runs, then its outcome with Done.
struct MaintenanceProgressView: View {
    @Environment(PerformanceModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            if let task = model.runningTask {
                ZStack {
                    Circle().stroke(Theme.glassStroke, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(spinning ? 270 : -90))
                        .animation(
                            reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false),
                            value: spinning)
                    Orb(size: 180) { LogoGlyph(size: 150) }
                }
                .frame(width: 220, height: 220)
                .onAppear { spinning = true }
                .accessibilityElement()
                .accessibilityLabel("Running \(task.localizedTitle)")
                Text(task.localizedTitle).font(.system(size: 30, weight: .bold)).padding(.top, 28)
                Text(
                    task.needsAdmin
                        ? "Enter your administrator password when macOS asks. This can take a moment."
                        : "This can take a minute."
                )
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
            } else if let result = model.lastResult {
                Orb(size: 160) {
                    Image(systemName: symbol(result.outcome))
                        .font(.system(size: 64, weight: .heavy))
                        .foregroundStyle(.white)
                }
                Text(headline(result.task, result.outcome))
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 28)
                Text(detail(result.task, result.outcome))
                    .font(.system(size: 15))
                    .foregroundStyle(result.outcome.isFailure ? Theme.coral : Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 520)
                    .padding(.top, 8)
            }
            Spacer(minLength: 24)
            if model.runningTask == nil {
                Button("Done") { model.dismissResult() }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 36)
            } else {
                Text("You can switch to other screens while this runs.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func symbol(_ outcome: MaintenanceOutcome) -> String {
        switch outcome {
        case .succeeded: "checkmark"
        case .cancelled: "xmark"
        case .failed: "exclamationmark"
        }
    }

    private func headline(_ task: MaintenanceTask, _ outcome: MaintenanceOutcome) -> String {
        switch outcome {
        case .succeeded: String(localized: "\(task.localizedTitle): done")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "\(task.localizedTitle) didn’t finish")
        }
    }

    private func detail(_ task: MaintenanceTask, _ outcome: MaintenanceOutcome) -> String {
        switch outcome {
        case .succeeded:
            task == .reindexSpotlight
                ? String(
                    localized: "Spotlight is rebuilding its index in the background. Search results fill in as it goes."
                )
                : String(localized: "The command finished without errors.")
        case .cancelled: String(localized: "Nothing was run.")
        case .failed(let message): message
        }
    }
}

extension MaintenanceOutcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
