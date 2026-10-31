import AppKit
import OpenCleanAppModel
import Permissions
import RuleKit
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Disk capacities without false precision: "160 GB" rather than "160.17 GB".
func formatCapacity(_ bytes: Int64) -> String {
    let gigabytes = Double(bytes) / 1_000_000_000
    // Rounded first, so ByteCountFormatter (which writes the unit in the user's language, "Go" in French)
    // has no decimals to show.
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    if gigabytes >= 1_000 {
        formatter.allowedUnits = .useTB
        return formatter.string(fromByteCount: Int64((gigabytes / 100).rounded()) * 100_000_000_000)
    }
    if gigabytes >= 10 {
        formatter.allowedUnits = .useGB
        return formatter.string(fromByteCount: Int64(gigabytes.rounded()) * 1_000_000_000)
    }
    return formatBytes(bytes)
}

/// A tri-state checkbox that announces its state to VoiceOver.
struct CheckboxButton: View {
    let state: AppModel.CheckState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(state == .off ? Color.clear : Theme.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(state == .off ? Color.white : Theme.accent, lineWidth: 1.5)
                )
                .overlay {
                    if state != .off {
                        Image(systemName: state == .on ? "checkmark" : "minus")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.deepTeal)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(
            state == .on
                ? Text("selected") : state == .mixed ? Text("partially selected") : Text("not selected"))
    }
}

/// A row in one of Cleanup's lists, selected like `SidebarRow`: soft white fill (the caller sets the
/// semibold label), white 7% on hover. Not `List(selection:)`, which paints the macOS accent colour.
/// `leading` (the checkbox) keeps its own clicks; the rest of the row is one plain button that selects it.
struct SelectableRow<Leading: View, Content: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Button(action: select) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.rowSelected : hovering ? Theme.rowHover : .clear)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

/// Free space and what OpenClean has freed, at the bottom of the sidebar.
struct StorageCard: View {
    let disk: DiskSpace?
    let stats: CleanupStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let disk {
                // Free space and total on one line when the sidebar is wide enough; otherwise just free space.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(formatCapacity(disk.available)) free")
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize()
                        Spacer(minLength: 4)
                        Text("of \(formatCapacity(disk.total))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                    }
                    Text("\(formatCapacity(disk.available)) free")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize()
                }
                .rollingNumber(disk.available)
                ProgressView(value: disk.freeFraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            // Nothing freed yet: no line at all rather than a placeholder.
            if stats.cleanups > 0, stats.totalFreedBytes > 0 {
                Text("\(formatBytes(stats.totalFreedBytes)) freed by OpenClean")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .glassPanel(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

struct AccessBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        if model.accessAdvice != .ok {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    // No fixedSize here: measured at minimum width it would inflate the window's minimum height.
                    Text(message).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .fixedSize()
                Button("Check Again") { model.refreshAccess() }
                    .buttonStyle(CapsuleButtonStyle())
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(14)
            .glassPanel(radius: 14)
            .padding([.horizontal, .top], 16)
        }
    }

    private var title: String {
        if updates.updatedFrom != nil {
            return String(localized: "OpenClean was updated. Allow Full Disk Access again")
        }
        return model.accessAdvice == .regrantAfterRebuild
            ? String(localized: "Full Disk Access needs to be granted again")
            : String(localized: "Full Disk Access is off")
    }

    private var message: String {
        if updates.updatedFrom != nil {
            return
                String(
                    localized:
                        "macOS treats each new version of OpenClean as a new app. In Settings, remove OpenClean from the Full Disk Access list, add it again, then click Check Again."
                )
        }
        return model.accessAdvice == .regrantAfterRebuild
            ? String(
                localized:
                    "This build of OpenClean has a new signature, so macOS no longer recognises the earlier permission. Remove OpenClean from the list in Settings, add it again, then click Check Again."
            )
            : String(localized: "Trash, Mail, Safari and iOS backups can only be scanned with Full Disk Access.")
    }
}

struct ProblemsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.loadedRules.problems.isEmpty {
            DisclosureGroup {
                ForEach(model.loadedRules.problems, id: \.self) { problem in
                    Text(problem).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Label("Some rule packs were skipped", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.gold)
            }
            .padding(14)
            .glassPanel(radius: 14)
            .padding([.horizontal, .top], 16)
        }
    }
}
