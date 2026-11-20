import Foundation

// Offline policy checks; this executable never requests display data, AX or a window list.
@main struct CheckPreviewScope {
    static func main() {
        guard CommandLine.arguments.count==2 else {exit(2)}
        let raw=CommandLine.arguments[1]
        guard let kit=PreviewCensus.ownedTemporaryURL(raw),kit.path==raw,
              PreviewCensus.ownedTemporaryURL(String(raw.dropFirst("/private".count)))?.path==raw,
              PreviewCensus.ownedTemporaryURL(raw+"/../"+kit.lastPathComponent)==nil,
              PreviewCensus.ownedTemporaryURL("/tmp")==nil else {exit(3)}
        let samples:[(Bool,Bool,Bool,Bool,Bool,Bool,Bool,String)]=[
            (false,false,true,false,true,true,true,"unverifiedThinOffscreen"),
            (false,false,true,false,true,true,false,"unverifiedOrdinary"),
            (true,false,true,false,false,false,false,"signedCompositor"),
            (true,false,false,false,false,false,false,"unverifiedOrdinary"),
            (false,true,true,false,false,false,false,"unverifiedOrdinary"),
            (false,true,true,false,true,false,false,"unverifiedOrdinary"),
            (false,true,true,false,true,true,false,"enrolledNonDocument"),
            (false,true,true,true,false,false,false,"enrolledNonDocument")]
        for row in samples {
            guard PreviewCensus.disposition(signedCompositor:row.0,fixture:row.1,validShape:row.2,explicitlyNonstandard:row.3,
                                             absentFromFixtureAX:row.4,unpresented:row.5,thinOffscreen:row.6)==row.7 else{exit(4)}
        }
        print("4 private path and 8 scoped disposition checks passed")
    }
}
