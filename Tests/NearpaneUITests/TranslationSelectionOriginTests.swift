import Foundation
import Testing
import os
@testable import NearpaneUI

@objc private protocol TestTranslationPeer {
    func inspect(reply: @escaping (Bool, Bool, Bool) -> Void)
}

private final class TestTranslationProvider: NSObject, TestTranslationPeer, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TestTranslationPeer.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func inspect(reply: @escaping (Bool, Bool, Bool) -> Void) {
        let connection = NSXPCConnection.current()
        reply((connection?.exportedObject as AnyObject?) === self, connection?.processIdentifier == getpid(),
              TranslationCaller.atCallback(to: self) == nil)
    }
}

struct TranslationSelectionOriginTests {
    @Test func hostAtRecordedCallbackIsNeverItsOwnSource() {
        // The actual 946afb9 provider had received the frontmost assertion before this callback.
        #expect(TranslationCaller.direct(pid: 80244, exactProvider: true, sameUser: true, host: 80244) == nil)
        #expect(TranslationCaller.atCallback(to: NSObject()) == nil)
    }

    @Test func privateFoundationDispatchIdentifiesItsActualExportAndRejectsTheSameProcess() throws {
        let provider = TestTranslationProvider(), listener = NSXPCListener.anonymous()
        listener.delegate = provider
        listener.resume()
        defer { listener.invalidate() }
        let client = NSXPCConnection(listenerEndpoint: listener.endpoint)
        client.remoteObjectInterface = NSXPCInterface(with: TestTranslationPeer.self)
        client.resume()
        defer { client.invalidate() }
        let reply = OSAllocatedUnfairLock(initialState: [Bool]())
        let done = DispatchSemaphore(value: 0)
        let proxy = try #require(client.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? TestTranslationPeer)
        proxy.inspect { exactExport, ownPID, rejected in
            reply.withLock { $0 = [exactExport, ownPID, rejected] }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(reply.withLock { $0 } == [true, true, true])
        withExtendedLifetime(provider) {}
    }

    @Test func onlyTheDirectSameUserPeerOfThisProviderQualifies() {
        let host: pid_t = 44, source: pid_t = 97
        #expect(TranslationCaller.direct(pid: source, exactProvider: true, sameUser: true, host: host) == source)
        #expect(TranslationCaller.direct(pid: source, exactProvider: false, sameUser: true, host: host) == nil)
        #expect(TranslationCaller.direct(pid: source, exactProvider: true, sameUser: false, host: host) == nil)
        for pid: pid_t? in [nil, 0, 1, -1] {
            #expect(TranslationCaller.direct(pid: pid, exactProvider: true, sameUser: true, host: host) == nil)
        }
    }

    @Test func sameAppWithAnotherFieldWindowProcessGenerationOrRangeCannotReuseAnOrigin() {
        let owner = SelectionForeground(pid: 70, birth: 100)
        let first = TranslationInputIdentity(owner: owner, field: 37, window: 111, range: NSRange(location: 1, length: 4))
        #expect(first.matches(owner: owner, field: 37, window: 111))
        #expect(!first.matches(owner: owner, field: 38, window: 111))
        #expect(!first.matches(owner: owner, field: 37, window: 112))
        #expect(!first.matches(owner: .init(pid: 70, birth: 101), field: 37, window: 111))
        #expect(first != .init(owner: owner, field: 37, window: 111, range: NSRange(location: 2, length: 4)))
    }

    @Test func genericPointerFeedbackRequiresTheSameLiveContextAndNeverAuthenticatesACaller() {
        let ambient = SelectionForeground(pid: 44, birth: 17)
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let visible = NSRect(x: 0, y: 20, width: 1200, height: 850)
        func read(_ point: NSPoint = NSPoint(x: 17, y: 68), activity: [UInt32] = [3, 2], display: UInt32 = 42,
                  foreground: SelectionForeground? = ambient) -> TranslationFeedbackPointer? {
            .init(foreground: foreground, display: display, screenFrame: screen, visibleFrame: visible, point: point, activity: activity)
        }
        let request = read()
        #expect(request != nil && request == read())
        #expect(request != read(.init(x: 18, y: 68)))
        #expect(request != read(activity: [4, 2]))
        #expect(request != read(display: 43))
        #expect(request != read(foreground: .init(pid: 44, birth: 18)))
        #expect(request != read(foreground: .init(pid: 88, birth: 12)))
        #expect(read(.init(x: 17, y: 890)) != nil)  // A pointer in the macOS menu bar is on this display.
        #expect(read(.init(x: 17, y: 910)) == nil)
        #expect(read(display: 0) == nil && read(foreground: nil) == nil)
        #expect(TranslationCaller.direct(pid: ambient.pid, exactProvider: false, sameUser: true, host: 98) == nil)
    }

    @Test func fallbackRequiresAPointerInTheBoundWindowAndFiniteCoordinates() {
        let selection = NSRect(x: 24, y: 31, width: 18, height: 11), point = NSPoint(x: 29, y: 40)
        #expect(TranslationPlacement.selectedRect(selection) == .selection(selection))
        #expect(TranslationPlacement.selectedRect(nil) == nil)
        #expect(TranslationPlacement.selectedRect(.zero) == nil)
        #expect(TranslationPlacement.selectedRect(.init(x: CGFloat.infinity, y: 2, width: 1, height: 1)) == nil)
        #expect(TranslationPlacement.pointerAt(point, insideOriginalWindow: true) == .pointer(point))
        #expect(TranslationPlacement.pointerAt(point, insideOriginalWindow: false) == nil)
        #expect(TranslationPlacement.pointerAt(.init(x: 0, y: CGFloat.nan), insideOriginalWindow: true) == nil)
    }
}
