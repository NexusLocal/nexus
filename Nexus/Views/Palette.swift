import AppKit
import SwiftUI

// The color pairs of the design (docs/design/nexus.pen). AccentColor in the asset catalog holds
// the purple for filled controls.
extension Color {
    static let accentText = pair(light: 0x7A3CF0, dark: 0xB48CFF)
    static let accentSoft = pair(light: 0x7A3CF0, lightAlpha: 0.08, dark: 0xB48CFF, darkAlpha: 0.12)
    static let statusGreen = pair(light: 0x30C25A, dark: 0x32D35E)
    static let statusOrange = pair(light: 0xF59A0A, dark: 0xFFA51F)
    static let statusRed = pair(light: 0xF0443A, dark: 0xFF5A50)
    static let statusGray = pair(light: 0x9A98A0, dark: 0x8E8C94)
    static let greenText = pair(light: 0x1E8A3C, dark: 0x4ADE80)
    static let orangeText = pair(light: 0xA35F00, dark: 0xFFB54D)
    static let redText = pair(light: 0xC9261C, dark: 0xFF6B61)
    static let warningBackground = pair(light: 0xF59A0A, lightAlpha: 0.12, dark: 0xFFA51F, darkAlpha: 0.15)
    static let errorBackground = pair(light: 0xF0443A, lightAlpha: 0.10, dark: 0xFF5A50, darkAlpha: 0.15)

    private static func pair(light: Int, lightAlpha: Double = 1, dark: Int, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int, alpha: Double) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Health {
    var color: Color {
        switch self {
        case .running: .statusGreen
        case .stopped: .statusGray
        case .attention: .statusOrange
        case .failed: .statusRed
        }
    }

    var textColor: Color {
        switch self {
        case .running: .greenText
        case .stopped: .secondary
        case .attention: .orangeText
        case .failed: .redText
        }
    }
}

extension NSImage {
    // A segmented control draws its images as templates. This image keeps its color, and has
    // room on the right for the gap to the label.
    static func statusDot(_ health: Health) -> NSImage {
        let image = NSImage(size: NSSize(width: 13, height: 8), flipped: false) { _ in
            NSColor(health.color).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct StatusDot: View {
    let health: Health

    var body: some View {
        Circle()
            .fill(health.color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(Text(String(describing: health)))
    }
}
