import AppKit
import Observation
import OpenCleanAppModel
import Permissions
import Quarantine
import RuleKit
import SwiftUI

/// The Quick Look target for Space Lens, shared by all its lists.
@MainActor
@Observable
final class SpaceLensPreview {
    var url: URL?

    func show(_ path: String) { url = URL(fileURLWithPath: path) }
}

enum SpaceLensFinder {
    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// "Today, 5:13 PM", "Yesterday, 9:02 AM", otherwise "Mar 4, 2025".
func spaceLensDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
    if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)") }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

/// A path for display, with the home folder shown as "~".
func spaceLensDisplayPath(_ path: String, home: String) -> String {
    guard pathIsWithin(path, home) else { return path }
    return "~" + String(decoding: path.utf8.dropFirst(home.utf8.count), as: UTF8.self)
}

/// The folder an item sits in, for display.
func spaceLensFolder(_ path: String, home: String) -> String {
    spaceLensDisplayPath((path as NSString).deletingLastPathComponent, home: home)
}

/// "From Documents" / "From Desktop" for files in the user-content folders.
func userContentLabel(_ path: String, home: String) -> String {
    pathIsWithin(path, home + "/Desktop", caseInsensitive: true)
        ? String(localized: "From Desktop") : String(localized: "From Documents")
}

/// Finder's icon for a file or folder, cached by path.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 28

    @MainActor private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// One file or folder in a Space Lens list: checkbox, icon, name, details, size, Reveal and Quick Look.
struct SpaceLensItemRow<Accessory: View>: View {
    @Environment(SpaceLensModel.self) private var model
    @Environment(SpaceLensPreview.self) private var preview
    let path: String
    let title: String
    let subtitle: String
    let size: Int64
    let isSelected: Bool
    /// Why the checkbox is disabled, shown as help text; nil when it can be ticked.
    let disabledReason: String?
    /// Highlighted from outside, e.g. while its segment in the Space Lens map is hovered.
    var isHighlighted = false
    let onToggle: () -> Void
    @ViewBuilder var accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CheckboxButton(state: isSelected ? .on : .off, label: title) { onToggle() }
                .disabled(disabledReason != nil)
                .opacity(disabledReason == nil ? 1 : 0.35)
                .help(
                    disabledReason
                        ?? (isSelected
                            ? String(localized: "Don’t move to the Trash") : String(localized: "Move to the Trash")))
            FileIcon(path: path)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    accessory
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button {
                    preview.show(path)
                } label: {
                    Image(systemName: "eye").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .help("Quick Look")
                .accessibilityLabel("Quick Look \(title)")
                Button {
                    SpaceLensFinder.reveal(path)
                } label: {
                    Image(systemName: "magnifyingglass").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(title) in Finder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .opacity(hovering ? 1 : 0.55)
            Text(formatBytes(size))
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .flatRowHighlight(hovering || isHighlighted ? Theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { SpaceLensFinder.reveal(path) }
            Button("Quick Look") { preview.show(path) }
        }
    }
}

extension SpaceLensItemRow where Accessory == EmptyView {
    init(
        path: String, title: String, subtitle: String, size: Int64, isSelected: Bool, disabledReason: String?,
        onToggle: @escaping () -> Void
    ) {
        self.init(
            path: path, title: title, subtitle: subtitle, size: size, isSelected: isSelected,
            disabledReason: disabledReason, onToggle: onToggle, accessory: { EmptyView() })
    }
}

/// A small factual label next to a row title ("From Documents", "Suggested to keep").
struct SpaceLensTag: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.black.opacity(0.22), in: Capsule())
    }
}

/// Glass list container used by every Space Lens list.
struct SpaceLensPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            .glassPanel()
    }
}

/// Divider between rows inside a glass panel.
struct SpaceLensDivider: View {
    var body: some View { Divider().overlay(Theme.glassDivider) }
}

/// Bottom bar: what's selected, the round Trash button, and Scan Again.
struct SpaceLensTrashBar: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        let count = model.selection.count
        HStack(spacing: 28) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(count > 0 ? "\(formatBytes(model.selectedBytes)) selected" : "Nothing selected")
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text(
                    count > 0
                        ? String(localized: "\(count) items · goes to the Trash")
                        : String(localized: "Tick items to move them")
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Button {
                model.requestTrash()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 22, weight: .semibold))
                    Text("Trash…").font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(GlassCircleButtonStyle(diameter: 96))
            .disabled(count == 0 || model.isTrashing)
            .accessibilityLabel("Move to Trash")

            HStack {
                Button("Scan Again") { model.startScan(model.tab) }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(model.isTrashing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
}

/// What happened after a move to the Trash.
struct SpaceLensReportBanner: View {
    @Environment(SpaceLensModel.self) private var model
    let report: TrashReport
    @State private var expanded = false

    var body: some View {
        let moved = report.trashed.count
        let skipped = report.notMoved
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(skipped.isEmpty ? Theme.accent : Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(moved: moved)).font(.system(size: 14, weight: .semibold))
                    Text(
                        skipped.isEmpty
                            ? String(localized: "You can put items back from the Trash in Finder.")
                            : String(localized: "\(skipped.count) items were left in place.")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !skipped.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Label(
                            expanded ? "Hide details" : "Details", systemImage: expanded ? "chevron.up" : "chevron.down"
                        )
                    }
                    .buttonStyle(CapsuleButtonStyle())
                }
                Button("Dismiss") { model.dismissReport() }
                    .buttonStyle(CapsuleButtonStyle())
            }
            if expanded {
                ForEach(skipped, id: \.request.path) { result in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text((result.request.path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(reason(result.outcome))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .glassPanel(radius: 14)
        .accessibilityElement(children: .combine)
    }

    private func headline(moved: Int) -> String {
        moved == 0
            ? String(localized: "Nothing was moved to the Trash")
            : "\(String(localized: "\(moved) items moved to the Trash")) · \(formatBytes(report.trashedBytes))"
    }

    private func reason(_ outcome: TrashOutcome) -> String {
        switch outcome {
        case .trashed: String(localized: "moved")
        case .skipped(let reason): reason.description.capitalizedFirst
        case .failed(let message): message
        }
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Footnote when some folders could not be read, pointing at Full Disk Access.
struct SpaceLensAccessNote: View {
    @Environment(SpaceLensModel.self) private var model
    let unreadable: Int

    var body: some View {
        if unreadable > 0 {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.gold)
                Text(
                    String(localized: "\(unreadable) folders couldn’t be read.")
                        + (model.hasFullDiskAccess
                            ? "" : " " + String(localized: "Full Disk Access lets OpenClean include them."))
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.hasFullDiskAccess {
                    Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
                        .buttonStyle(CapsuleButtonStyle())
                        .fixedSize()
                }
            }
        }
    }
}

/// "Start over" link at the top left of a results screen.
struct SpaceLensBackButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Discard these results and go back. Nothing is removed.")
    }
}

/// Start screen for one tab: orb, headline, one sentence, the round Scan button, options below.
struct SpaceLensHomeView<Options: View>: View {
    let symbol: String
    let headline: String
    let message: String
    var scanDisabled = false
    let scan: () -> Void
    @ViewBuilder var options: Options

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            Orb(size: 200) {
                Image(systemName: symbol)
                    .font(.system(size: 78, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(headline)
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 26)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
                .lineLimit(3)
                .padding(.top, 10)
            Spacer(minLength: 20)
            Button("Scan", action: scan)
                .buttonStyle(GlassCircleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(scanDisabled)
            options
                .padding(.top, 16)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

/// Full-screen progress for a running scan: the orb inside a spinning ring, live counters, Stop.
struct SpaceLensScanningView: View {
    let status: String
    let bigNumber: String
    let detail: String
    let stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: spinning)
                Orb(size: 220) { LogoGlyph(size: 190) }
            }
            .frame(width: 264, height: 264)
            .onAppear { spinning = true }
            .accessibilityElement()
            .accessibilityLabel("Scanning")
            .accessibilityValue(detail)

            Text(status)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 28)
            Text(bigNumber)
                .font(.system(size: 56, weight: .bold))
                .rollingNumber(bigNumber)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .rollingNumber(detail)
            Spacer(minLength: 24)
            Button("Stop", action: stop)
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Centered message for empty results.
struct SpaceLensEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(Theme.textSecondary)
            Text(title).font(.system(size: 22, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}
