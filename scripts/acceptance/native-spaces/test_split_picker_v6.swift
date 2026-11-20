import Foundation
import CoreGraphics

// No process, display or accessibility connections. V5 measured the two window frames;
// the marker below is test input. The v5 trace did not record its AX identity or hit.
@main enum Tests {
    static func main() {
        let screen=CGRect(x:0,y:0,width:1470,height:956), tile=CGRect(x:0,y:33,width:733,height:923)
        let logical=CGRect(x:585,y:244,width:540,height:333), presented=CGRect(x:753,y:244,width:540,height:333)
        let marker=CGRect(x:615,y:392,width:480,height:110)
        func point(display:CGRect?=nil, left:CGRect?=nil, leftCG:CGRect?=nil, document:CGRect?=nil,
                   actual:CGRect?=nil, labelled:CGRect?=nil)->CGPoint? {
            SplitPickerGeometry.markerPoint(screen:display ?? screen,tiledAX:left ?? tile,tiledCG:leftCG ?? tile,
                logical:document ?? logical,presented:actual ?? presented,marker:labelled ?? marker)
        }
        precondition(point()==CGPoint(x:1023,y:447))
        // Same CG presentation after a uniformly scaled picker transform and display offsets.
        precondition(point(actual:.init(x:870,y:300,width:270,height:166.5))==CGPoint(x:1005,y:401.5))
        let xoff:CGFloat = -1470, yoff:CGFloat = 75
        precondition(point(display:screen.offsetBy(dx:xoff,dy:yoff),left:tile.offsetBy(dx:xoff,dy:yoff),
            leftCG:tile.offsetBy(dx:xoff,dy:yoff),document:logical.offsetBy(dx:xoff,dy:yoff),
            actual:presented.offsetBy(dx:xoff,dy:yoff),labelled:marker.offsetBy(dx:xoff,dy:yoff)) == CGPoint(x:-447,y:522))
        precondition(point(actual:logical)==nil) // ordinary side-by-side (no presentation transform)
        precondition(point(left:tile.offsetBy(dx:8,dy:0))==nil) // tiled AX disagrees with current CG
        precondition(point(left:.init(x:0,y:33,width:733,height:702),leftCG:.init(x:0,y:33,width:733,height:702))==nil)
        precondition(point(actual:presented.offsetBy(dx:-100,dy:0))==nil) // overlaps left tile
        precondition(point(actual:presented.offsetBy(dx:400,dy:0))==nil) // outside physical display
        precondition(point(actual:.init(x:753,y:244,width:380,height:333))==nil) // inconsistent projection
        precondition(point(labelled:marker.offsetBy(dx:80,dy:0))==nil) // marker not entirely in enrolled window
        precondition(point(left:.null)==nil && point(labelled:.zero)==nil)
        let title="Nearpane Split 37c620b1-07c5-4c06-9c92-f7598ac625f6 B"
        precondition(SplitPickerGeometry.mentionsDocument(title,title:title))
        precondition(SplitPickerGeometry.mentionsDocument(title+" — Split Notes",title:title))
        for other in [title+"2","prefix"+title,title+"_changed",String(title.dropLast())+"A","the nonce is elsewhere"] {
            precondition(!SplitPickerGeometry.mentionsDocument(other,title:title))
        }
        for known in ["enrolledDocumentB","appleDock","appleWindowManager","appleMissionControl"] {
            precondition(SplitPickerGeometry.presentedRoute(top:"enrolledDocumentB",hit:known,enrolledSystemHit:true) != nil)
            for top in ["appleDock","appleWindowManager","otherFixtureSurface","otherSurface","unresolved","noSurface"] {
                precondition(SplitPickerGeometry.presentedRoute(top:top,hit:known,enrolledSystemHit:true)==nil)
            }
        }
        precondition(SplitPickerGeometry.presentedRoute(top:"enrolledDocumentB",hit:"appleDock",enrolledSystemHit:false)==nil)
        precondition(SplitPickerGeometry.presentedRoute(top:"enrolledDocumentB",hit:"enrolledDocumentB",enrolledSystemHit:false) != nil)
        for hit in ["otherOwner","otherFixtureElement","unresolved","appleWindowServer","appleControlCenter"] {
            precondition(SplitPickerGeometry.presentedRoute(top:"enrolledDocumentB",hit:hit,enrolledSystemHit:true)==nil)
        }
    }
}
