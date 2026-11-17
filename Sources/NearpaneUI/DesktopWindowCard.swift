import SwiftUI

struct DesktopWindowCard: View {
    @Environment(\.colorScheme) private var scheme
    static func windowBacking(for scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.16 : 0.96)
    }
    let label: String
    let icon: NSImage?
    let image: CGImage?
    var pictureHeight: CGFloat = 94
    var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
                        .background(Self.windowBacking(for: scheme))
                } else {
                    Color.primary.opacity(0.045)
                    VStack(spacing: 3) {
                        if let icon {
                            Image(nsImage: icon).resizable().scaledToFit().frame(width: 25, height: 25)
                                .accessibilityHidden(true)
                        }
                        if unavailable {
                            Text("暂无窗口画面").font(.caption2).foregroundStyle(Color(white: scheme == .dark ? 0.82 : 0.28))
                        }
                    }
                }
            }.frame(maxWidth: .infinity).frame(height: pictureHeight)
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 15, height: 15)
                } else { Image(systemName: "macwindow").frame(width: 15) }
                Text(label).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 7).padding(.vertical, 6)
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.14)) }
        .contentShape(Rectangle())
    }
}
