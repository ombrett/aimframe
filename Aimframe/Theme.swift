import SwiftUI
import UIKit

/// Aimframe's look, taken from the icon: near-black, ivory viewfinder, yellow focus point.
/// Yellow means "do something", green means "this is right"; both always come with text or a symbol.
enum Theme {
    static let background = Color(red: 0.027, green: 0.031, blue: 0.043)     // #07080B
    static let panel = Color(red: 0.075, green: 0.08, blue: 0.095)
    static let panelHigh = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let ivory = Color(red: 0.988, green: 0.945, blue: 0.84)           // #FCF1D6
    static let ivoryDim = Color(red: 0.988, green: 0.945, blue: 0.84).opacity(0.62)
    static let yellow = Color(red: 1.0, green: 0.788, blue: 0.012)           // #FFC903
    static let yellowWash = Color(red: 1.0, green: 0.788, blue: 0.012).opacity(0.14)
    static let green = Color(red: 0.36, green: 0.86, blue: 0.52)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.38)

    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func small(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .semibold, design: .rounded) }

    static func color(for tone: Tone) -> Color {
        switch tone {
        case .neutral: return ivoryDim
        case .guide: return yellow
        case .good: return green
        case .warning: return red
        }
    }

    static func symbol(for tone: Tone) -> String {
        switch tone {
        case .neutral: return "viewfinder"
        case .guide: return "arrow.up.and.down.and.arrow.left.and.right"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func shutter() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// The corner brackets of the icon, used for the subject box and the detail-shot frame.
struct Brackets: Shape {
    var length: CGFloat = 0.22

    func path(in r: CGRect) -> Path {
        var p = Path()
        let lx = r.width * length, ly = r.height * length
        p.move(to: CGPoint(x: r.minX, y: r.minY + ly)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + lx, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - lx, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + ly))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - ly)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - lx, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + lx, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - ly))
        return p
    }
}

/// A small rounded label used over the viewfinder.
struct Pill: View {
    let text: String
    var color: Color = Theme.ivory
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol = symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(Theme.small())
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

struct ChipLabel: View {
    let title: String
    var selected = false
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol = symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title).lineLimit(1)
        }
        .font(Theme.small(13))
        .foregroundColor(selected ? Theme.yellow : Theme.ivoryDim)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(selected ? Theme.yellowWash : Theme.panel)
        .overlay(Capsule().stroke(selected ? Theme.yellow.opacity(0.6) : Color.clear, lineWidth: 1))
        .clipShape(Capsule())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}
