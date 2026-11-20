#import "NativeSpaceActions.h"
#import "event_serialize.h"
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>

// The protocol descriptions and MIT license are pinned in Resources/Upstream/NativeSpaceActions.
NPDockProtocol NPDockProtocolForVersion(int major, int minor) {
    if (major == 27 && minor == 0) return NPDockSerialized27;
    if (major == 26 && minor >= 6 && minor <= 7) return NPDockLowTravel26;
    return NPDockUnsupported;
}

NPDockProtocol NPDockInstalledProtocol(void) {
#if defined(__arm64__)
    char build[64] = {0};
    size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0) || strcmp(build, "26A428"))
        return NPDockUnsupported;
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    return NPDockProtocolForVersion((int)os.majorVersion, (int)os.minorVersion);
#else
    return NPDockUnsupported;
#endif
}

CGEventRef NPDockCopySwipeEvent(NPDockProtocol protocol, bool right, bool natural,
                                int phase, CGPoint point, uint64_t timestamp) {
    if ((protocol != NPDockSerialized27 && protocol != NPDockLowTravel26) ||
        (phase != 1 && phase != 2 && phase != 4) || timestamp == 0) return NULL;
    // Natural-scroll inversion was observed for the serialized 27 protocol only.
    // Untested 26 builds remain outside the runtime allowlist.
    const double sign = protocol == NPDockSerialized27 ? ((right == natural) ? -1.0 : 1.0) : (right ? 1.0 : -1.0);
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;
    CGEventSetLocation(event, point);
    CGEventSetTimestamp(event, timestamp);
    CGEventSetIntegerValueField(event, (CGEventField)55, 30);
    CGEventSetIntegerValueField(event, (CGEventField)110, 23);
    CGEventSetIntegerValueField(event, (CGEventField)123, 1);
    CGEventSetIntegerValueField(event, (CGEventField)132, phase);
    if (protocol == NPDockLowTravel26) {
        CGEventSetDoubleValueField(event, (CGEventField)124, sign * 0.0001);
        CGEventSetDoubleValueField(event, (CGEventField)129, sign * 2000.0);
        CGEventSetDoubleValueField(event, (CGEventField)130, sign * 2000.0);
        return event;
    }
    CGEventSetDoubleValueField(event, (CGEventField)124, sign * 0.000016);
    CGEventSetDoubleValueField(event, (CGEventField)125, 0.1);
    CGEventSetIntegerValueField(event, (CGEventField)134, phase);
    CGEventSetDoubleValueField(event, (CGEventField)138, 3.0);
    CGEventSetDoubleValueField(event, (CGEventField)169, (double)timestamp);
    if (phase == 4) CGEventSetDoubleValueField(event, (CGEventField)129, sign * 9999.0);
    CGEventRef encoded = iss_augment_dock_swipe_event(event);
    CFRelease(event);
    return encoded;
}

CGEventRef NPDockCopyCompanion(NPDockProtocol protocol, CGPoint point, uint64_t timestamp) {
    if (protocol != NPDockSerialized27 || !timestamp) return NULL;
    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        CGEventSetLocation(event, point);
        CGEventSetTimestamp(event, timestamp);
        CGEventSetIntegerValueField(event, (CGEventField)55, 29);
    }
    return event;
}

static bool pointerOnDisplay(CGPoint *point, CGDirectDisplayID intendedDisplay) {
    CGEventRef source = CGEventCreate(NULL);
    if (!source) return false;
    *point = CGEventGetLocation(source);
    CFRelease(source);
    uint32_t count = 0;
    CGDirectDisplayID display = 0;
    return CGGetDisplaysWithPoint(*point, 1, &display, &count) == kCGErrorSuccess &&
           count == 1 && display == intendedDisplay && !CGDisplayIsInMirrorSet(display);
}

bool NPSendAdjacentSwipe(bool right, CGDirectDisplayID intendedDisplay, NPDockDispatch *receipt) {
    NPDockProtocol protocol = NPDockInstalledProtocol();
    CGPoint point;
    if (!receipt || protocol == NPDockUnsupported || !CGPreflightPostEventAccess() ||
        !pointerOnDisplay(&point, intendedDisplay)) return false;
    Boolean valid = false;
    bool natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication, &valid);
    if (!valid) natural = true;
    const int phases[] = {1, 2, 4};
    CGEventRef swipes[3] = {0}, companions[3] = {0};
    bool posted = false;
    for (int i = 0; i < 3; ++i) {
        const uint64_t stamp = mach_absolute_time();
        swipes[i] = NPDockCopySwipeEvent(protocol, right, natural, phases[i], point, stamp);
        if (!swipes[i]) goto cleanup;
        if (protocol == NPDockSerialized27) {
            companions[i] = NPDockCopyCompanion(protocol, point, stamp);
            if (!companions[i]) goto cleanup;
        }
    }
    if (!CGPreflightPostEventAccess() || !pointerOnDisplay(&point, intendedDisplay)) goto cleanup;
    receipt->protocolVersion = (int)protocol;
    receipt->natural = natural;
    receipt->signedProgress = CGEventGetDoubleValueField(swipes[2], (CGEventField)124);
    receipt->endVelocity = CGEventGetDoubleValueField(swipes[2], (CGEventField)129);
    for (int i = 0; i < 3; ++i) {
        receipt->phaseTimes[i] = mach_absolute_time();
        CGEventPost(kCGSessionEventTap, swipes[i]);
        if (companions[i]) CGEventPost(kCGSessionEventTap, companions[i]);
    }
    posted = true;
cleanup:
    for (int i = 0; i < 3; ++i) {
        if (swipes[i]) CFRelease(swipes[i]);
        if (companions[i]) CFRelease(companions[i]);
    }
    return posted;
}
