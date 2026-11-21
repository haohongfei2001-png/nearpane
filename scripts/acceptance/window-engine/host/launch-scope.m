// A Launch Services caller. Only the requested signed Host samples WindowServer or TCC.
#import <AppKit/AppKit.h>
#include <stdio.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3 || argc > 4) return 2;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES].URLByResolvingSymlinksInPath;
        NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:@(argv[2])];
        if (!nonce || (argc == 4 && strcmp(argv[3], "--registered-window"))) return 2;
        NSWorkspaceOpenConfiguration *config = NSWorkspaceOpenConfiguration.configuration;
        config.promptsUserIfNeeded = NO;
        config.activates = NO;
        config.addsToRecentItems = NO;
        config.allowsRunningApplicationSubstitution = NO;
        config.createsNewApplicationInstance = YES;
        NSMutableArray *args = [@[@"--read-stage-engine-scope", nonce.UUIDString, @"--private-receipt"] mutableCopy];
        if (argc == 4) [args addObject:@"--registered-window"];
        config.arguments = args;
        __block BOOL complete = NO;
        __block NSDictionary *result;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:config completionHandler:
            ^(NSRunningApplication *app, NSError *error) {
                BOOL exact = app && [app.bundleURL.URLByResolvingSymlinksInPath.path isEqual:url.path];
                result = @{@"exactLaunchPath":@(exact), @"pid":@(app ? app.processIdentifier : 0),
                           @"errorDomain":error.domain ?: @"", @"errorCode":@(error.code)};
                complete = YES;
            }];
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:12];
        while (!complete && end.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        if (!complete) result = @{@"exactLaunchPath":@NO, @"pid":@0, @"errorDomain":@"launchTimeout", @"errorCode":@0};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        if (!data) return 3;
        [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
        return 0;
    }
}
