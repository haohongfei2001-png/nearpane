import SwiftUI

struct DesktopWindowCard: View {
    let label: String
    let icon: NSImage?
    let image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .scaledToFit().frame(maxWidth: .infinity, maxHeight: 132)
                    .background(.black.opacity(0.07))
            }
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 19, height: 19)
                } else { Image(systemName: "macwindow").frame(width: 19) }
                Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 7).padding(.vertical, 6)
        }
        .foregroundStyle(.primary).background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.14)) }
        .contentShape(Rectangle())
    }
}
