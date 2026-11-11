import AppKit
import Testing
@testable import NearpaneOrdinaryWindowController

struct OwnerIdentityTests {
    private final class App: OrdinaryApplicationReference {
        let processIdentifier: pid_t = 101
        var bundleIdentifier: String? = "net.example.test"
        var executableURL: URL? = URL(fileURLWithPath: "/ordinary.app/Contents/MacOS/ordinary")
        var activationPolicy: NSApplication.ActivationPolicy = .regular
        var isTerminated = false
    }

    private final class Probe {
        let app = App()
        let owner = OrdinaryOwnerIdentity()
        var launches: [UInt64] = []
        var digest = Data([1])
        var inode: ino_t = 1
        var lookups = 0, samples = 0
        var allowLookup = true
        func verify() throws {
            try owner.verify(101, launch: 200, bundle: "net.example.test", kernel: { pid in
                self.samples += 1
                return OrdinaryProcessImage(pid: pid, launch: self.launches.isEmpty ? 200 : self.launches.removeFirst(),
                    executable: URL(fileURLWithPath: "/ordinary.app/Contents/MacOS/ordinary"),
                    device: 1, inode: self.inode)
            }, signing: { _ in self.digest }, find: { _ in
                self.lookups += 1
                return self.allowLookup ? self.app : nil
            })
        }
    }

    @Test func testLiveOwnerSurvivesUnavailableAppLookupWhileKernelAndSignatureStayPositive() throws {
        let probe = Probe()
        try probe.verify()
        probe.allowLookup = false
        try probe.verify()
        #expect(probe.lookups == 1)
        #expect(probe.samples == 4)
    }

    @Test func testFailedFirstLookupCannotBind() {
        let probe = Probe()
        probe.allowLookup = false
        #expect(throws: Refusal.self) { try probe.verify() }
    }

    @Test func testProcessGenerationMustMatchBeforeAndAfterRead() throws {
        let probe = Probe()
        try probe.verify()
        probe.launches = [200, 201]
        #expect(throws: Refusal.self) { try probe.verify() }
        probe.launches = [201]
        #expect(throws: Refusal.self) { try probe.verify() }
    }

    @Test func testChangedExecutableOrSignatureCannotInheritAuthorization() throws {
        let probe = Probe()
        try probe.verify()
        probe.inode = 2
        #expect(throws: Refusal.self) { try probe.verify() }
        probe.inode = 1
        probe.digest = Data([2])
        #expect(throws: Refusal.self) { try probe.verify() }
        probe.digest = Data([1])
        probe.app.executableURL = URL(fileURLWithPath: "/different.app/Contents/MacOS/ordinary")
        #expect(throws: Refusal.self) { try probe.verify() }
    }

    @Test func testRetainedAppMustRemainRegularLiveAndBoundToSameBundle() throws {
        let probe = Probe()
        try probe.verify()
        probe.app.activationPolicy = .accessory
        #expect(throws: Refusal.self) { try probe.verify() }
        probe.app.activationPolicy = .regular
        probe.app.isTerminated = true
        #expect(throws: Refusal.self) { try probe.verify() }
        probe.app.isTerminated = false
        probe.app.bundleIdentifier = "net.example.other"
        #expect(throws: Refusal.self) { try probe.verify() }
    }
}
