// One read-only CI program. Link only the production scope decoder, never a window or input fixture.
#import <AppKit/AppKit.h>
#import <unistd.h>
#import "scope_binding.h"

static BOOL activeConsole(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[(__bridge NSString *)kCGSessionOnConsoleKey] isEqual:@YES] &&
           [session[(__bridge NSString *)kCGSessionLoginDoneKey] isEqual:@YES] &&
           [session[(__bridge NSString *)kCGSessionUserIDKey] isEqual:@(getuid())] &&
           ![session[@"CGSSessionScreenIsLocked"] boolValue];
}

static NSString *uuidField(NSDictionary *row) {
    id value = row[@"uuid"];
    if (!value || value == NSNull.null) return @"missing";
    return nc_uuid(value) ? @"valid" : @"malformed";
}

static NSDictionary *readScope(unsigned index) {
    NSMutableDictionary *facts = [@{@"read": @(index), @"console": @(activeConsole()),
        @"uptime": @(NSProcessInfo.processInfo.systemUptime)} mutableCopy];
    if (![facts[@"console"] boolValue]) return facts;

    typedef int (*Connection)(void);
    typedef CFArrayRef (*CopyManaged)(int);
    static Connection connect;
    static CopyManaged managed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
        if (sky) {
            connect = (Connection)dlsym(sky, "SLSMainConnectionID");
            managed = (CopyManaged)dlsym(sky, "SLSCopyManagedDisplaySpaces");
        }
    });
    const int conn = connect ? connect() : 0;
    NSArray *inventory = conn > 0 && managed ? CFBridgingRelease(managed(conn)) : nil;
    BOOL valid = [inventory isKindOfClass:NSArray.class];
    uint32_t n = 0, copied = 0;
    CGDirectDisplayID display = 0;
    NSArray *screens = NSScreen.screens;
    BOOL queried = CGGetActiveDisplayList(0, NULL, &n) == kCGErrorSuccess;
    BOOL single = queried && n == 1 && CGGetActiveDisplayList(1, &display, &copied) == kCGErrorSuccess &&
        copied == 1 && display == CGMainDisplayID() && !CGDisplayIsInMirrorSet(display) &&
        screens.count == 1 && [[screens[0] deviceDescription][@"NSScreenNumber"] isEqual:@(display)];
    CFUUIDRef uuid = single ? CGDisplayCreateUUIDFromDisplayID(display) : NULL;
    NSString *displayID = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
    if (uuid) CFRelease(uuid);
    NSDictionary *row = valid && inventory.count == 1 && [inventory[0] isKindOfClass:NSDictionary.class]
        ? inventory[0] : @{};
    NSDictionary *current = [row[@"Current Space"] isKindOfClass:NSDictionary.class] ? row[@"Current Space"] : @{};
    NSNumber *number = nc_space_number(current);
    NSArray *roster = [row[@"Spaces"] isKindOfClass:NSArray.class] ? row[@"Spaces"] : @[];
    facts[@"currentUUIDField"] = uuidField(current);
    for (id entry in roster) {
        if (number && [entry isKindOfClass:NSDictionary.class] && [nc_space_number(entry) isEqual:number])
            facts[@"matchedUUIDField"] = uuidField(entry);
    }
    [facts addEntriesFromDictionary:@{@"connectionAvailable": @(conn > 0), @"displayQuerySucceeded": @(queried),
        @"inventoryAvailable": @(valid), @"cgDisplayCount": @(n), @"appKitScreenCount": @(screens.count),
        @"managedDisplayCount": @(valid ? inventory.count : 0)}];
    NSDictionary *bound = nc_bound_scope(row, displayID, single, nc_direct_home(conn, row[@"Display Identifier"]), facts);
    if (bound) facts[@"bound"] = bound;
    return facts;
}

int main(void) {
    @autoreleasepool {
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        if (getuid() == 0 || getuid() != geteuid() || ![NSUserName() isEqual:@"runner"] ||
            ![env[@"GITHUB_ACTIONS"] isEqual:@"true"] || ![env[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"] ||
            ![env[@"RUNNER_OS"] isEqual:@"macOS"] ||
            ![@[@"workflow_dispatch", @"push"] containsObject:env[@"GITHUB_EVENT_NAME"] ?: @""] ||
            ![env[@"NP_HOSTED_SCOPE_ONLY"] isEqual:@"1"]) return 2;
        NSDictionary *first = readScope(1);
        [NSThread sleepForTimeInterval:0.025];
        NSDictionary *second = readScope(2);
        NSDictionary *raw = @{@"schema": @1, @"scope": @"readOnlyHostedDesktop", @"systemWrites": @0,
            @"operatingSystem": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"windowTrials": @"NOT_RUN", @"reads": @[first, second]};
        NSData *bytes = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingSortedKeys error:NULL];
        if (!bytes) return 3;
        fwrite(bytes.bytes, 1, bytes.length, stdout);
        puts("");
    }
    return 0;
}
