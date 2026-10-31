import AppInventory
import OpenCleanAppModel
import SwiftUI

struct UninstallerView: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .idle: UninstallerIdleView()
            case .loading: UninstallerLoadingView()
            case .list: UninstallerListView()
            case .uninstalling: UninstallerWorkingView()
            case .finished: UninstallerCompleteView()
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .onAppear { model.onAppear() }
        .sheet(isPresented: $model.isConfirmPresented) { UninstallerConfirmSheet() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil && model.phase != .finished },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: List

struct UninstallerListView: View {
    @Environment(UninstallerModel.self) private var model
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Uninstaller").font(.system(size: 30, weight: .bold))
                    Text(
                        "Apps move to quarantine with their leftovers, so you can restore them for \(appModel.settings.clampedRetentionDays) days."
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                StatPill(
                    text:
                        "\(String(localized: "\(model.uninstallableApps.count) apps")) · \(formatBytes(model.totalAppBytes))"
                ) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .semibold))
                }
                .fixedSize()
                Button("Refresh") { model.load() }
                    .buttonStyle(CapsuleButtonStyle())
                    .fixedSize()
                    .help("List apps again and re-measure their sizes")
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    UninstallerSearchField(text: $model.searchText)
                        .padding(12)
                    Divider().overlay(Theme.glassDivider)
                    UninstallerAppList()
                }
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .glassPanel()

                UninstallerDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassPanel()
            }
            .padding(.horizontal, 32)

            UninstallBar()
        }
    }
}

struct UninstallerSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            TextField("Search apps", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .accessibilityLabel("Search apps")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.glassStroke))
    }
}

struct UninstallerAppList: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        let apps = model.filteredApps
        if apps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.apps.isEmpty ? "square.dashed" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(model.uninstallableApps.isEmpty ? "No apps to uninstall" : "No apps match “\(model.searchText)”")
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        UninstallerAppRow(app: app, isSelected: model.selectedAppID == app.id) {
                            model.select(app)
                        }
                        if app.id != apps.last?.id {
                            Divider().overlay(Theme.glassDivider).padding(.leading, 58)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

struct UninstallerAppRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // A plain tappable row rather than a Button: on recent macOS a plain-style Button in a list draws
        // its own rounded highlight over the flat selection fill.
        HStack(spacing: 12) {
            UninstallerAppIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let version = app.version {
                        Text(version).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if let state = app.stateLabel {
                        UninstallerTag(text: state.text, tint: state.tint)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(formatBytes(app.size))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        // Square-cornered, edge-to-edge fill so it lines up with the dividers above and below.
        .flatRowHighlight(isSelected ? Theme.glassStroke : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAction(.default, action)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Bottom bar: what is selected and the round Uninstall button.
struct UninstallBar: View {
    @Environment(UninstallerModel.self) private var model
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let bytes = model.selectedBytes
        let count = model.chosenLeftovers.count
        HStack(spacing: 28) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(bytes > 0 ? "\(formatBytes(bytes)) selected" : "Nothing selected")
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                Text(caption(count: count))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Button("Uninstall") { model.requestUninstall() }
                .buttonStyle(GlassCircleButtonStyle(diameter: 96))
                .disabled(!model.canUninstall)
                .keyboardShortcut(.defaultAction)
                .help("Review what moves to quarantine before anything happens")

            Text(
                model.selectedApp?.status.isRemovable == true
                    ? "Restorable from History for \(appModel.settings.clampedRetentionDays) days"
                    : "Pick an app to see what it left behind"
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    private func caption(count: Int) -> String {
        guard let app = model.selectedApp else { return String(localized: "Select an app") }
        guard app.status.isRemovable else { return app.status.explanation }
        if model.selectedAppIsRunning { return String(localized: "Quit \(app.name) to uninstall it") }
        let summary = String(localized: "\(app.name) + \(leftoverCount(count)) to quarantine")
        return app.status.requiresAdministrator ? summary + " · " + String(localized: "needs your password") : summary
    }
}

// MARK: Confirmation

struct UninstallerConfirmSheet: View {
    @Environment(UninstallerModel.self) private var model
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chosen = model.chosenLeftovers
        let byName = chosen.filter { $0.match == .name }.count
        VStack(alignment: .leading, spacing: 16) {
            if let app = model.selectedApp {
                HStack(spacing: 12) {
                    UninstallerAppIcon(path: app.path, size: 44)
                    Text("Uninstall \(app.name)?").font(.title2.bold())
                }
                Text(
                    "These items move to quarantine. You can restore them from History for \(appModel.settings.clampedRetentionDays) days; after that they are deleted."
                )
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    row(symbol: "app.dashed", title: (app.path as NSString).lastPathComponent, bytes: app.size)
                    row(
                        symbol: "folder", title: leftoverCount(chosen.count),
                        bytes: chosen.reduce(0) { $0 + $1.size })
                }
                if app.status.requiresAdministrator {
                    Label(
                        "macOS will ask for your administrator password to move \(app.name) to quarantine. If you restore it later, it comes back owned by you.",
                        systemImage: "lock"
                    )
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if byName > 0 {
                    Label(
                        "\(byName) items were matched by name. Check that they belong to this app.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .lineLimit(2)
                }
                if !model.reportOnlyLeftovers.isEmpty {
                    Text(
                        "\(leftoverCount(model.reportOnlyLeftovers.count)) in /Library stay in place (needs administrator — not supported yet)."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Quarantine") {
                    dismiss()
                    Task {
                        await model.uninstall()
                        appModel.refreshHistory()
                        appModel.refreshDisk()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canUninstall)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func row(symbol: String, title: String, bytes: Int64) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(formatBytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
