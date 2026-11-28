#if canImport(AppKit)
import AppKit

/// R4 specifies opaque sRGB text and symbol colors independently of the wallpaper and material.
public enum SidebarTextColor {
    public static let primary = adaptive(light: 0x25272A, dark: 0xF1F2F4)
    public static let secondary = adaptive(light: 0x55595F, dark: 0xCCD0D4)

    private static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .accessibilityHighContrastAqua: return .black
            case .accessibilityHighContrastDarkAqua: return .white
            case .darkAqua: return opaqueRGB(dark)
            default: return opaqueRGB(light)
            }
        }
    }

    private static func opaqueRGB(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
