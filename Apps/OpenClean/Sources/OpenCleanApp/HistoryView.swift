import AppKit
import OpenCleanAppModel
import Quarantine
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingRestore?
    @State private var isAsking = false
    @State private var lastRestore: RestoreReport?

    struct PendingRestore {
        let sessionID: String
        let paths: Set<String>?
    }

    var body: some View {
        let stats = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("History").font(.system(size: 30, weight: .bold))
                        Text("Quarantined items can be restored until they expire.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    HStack(spacing: 28) {
                        stat(formatBytes(stats.totalFreedBytes), String(localized: "freed in total"))
                        stat(
                            "\(stats.cleanups)",
                            stats.cleanups == 1 ? String(localized: "cleanup") : String(localized: "cleanups"))
                    }
                }

                if let lastRestore {
                    Label(
                        "\(lastRestore.restored.count) restored, \(lastRestore.skipped.count) skipped.",
                        systemImage: "arrow.uturn.backward.circle.fill"
                    )
                    .foregroundStyle(Theme.accent)
                }

                if model.history.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(Theme.textSecondary)
                        Text("No cleanups yet").font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .glassPanel()
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.history) { listing in
                            Group {
                                switch listing {
                                case .ok(let manifest):
                                    SessionRow(manifest: manifest, retentionDays: model.settings.clampedRetentionDays) {
                                        paths in
                                        pending = PendingRestore(sessionID: manifest.id, paths: paths)
                                        isAsking = true
                                    }
                                case .damaged(let id, _):
                                    HStack {
                                        Label("Damaged session \(id)", systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(Theme.gold)
                                        Spacer()
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([
                                                model.paths.quarantine.appendingPathComponent(id)
                                            ])
                                        }
                                        .buttonStyle(CapsuleButtonStyle())
                                    }
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            if listing.id != model.history.last?.id {
                                Divider().overlay(Theme.glassDivider)
                            }
                        }
                    }
                    .glassPanel()
                }

            }
            .padding(32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.refreshHistory() }
        .confirmationDialog("If a file already exists at the original location:", isPresented: $isAsking) {
            Button("Skip It") { restore(.skip) }
            Button("Keep Both") { restore(.keepBoth) }
            Button("Replace It (old one goes to Trash)") { restore(.replace) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func restore(_ policy: ConflictPolicy) {
        guard let pending else { return }
        Task {
            lastRestore = await model.restore(sessionID: pending.sessionID, paths: pending.paths, onConflict: policy)
        }
    }
}

struct SessionRow: View {
    let manifest: SessionManifest
    let retentionDays: Int
    let onRestore: (Set<String>?) -> Void
    @State private var isExpanded = false

    var body: some View {
        let restorable = Set(manifest.restorableEntries.map(\.id))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                // A plain button rather than DisclosureGroup: buttons inside a DisclosureGroup label lose clicks.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 14, weight: .semibold))
                            Text(summary).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? Text("expanded") : Text("collapsed"))
                Spacer()
                quarantineStatus(hasRestorable: !restorable.isEmpty)
                if manifest.purgedAt == nil && !restorable.isEmpty {
                    Button("Restore All…") { onRestore(nil) }
                        .buttonStyle(CapsuleButtonStyle())
                        .fixedSize()
                }
            }
            if isExpanded {
                ForEach(manifest.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((entry.originalPath as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entryStatus(entry))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                        if manifest.purgedAt == nil && restorable.contains(entry.id) {
                            Button("Restore") { onRestore([entry.originalPath]) }
                                .buttonStyle(CapsuleButtonStyle())
                        }
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    @ViewBuilder
    private func quarantineStatus(hasRestorable: Bool) -> some View {
        if manifest.purgedAt != nil {
            Text("Expired and deleted").font(.caption).foregroundStyle(Theme.textTertiary)
                .frame(width: 200, alignment: .leading)
        } else if hasRestorable {
            let left = daysLeft
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "\(Text("\(formatBytes(manifest.quarantinedBytes)) in quarantine")) · \(Text("\(left) days left"))"
                )
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                ProgressView(value: Double(left), total: Double(max(retentionDays, 1)))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            .frame(width: 200)
        }
    }

    private var daysLeft: Int {
        let expiry = manifest.createdAt.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
        return max(0, Int((expiry.timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    private var title: String {
        let time = manifest.createdAt.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(manifest.createdAt) { return String(localized: "Today, \(time)") }
        if calendar.isDateInYesterday(manifest.createdAt) { return String(localized: "Yesterday, \(time)") }
        return manifest.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var summary: String {
        var parts = [String(localized: "Freed \(formatBytes(CleanupStats.freedBytes(manifest)))")]
        let count = manifest.entries.count
        parts.append(String(localized: "\(count) items"))
        if !manifest.skippedEntries.isEmpty {
            parts.append(String(localized: "\(manifest.skippedEntries.count) skipped"))
        }
        return parts.joined(separator: " · ")
    }

    /// "Quarantined", or "Skipped — Changed since the scan; an app may be using it."
    private func entryStatus(_ entry: ManifestEntry) -> String {
        let detail = SkippedItems.explanation(for: entry) ?? entry.reason
        return [entry.outcome.localizedName, detail].compactMap { $0 }.joined(separator: " — ")
    }
}
