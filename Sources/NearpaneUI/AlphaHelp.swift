import SwiftUI

/// Read the quick-start shipped with this exact Alpha, inside Settings (no browser launch).
struct AlphaHelp: View {
    private static let paragraphs: [AttributedString] = {
        guard let url = Bundle.main.url(forResource: "AlphaHelp", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").map {
            (try? AttributedString(markdown: $0)) ?? AttributedString($0)
        }
    }()
    var body: some View {
        if !Self.paragraphs.isEmpty {
            DisclosureGroup("使用帮助与故障处理") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.paragraphs.indices, id: \.self) { index in
                        Text(Self.paragraphs[index]).textSelection(.enabled)
                    }
                }.font(.callout).padding(.vertical, 4)
            }.accessibilityIdentifier("nearpane-alpha-help")
        }
    }
}
