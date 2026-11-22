#import <Security/Security.h>
#import <bsm/libbsm.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>

static NSString *const fixtureID = @"com.holdsnow.nearpane.stage-interactive-fixture";
static NSString *const hostID = @"com.holdsnow.nearpane.alpha";
static NSString *const hostBinary = @"/Applications/Nearpane.app/Contents/MacOS/NearpaneHost";

static uint64_t processBirth(pid_t pid) {
    struct proc_bsdinfo info = {};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        info.pbi_pid != (uint32_t)pid || info.pbi_uid != getuid()) return 0;
    return info.pbi_start_tvsec * UINT64_C(1000000) + info.pbi_start_tvusec;
}
static BOOL kernelExecutable(pid_t pid, NSString *expected) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(pid, path, sizeof(path)) > 0 && [@(path) isEqual:expected];
}
static int privateDirectory(NSString *path) {
    int d = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat s;
    if (d >= 0 && !fstat(d, &s) && s.st_uid == getuid() && (s.st_mode & 0777) == 0700) return d;
    if (d >= 0) close(d);
    return -1;
}
static NSString *codeHash(SecCodeRef code, NSString *identifier) {
    if (!code) return nil;
    NSString *rule = [NSString stringWithFormat:
        @"anchor apple generic and identifier \"%@\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
         "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\"", identifier];
    SecRequirementRef req = NULL;
    CFDictionaryRef raw = NULL;
    OSStatus e = SecRequirementCreateWithString((__bridge CFStringRef)rule, 0, &req);
    if (!e) e = SecCodeCheckValidity(code, kSecCSStrictValidate, req);
    if (!e) e = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
    NSDictionary *info = CFBridgingRelease(raw);
    if (req) CFRelease(req);
    NSData *digest = info[(__bridge NSString *)kSecCodeInfoUnique];
    if (e || digest.length != 20 || ![info[(__bridge NSString *)kSecCodeInfoIdentifier] isEqual:identifier] ||
        ![info[(__bridge NSString *)kSecCodeInfoTeamIdentifier] isEqual:@"ZB9D4T66QB"]) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    const uint8_t *bytes = digest.bytes;
    for (size_t i = 0; i < digest.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}
static NSDictionary *verifiedPeerImage(int fd, NSString *expectedPath, NSString *identifier) {
    audit_token_t token = {};
    socklen_t size = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token) ||
        audit_token_to_euid(token) != getuid()) return nil;
    pid_t pid = audit_token_to_pid(token);
    audit_token_t self = {};
    mach_msg_type_number_t words = TASK_AUDIT_TOKEN_COUNT;
    SecuritySessionId session = 0;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&self, &words) != KERN_SUCCESS ||
        words != TASK_AUDIT_TOKEN_COUNT || audit_token_to_asid(self) != audit_token_to_asid(token) ||
        SessionGetInfo(callerSecuritySession, &session, NULL) || !session) return nil;
    uint64_t birth = pid > 1 ? processBirth(pid) : 0;
    if (!birth || !kernelExecutable(pid, expectedPath)) return nil;
    NSData *data = [NSData dataWithBytes:&token length:sizeof(token)];
    SecCodeRef code = NULL;
    NSDictionary *query = @{(__bridge NSString *)kSecGuestAttributeAudit:data};
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)query, 0, &code)) return nil;
    NSString *digest = codeHash(code, identifier);
    CFRelease(code);
    if (!digest || processBirth(pid) != birth || !kernelExecutable(pid, expectedPath)) return nil;
    return @{@"pid":@(pid), @"birth":@(birth), @"cdhash":digest, @"securitySession":@(session)};
}
static NSDictionary *authenticatedHost(int fd) { return verifiedPeerImage(fd,hostBinary,hostID); }
static BOOL sameUUID(id a, id b) {
    if (![a isKindOfClass:NSString.class] || ![b isKindOfClass:NSString.class]) return NO;
    NSUUID *x = [[NSUUID alloc] initWithUUIDString:a], *y = [[NSUUID alloc] initWithUUIDString:b];
    return x && [x isEqual:y];
}
static BOOL positiveInteger(id n) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n) != CFBooleanGetTypeID() &&
           !CFNumberIsFloatType((__bridge CFNumberRef)n) && [n longLongValue] > 0;
}
static BOOL exactlyTrue(id value) { return value == (__bridge id)kCFBooleanTrue; }
static NSDictionary *readPreflight(NSString *nonce) {
    int rootFD = privateDirectory([@"/private/tmp/nearpane-host-scope." stringByAppendingString:nonce]);
    if (rootFD < 0) return nil;
    int f = openat(rootFD, "preflight.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    close(rootFD);
    if (f < 0) return nil;
    struct stat s;
    BOOL safe = !fstat(f,&s) && S_ISREG(s.st_mode) && s.st_nlink == 1 && s.st_uid == getuid() &&
                (s.st_mode & 0777) == 0600 && s.st_size > 0 && s.st_size <= 524288;
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:f closeOnDealloc:YES];
    NSData *data = safe ? [handle readDataUpToLength:(NSUInteger)s.st_size + 1 error:NULL] : nil;
    if (!data || data.length != (NSUInteger)s.st_size) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}
static BOOL ordinaryHostPreflight(NSDictionary *p, NSDictionary *peer, NSDictionary *open, uint64_t nowNS) {
    NSDictionary *subject = p[@"subject"], *reading = p[@"spaceScope"];
    NSDictionary *system = p[@"system"], *permissions = p[@"permissions"];
    if (![reading isKindOfClass:NSDictionary.class] || ![system isKindOfClass:NSDictionary.class] ||
        ![system[@"sip"] isKindOfClass:NSDictionary.class] || ![permissions isKindOfClass:NSDictionary.class] ||
        ![system[@"build"] isEqual:@"26A428"] || !exactlyTrue(system[@"sip"][@"enabled"]) ||
        !exactlyTrue(permissions[@"accessibility"]) || !exactlyTrue(permissions[@"listenEvent"])) return NO;
    NSDictionary *scope = reading[@"scope"];
    NSArray *samples = reading[@"samples"];
    if (!peer || ![subject isKindOfClass:NSDictionary.class] || ![reading isKindOfClass:NSDictionary.class] ||
        ![scope isKindOfClass:NSDictionary.class] || ![samples isKindOfClass:NSArray.class] || samples.count != 2 ||
        ![subject[@"identifier"] isEqual:hostID] || ![subject[@"teamIdentifier"] isEqual:@"ZB9D4T66QB"] ||
        ![subject[@"kernelExecutable"] isEqual:hostBinary] || !exactlyTrue(subject[@"atDailyInstallPath"]) ||
        ![subject[@"sourceState"] isEqual:@"clean"] || ![subject[@"pid"] isEqual:peer[@"pid"]] ||
        ![subject[@"birth"] isEqual:peer[@"birth"]] || ![subject[@"cdhash"] isEqual:peer[@"cdhash"]] ||
        !sameUUID(p[@"challenge"], open[@"challenge"]) || !exactlyTrue(reading[@"readOnly"]) ||
        ![scope[@"status"] isEqual:@"PASS"] || !sameUUID(open[@"displayUUID"],scope[@"displayUUID"]) ||
        !sameUUID(open[@"spaceUUID"],scope[@"spaceUUID"]) || !positiveInteger(open[@"nativeID"]) ||
        ![scope[@"nativeID"] isEqual:open[@"nativeID"]]) return NO;
    uint64_t previous = 0;
    for (NSDictionary *s in samples) {
        if (![s isKindOfClass:NSDictionary.class] || ![s[@"session"] isKindOfClass:NSDictionary.class] ||
            ![s[@"display"] isKindOfClass:NSDictionary.class] || ![s[@"ordinaryIdentity"] isKindOfClass:NSDictionary.class] ||
            !positiveInteger(s[@"startedUptimeNS"]) || !positiveInteger(s[@"endedUptimeNS"])) return NO;
        uint64_t a = [s[@"startedUptimeNS"] unsignedLongLongValue], b = [s[@"endedUptimeNS"] unsignedLongLongValue];
        if (previous >= a || a > b || b > nowNS || nowNS - b > 12 * NSEC_PER_SEC ||
            ![s[@"hostPID"] isEqual:peer[@"pid"]] || ![s[@"hostBirth"] isEqual:peer[@"birth"]] ||
            !exactlyTrue(s[@"session"][@"qualified"]) || ![s[@"session"][@"securitySessionID"] isEqual:peer[@"securitySession"]] ||
            !exactlyTrue(s[@"display"][@"topologyConfirmed"]) || ![s[@"display"][@"activeCGCount"] isEqual:@1] ||
            ![s[@"ordinaryIdentity"][@"status"] isEqual:@"PASS"] ||
            ![s[@"directCurrent"] isEqual:open[@"nativeID"]] || ![s[@"directCurrentAfter"] isEqual:open[@"nativeID"]]) return NO;
        previous = b;
    }
    return YES;
}
