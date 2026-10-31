import AppKit
import OpenCleanAppModel
import OpenCleanKit
import Permissions
import SwiftUI
import Updater

@main
struct OpenCleanApp: App {
    @State private var model: AppModel
    @State private var uninstaller: UninstallerModel
    @State private var spaceLens: SpaceLensModel
    @State private var performance: PerformanceModel
    @State private var updates: UpdateModel
    @State private var reminder: ScanReminderModel
    @State private var navigation = AppNavigation()
    @State private var onboarding = OnboardingModel(defaults: .standard)
    /// Only set in the UI tests' layout-report mode (see `LayoutReport`).
    @State private var layoutProbe: LayoutProbe? = LayoutReport.outputPath == nil ? nil : LayoutProbe()
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled = true

    init() {
        let coordinator = OpenCleanCoordinator()
        let appModel = AppModel(
            coordinator: coordinator,
            signatureTracker: SignatureTracker(defaults: .standard, currentSignature: SignatureTracker.currentCDHash()))
        _model = State(initialValue: appModel)
        // Runs while the app or its menu bar item is running, so it starts here rather than with a window.
        let reminder = ScanReminderModel(
            settings: ScanReminderSettingsStore(defaults: .standard),
            scan: ScanReminderModel.backgroundScan(coordinator: coordinator),
            notifier: UserNotificationReminderNotifier(),
            isBusy: { appModel.phase == .scanning || appModel.phase == .cleaning })
        reminder.start()
        _reminder = State(initialValue: reminder)
        _uninstaller = State(initialValue: UninstallerModel(coordinator: coordinator))
        _spaceLens = State(initialValue: SpaceLensModel(coordinator: coordinator))
        _performance = State(initialValue: PerformanceModel(coordinator: coordinator))
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openclean"
        _updates = State(
            initialValue: UpdateModel(
                coordinator: coordinator, settings: UpdateSettingsStore(defaults: .standard),
                client: coordinator.makeUpdateHTTPClient(),
                installer: coordinator.selfUpdateInstaller(bundleIdentifier: bundleID),
                currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                currentAppPath: Bundle.main.bundlePath, relaunch: { AppRelauncher.relaunch($0) }))
        // Needed when started with `swift run`; harmless inside OpenClean.app.
        NSApplication.shared.setActivationPolicy(.regular)
        DockPresence.start()
    }

    var body: some Scene {
        WindowGroup("OpenClean", id: MenuBarSettings.mainWindowID) {
            Group {
                if onboarding.isCompleted {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .animation(.easeInOut(duration: 0.5), value: onboarding.isCompleted)
            .environment(model)
            .environment(uninstaller)
            .environment(spaceLens)
            .environment(performance)
            .environment(navigation)
            .environment(onboarding)
            .environment(updates)
            .environment(reminder)
            .environment(\.layoutProbe, layoutProbe)
            .frame(minWidth: 1200, minHeight: 720)
            .sheet(isPresented: $updates.isSheetPresented) {
                SoftwareUpdateSheet().environment(updates)
            }
            .task {
                model.onLaunch()
                if let output = LayoutReport.outputPath, let layoutProbe {
                    // No update check: the report must not touch the network.
                    await LayoutReport.run(output: output, probe: layoutProbe, navigation: navigation)
                    return
                }
                updates.onLaunch()
            }
        }
        .windowStyle(.hiddenTitleBar)
        // Open at a comfortable size and never let the window shrink below the layout's minimum.
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // No "Hide Sidebar" menu item: the sidebar is always shown.
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updates: updates)
            }
            // Settings live in the main window (sidebar → Settings), so ⌘, goes there.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton(navigation: navigation)
            }
            CommandGroup(before: .help) {
                Button("Welcome Tour…") { onboarding.restart() }
                    .disabled(!onboarding.isCompleted)
            }
        }
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPopover()
                .environment(model)
                .environment(performance)
                .environment(navigation)
                .environment(reminder)
        } label: {
            MenuBarLabel().environment(performance)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: menuBarEnabled) { _, enabled in DockPresence.menuBarItemChanged(enabled: enabled) }
    }
}
