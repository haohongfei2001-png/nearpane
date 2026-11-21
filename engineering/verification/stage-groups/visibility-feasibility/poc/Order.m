#import "Lab.h"

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3 || !hosted()) return 64;
    NSString *mode = @(argv[1]), *root = @(argv[2]);
    if (![@[@"cold-main",@"appkit-load",@"app-main",@"independent",@"transaction"] containsObject:mode]) return 64;
    if (!fixtureIdentity(root, @"A")) return 65;
    // No CG/AX enumeration or NSWorkspace call before opening the cold main connection.
    BOOL loaded = NO;
    if (![mode isEqual:@"cold-main"]) loaded = NSApplicationLoad();
    if ([mode isEqual:@"app-main"]) [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
    MainConnection main = sky(@"SLSMainConnectionID");
    int cid = main ? main() : 0, primary = cid, openError = 0;
    int (*release)(int) = sky(@"SLSReleaseConnection");
    BOOL separate = [mode isEqual:@"independent"];
    if (separate) {
        int (*create)(int, int *) = sky(@"SLSNewConnection");
        cid = 0; openError = (create && release) ? create(0, &cid) : -1;
    }
    emit(@{@"pid":@(getpid()),@"mode":mode,@"appKitLoaded":@(loaded),@"main":@(primary),@"cid":@(cid),@"openError":@(openError)});
    char request[64];
    while (fgets(request, sizeof(request), stdin)) { @autoreleasepool {
        NSString *op = [@(request) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([op isEqual:@"close"]) break;
        if (![@[@"out0",@"in0",@"out1",@"in1"] containsObject:op]) return 64;
        NSDictionary *idn = fixtureIdentity(root, @"A");
        if (!idn || !cid || openError || (separate && primary == cid)) { emit(@{@"status":@"BLOCKED",@"reason":@"identity or connection"}); continue; }
        uint32_t wid = [idn[@"windows"][[op hasSuffix:@"0"] ? 0 : 1] unsignedIntValue];
        BOOL hide = [op hasPrefix:@"out"];
        if (![mode isEqual:@"transaction"]) { emit(directOrder(cid, wid, hide)); continue; }
        CFTypeRef (*create)(int) = sky(@"SLSTransactionCreate");
        int (*order)(CFTypeRef,uint32_t,int,uint32_t) = sky(@"SLSTransactionOrderWindow");
        int (*commit)(CFTypeRef,int) = sky(@"SLSTransactionCommit");
        CFTypeRef tx = create && order && commit ? create(cid) : NULL;
        if (!tx) { emit(@{@"status":@"BLOCKED",@"reason":@"no transaction"}); continue; }
        int orderCode = order(tx, wid, hide ? 0 : 2, 0);
        int commitCode = commit(tx, 0); CFRelease(tx);
        emit(@{@"orderResult":@(orderCode),@"commitResult":@(commitCode),@"mode":@(hide ? 0 : 2)});
    }}
    emit(@{@"released":separate && cid && release ? @(release(cid)) : none()});
    return 0;
}}
