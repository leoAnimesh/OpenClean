import AppKit
import Charts
import OpenCleanAppModel
import SwiftUI
import SystemMonitor

// Small building blocks shared by the Performance screens and the menu bar popover.

func formatPercent(_ fraction: Double?) -> String {
    guard let fraction else { return "–" }
    return fraction.formatted(.percent.precision(.fractionLength(0)))
}

/// Physical memory in binary units, the way macOS sizes it: a 24 GB Mac reads "24 GB", not "25.77 GB".
func formatMemory(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}

/// "1.2 MB/s", "340 KB/s", "0 KB/s".
func formatRate(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else { return "–" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    // "0 KB/s" rather than "Zero KB/s".
    formatter.allowsNonnumericFormatting = false
    if bytesPerSecond < 1_000 { formatter.allowedUnits = .useKB }
    return String(localized: "\(formatter.string(fromByteCount: bytesPerSecond < 1_000 ? 0 : Int64(bytesPerSecond)))/s")
}

/// "Today, 5:13 PM", "Yesterday, 9:02 AM", otherwise "Mar 4, 5:13 PM" (same style as History).
func formatRelativeDay(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
    if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)") }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

func pressureLabel(_ pressure: MemoryPressure) -> String {
    switch pressure {
    case .normal: String(localized: "Normal")
    case .warning: String(localized: "Elevated")
    case .critical: String(localized: "High")
    case .unknown: String(localized: "Unknown")
    }
}

func pressureColor(_ pressure: MemoryPressure) -> Color {
    switch pressure {
    case .normal, .unknown: Theme.accent
    case .warning: Theme.gold
    case .critical: Theme.coral
    }
}

/// A word in a small capsule, like `SafetyTag`: "Needs admin", "System (read-only)". Never color alone.
struct StatusTag: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A tiny line + area chart of recent values. Decorative: the number next to it carries the meaning.
struct Sparkline: View {
    let points: [MetricPoint]
    /// Fixed upper bound (e.g. 1 for fractions); nil scales to the data.
    var maxValue: Double?
    var color: Color = Theme.accent

    var body: some View {
        let top = max(maxValue ?? (points.map(\.value).max() ?? 0), maxValue == nil ? 1 : 0.0001)
        Chart(points) { point in
            AreaMark(x: .value("Sample", point.id), y: .value("Value", min(point.value, top)))
                .foregroundStyle(color.opacity(0.22))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Sample", point.id), y: .value("Value", min(point.value, top)))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...top)
        .chartXScale(domain: .automatic(includesZero: false))
        .accessibilityHidden(true)
    }
}

/// A thin horizontal meter (0…1) for the menu bar popover.
struct MeterBar: View {
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.glassStroke)
                Capsule().fill(color)
                    .frame(width: max(4, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// App icon for a bundle path, or an SF Symbol tile for bundle-less processes.
struct ProcessIcon: View {
    let bundlePath: String?
    var size: CGFloat = 28

    var body: some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(Theme.glassFill)
                .overlay(
                    Image(systemName: "terminal")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                )
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// Renders the logo glyph as a monochrome template image for the menu bar.
@MainActor
enum MenuBarGlyph {
    static let image: NSImage = {
        let renderer = ImageRenderer(content: LogoGlyph(size: 18).frame(width: 18, height: 18))
        renderer.scale = 2
        let image =
            renderer.nsImage ?? NSImage(
                systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "OpenClean"
        return image
    }()
}

/// Grey rows shaped like the process list, shown while its first figures are measured (they need two
/// samples), so the list doesn't jump into place and the wait reads as loading rather than as empty.
struct PlaceholderRows: View {
    var count = 3
    var iconSize: CGFloat = 18
    var spacing: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).frame(width: iconSize, height: iconSize)
                    // Varied widths so the rows read as names rather than a pattern.
                    Capsule().frame(width: [110, 80, 96, 70, 88][index % 5], height: 8)
                    Spacer()
                    Capsule().frame(width: 34, height: 8)
                    Capsule().frame(width: 48, height: 8)
                }
                .frame(height: iconSize + 4)
            }
        }
        .foregroundStyle(Theme.glassStroke)
        .opacity(dimmed ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Measuring")
    }
}
