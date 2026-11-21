import AppKit
import Testing
@testable import NearpaneHost

struct ServiceOpenIntentTests {
    private func event(_ id: AEEventID, marker: AEKeyword? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id, targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let marker { event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: marker) }
        return event
    }

    @Test func serviceAndLoginOpensSkipSettingsIncludingReopenWhenMarked() {
        for eventID in [kAEOpenApplication, kAEReopenApplication] {
            #expect(HostOpenIntent(event: event(AEEventID(eventID), marker: AEKeyword(keyAELaunchedAsServiceItem))) == .service)
            #expect(HostOpenIntent(event: event(AEEventID(eventID), marker: AEKeyword(keyAELaunchedAsLogInItem))) == .login)
        }
    }

    @Test func finderReopenStillOpensSettingsAfterABackgroundLaunch() {
        #expect(HostOpenIntent(event: nil, backgroundLaunch: true) == .background)
        #expect(HostOpenIntent(event: event(AEEventID(kAEReopenApplication))) == .unmarked)
        #expect(HostOpenIntent(event: event(AEEventID(kAEOpenApplication))) == .unmarked)
        #expect(HostOpenIntent(event: nil) == .unmarked)
    }
}
