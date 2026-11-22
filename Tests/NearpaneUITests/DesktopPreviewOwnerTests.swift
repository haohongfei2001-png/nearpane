import AppKit
import NearpaneCore
import SwiftUI
@testable import NearpaneUI
import Testing

@MainActor struct DesktopPreviewOwnerTests {
    private final class Application: OrdinaryApplicationReference {
        var processIdentifier: pid_t = 103, activationPolicy = NSApplication.ActivationPolicy.regular
        var bundleIdentifier: String? = "net.example.spaces-document"
        var executableURL: URL? = URL(fileURLWithPath: "/Field Notes.app/Contents/MacOS/FieldNotes")
        var isTerminated = false
    }
    private final class Fixture {
        let key = DesktopWindowKey(pid: 103, birth: 202, number: 400)
        let app = Application(), path = URL(fileURLWithPath: "/Field Notes.app/Contents/MacOS/FieldNotes")
        var birth: UInt64 = 202, inode: ino_t = 35, digest = Data([7])
        var kernelReads = 0, signatureReads = 0

        func kernel(_ pid: pid_t) -> OrdinaryProcessImage {
            kernelReads += 1
            return .init(pid: pid, launch: birth, executable: path, device: 1, inode: inode)
        }
        func signed(_ pid: pid_t) -> Data { signatureReads += 1; return digest }
        func bind() -> DesktopPreviewOwner? { .init(key: key, app: app, kernel: kernel, signing: signed) }
        func check(_ bound: DesktopPreviewOwner?, lookup: Application?, generation: Bool? = true, key override: DesktopWindowKey? = nil)
            -> (allowed: Bool, evidence: PreviewPipelineAudit.Reason) {
            let target = override ?? key
            let observed = DesktopPreviewOwner.read(target, generation: { _ in generation }, find: { _ in lookup })
            return DesktopPreviewOwner.resolve(observed, key: target, bound: bound, kernel: kernel, signing: signed)
        }
    }

    @Test func historicalPictureChecksOriginalSignatureAndProcessImageEvenWithALiveAppReference() throws {
        let f = Fixture(), bound = try #require(f.bind())
        #expect(bound.stillSigned(as:f.key,kernel:f.kernel,signing:f.signed))
        f.digest = Data([99])
        #expect(!bound.stillSigned(as:f.key,kernel:f.kernel,signing:f.signed))
        f.digest = Data([7]); f.birth += 1
        #expect(!bound.stillSigned(as:f.key,kernel:f.kernel,signing:f.signed))
    }

    @Test func exactSelectionCanReproveAMissingApplicationReferenceForTheSameForegroundProcess() {
        let f = Fixture()
        let direct = DesktopPreviewOwner.read(f.key, generation: { _ in true }, find: { _ -> Application? in nil })
        var frontReads = 0
        let resolved = DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { f.app }, focusedPID: {
            frontReads += 1; return f.key.pid
        }, kernel: f.kernel, signing: f.signed)
        #expect(resolved.app === f.app && resolved.evidence == .applicationLookupRecovered)
        #expect(frontReads == 2 && f.kernelReads == 2 && f.signatureReads == 1)
    }

    @Test func exactSelectionNeedsTheSameForegroundThroughSignatureAndKernelReadback() {
        let f = Fixture()
        let direct = DesktopPreviewOwner.Read<Application>.missing(.application)
        var fronts: [pid_t] = [f.key.pid, 999]
        #expect(DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { f.app },
            focusedPID: { fronts.removeFirst() }, kernel: f.kernel, signing: f.signed).app == nil)
        #expect(DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { f.app },
            focusedPID: { nil }, kernel: f.kernel, signing: f.signed).app == nil)
        #expect(DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { f.app },
            focusedPID: { f.key.pid }, kernel: f.kernel, signing: { _ in throw WindowIdentityFailure("unavailable") }).app == nil)
        f.birth += 1
        #expect(DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { f.app },
            focusedPID: { f.key.pid }, kernel: f.kernel, signing: f.signed).app == nil)
        f.birth = f.key.birth; f.app.executableURL = URL(fileURLWithPath: "/other")
        #expect(DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { f.app },
            focusedPID: { f.key.pid }, kernel: f.kernel, signing: f.signed).app == nil)
    }

    @Test func foregroundCannotReplacePositiveDenialUnknownGenerationOrForeignRegularApp() {
        let f = Fixture()
        for direct: DesktopPreviewOwner.Read<Application> in [.denied, .missing(.kernel), .missing(.bundle)] {
            var looked = false
            let got = DesktopWindowTarget.selectionOwner(for: f.key, direct: direct, foreground: { looked = true; return f.app },
                focusedPID: { f.key.pid }, kernel: f.kernel, signing: f.signed)
            #expect(got.app == nil && !looked)
        }
        for state in ["otherPID","accessory","terminated","toolBundle"] {
            let other = Application()
            switch state {
            case "otherPID": other.processIdentifier += 1
            case "accessory": other.activationPolicy = .accessory
            case "terminated": other.isTerminated = true
            default: other.bundleIdentifier = "com.holdsnow.nearpane.alpha"
            }
            #expect(DesktopWindowTarget.selectionOwner(for: f.key, direct: .missing(.application), foreground: { other },
                focusedPID: { f.key.pid }, kernel: f.kernel, signing: f.signed).app == nil)
        }
        let direct = DesktopWindowTarget.selectionOwner(for: f.key, direct: .found(f.app, bundle: "net.example.spaces-document"),
            foreground: { nil }, focusedPID: { nil }, kernel: f.kernel, signing: f.signed)
        #expect(direct.app === f.app && direct.evidence == .allowed)
    }

    @Test func activeCardSurvivesAMissingOwnerLookupOnlyAfterIndependentPositiveEvidence() throws {
        let f = Fixture()
        #expect(!f.check(nil, lookup: nil).allowed)
        let bound = try #require(f.bind())
        let fastKernel = f.kernelReads, fastSignatures = f.signatureReads
        #expect(f.check(bound, lookup: f.app) == (true, .allowed))
        #expect(f.kernelReads == fastKernel && f.signatureReads == fastSignatures)
        #expect(f.check(bound, lookup: nil) == (true, .applicationLookupRecovered))
        #expect(f.kernelReads == fastKernel + 2 && f.signatureReads == fastSignatures + 1)
        #expect(f.check(bound, lookup: nil, generation: nil) == (true, .kernelReadRecovered))
        let incomplete = Application(); incomplete.bundleIdentifier = nil
        #expect(f.check(bound, lookup: incomplete) == (true, .bundleReadRecovered))
        #expect(!f.check(bound, lookup: nil, key: .init(pid: 103, birth: 202, number: 401)).allowed)
        f.inode += 1
        #expect(!f.check(bound, lookup: nil).allowed)
        f.inode -= 1; f.digest = Data([8])
        #expect(!f.check(bound, lookup: nil).allowed)
        f.digest = Data([7]); f.birth += 1
        #expect(!f.check(bound, lookup: nil).allowed)
    }

    @Test func recoveredOwnershipDrawsTheSourceGreenAndRevokedSharingStillShowsTheOutline() throws {
        let f = Fixture(), space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bytes = Data([38, 132, 98, 255])
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let source = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: space, bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        func cardPixel(owner: DesktopPreviewOwner?, shared: Bool) throws -> [UInt8] {
            let eligible = f.check(owner, lookup: nil).allowed && DesktopWindowTarget.SurfacePurpose.picture.accepts(drawn: true, allowsContent: shared)
            let card = DesktopWindowCard(label: "Field Notes", icon: nil, image: eligible ? source : nil,
                pictureSize: .init(width: 32, height: 32), borderWidth: 0).frame(width: 32).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: card); renderer.scale = 1
            let crop = try #require(renderer.cgImage?.cropping(to: CGRect(x: 16, y: 16, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba
        }
        let bound = try #require(f.bind())
        let outline = try cardPixel(owner: nil, shared: true)
        #expect(outline[3] < 255)
        #expect(try cardPixel(owner: bound, shared: true) == [38, 132, 98, 255])
        #expect(try cardPixel(owner: bound, shared: false) == outline)
    }

    @Test func negativeOrWithdrawnAuthorityNeverUsesTheRetainedProcessReference() throws {
        let f = Fixture(), fresh = Application()
        let bound = try #require(f.bind())
        let signedBefore = f.signatureReads
        #expect(f.check(bound, lookup: fresh, generation: false) == (false, .ownerChanged))
        fresh.activationPolicy = .accessory
        #expect(!f.check(bound, lookup: fresh).allowed)
        fresh.activationPolicy = .regular; fresh.isTerminated = true
        #expect(!f.check(bound, lookup: fresh).allowed)
        fresh.isTerminated = false; fresh.bundleIdentifier = "com.holdsnow.nearpane.alpha"
        #expect(!f.check(bound, lookup: fresh).allowed)
        fresh.bundleIdentifier = "net.example.unrelated"
        #expect(!f.check(bound, lookup: fresh).allowed)
        #expect(f.signatureReads == signedBefore)
        f.app.activationPolicy = .accessory
        #expect(!f.check(bound, lookup: nil).allowed)
        f.app.activationPolicy = .regular; f.app.isTerminated = true
        #expect(!f.check(bound, lookup: nil).allowed)
    }
}
