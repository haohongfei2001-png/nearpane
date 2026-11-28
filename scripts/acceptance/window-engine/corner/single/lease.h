// Private protocol for one signed controller and its directly spawned synthetic ordinary window.
#import "guardian/identity.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <fcntl.h>
#include <poll.h>
static NSString *const ctlID = @"com.holdsnow.nearpane.engine-fixture";
static NSString *const ownerID = @"com.holdsnow.nearpane.engine-fixture.a";
static inline NSString *singleKit(void) { return NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent; }
static inline NSString *singlePath(BOOL child) {
    return
        [singleKit() stringByAppendingPathComponent:child ? @"Lease Window.app/Contents/MacOS/LeaseWindow"
                                                          : @"Lease Controller.app/Contents/MacOS/LeaseController"];
}
static inline NSData *singleCode(pid_t pid, BOOL child) {
    NSString *id = child ? ownerID : ctlID;
    NSString *rule = [NSString
        stringWithFormat:
            @"anchor apple generic and identifier \"%@\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            @"and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "
            @"\"ZB9D4T66QB\"",
            id];
    return ncg_rule_hash(pid, singlePath(child), rule);
}
static inline BOOL singleSize(NSArray *x) {
    if (![x isKindOfClass:NSArray.class] || x.count != 4)
        return NO;
    for (id n in x)
        if (![n isKindOfClass:NSNumber.class] || !isfinite([n doubleValue]))
            return NO;
    return [x[2] doubleValue] > 0 && [x[3] doubleValue] > 0;
}
static inline BOOL singleNear(NSArray *a, NSArray *b) {
    if (!singleSize(a) || !singleSize(b))
        return NO;
    for (int i = 0; i < 4; i++)
        if (fabs([a[i] doubleValue] - [b[i] doubleValue]) > .75)
            return NO;
    return YES;
}
static inline BOOL singleInvisible(NSDictionary *w) {
    return [w[@"alpha"] isEqual:@0] && [w[@"clickThrough"] isEqual:@YES] && [w[@"opaque"] isEqual:@NO] &&
           [w[@"key"] isEqual:@NO] && [w[@"main"] isEqual:@NO] && [w[@"canKey"] isEqual:@NO] &&
           [w[@"canMain"] isEqual:@NO] && [w[@"panel"] isEqual:@NO] && [w[@"shadow"] isEqual:@NO] &&
           [w[@"mini"] isEqual:@NO] && [w[@"activeApp"] isEqual:@NO] && [w[@"onActiveSpace"] isEqual:@YES] &&
           [w[@"ordered"] isEqual:@YES];
}
static inline BOOL singleWrite(int fd, id object) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (!d || d.length > 2048)
        return NO;
    NSMutableData *line = [d mutableCopy];
    const char nl = '\n';
    [line appendBytes:&nl length:1];
    return write(fd, line.bytes, line.length) == (ssize_t)line.length;
}
