// Installed-helper read-only mode. It accepts one request from its signed parent and never opens a profile.
#import <dlfcn.h>
#import <time.h>

static NSString *diagnosticHash(NSData *digest) {
    if (!digest.length)
        return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:digest.length * 2];
    for (NSUInteger i = 0; i < digest.length; i++)
        [hex appendFormat:@"%02x", ((const uint8_t *)digest.bytes)[i]];
    return hex;
}
static pid_t diagnosticResponsible(void) {
    typedef pid_t (*ReadResponsiblePID)(pid_t);
    ReadResponsiblePID read = (ReadResponsiblePID)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    return read ? read(getpid()) : -1;
}
static BOOL diagnosticPipes(void) {
    struct stat a, b;
    return fstat(STDIN_FILENO, &a) == 0 && fstat(STDOUT_FILENO, &b) == 0 && S_ISFIFO(a.st_mode) &&
           S_ISFIFO(b.st_mode);
}
static BOOL diagnosticEnvelope(NSDictionary *m, uint64_t now) {
    NSSet *allowed = [NSSet setWithArray:@[ @"schema", @"challenge", @"issued", @"hostPID", @"hostBirth", @"hostHash",
                                           @"childPID", @"childBirth", @"childHash", @"window", @"fixtureHash",
                                           @"executable", @"display", @"space", @"nativeID" ]];
    if (![m isKindOfClass:NSDictionary.class] || (!m[@"nativeID"] ? m.count != 12 : m.count != 15) ||
        ![[NSSet setWithArray:m.allKeys] isSubsetOfSet:allowed])
        return NO;
    if (![m[@"schema"] isEqual:@1] || !number(m[@"schema"]) || ![m[@"challenge"] isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:m[@"challenge"]] || !number(m[@"issued"]) ||
        ![m[@"window"] isKindOfClass:NSDictionary.class] || ![m[@"executable"] isKindOfClass:NSString.class] ||
        ![m[@"fixtureHash"] isKindOfClass:NSString.class] ||
        ![@[ @40, @64 ] containsObject:@([m[@"fixtureHash"] length])])
        return NO;
    uint64_t issued = [m[@"issued"] unsignedLongLongValue];
    if (!issued || now < issued || now - issued > UINT64_C(6000000000))
        return NO;
    NSDictionary *window = m[@"window"];
    if (window.count != 3 || ![m[@"executable"] hasPrefix:@"/"] || [m[@"executable"] length] >= PATH_MAX)
        return NO;
    for (NSString *key in @[ @"pid", @"birth", @"number" ])
        if (!number(window[key]) || [window[key] compare:@0] != NSOrderedDescending)
            return NO;
    if (![window[@"pid"] isEqual:@([window[@"pid"] intValue])] ||
        ![window[@"number"] isEqual:@([window[@"number"] unsignedIntValue])] ||
        ![window[@"birth"] isEqual:@([window[@"birth"] unsignedLongLongValue])])
        return NO;
    if (!m[@"display"] && !m[@"space"] && !m[@"nativeID"])
        return YES;
    uint8_t display[16], space[16];
    return decodeUUID(m[@"display"], display) && decodeUUID(m[@"space"], space) && number(m[@"nativeID"]) &&
           [m[@"nativeID"] compare:@0] == NSOrderedDescending &&
           [m[@"nativeID"] isEqual:@([m[@"nativeID"] unsignedLongLongValue])];
}
static int inspectRegisteredFixture(void) {
    if (!diagnosticPipes())
        return 2;
    pid_t parent = getppid(), own = getpid(), actualParent = 0;
    uint64_t hostBirth = ncg_birth(parent, NULL), childBirth = ncg_birth(own, &actualParent);
    NSString *hostHash = diagnosticHash(signedProduct(parent, hostExe, @"com.holdsnow.nearpane.alpha"));
    NSString *childHash = diagnosticHash(signedProduct(own, guardianExe, @"com.holdsnow.nearpane.alpha.corner-guardian"));
    if (!hostBirth || !childBirth || actualParent != parent || !hostHash || !childHash)
        return 3;
    NSDictionary *m = productMessage(), *w = m[@"window"];
    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!diagnosticEnvelope(m, started) || ![m[@"hostPID"] isEqual:@(parent)] || ![m[@"hostBirth"] isEqual:@(hostBirth)] ||
        ![m[@"hostHash"] isEqual:hostHash] || ![m[@"childPID"] isEqual:@(own)] ||
        ![m[@"childBirth"] isEqual:@(childBirth)] || ![m[@"childHash"] isEqual:childHash])
        return 3;

    pid_t responsibleBefore = diagnosticResponsible();
    BOOL axBefore = AXIsProcessTrusted();
    // Effective access can be attributed to another responsible process. In that case observe just this
    // registered CG owner and report the helper's permission query without using effective AX on the fixture.
    BOOL inspectWindow = responsibleBefore == own && axBefore;
    NPGuardianFixtureObservation raw = {.size = sizeof(raw), .version = 1};
    int32_t result = np_guardian_observe_fixture(
        [w[@"pid"] intValue], [w[@"birth"] unsignedLongLongValue], [w[@"number"] unsignedIntValue],
        (__bridge CFStringRef)m[@"executable"], (__bridge CFStringRef)m[@"fixtureHash"],
        inspectWindow ? [m[@"nativeID"] unsignedLongLongValue] : 0,
        inspectWindow ? (__bridge CFStringRef)m[@"display"] : NULL,
        inspectWindow ? (__bridge CFStringRef)m[@"space"] : NULL, &raw);
    BOOL axAfter = AXIsProcessTrusted();
    pid_t responsibleAfter = diagnosticResponsible();
    uint64_t ended = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!diagnosticEnvelope(m, ended) || getppid() != parent || ncg_birth(parent, NULL) != hostBirth ||
        ncg_birth(own, &actualParent) != childBirth || actualParent != parent ||
        ![hostHash isEqual:diagnosticHash(signedProduct(parent, hostExe, @"com.holdsnow.nearpane.alpha"))] ||
        ![childHash isEqual:diagnosticHash(signedProduct(own, guardianExe, @"com.holdsnow.nearpane.alpha.corner-guardian"))])
        return 3;
    NSMutableDictionary *reply = [@{
        @"schema" : @1, @"challenge" : m[@"challenge"], @"hostPID" : @(parent), @"hostBirth" : @(hostBirth),
        @"hostHash" : hostHash, @"childPID" : @(own), @"childBirth" : @(childBirth), @"childHash" : childHash,
        @"window" : w, @"fixtureHash" : m[@"fixtureHash"], @"started" : @(started), @"ended" : @(ended),
        @"responsibleBefore" : @(responsibleBefore), @"responsibleAfter" : @(responsibleAfter),
        @"axBefore" : @(axBefore), @"axAfter" : @(axAfter), @"receiptCode" : @(result),
        @"observation" : [[NSData dataWithBytes:&raw length:sizeof(raw)] base64EncodedStringWithOptions:0]
    } mutableCopy];
    for (NSString *k in @[ @"display", @"space", @"nativeID" ])
        if (m[k])
            reply[k] = m[k];
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingSortedKeys error:NULL];
    // A single bounded pipe packet. The process stays alive for the Host's final kernel/signature check.
    if (!data.length || data.length > 4000 || write(STDOUT_FILENO, data.bytes, data.length) != (ssize_t)data.length ||
        write(STDOUT_FILENO, "\n", 1) != 1)
        return 4;
    struct pollfd finish = {.fd = STDIN_FILENO, .events = POLLIN};
    char release = 0;
    return poll(&finish, 1, 2000) > 0 && read(STDIN_FILENO, &release, 1) == 1 && release == 'Q' ? 0 : 4;
}
