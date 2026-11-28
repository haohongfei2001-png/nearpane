#pragma once
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <Security/Security.h>

// Only a single Apple-signed wallpaper-agent surface exactly covering this physical screen qualifies.
static inline NSArray *stillWallpaperWindow(CGRect frame) {
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.wallpaper.agent"];
    if (apps.count != 1) return nil;
    pid_t pid = apps.firstObject.processIdentifier;
    struct proc_bsdinfo bsd = {};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd) ||
        bsd.pbi_pid != (uint32_t)pid || bsd.pbi_uid != getuid()) return nil;
    static SecRequirementRef rule;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.wallpaper.agent\""), 0, &rule); });
    SecCodeRef code = NULL;
    if (!rule || SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)@{(__bridge id)kSecGuestAttributePid:@(pid)}, 0, &code) || !code) return nil;
    OSStatus signedApple = SecCodeCheckValidity(code, 0, rule);
    CFRelease(code);
    if (signedApple != errSecSuccess) return nil;
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSNumber *found = nil;
    for (NSDictionary *row in rows) {
        CGRect bounds;
        if (![row[(id)kCGWindowOwnerPID] isEqual:@(pid)] || !row[(id)kCGWindowLayer] ||
            [row[(id)kCGWindowLayer] intValue] > CGWindowLevelForKey(kCGDesktopWindowLevelKey) ||
            ![row[(id)kCGWindowIsOnscreen] boolValue] || ![row[(id)kCGWindowAlpha] isEqual:@1] ||
            ![row[(id)kCGWindowBounds] isKindOfClass:NSDictionary.class] ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds], &bounds) ||
            !CGRectEqualToRect(bounds, frame)) continue;
        NSNumber *window = row[(id)kCGWindowNumber];
        if (found || !window.unsignedIntValue) return nil;
        found = window;
    }
    return found ? @[ @(pid), @(bsd.pbi_start_tvsec * 1000000ULL + bsd.pbi_start_tvusec), found ] : nil;
}
