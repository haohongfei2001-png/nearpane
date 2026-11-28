// Capture-only composition. The lyric and screenshot interiors are the actual
// production views. Width/material match; Riftlet height comes from production
// LayoutComposer and the actual TrayModule.rowCount, never a lyric-sized slot.
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
    public static func canonicalTrayHeight(rows: Int) -> CGFloat {
        // The same public composer used by EdgeSurfaceView: default one-row
        // tray is 76 pt; with a real third slot it becomes two rows / 144 pt.
        // The ample bound prevents photography from compressing either state.
        CGFloat(LayoutComposer.compose(width:208,height:640,pinnedCount:0,expanded:false,
            settings:.init(),content:.toolsOnly,voiceEnabled:false,trayEnabled:true,
            trayRows:rows,lyricsHeight:0,toolOrder:[BuiltinCatalog.screenshots]).screenshots.height)
    }
    public static func photographySize(lyricsHeight: Double, trayRows: Int) -> NSSize {
        let lyric:CGFloat=lyricsHeight > 0 ? 192 : 0
        let scale:CGFloat=280.0/208.0
        return NSSize(width:280,height:(lyric+canonicalTrayHeight(rows:trayRows))*scale+(lyric > 0 ? 16:0))
    }
    private var order: [String] {
        host.registry.preferences.filter {
            $0.enabled && ($0.id == BuiltinCatalog.lyrics || $0.id == BuiltinCatalog.screenshots)
        }.map(\.id)
    }
    public var body: some View {
        let trayHeight=Self.canonicalTrayHeight(rows:modules.tray.rowCount)
        let size=Self.photographySize(lyricsHeight:modules.lyricsHeight,trayRows:modules.tray.rowCount)
        VStack(spacing:16) {
            ForEach(order,id:\.self) { id in
                if id == BuiltinCatalog.lyrics,let lyrics=modules.lyrics,lyrics.height > 0 {
                    HostLyricsCard(lyrics:lyrics)
                        .frame(width:208,height:192)
                        .scaleEffect(scale,anchor:.topLeading)
                        .frame(width:280,height:192*scale,alignment:.topLeading)
                } else if id == BuiltinCatalog.screenshots {
                    TraySurface(modules.tray,left:false)
                        .frame(width:208,height:trayHeight)
                        .background {
                            FilmMatchedLyricMaterial()
                                .overlay(Color(red:0.99,green:0.99,blue:0.986).opacity(0.56))
                                .overlay(LinearGradient(colors:[.white.opacity(0.14),.clear],startPoint:.topLeading,endPoint:.bottomTrailing))
                        }
                        .clipShape(RoundedRectangle(cornerRadius:18,style:.continuous))
                        .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).strokeBorder(.white.opacity(0.76),lineWidth:1))
                        .scaleEffect(scale,anchor:.topLeading)
                        .frame(width:280,height:trayHeight*scale,alignment:.topLeading)
                        .accessibilityIdentifier("film-riftlet-card")
                }
            }
        }
        .frame(width:size.width,height:size.height,alignment:.top)
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
