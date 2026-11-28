#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <libproc.h>

static NSString *const labID = @"net.example.nearpane.visibility.";
static id none(void) { return NSNull.null; }
static NSArray *rectArray(CGRect r) {
    return @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)];
}
static id readJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static void saveJSON(id value, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (![data writeToFile:path atomically:YES]) exit(74);
}
static void emit(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data || fwrite(data.bytes, 1, data.length, stdout) != data.length) exit(74);
    putchar('\n'); fflush(stdout);
}
static BOOL hosted(void) {
    NSDictionary *e = NSProcessInfo.processInfo.environment;
    return [e[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"] && [e[@"GITHUB_ACTIONS"] isEqual:@"true"]
        && [e[@"RUNNER_OS"] isEqual:@"macOS"] && [NSUserName() isEqual:@"runner"];
}
static uint64_t generation(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || info.pbi_pid != (uint32_t)pid || info.pbi_uid != getuid()) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
static id fixtureIdentity(NSString *root, NSString *name) {
    if (![@[@"A",@"B"] containsObject:name]) return nil;
    NSDictionary *record = readJSON([root stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);
    pid_t pid = [record[@"pid"] intValue]; uint64_t gen = generation(pid);
    char exe[PROC_PIDPATHINFO_MAXSIZE] = {};
    NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.app/Contents/MacOS/Fixture", name]];
    if (!gen || gen != [record[@"generation"] unsignedLongLongValue] || proc_pidpath(pid, exe, sizeof(exe)) <= 0
        || ![[@(exe) stringByResolvingSymlinksInPath] isEqual:path.stringByResolvingSymlinksInPath]
        || ![record[@"bundle"] isEqual:[labID stringByAppendingString:name.lowercaseString]]
        || [record[@"windows"] count] != 2) return nil;
    return record;
}
static void *sky(NSString *name) {
    static void *library; static dispatch_once_t once;
    dispatch_once(&once, ^{ library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL); });
    return library ? dlsym(library, name.UTF8String) : NULL;
}
typedef int (*MainConnection)(void);
typedef int (*WindowOrder)(int, uint32_t, int, uint32_t);
static NSDictionary *directOrder(int cid, uint32_t number, BOOL hide) {
    WindowOrder order = sky(@"SLSOrderWindow");
    if (!cid || !order) return @{@"status":@"BLOCKED",@"reason":@"missing connection or symbol"};
    // NUIKit/CGSInternal c4f6f55, CGSWindow.h lines 49–53. In preserves the ordering slot.
    int mode = hide ? 0 : 2;
    return @{@"cid":@(cid),@"mode":@(mode),@"result":@(order(cid, number, mode, 0))};
}
