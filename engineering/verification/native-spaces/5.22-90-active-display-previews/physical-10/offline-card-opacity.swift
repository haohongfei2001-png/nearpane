import SwiftUI
@testable import NearpaneUI
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func image(_ rgba: [UInt8]) -> CGImage {
    let data=Data(Array(repeating:rgba,count:64).flatMap{$0})
    return CGImage(width:8,height:8,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:32,space:space,
                   bitmapInfo: .init(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:data as CFData)!,
                   decode:nil,shouldInterpolate:false,intent:.relativeColorimetric)!
}
@MainActor func pixel<V: View>(_ view: V) -> [Int] {
    let renderer=ImageRenderer(content:view)
    renderer.scale=1
    let crop=renderer.cgImage!.cropping(to:CGRect(x:65,y:48,width:1,height:1))!
    var bytes=[UInt8](repeating:0,count:4)
    bytes.withUnsafeMutableBytes{
        let ctx=CGContext(data:$0.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(crop,in:CGRect(x:0,y:0,width:1,height:1))
    }
    return bytes.map(Int.init)
}
MainActor.assumeIsolated {
    for (k,img) in [("unavailable",nil),("fullyTransparentSource",image([0,0,0,0])),("translucentGraySource",image([131,131,132,159])),("fixturePurple",image([97,43,190,255]))] {
        let card=DesktopWindowCard(label:"Field Notes · 2",icon:nil,image:img,pictureSize:CGSize(width:132,height:104),borderWidth:1)
        for scheme in [ColorScheme.dark, .light] {
            let b=Button(action:{}){ card }.buttonStyle(.plain).frame(width:132)
            print(k,scheme,"enabled",pixel(b.environment(\.colorScheme,scheme)),"disabled",pixel(b.disabled(true).environment(\.colorScheme,scheme)))
        }
    }
}
