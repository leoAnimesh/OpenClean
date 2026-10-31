import AppInventory
import AppKit
import OpenCleanAppModel
import SwiftUI

/// Right-hand panel: facts about the selected app and what it left behind.
struct UninstallerDetailView: View {
    @Environment(UninstallerModel.self) private var model
    @State private var isQuitting = false
    @State private var quitNotice: String?

    var body: some View {
        if let app = model.selectedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UninstallerAppHeader(app: app)
                    notices(for: app)
                    if app.status.isRemovable {
                        removableSection(for: app)
                    }
                    if !model.reportOnlyLeftovers.isEmpty {
                        systemSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "xmark.app")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text("Select an app").font(.system(size: 17, weight: .semibold))
                Text("You’ll see its size, its leftovers in your Library, and what would move to quarantine.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 320)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func notices(for app: InstalledApp) -> some View {
        if !app.status.isRemovable {
            notice(symbol: "lock.fill", text: app.status.localizedExplanation, tint: Theme.gold)
        } else if model.selectedAppIsRunning {
            HStack(spacing: 12) {
                notice(
                    symbol: "exclamationmark.triangle.fill",
                    text: quitNotice ?? String(localized: "\(app.name) is running. Quit it to uninstall."),
                    tint: Theme.gold)
                Button("Force Quit…") { forceQuit(app) }
                    .buttonStyle(CapsuleButtonStyle())
                    .fixedSize()
                    .disabled(isQuitting)
            }
        } else if app.status.requiresAdministrator {
            notice(
                symbol: "lock.fill",
                text:
                    String(
                        localized:
                            "\(app.name) is owned by the system. macOS will ask for your administrator password to move it to quarantine."
                    ),
                tint: Theme.gold)
        }
    }

    /// Asks first, force quits the app's running copies at exactly this path, then re-checks the app
    /// (which also refreshes the Uninstall button) once they've gone.
    private func forceQuit(_ app: InstalledApp) {
        guard app.bundleID != InstalledApp.openCleanBundleID else { return }
        let running = NSWorkspace.shared.runningApplications.filter { runningApp in
            guard let url = runningApp.bundleURL else { return false }
            return url.resolvingSymlinksInPath().path == URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        }
        guard !running.isEmpty else {
            model.select(app)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Force quit \(app.name)?")
        alert.informativeText = String(localized: "Any unsaved changes in \(app.name) will be lost.")
        alert.addButton(withTitle: String(localized: "Force Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isQuitting = true
        quitNotice = String(localized: "Quitting \(app.name)…")
        for runningApp in running { runningApp.forceTerminate() }
        Task {
            for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            isQuitting = false
            quitNotice =
                running.allSatisfy(\.isTerminated) ? nil : String(localized: "\(app.name) didn't quit. Try again.")
            model.select(app)
        }
    }

    private func notice(symbol: String, text: String, tint: Color) -> some View {
        Label {
            Text(text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
    }

    @ViewBuilder
    private func removableSection(for app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What moves to quarantine").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                UninstallerItemRow(
                    title: (app.path as NSString).lastPathComponent,
                    folder: ((app.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                    tag: app.status.requiresAdministrator
                        ? (String(localized: "Needs password"), Theme.gold)
                        : (String(localized: "Application"), Theme.textSecondary),
                    size: app.size, state: .on, isLocked: true
                ) {}
                ForEach(model.leftoverGroups, id: \.kind) { group in
                    Divider().overlay(Theme.glassDivider)
                    Text(group.kind.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.items) { leftover in
                        UninstallerItemRow(
                            title: leftover.displayName, folder: leftover.displayFolder, tag: leftover.matchLabel,
                            size: leftover.size, state: model.isSelected(leftover) ? .on : .off, isLocked: false
                        ) {
                            model.toggle(leftover)
                        }
                    }
                }
            }
            .glassPanel(radius: 12)
            if model.isFindingLeftovers {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for leftovers…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            } else if model.removableLeftovers.isEmpty {
                Text("No leftovers found in your Library.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(
                    "Only exact matches are listed: folders and files named after \(app.bundleID ?? String(localized: "the bundle ID")), or exactly “\(app.name)” in Application Support, Caches and Logs."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also found in /Library").font(.system(size: 15, weight: .semibold))
                Text("Needs administrator — not supported yet. These stay in place and are shown for information.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                ForEach(model.reportOnlyLeftovers) { leftover in
                    if leftover.id != model.reportOnlyLeftovers.first?.id {
                        Divider().overlay(Theme.glassDivider)
                    }
                    UninstallerItemRow(
                        title: leftover.displayName, folder: leftover.displayFolder,
                        tag: (String(localized: "Report only"), Theme.textTertiary), size: leftover.size, state: nil,
                        isLocked: true
                    ) {}
                }
            }
            .glassPanel(radius: 12)
        }
    }
}

struct UninstallerAppHeader: View {
    let app: InstalledApp

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            UninstallerAppIcon(path: app.path, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Text(
                    [app.version.map { String(localized: "Version \($0)") }, app.bundleID].compactMap { $0 }.joined(
                        separator: " · ")
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .textSelection(.enabled)
                Text((app.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 20) {
                    fact(formatBytes(app.size), "on disk")
                    fact(app.lastUsed.map(uninstallerDateText) ?? String(localized: "Unknown"), "last opened")
                    fact(app.ownerUID == 0 ? String(localized: "System (root)") : String(localized: "You"), "owner")
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// One file or folder row; `state == nil` means report-only (no checkbox).
struct UninstallerItemRow: View {
    let title: String
    let folder: String
    let tag: (text: String, tint: Color)
    let size: Int64
    let state: AppModel.CheckState?
    let isLocked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let state {
                CheckboxButton(state: state, label: title, action: toggle)
                    .disabled(isLocked)
                    .help(isLocked ? String(localized: "The app itself is always included") : "")
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            UninstallerTag(text: tag.text, tint: tag.tint)
            Text(formatBytes(size))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .onTapGesture { if state != nil && !isLocked { toggle() } }
        .accessibilityElement(children: .contain)
    }
}
