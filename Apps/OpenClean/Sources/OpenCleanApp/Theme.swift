import RuleKit
import SwiftUI

// The OpenClean look: deep gradient backdrops, frosted glass panels, one round glass action per screen.
// Every color, gradient and reusable surface lives here. See .claude/skills/openclean-design/SKILL.md.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

enum Theme {
    // Brand
    static let mint = Color(hex: 0x4BF2B8)
    static let teal = Color(hex: 0x12A88B)
    static let deepTeal = Color(hex: 0x0A4756)
    /// Progress, checkmarks, selection. The only bright accent.
    static let accent = Color(hex: 0x7DF5C8)
    /// Review items and notices.
    static let gold = Color(hex: 0xFFD58A)
    /// Caution items.
    static let coral = Color(hex: 0xFFB894)

    // Text on dark backdrops
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.8)
    static let textTertiary = Color.white.opacity(0.62)

    // Glass
    static let glassFill = Color.white.opacity(0.09)
    static let glassStroke = Color.white.opacity(0.14)
    static let glassDivider = Color.white.opacity(0.08)
    /// Selected and hovered rows in the sidebar and Cleanup's lists (never the system accent colour).
    static let rowSelected = Color.white.opacity(0.16)
    static let rowHover = Color.white.opacity(0.07)
    static let sidebar = Color(hex: 0x05181D)

    static let panelRadius: CGFloat = 16
    static let tileRadius: CGFloat = 10
}

/// Which backdrop a screen sits on.
enum Backdrop {
    case scan, success, history, uninstaller, spaceLens, performance

    var gradient: LinearGradient {
        let colors: [UInt32] =
            switch self {
            case .scan: [0x082A33, 0x0B4A4C, 0x12795F]
            case .success: [0x0A3A3E, 0x0F6656, 0x1FA67A]
            case .history: [0x0C1B33, 0x15335A, 0x1F5A7A]
            case .uninstaller: [0x22102E, 0x3D1A52, 0x6A3478]
            case .spaceLens: [0x0F1638, 0x1E2B66, 0x34489A]
            case .performance: [0x2A1407, 0x52290E, 0x8A4E1A]
            }
        return LinearGradient(
            colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: Surfaces

struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.panelRadius

    func body(content: Content) -> some View {
        content
            .background(Theme.glassFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.glassStroke))
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.panelRadius) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}

// MARK: Live numbers

/// Rolls digits when a live number changes (sizes, counts, percentages). Off with Reduce Motion.
struct RollingNumber<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: value)
    }
}

extension View {
    func rollingNumber<Value: Equatable>(_ value: Value) -> some View {
        modifier(RollingNumber(value: value))
    }
}

// MARK: Buttons

/// The one big round action on a screen (Scan, Clean).
struct GlassCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 112

    func makeBody(configuration: Configuration) -> some View {
        GlassCircle(configuration: configuration, diameter: diameter)
    }

    private struct GlassCircle: View {
        let configuration: Configuration
        let diameter: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: diameter * 0.18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(
                        RadialGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.12)],
                            center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: diameter * 0.7))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.28), radius: 15, y: 12)
                .padding(8)
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(duration: 0.25), value: configuration.isPressed)
        }
    }
}

/// Secondary pill buttons. `prominent` is white with teal text, used for Done.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    private struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            CapsuleButtonStyle.body(configuration, prominent: prominent)
                .opacity(isEnabled ? 1 : 0.4)
        }
    }

    fileprivate static func body(_ configuration: Configuration, prominent: Bool) -> some View {
        configuration.label
            .font(.system(size: 14, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Theme.deepTeal : .white)
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            .background(prominent ? Color.white : Color.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.28)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: Brand marks

/// The open "O" ring of the logo, drawn in a square of any size.
struct LogoRing: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(x: rect.minX + unit * 0.5, y: rect.minY + unit * 0.534)
        let radius = unit * 0.267
        var path = Path()
        // Clockwise on screen from 3 o’clock round to 12 o’clock, leaving the top-right quarter for the spark.
        for degrees in stride(from: 0.0, through: 270.0, by: 3) {
            let radians = degrees * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
            if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    static func lineWidth(for size: CGFloat) -> CGFloat { size * 0.112 }
}

/// A four-point spark centered at a unit point with a unit radius.
struct Spark: Shape {
    var center = CGPoint(x: 0.716, y: 0.316)
    var radius: CGFloat = 0.119

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height)
        let c = CGPoint(x: rect.minX + center.x * unit, y: rect.minY + center.y * unit)
        let r = radius * unit
        let near = r * 0.112
        let far = r * 0.224
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addCurve(
            to: CGPoint(x: c.x + r, y: c.y), control1: CGPoint(x: c.x + near, y: c.y - far),
            control2: CGPoint(x: c.x + far, y: c.y - near))
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x + far, y: c.y + near),
            control2: CGPoint(x: c.x + near, y: c.y + far))
        path.addCurve(
            to: CGPoint(x: c.x - r, y: c.y), control1: CGPoint(x: c.x - near, y: c.y + far),
            control2: CGPoint(x: c.x - far, y: c.y + near))
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y - r), control1: CGPoint(x: c.x - far, y: c.y - near),
            control2: CGPoint(x: c.x - near, y: c.y - far))
        path.closeSubpath()
        return path
    }
}

/// White ring + spark, for placing on any colored ground.
struct LogoGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            LogoRing().stroke(
                .white, style: StrokeStyle(lineWidth: LogoRing.lineWidth(for: size), lineCap: .round))
            Spark().fill(.white)
            Spark(center: CGPoint(x: 0.85, y: 0.133), radius: 0.044).fill(.white.opacity(0.85))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app icon: gradient squircle with the glyph. Matches scripts/make-app-icon.swift.
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [Theme.mint, Theme.teal, Theme.deepTeal], startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            shape.fill(
                RadialGradient(
                    colors: [.white.opacity(0.5), .white.opacity(0)], center: UnitPoint(x: 0.3, y: 0.15),
                    startRadius: 0, endRadius: size * 0.6))
            LogoGlyph(size: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The glossy hero sphere at the center of Smart Scan screens.
struct Orb<Content: View>: View {
    var size: CGFloat = 240
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.black.opacity(0.28))
                .frame(width: size * 0.65, height: size * 0.07)
                .blur(radius: 6)
                .offset(y: size * 0.56)
            Circle().fill(
                RadialGradient(
                    colors: [Color(hex: 0x8CFFD6), Color(hex: 0x19B48E), Color(hex: 0x063F49)],
                    center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.8))
            Circle().fill(
                RadialGradient(
                    colors: [.white.opacity(0.75), .white.opacity(0)], center: UnitPoint(x: 0.36, y: 0.2),
                    startRadius: 0, endRadius: size * 0.4))
            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5)
            content
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: Data display

struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 6
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Small rounded pill for status at the top right of a screen.
struct StatPill<Icon: View>: View {
    let text: String
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 7) {
            icon
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.white.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Gradient tile with a white SF Symbol, one per cleanup category.
struct CategoryIcon: View {
    let category: RuleCategory
    var size: CGFloat = 36

    var body: some View {
        let (symbol, top, bottom) = Self.style(for: category)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            .accessibilityHidden(true)
    }

    static func style(for category: RuleCategory) -> (String, Color, Color) {
        switch category {
        case .system: ("gearshape.2.fill", Color(hex: 0xFF7A9A), Color(hex: 0xD2386A))
        case .user: ("doc.text.fill", Color(hex: 0xFFBF5A), Color(hex: 0xEE7A1C))
        case .browsers: ("globe", Color(hex: 0x62BFFF), Color(hex: 0x2E6BEA))
        case .developer: ("chevron.left.forwardslash.chevron.right", Color(hex: 0x9B8CFF), Color(hex: 0x5643D9))
        case .ai: ("cpu.fill", Color(hex: 0x55E3D2), Color(hex: 0x168C9C))
        case .mail: ("envelope.fill", Color(hex: 0x7AD8FF), Color(hex: 0x2496D6))
        case .trash: ("trash.fill", Color(hex: 0xBFC8D1), Color(hex: 0x6B7785))
        case .ios: ("iphone", Color(hex: 0x86E482), Color(hex: 0x2E9E4E))
        }
    }
}

/// Safe / Review / Caution label. Color is never the only signal: the word is always shown.
struct SafetyTag: View {
    let safety: SafetyLevel

    var body: some View {
        Text(Self.label(safety))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.color(safety))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.22), in: Capsule())
            .accessibilityLabel("Safety: \(Self.label(safety))")
    }

    static func label(_ safety: SafetyLevel) -> String {
        switch safety {
        case .regenerable: String(localized: "Safe")
        case .review: String(localized: "Review")
        case .caution: String(localized: "Caution")
        }
    }

    static func color(_ safety: SafetyLevel) -> Color {
        switch safety {
        case .regenerable: Theme.textSecondary
        case .review: Theme.gold
        case .caution: Theme.coral
        }
    }
}

// MARK: Performance

extension Theme {
    /// The GPU's share in the shared memory bar, next to `accent` for everything else.
    static let gpu = Color(hex: 0xB3A6FF)
}

// MARK: Space Lens

extension Theme {
    /// Segment colors for the space map, one per top-level folder in turn. Bright, similar lightness,
    /// and distinct from each other on the indigo backdrop.
    static let spaceMapPalette: [Color] = [
        Color(hex: 0x7DF5C8),  // mint (accent)
        Color(hex: 0x62BFFF),  // sky
        Color(hex: 0xB3A6FF),  // lavender
        Color(hex: 0xFF8FAB),  // rose
        Color(hex: 0xFFC56E),  // amber
        Color(hex: 0x55E3D2),  // aqua
        Color(hex: 0xFFB894),  // coral
        Color(hex: 0x9BE68F),  // leaf
    ]
    /// "Other" aggregates and unreadable folders in the space map.
    static let spaceMapMuted = Color(hex: 0xBFC8D1)
    /// The map's center disc.
    static let spaceMapCenter = Color(hex: 0x0F1638, opacity: 0.6)
}
