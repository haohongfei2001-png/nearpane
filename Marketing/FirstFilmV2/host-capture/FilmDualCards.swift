// Capture-only composition. The lyric and screenshot interiors are the actual
// production views; only the Riftlet outer size/material is matched for the film.
import AppKit
import SwiftUI
import NearpaneCore
import NearpaneTray
import LyricUI

@MainActor public struct FilmDualCards: View {
    let host: HostSession
    let modules: EmbeddedModules
    private let scale: CGFloat=280.0/208.0
    public init(host: HostSession,modules: EmbeddedModules) { self.host=host;self.modules=modules }
    private var order: [String] {
        host.registry.preferences.filter {
            $0.enabled && ($0.id == BuiltinCatalog.lyrics || $0.id == BuiltinCatalog.screenshots)
        }.map(\.id)
    }
    public var body: some View {
        VStack(spacing:16) {
            ForEach(order,id:\.self) { id in
                if id == BuiltinCatalog.lyrics,let lyrics=modules.lyrics,lyrics.height > 0 {
                    HostLyricsCard(lyrics:lyrics)
                        .frame(width:208,height:192)
                        .scaleEffect(scale,anchor:.topLeading)
                        .frame(width:280,height:192*scale,alignment:.topLeading)
                } else if id == BuiltinCatalog.screenshots {
                    TraySurface(modules.tray,left:false)
                        .frame(width:208,height:192)
                        .background {
                            FilmMatchedLyricMaterial()
                                .overlay(Color(red:0.99,green:0.99,blue:0.986).opacity(0.56))
                                .overlay(LinearGradient(colors:[.white.opacity(0.14),.clear],startPoint:.topLeading,endPoint:.bottomTrailing))
                        }
                        .clipShape(RoundedRectangle(cornerRadius:18,style:.continuous))
                        .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).strokeBorder(.white.opacity(0.76),lineWidth:1))
                        .scaleEffect(scale,anchor:.topLeading)
                        .frame(width:280,height:192*scale,alignment:.topLeading)
                        .accessibilityIdentifier("film-riftlet-card")
                }
            }
            Spacer(minLength:0)
        }
        .environment(\.colorScheme,.light)
        .nativeVerificationAccessibility()
    }
}

private struct FilmMatchedLyricMaterial: NSViewRepresentable {
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material = .popover;view.blendingMode = .behindWindow;view.state = .active
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
}

public extension EmbeddedModules {
    var filmActualLyricsModel: LyricAppModel? { lyrics?.module.model }
    var filmActualLyricsHeight: Double { lyrics?.height ?? 0 }
    func filmExposeRealSurfaces() { setInteractionHidden(false) }
}
