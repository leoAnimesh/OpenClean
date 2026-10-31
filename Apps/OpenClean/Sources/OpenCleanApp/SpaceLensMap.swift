import AppKit
import OpenCleanAppModel
import SpaceKit
import SwiftUI

// MARK: Layout

/// One arc of the sunburst. Angles are radians clockwise from 12 o'clock.
struct SunburstSegment: Identifiable {
    let node: SpaceNode
    let ring: Int
    let start: Double
    let end: Double
    let colorIndex: Int

    var id: String { node.id }
}

/// Pure geometry for the sunburst, kept apart from drawing so hit-testing uses the same numbers.
struct SunburstGeometry {
    static let rings = 3
    let center: CGPoint
    let innerRadius: CGFloat
    let ringWidth: CGFloat

    init(size: CGSize) {
        let outer = max(10, min(size.width, size.height) / 2 - 4)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        innerRadius = outer * 0.32
        ringWidth = (outer - innerRadius) / CGFloat(Self.rings)
    }

    /// Arcs for the focused folder's children (ring 1) and up to two levels below them.
    static func segments(for focus: SpaceNode, minSweep: Double = 0.008) -> [SunburstSegment] {
        var result: [SunburstSegment] = []
        func place(_ node: SpaceNode, ring: Int, start: Double, sweep: Double, color: Int?) {
            guard ring <= rings, node.size > 0 else { return }
            var angle = start
            for (index, child) in node.children.enumerated() {
                let share = sweep * Double(child.size) / Double(node.size)
                if share >= minSweep {
                    let colorIndex = color ?? index
                    result.append(
                        SunburstSegment(
                            node: child, ring: ring, start: angle, end: angle + share, colorIndex: colorIndex))
                    if child.isDirectory {
                        place(child, ring: ring + 1, start: angle, sweep: share, color: colorIndex)
                    }
                }
                angle += share
            }
        }
        place(focus, ring: 1, start: 0, sweep: 2 * .pi, color: nil)
        return result
    }

    func radii(ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        let inner = innerRadius + CGFloat(ring - 1) * ringWidth
        return (inner + 1, inner + ringWidth - 1)
    }

    func path(for segment: SunburstSegment) -> Path {
        let (inner, outer) = radii(ring: segment.ring)
        // Screen angles: 0 at 3 o'clock, increasing clockwise (y points down).
        let start = Angle(radians: segment.start - .pi / 2)
        let end = Angle(radians: segment.end - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    enum Hit: Equatable {
        case center
        case segment(String)
    }

    func hit(_ point: CGPoint, in segments: [SunburstSegment]) -> Hit? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < innerRadius { return .center }
        let ring = Int((distance - innerRadius) / ringWidth) + 1
        guard ring <= Self.rings else { return nil }
        var angle = atan2(Double(dy), Double(dx)) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return segments.first { $0.ring == ring && angle >= $0.start && angle < $0.end }.map { .segment($0.id) }
    }
}

// MARK: Sunburst

struct SunburstView: View {
    @Environment(SpaceLensModel.self) private var model
    let focus: SpaceNode
    @Binding var hoveredID: String?

    var body: some View {
        let segments = SunburstGeometry.segments(for: focus)
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size)
            let selected = Set(model.selection.keys)
            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        let path = geometry.path(for: segment)
                        context.fill(path, with: .color(color(for: segment)))
                        context.stroke(path, with: .color(Theme.spaceMapCenter), lineWidth: 1)
                        if selected.contains(segment.id) {
                            context.stroke(path, with: .color(.white), lineWidth: 2)
                        }
                    }
                    let disc = Path(
                        ellipseIn: CGRect(
                            x: geometry.center.x - geometry.innerRadius, y: geometry.center.y - geometry.innerRadius,
                            width: geometry.innerRadius * 2, height: geometry.innerRadius * 2))
                    context.fill(disc, with: .color(Theme.spaceMapCenter))
                    context.stroke(disc, with: .color(Theme.glassStroke), lineWidth: 1)
                }
                centerLabel(segments: segments)
                    .frame(width: geometry.innerRadius * 1.7)
                    .position(geometry.center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if case .segment(let id) = geometry.hit(point, in: segments) {
                        hoveredID = id
                    } else {
                        hoveredID = nil
                    }
                case .ended:
                    hoveredID = nil
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    switch geometry.hit(value.location, in: segments) {
                    case .center:
                        model.goUp()
                    case .segment(let id):
                        if let node = segments.first(where: { $0.id == id })?.node, node.canOpen {
                            withAnimation(.easeInOut(duration: 0.25)) { model.focus(on: id) }
                        }
                    case nil:
                        break
                    }
                })
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Space map of \(focus.name)")
        .accessibilityValue("\(formatBytes(focus.size)). The list beside it shows the same items.")
    }

    private func color(for segment: SunburstSegment) -> Color {
        let node = segment.node
        let base: Color =
            node.isAggregate || node.isUnreadable
            ? Theme.spaceMapMuted
            : Theme.spaceMapPalette[segment.colorIndex % Theme.spaceMapPalette.count]
        let ringOpacity = [0.95, 0.8, 0.66][min(segment.ring, 3) - 1]
        let opacity = hoveredID == segment.id ? 1 : (node.isDirectory ? ringOpacity : ringOpacity * 0.8)
        return base.opacity(hoveredID == nil || hoveredID == segment.id ? opacity : opacity * 0.8)
    }

    @ViewBuilder
    private func centerLabel(segments: [SunburstSegment]) -> some View {
        let hovered = hoveredID.flatMap { id in segments.first { $0.id == id }?.node }
        let shown = hovered ?? focus
        VStack(spacing: 3) {
            Text(title(for: shown))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(formatBytes(shown.size))
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if hovered == nil, model.breadcrumb.count > 1 {
                Text("Click to go up")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .foregroundStyle(.white)
    }

    private func title(for node: SpaceNode) -> String {
        if case .other(let count) = node.kind { return String(localized: "\(count) smaller items") }
        return node.name
    }
}

extension SpaceNode {
    /// Folders with something to show inside: kept children, or a summary that can be rescanned.
    var canOpen: Bool { isDirectory && (!children.isEmpty || isTruncated) }
}

// MARK: Tab

struct SpaceMapTab: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        switch model.mapPhase {
        case .idle:
            SpaceLensHomeView(
                symbol: "chart.pie.fill", headline: String(localized: "See what takes up space"),
                message:
                    String(
                        localized:
                            "Space Lens maps a folder by size so you can find what to remove. Nothing is removed until you tick it and confirm; items go to the Trash."
                    ),
                scan: { model.startMapScan() },
                options: {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Folder: \(folderLabel(model.mapRoot))")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose Folder…") {
                                if let path = chooseFolder(startingAt: model.mapRoot) { model.startMapScan(root: path) }
                            }
                            .buttonStyle(CapsuleButtonStyle())
                        }
                    }
                })
        case .scanning:
            let progress = model.mapProgress
            SpaceLensScanningView(
                status: String(localized: "Scanning \(folderLabel(model.mapRoot))…"),
                bigNumber: formatBytes(progress.bytes),
                detail: String(localized: "\(progress.items) items")
                    + (progress.unreadable > 0
                        ? " · " + String(localized: "\(progress.unreadable) unreadable") : ""),
                stop: { model.stopScan(.map) })
        case .results:
            SpaceMapResultsView()
        }
    }

    private func folderLabel(_ path: String) -> String {
        path == model.home ? String(localized: "Home") : (path as NSString).lastPathComponent
    }
}

@MainActor
func chooseFolder(startingAt path: String, prompt: String = String(localized: "Choose")) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct SpaceMapResultsView: View {
    @Environment(SpaceLensModel.self) private var model
    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SpaceLensBackButton(title: "Start over") { model.startOver(.map) }
                breadcrumb
                if let result = model.mapResult, !result.isComplete {
                    Label(
                        "The scan was stopped early. Sizes are partial.", systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.gold)
                }
                if let report = model.lastReport { SpaceLensReportBanner(report: report) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 16)

            if let focus = model.focusedNode {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 10) {
                        SunburstView(focus: focus, hoveredID: $hoveredID)
                            .frame(minWidth: 300, maxWidth: 460, minHeight: 300, maxHeight: 460)
                        Text("Sizes are space on disk. Copies made by APFS cloning may share space.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    childList(focus)
                        .frame(minWidth: 380, maxWidth: 480)
                }
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            SpaceLensAccessNote(unreadable: model.mapResult?.unreadableCount ?? 0)
                .padding(.horizontal, 32)
            SpaceLensTrashBar()
        }
    }

    private var breadcrumb: some View {
        let trail = model.breadcrumb
        return HStack(spacing: 6) {
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                let title =
                    index == 0 && model.mapResult?.rootPath == model.home ? String(localized: "Home") : node.name
                if index == trail.count - 1 {
                    Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { model.focus(on: node.id) }
                    } label: {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let focus = trail.last {
                Text(formatBytes(focus.size))
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func childList(_ focus: SpaceNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if focus.isTruncated || focus.isUnreadable {
                    truncatedNote(focus)
                }
                if !focus.children.isEmpty {
                    SpaceLensPanel {
                        ForEach(Array(focus.children.enumerated()), id: \.element.id) { index, child in
                            if index > 0 { SpaceLensDivider() }
                            row(child)
                        }
                    }
                } else if !focus.isTruncated {
                    SpaceLensEmptyState(
                        symbol: "folder", title: String(localized: "Empty folder"),
                        message: String(localized: "Nothing inside takes up space."))
                }
            }
            .padding(.bottom, 8)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ node: SpaceNode) -> some View {
        if case .other(let count) = node.kind {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.spaceMapMuted)
                    .frame(width: 28, height: 28)
                    .padding(.leading, 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) smaller items").font(.system(size: 14, weight: .semibold))
                    Text("Grouped to keep the map light").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(formatBytes(node.size)).font(.system(size: 14)).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .flatRowHighlight(hoveredID == node.id ? Theme.rowHover : .clear)
            .accessibilityElement(children: .combine)
        } else if let candidate = model.candidate(for: node) {
            SpaceLensItemRow(
                path: candidate.path, title: node.name, subtitle: subtitle(node), size: node.size,
                isSelected: model.isSelected(candidate.path),
                disabledReason: model.protection(for: candidate.path, isDirectory: candidate.isDirectory)
                    .map { String(localized: "Can’t be moved to the Trash: \($0)") },
                isHighlighted: hoveredID == node.id,
                onToggle: { model.toggle(candidate) },
                accessory: {
                    if node.canOpen {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { model.focus(on: node.id) }
                        } label: {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(node.name)")
                        .accessibilityLabel("Open \(node.name)")
                    }
                }
            )
            .onHover { inside in hoveredID = inside ? node.id : (hoveredID == node.id ? nil : hoveredID) }
        }
    }

    private func subtitle(_ node: SpaceNode) -> String {
        switch node.kind {
        case .directory:
            if node.isUnreadable { return String(localized: "Folder · couldn’t be read") }
            let items = max(0, node.itemCount - 1)
            return String(localized: "Folder · \(items) items")
        case .symlink: return String(localized: "Alias (not followed)")
        case .file, .other: return String(localized: "File")
        }
    }

    private func truncatedNote(_ focus: SpaceNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: focus.isUnreadable ? "lock.fill" : "info.circle.fill")
                .foregroundStyle(Theme.gold)
            Text(
                focus.isUnreadable
                    ? String(localized: "OpenClean couldn’t read this folder.")
                    : String(localized: "This folder is deep in the map, so its contents were summarized.")
            )
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            if focus.isTruncated, let path = focus.path {
                Button("Scan This Folder") { model.startMapScan(root: path) }
                    .buttonStyle(CapsuleButtonStyle())
                    .fixedSize()
            }
        }
        .padding(14)
        .glassPanel(radius: 14)
    }
}
