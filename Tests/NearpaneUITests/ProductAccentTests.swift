#if canImport(NearpaneVoice) && canImport(NearpaneTray)
import AppKit
import SwiftUI
import Testing
import NearpaneCore
@testable import NearpaneUI
@testable import NearpaneTray
@testable import NearpaneVoice

@MainActor struct ProductAccentTests {
    @Test func selectableAppKitTranscriptReadsTheSameAccentAsSwiftUIEditing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 130),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let views = VStack {
            TranscriptLine(text: "合成文字", edit: { _ in })
            TranscriptEditor(text: .constant("合成文字"), fontSize: 13, lineSpacing: nil)
        }.productAccent(.green)
        let hosting = NSHostingView(rootView: views)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView { return [text] }
            return view.subviews.flatMap(editors)
        }
        let samples = editors(hosting)
        #expect(samples.count == 2)
        for text in samples {
            let ink = try #require(text.insertionPointColor.usingColorSpace(.sRGB))
            #expect(ink.greenComponent > ink.redComponent + 0.15)
            let highlight = try #require((text.selectedTextAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB))
            #expect(highlight.greenComponent > highlight.redComponent)
        }
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test(arguments: [ProductAccent.purple, .green], [ColorScheme.light, .dark])
    func cameraAndVoiceUseTheSameHostInk(_ accent: ProductAccent, _ appearance: ColorScheme) throws {
        let sample = HStack(spacing: 0) {
            Rectangle().fill(accent.color).frame(width: 40, height: 36)
            VoiceCaptureGlyph(presentation: .init(.paused, 0)).frame(width: 40, height: 36)
            Button {} label: {
                TrayCameraGlyph(width: 24).frame(width: 40, height: 36)
            }.buttonStyle(TrayCaptureStyle())
        }
        .productAccent(accent)
        .background(appearance == .light ? Color.white : Color.black)
        .environment(\.colorScheme, appearance)
        let renderer = ImageRenderer(content: sample)
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func rgb(_ x: Int, _ y: Int) throws -> NSColor {
            try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let reference = try rgb(20, 18)
        if accent == .purple {
            #expect(reference.blueComponent > reference.greenComponent + 0.15)
        } else {
            #expect(reference.greenComponent > reference.redComponent + 0.15)
        }
        for region in [40..<80, 80..<120] {
            var count = 0
            for x in region {
                for y in 0..<36 {
                    let pixel = try rgb(x, y)
                    if abs(pixel.redComponent - reference.redComponent) < 0.04,
                       abs(pixel.greenComponent - reference.greenComponent) < 0.04,
                       abs(pixel.blueComponent - reference.blueComponent) < 0.04 {
                        count += 1
                    }
                }
            }
            #expect(count > 6)
        }
    }
}
#endif
