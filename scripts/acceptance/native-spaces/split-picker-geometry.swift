import Foundation
import CoreGraphics

// AX reports a document's logical frame. WindowServer moves and may scale its actual
// presentation while choosing the other half of Split View. Only project the signed
// fixture's own nonce-bearing accessibility marker through this measured transformation.
enum SplitPickerGeometry {
    static func valid(_ f: CGRect) -> Bool {
        !f.isNull && !f.isInfinite && f.origin.x.isFinite && f.origin.y.isFinite &&
            f.size.width.isFinite && f.size.height.isFinite && f.size.width > 2 && f.size.height > 2
    }

    static func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        valid(a) && valid(b) && abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance &&
            abs(a.maxX-b.maxX) <= tolerance && abs(a.maxY-b.maxY) <= tolerance
    }

    static func markerPoint(screen: CGRect, tiledAX: CGRect, tiledCG: CGRect, logical: CGRect,
                            presented: CGRect, marker: CGRect) -> CGPoint? {
        guard [screen,tiledAX,tiledCG,logical,presented,marker].allSatisfy(valid),
              near(tiledAX,tiledCG), screen.insetBy(dx:-2,dy:-2).contains(tiledCG),
              abs(tiledCG.minX-screen.minX)<=2, abs(tiledCG.maxY-screen.maxY)<=2,
              tiledCG.height>=screen.height*0.90, (0.25...0.75).contains(tiledCG.width/screen.width),
              screen.contains(presented), presented.minX>=tiledCG.maxX-1,
              logical.minX<tiledCG.maxX-2, !near(logical,presented),
              logical.insetBy(dx:1,dy:1).contains(marker) else { return nil }
        let scaleX=presented.width/logical.width, scaleY=presented.height/logical.height
        guard (0.2...1.05).contains(scaleX), abs(scaleX-scaleY)<=0.03 else {return nil}
        let point=CGPoint(x:presented.minX+(marker.midX-logical.minX)*scaleX,
                          y:presented.minY+(marker.midY-logical.minY)*scaleY)
        return presented.insetBy(dx:2,dy:2).contains(point) ? point:nil
    }

    static func mentionsDocument(_ text: String, title: String) -> Bool {
        guard !title.isEmpty, text.count<=2048, let match=text.range(of:title) else {return false}
        func boundary(_ c: Character) -> Bool {!c.isLetter && !c.isNumber && c != "_"}
        return (match.lowerBound==text.startIndex || boundary(text[text.index(before:match.lowerBound)])) &&
            (match.upperBound==text.endIndex || boundary(text[match.upperBound]))
    }

    static func presentedRoute(top: String, hit: String) -> String? {
        guard top == "enrolledDocumentB" else { return nil }
        switch hit {
        case "enrolledDocumentB": return "presentedMarkerHitEnrolledDocument"
        case "appleDock", "appleWindowManager", "appleMissionControl": return "presentedMarkerHitSignedPicker"
        default: return nil
        }
    }
}
