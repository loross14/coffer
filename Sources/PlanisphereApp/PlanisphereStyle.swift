import AppKit
import SwiftUI

/// Shared materials for the native workspace. Keep contrast in both system appearances.
enum PSStyle {
    static let accent = adaptive(light: 0x315ED4, dark: 0x8CA9FF)
    static let canvas = adaptive(light: 0xFAF9F6, dark: 0x181A1E)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202227)
    static let sidebar = adaptive(light: 0xF0EFEB, dark: 0x14161A)
    static let border = Color.primary.opacity(0.08)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct PSButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        PSButtonBody(configuration: configuration, primary: primary)
    }

    private struct PSButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(primary ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .background(primary ? PSStyle.accent : Color.primary.opacity(hovered ? 0.09 : 0.045),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.clear : PSStyle.border))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
        }
    }
}

struct PSIconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .onHover { hovered = $0 }
        .help(help).accessibilityLabel(help)
    }
}

struct PSSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
            .tracking(1.2).foregroundStyle(.secondary)
    }
}

extension VaultSurface {
    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .pruning: return "leaf"
        }
    }
    var subtitle: String {
        switch self {
        case .history: return "Every saved moment"
        case .graph: return "Follow your connections"
        case .pruning: return "Make room for what matters"
        }
    }
}
