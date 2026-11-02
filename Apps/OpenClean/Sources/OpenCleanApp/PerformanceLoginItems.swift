import AppKit
import Maintenance
import OpenCleanAppModel
import OpenCleanKit
import SwiftUI

struct LoginItemsView: View {
    @Environment(PerformanceModel.self) private var model
    @State private var removeTarget: LaunchItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(OpenCleanCoordinator.loginItemsSettingsURL)
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .fixedSize()
                    Button("Refresh") { Task { await model.refreshLoginItems() } }
                        .buttonStyle(CapsuleButtonStyle())
                        .fixedSize()
                        .disabled(model.isLoadingInventory)
                    if model.isLoadingInventory { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let notice = model.loginItemsNotice {
                    Label(
                        notice.text,
                        systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(notice.isError ? Theme.coral : Theme.accent)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let inventory = model.inventory {
                    if !inventory.launchctlAvailable {
                        Label(
                            "launchctl couldn’t be asked for the current state, so “running” isn’t shown.",
                            systemImage: "questionmark.circle"
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.gold)
                    }
                    section(
                        title: "Your launch agents",
                        caption:
                            "Helpers apps installed for your account. Turning one off stops it and keeps it from starting; removing it moves its file to quarantine, which you can undo in History.",
                        items: inventory.items(in: .user), empty: "No launch agents in your Library.")
                    section(
                        title: "Installed for all users",
                        caption:
                            "Agents and daemons in /Library are installed by an administrator and run for everyone. OpenClean lists them so you know they’re there, but doesn’t change them.",
                        items: inventory.items(in: .systemAgent) + inventory.items(in: .systemDaemon),
                        empty: "None installed.")
                    bundledSection(inventory.bundled)
                    if !inventory.unreadable.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Files that couldn’t be read").font(.system(size: 13, weight: .semibold))
                            ForEach(inventory.unreadable) { item in
                                Text("\(item.path) — \(item.reason)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading launch agents…").foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .glassPanel()
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .task { if model.inventory == nil { await model.refreshLoginItems() } }
        .alert(
            "Remove \(removeTarget?.label ?? "")?", isPresented: removeBinding, presenting: removeTarget
        ) { item in
            Button("Cancel", role: .cancel) {}
            Button("Move to Quarantine", role: .destructive) { Task { await model.remove(item) } }
        } message: { _ in
            Text(
                "OpenClean stops the agent and moves its file to quarantine. You can restore it from History for \(model.retentionDays) days; it starts again at your next login after restoring."
            )
        }
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })
    }

    @ViewBuilder
    private func section(
        title: LocalizedStringKey, caption: LocalizedStringKey, items: [LaunchItem], empty: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 18, weight: .bold))
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if items.isEmpty {
                Text(empty)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel()
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        LaunchItemRow(item: item, busy: model.busyItems.contains(item.path)) {
                            Task { await model.disable(item) }
                        } onEnable: {
                            Task { await model.enable(item) }
                        } onRemove: {
                            removeTarget = item
                        }
                        if item.id != items.last?.id { Divider().overlay(Theme.glassDivider) }
                    }
                }
                .glassPanel()
            }
        }
    }

    @ViewBuilder
    private func bundledSection(_ bundled: [BundledBackgroundItem]) -> some View {
        if !bundled.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Background items inside apps").font(.system(size: 18, weight: .bold))
                Text(
                    "These apps carry their own login items. macOS decides whether they run; turn them on or off in System Settings → General → Login Items."
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    ForEach(bundled) { entry in
                        HStack(spacing: 12) {
                            ProcessIcon(bundlePath: entry.bundlePath, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.appName).font(.system(size: 14, weight: .semibold))
                                Text(entry.items.joined(separator: ", "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer()
                            StatusTag(text: String(localized: "Managed by macOS"))
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 52)
                        .accessibilityElement(children: .combine)
                        if entry.id != bundled.last?.id { Divider().overlay(Theme.glassDivider) }
                    }
                }
                .glassPanel()
            }
        }
    }
}

struct LaunchItemRow: View {
    let item: LaunchItem
    let busy: Bool
    let onDisable: () -> Void
    let onEnable: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProcessIcon(bundlePath: item.owner?.bundlePath, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(ownerText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let program = item.definition.program {
                    Text(program)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(program)
                }
            }
            Spacer(minLength: 12)
            StatusTag(text: stateText, color: item.isDisabled ? Theme.textTertiary : Theme.textSecondary)
            if item.scope.isActionable {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 190)
                } else {
                    Button(item.isDisabled ? "Turn On" : "Turn Off", action: item.isDisabled ? onEnable : onDisable)
                        .buttonStyle(CapsuleButtonStyle())
                        .fixedSize()
                    Button("Remove", action: onRemove)
                        .buttonStyle(CapsuleButtonStyle())
                        .fixedSize()
                }
            } else {
                StatusTag(text: String(localized: "System (read-only)"), color: Theme.gold)
                    .help(
                        "Installed for all users by an administrator. OpenClean doesn’t change these in this version.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var ownerText: String {
        var parts: [String] = []
        if let owner = item.owner {
            parts.append(
                owner.confidence == .exact
                    ? String(localized: "From \(owner.appName)") : String(localized: "Probably from \(owner.appName)"))
        } else {
            parts.append(String(localized: "Unknown app"))
        }
        if item.definition.runAtLoad { parts.append(String(localized: "starts at login")) }
        switch item.definition.keepAlive {
        case .always: parts.append(String(localized: "kept running"))
        case .conditional: parts.append(String(localized: "restarted when needed"))
        case .no: break
        }
        if item.scope == .systemDaemon { parts.append(String(localized: "runs as root")) }
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        if item.isDisabled { return String(localized: "Off") }
        switch item.loadState {
        case .loaded(let pid): return pid == nil ? String(localized: "Loaded") : String(localized: "Running")
        case .notLoaded: return String(localized: "Not loaded")
        case .unknown: return String(localized: "Unknown")
        }
    }
}
