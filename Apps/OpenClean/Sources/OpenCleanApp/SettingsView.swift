import AppKit
import OpenCleanAppModel
import Permissions
import SwiftUI

/// Global settings and preferences, shown in the main window from the sidebar's Settings row (or ⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateModel.self) private var updates
    @Environment(OnboardingModel.self) private var onboarding
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled = true
    @AppStorage(MenuBarSettings.metricKey) private var menuBarMetric = MenuBarMetric.cpuMemoryAndNetwork.rawValue

    var body: some View {
        @Bindable var model = model
        @Bindable var updates = updates
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings").font(.system(size: 30, weight: .bold))
                    Text("Preferences for every part of OpenClean.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }

                section("General", symbol: "menubar.rectangle") {
                    row(String(localized: "Show CPU and memory in the menu bar")) {
                        Toggle("", isOn: $menuBarEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    divider
                    row(String(localized: "Menu bar shows")) {
                        Picker("", selection: $menuBarMetric) {
                            ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!menuBarEnabled)
                    }
                }

                section("Updates", symbol: "arrow.down.circle") {
                    row(String(localized: "Check for updates automatically")) {
                        Toggle("", isOn: $updates.autoCheck).toggleStyle(.switch).labelsHidden()
                    }
                    divider
                    row(String(localized: "OpenClean \(updates.currentVersionText)"), detail: lastCheckedText) {
                        Button("Check Now") { updates.checkForUpdates() }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                    note(
                        "OpenClean asks api.github.com once a day whether a newer release exists, and downloads updates only from GitHub. Nothing about you is sent."
                    )
                }

                section("Cleaning", symbol: "sparkles") {
                    row(
                        String(localized: "Keep removed files for \(model.retentionDays) days"),
                        detail: String(localized: "After this, quarantined files are deleted for good.")
                    ) {
                        Stepper("", value: $model.retentionDays, in: 1...90).labelsHidden()
                    }
                    divider
                    row(
                        String(localized: "Show advanced (caution) rules"),
                        detail: String(localized: "Adds rules that need a closer look before cleaning.")
                    ) {
                        Toggle("", isOn: $model.advancedEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    divider
                    row(
                        String(localized: "Your rule packs"),
                        detail: String(localized: "Add your own YAML rules to this folder.")
                    ) {
                        Button("Reveal in Finder") { revealUserRules() }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }

                ScanReminderSettingsSection()
                    .layoutProbe("settings.scanReminder")

                section("Excluded locations", symbol: "eye.slash") {
                    if model.settings.excludedPaths.isEmpty {
                        note("Nothing is excluded. Excluded folders and files are never scanned or cleaned.")
                    }
                    ForEach(model.settings.excludedPaths, id: \.self) { path in
                        row((path as NSString).abbreviatingWithTildeInPath) {
                            Button("Stop Excluding") { model.removeExclusion(path) }
                                .buttonStyle(CapsuleButtonStyle())
                        }
                        divider
                    }
                    row(String(localized: "Add a folder or file")) {
                        Button("Add…") { addExclusion() }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }

                section("Project folders", symbol: "folder.badge.gearshape") {
                    if model.settings.projectFolders.isEmpty {
                        note(
                            "OpenClean looks for old projects in your home folder, but never in Documents or Desktop. Add a folder where you keep code, such as Documents/Code, to search it too."
                        )
                    }
                    ForEach(model.settings.projectFolders, id: \.self) { path in
                        row((path as NSString).abbreviatingWithTildeInPath) {
                            Button("Remove") { model.removeProjectFolder(path) }
                                .buttonStyle(CapsuleButtonStyle())
                        }
                        divider
                    }
                    row(
                        String(localized: "Add a project folder"),
                        detail:
                            String(
                                localized:
                                    "Only node_modules, virtual environments and build output go to quarantine. Nothing else in it is touched."
                            )
                    ) {
                        Button("Add…") { addProjectFolder() }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }
                .layoutProbe("settings.projectFolders")

                section("Permissions", symbol: "lock.shield") {
                    row(String(localized: "Full Disk Access"), detail: accessDetail) {
                        HStack(spacing: 10) {
                            StatusTag(
                                text: model.accessAdvice == .ok
                                    ? String(localized: "Allowed") : String(localized: "Not allowed"),
                                color: model.accessAdvice == .ok ? Theme.accent : Theme.gold)
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL)
                            }
                            .buttonStyle(CapsuleButtonStyle())
                        }
                    }
                }

                section("About", symbol: "info.circle") {
                    row(
                        String(localized: "OpenClean \(updates.currentVersionText)"),
                        detail: String(localized: "Open source under GPL-3.0.")
                    ) {
                        Button("GitHub") {
                            if let url = URL(string: "https://github.com/leoAnimesh/OpenClean") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(CapsuleButtonStyle())
                    }
                    divider
                    row(
                        String(localized: "Welcome tour"),
                        detail: String(localized: "See the feature tour and permission setup again.")
                    ) {
                        Button("Show Tour") { onboarding.restart() }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .tint(Theme.accent)
        .task { model.refreshAccess() }
    }

    private var lastCheckedText: String {
        String(localized: "Last checked \(updates.lastChecked.map(formatRelativeDay) ?? String(localized: "never"))")
    }

    private var accessDetail: String {
        switch model.accessAdvice {
        case .ok: String(localized: "Trash, Mail, Safari and iOS backups can be scanned.")
        case .grant: String(localized: "Needed to scan Trash, Mail, Safari and iOS backups.")
        case .regrantAfterRebuild: String(localized: "OpenClean was updated: remove it from the list and add it again.")
        }
    }

    // MARK: Building blocks

    private func section(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> some View)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) { content() }
                .glassPanel()
        }
    }

    private func row(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }

    private var divider: some View { Divider().overlay(Theme.glassDivider) }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.addExclusion(url.path)
        }
    }

    private func addProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a folder where you keep code projects.")
        if panel.runModal() == .OK, let url = panel.url {
            model.addProjectFolder(url.path)
        }
    }

    private func revealUserRules() {
        try? FileManager.default.createDirectory(at: model.paths.userRules, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([model.paths.userRules])
    }
}
