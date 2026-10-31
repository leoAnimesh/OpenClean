import AppKit
import OpenCleanAppModel
import SwiftUI
import Updater

// MARK: Banner

/// "OpenClean 0.3.0 is available" at the top of the detail area, under the Full Disk Access banner.
/// Hidden once the version is skipped or after "Remind Me Later" (until the next launch).
struct UpdateBanner: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        if let release = updates.bannerRelease {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenClean \(release.version.description) is available").font(.headline)
                    Text(
                        "You have \(updates.currentVersionText). Your current version stays in History after updating."
                    )
                    .font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("What's New") { updates.showUpdate() }
                    .buttonStyle(CapsuleButtonStyle())
                    .fixedSize()
                Button("Update") {
                    updates.showUpdate()
                    if release.isInstallable { updates.downloadAndInstall() }
                }
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(14)
            .glassPanel(radius: 14)
            .padding([.horizontal, .top], 16)
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: Sheet

/// Software Update: checking, the available release with its notes, download progress, verifying,
/// install and relaunch, or a plain error with Retry and a GitHub fallback.
struct SoftwareUpdateSheet: View {
    @Environment(UpdateModel.self) private var updates
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                AppIconView(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            content
            buttons
        }
        .padding(24)
        .frame(width: 560)
        .foregroundStyle(.white)
        .background(Backdrop.scan.gradient.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .animation(.easeInOut(duration: 0.25), value: stateKey)
    }

    /// A coarse key for animating between states without re-animating every progress tick.
    private var stateKey: Int {
        switch updates.state {
        case .idle: 0
        case .checking: 1
        case .upToDate: 2
        case .available: 3
        case .downloading: 4
        case .verifying: 5
        case .ready: 6
        case .installing: 7
        case .failed: 8
        }
    }

    private var newVersion: String { updates.release?.version.description ?? "" }

    private var title: String {
        switch updates.state {
        case .idle, .checking: String(localized: "Checking for updates…")
        case .upToDate: String(localized: "You're up to date")
        case .available, .downloading, .verifying: String(localized: "A new version of OpenClean is available")
        case .ready: String(localized: "Ready to install OpenClean \(newVersion)")
        case .installing: String(localized: "Installing OpenClean \(newVersion)…")
        case .failed:
            updates.release == nil
                ? String(localized: "Couldn't check for updates") : String(localized: "The update didn't finish")
        }
    }

    private var subtitle: String {
        switch updates.state {
        case .idle, .checking: String(localized: "Asking GitHub for the latest release.")
        case .upToDate: String(localized: "OpenClean \(updates.currentVersionText) is the newest version.")
        case .available, .downloading, .verifying, .ready, .installing:
            String(localized: "OpenClean \(newVersion) is available — you have \(updates.currentVersionText).")
        case .failed(let message): message
        }
    }

    @ViewBuilder private var content: some View {
        switch updates.state {
        case .idle, .checking:
            status("Checking…")
        case .upToDate:
            if let lastChecked = updates.lastChecked {
                Text("Last checked \(formatRelativeDay(lastChecked)).")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        case .available(let release):
            ReleaseNotesPanel(release: release)
            if !release.isInstallable {
                Text("This release can't be installed from inside OpenClean. Download it from GitHub instead.")
                    .font(.system(size: 12)).foregroundStyle(Theme.gold)
            }
        case .downloading(let progress):
            DownloadProgressView(progress: progress)
        case .verifying:
            status("Verifying…")
        case .ready:
            if let blocker = updates.installBlocker {
                note(blocker, symbol: "exclamationmark.triangle.fill", color: Theme.gold)
            } else {
                note(
                    String(
                        localized:
                            "Your current version is kept in History, so you can go back to it. After OpenClean restarts, macOS will ask you to allow Full Disk Access again."
                    ),
                    symbol: "clock.arrow.circlepath", color: Theme.accent)
            }
        case .installing:
            status("Installing…")
        case .failed:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch updates.state {
            case .idle, .checking:
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(CapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
            case .upToDate:
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            case .available(let release):
                Button("Skip This Version") { updates.skipThisVersion() }
                    .buttonStyle(CapsuleButtonStyle())
                Spacer()
                Button("Remind Me Later") { updates.remindMeLater() }
                    .buttonStyle(CapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if release.isInstallable {
                    Button("Download & Install") { updates.downloadAndInstall() }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("View on GitHub") { NSWorkspace.shared.open(release.htmlURL) }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading, .verifying:
                Spacer()
                Button("Cancel") { updates.cancelDownload() }
                    .buttonStyle(CapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(updates.state == .verifying)
            case .ready:
                Spacer()
                Button("Later") { updates.remindMeLater() }
                    .buttonStyle(CapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if updates.installBlocker != nil {
                    Button("Open Installer") {
                        if let dmg = updates.stagedDiskImage { NSWorkspace.shared.open(dmg) }
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Install and Relaunch") { updates.installAndRelaunch() }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            case .installing:
                Spacer()
            case .failed:
                Button("Download from GitHub") {
                    NSWorkspace.shared.open(updates.release?.htmlURL ?? ReleaseFeed.releasesPage)
                }
                .buttonStyle(CapsuleButtonStyle())
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(CapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Retry") { updates.retry() }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func status(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 36)
    }

    private func note(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glassPanel(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Release notes from Markdown, in a scrolling glass panel.
struct ReleaseNotesPanel: View {
    let release: Release

    var body: some View {
        let blocks = ReleaseNotes.blocks(from: release.notes)
        VStack(alignment: .leading, spacing: 8) {
            Text("What's New").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if blocks.isEmpty {
                        Text("No release notes were published for this version.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(blocks) { block in
                        switch block {
                        case .heading(let text, _):
                            Text(text).font(.system(size: 14, weight: .semibold)).padding(.top, 4)
                        case .bullet(let text, _):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Theme.accent)
                                Text(text).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 13))
                        case .paragraph(let text, _):
                            Text(text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(height: 200)
            .glassPanel(radius: 12)
        }
    }
}

/// "12.4 MB of 18.1 MB · 3.2 MB/s" over a thin accent bar.
struct DownloadProgressView: View {
    let progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(Theme.accent)
                        .frame(width: proxy.size.width * (progress.fraction ?? 0))
                        .animation(.easeOut(duration: 0.2), value: progress.fraction)
                }
            }
            .frame(height: 6)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .rollingNumber(progress.received)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading")
        .accessibilityValue(label)
    }

    private var label: String {
        let received = formatBytes(progress.received)
        let size = progress.total.map { String(localized: "\(received) of \(formatBytes($0))") } ?? received
        return "\(size) · \(formatRate(progress.bytesPerSecond))"
    }
}

// MARK: Menu command

/// OpenClean → Check for Updates…: brings the main window forward and shows the sheet there.
struct CheckForUpdatesButton: View {
    let updates: UpdateModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            MainWindow.show(openWindow: openWindow)
            updates.checkForUpdates()
        }
    }
}

/// OpenClean → Settings… (⌘,): shows the Settings page in the main window.
struct OpenSettingsButton: View {
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            navigation.selection = .settings
            MainWindow.show(openWindow: openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

@MainActor
enum MainWindow {
    static func show(openWindow: OpenWindowAction) {
        DockPresence.showInDock()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: isMain) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MenuBarSettings.mainWindowID)
        }
    }

    static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(MenuBarSettings.mainWindowID) == true && window.canBecomeMain
    }
}

/// Keeps OpenClean in the Dock only while a main window is open: closing the last one leaves just the
/// menu bar item (when it is enabled), and opening a window, from the menu bar or by launching the app
/// again, brings the Dock icon back.
@MainActor
enum DockPresence {
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // Posted on the main queue, so the window is only ever touched on the main thread.
            nonisolated(unsafe) let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let closing, MainWindow.isMain(closing) else { return }
                // A minimised window still counts: it can only be brought back from the Dock.
                let othersOpen = NSApp.windows.contains {
                    $0 !== closing && MainWindow.isMain($0) && ($0.isVisible || $0.isMiniaturized)
                }
                if !othersOpen && menuBarEnabled { NSApp.setActivationPolicy(.accessory) }
            }
        }
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, MainWindow.isMain(window) else { return }
                showInDock()
            }
        }
    }

    static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The menu bar item was removed (Settings, or ⌘-dragged out of the menu bar): without a Dock icon
    /// too, nothing would be left to reopen or quit the app.
    static func menuBarItemChanged(enabled: Bool) {
        if !enabled { showInDock() }
    }

    private static var menuBarEnabled: Bool {
        UserDefaults.standard.object(forKey: MenuBarSettings.enabledKey) as? Bool ?? true
    }
}

// MARK: Relaunch

@MainActor
enum AppRelauncher {
    /// Starts a detached shell that waits for this process to exit (at most ~10 s), then opens the app
    /// at `path` again, and quits. The path and pid are passed as arguments, never spliced into the script.
    static func relaunch(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ $i -lt 45 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$0\"",
            path, String(ProcessInfo.processInfo.processIdentifier),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // A window with an attached sheet can keep the app from quitting, so close sheets first and
        // quit on the next run-loop turn. The new version is already in place and nothing is left to
        // save, so if AppKit still declines, exit after a short grace period.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
}
