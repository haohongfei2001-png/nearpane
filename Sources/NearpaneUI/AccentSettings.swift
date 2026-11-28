import AppKit
import SwiftUI
import NearpaneCore

extension ProductAccent {
    public var color: Color {
        switch self {
        case .system: Color(nsColor: .controlAccentColor)
        case .purple: Color(nsColor: Self.referenceViolet)
        case .blue: Color(nsColor: .systemBlue)
        case .teal: Color(nsColor: .systemTeal)
        case .green: Color(nsColor: .systemGreen)
        case .orange: Color(nsColor: .systemOrange)
        case .pink: Color(nsColor: .systemPink)
        case .graphite: Color(nsColor: .systemGray)
        }
    }

    // The reference voice glyph uses violet on a light control. Keep its hue legible on dark glass.
    private static let referenceViolet = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.76, green: 0.68, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.52, green: 0.24, blue: 0.90, alpha: 1)
    }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .purple: "紫色"
        case .blue: "蓝色"
        case .teal: "青色"
        case .green: "绿色"
        case .orange: "橙色"
        case .pink: "粉色"
        case .graphite: "石墨色"
        }
    }
}

extension View {
    public func productAccent(_ accent: ProductAccent) -> some View {
        // Native SwiftUI controls read tint. AppKit representables resolve Color.accentColor
        // from their context; setting tint alone leaves those views on the system accent.
        tint(accent.color).accentColor(accent.color)
    }
}

public struct AccentSettings: View {
    let host: HostSession
    public init(host: HostSession) { self.host = host }

    public var body: some View {
        HStack {
            Picker("强调色", selection: Binding(get: { host.configuration.accent }, set: { host.setAccent($0) })) {
                ForEach(ProductAccent.allCases, id: \.self) { accent in Text(accent.label).tag(accent) }
            }
            .pickerStyle(.menu).fixedSize().accessibilityIdentifier("nearpane-accent")
            Circle().fill(host.configuration.accent.color).frame(width: 12, height: 12)
                .accessibilityHidden(true)
        }
        .help("用于 Nearpane 各模块的重点内容和控件")
    }
}
