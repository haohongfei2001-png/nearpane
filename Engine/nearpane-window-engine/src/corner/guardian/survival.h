// Read-only continuation of an authenticated fixture inspection. No WAL, restore callback or setter.
#include "exit-watch.h"
static NSArray *survivalFrame(NPGuardianRect f) { return @[@(f.x), @(f.y), @(f.width), @(f.height)]; }
static BOOL survivalProof(const NPGuardianFixtureObservation *r) {
    return r->signatures_closed && r->same_geometry && r->held_in_caller && r->released &&
           r->first.uptime_ns < r->second.uptime_ns && r->first.ax_trusted && r->second.ax_trusted &&
           r->first.native_sample_attempted && r->second.native_sample_attempted &&
           !r->first.native_sample_code && !r->second.native_sample_code &&
           r->first.same_retained && r->second.same_retained && r->first.cg_onscreen && r->second.cg_onscreen;
}
static int observeAfterParentExit(NSDictionary *m, const NPGuardianFixtureObservation *pre,
                                  pid_t parent, uint64_t parentBirth, pid_t responsible) {
    NSDictionary *w = m[@"window"];
    NCMember member = {.pid = [w[@"pid"] intValue], .birth = [w[@"birth"] unsignedLongLongValue],
                       .window = [w[@"number"] unsignedIntValue], .native = [m[@"nativeID"] unsignedLongLongValue]};
    NSString *scope = [m[@"challenge"] lowercaseString];
    NSString *path = [@"/private/tmp/nearpane-host-scope." stringByAppendingString:scope];
    int dir = open(path.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int queue = ncg_watch_exit(parent, parentBirth), fd = -1, rc = 4;
    void *held = NULL;
    struct stat st;
    uint32_t input[13], lastInput[13];
    if (!survivalProof(pre) || !member.native || !decodeUUID(m[@"display"], member.display) ||
        !decodeUUID(m[@"space"], member.space) || dir < 0 || fstat(dir, &st) || st.st_uid != getuid() ||
        (st.st_mode & 0777) != 0700 || queue < 0 || np_corner_secure_input() ||
        (responsible != parent && responsible != getpid()) || !AXIsProcessTrusted()) goto refused;
    if (getppid() != parent || ncg_birth(parent, NULL) != parentBirth) goto refused;
    held = np_corner_retain_window(&member);
    if (!held || !np_corner_same_window(&member, held)) goto refused;
    fd = openat(dir, "guardian-post-exit.pending", O_EXCL | O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) goto refused;
    np_corner_inputs(input);
    if (write(STDOUT_FILENO, "ARMED\n", 6) != 6) goto cleanup;
    {
        BOOL exited = ncg_saw_exit(queue, parent, parentBirth, 8000);
        NPGuardianFixtureObservation post = {.size = sizeof(post), .version = 1};
        BOOL access = AXIsProcessTrusted(), exact = NO;
        int sampled = -1;
        if (exited && access && np_corner_same_window(&member, held)) {
            sampled = np_guardian_observe_fixture(member.pid, member.birth, member.window,
                (__bridge CFStringRef)m[@"executable"], (__bridge CFStringRef)m[@"fixtureHash"], member.native,
                (__bridge CFStringRef)m[@"display"], (__bridge CFStringRef)m[@"space"], &post);
            exact = sampled == 0 && survivalProof(&post) && np_corner_same_window(&member, held);
        }
        np_corner_inputs(lastInput);
        BOOL stableInput = !memcmp(input, lastInput, sizeof(input)) && !np_corner_secure_input();
        BOOL geometry = exact && [survivalFrame(pre->second.ax) isEqual:survivalFrame(post.second.ax)] &&
                        [survivalFrame(pre->second.cg) isEqual:survivalFrame(post.second.cg)];
        np_corner_release_window(held);
        held = NULL;
        NSDictionary *receipt = @{
            @"schema": @1, @"challenge": m[@"challenge"], @"hostPID": @(parent), @"hostBirth": @(parentBirth),
            @"hostHash": m[@"hostHash"], @"childPID": m[@"childPID"], @"childBirth": m[@"childBirth"],
            @"childHash": m[@"childHash"], @"window": w, @"fixtureHash": m[@"fixtureHash"],
            @"display": m[@"display"], @"space": m[@"space"], @"nativeID": m[@"nativeID"],
            @"kernelExit": @(exited), @"postExitAXTrusted": @(access), @"responsibleBefore": @(responsible),
            @"responsibleAfter": @(diagnosticResponsible()), @"sampleCode": @(sampled),
            @"exactOriginalRetained": @(exact), @"geometryReturned": @(geometry), @"inputStable": @(stableInput),
            @"originalReleased": @YES, @"firstPostReadNS": @(post.first.uptime_ns), @"secondPostReadNS": @(post.second.uptime_ns),
            @"originalAX": survivalFrame(pre->second.ax), @"originalCG": survivalFrame(pre->second.cg),
            @"postAX": survivalFrame(post.second.ax), @"postCG": survivalFrame(post.second.cg),
            @"status": exited && exact && geometry && stableInput ? @"PASS" : @"UNKNOWN",
            @"scope": @"readOnlyOriginalObjectAcrossHostExit", @"windowWrites": @0, @"spaceWrites": @0, @"mayPark": @NO
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:NULL];
        if (data.length && data.length < 4096 && write(fd, data.bytes, data.length) == (ssize_t)data.length &&
            !fsync(fd) && !renameatx_np(dir, "guardian-post-exit.pending", dir, "guardian-post-exit.json", RENAME_EXCL)) rc = 0;
    }
    goto cleanup;
refused:
    rc = write(STDOUT_FILENO, "REFUSED\n", 8) == 8 ? 0 : 4;
cleanup:
    if (held) np_corner_release_window(held);
    if (fd >= 0) { close(fd); unlinkat(dir, "guardian-post-exit.pending", 0); fsync(dir); }
    if (dir >= 0) close(dir);
    if (queue >= 0) close(queue);
    return rc;
}
