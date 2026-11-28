// The caller is the Host running the one-fixture read-only command; this is never a recovery grant.
#import "retained-observation.h"
#import "identity.h"
#import <time.h>
static BOOL ncg_registered_fixture(const NCMember *m, NSString *path, NSString *expectedHash) {
    if (birth(m->pid) != m->birth)
        return NO;
    // Match signer and path, then validate the actual identifier read from the same signed image.
    NSString *rule =
        @"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate "
        @"leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\"";
    NSData *hash = ncg_rule_hash(m->pid, path, rule);
    if (!hash.length || expectedHash.length != hash.length * 2)
        return NO;
    NSMutableString *actual = [NSMutableString string];
    for (NSUInteger i = 0; i < hash.length; i++)
        [actual appendFormat:@"%02x", ((const uint8_t *)hash.bytes)[i]];
    if (![actual isEqual:expectedHash])
        return NO;
    SecCodeRef image = NULL;
    CFDictionaryRef info = NULL;
    OSStatus error = SecCodeCopyGuestWithAttributes(
        NULL,
        (__bridge CFDictionaryRef)
            @{(__bridge NSString *)kSecGuestAttributePid : @(m->pid)},
        0, &image);
    if (!error)
        error = SecCodeCopySigningInformation(image, kSecCSSigningInformation, &info);
    NSDictionary *fields = (__bridge NSDictionary *)info;
    BOOL valid = !error &&
                 [fields[(__bridge NSString *)kSecCodeInfoIdentifier]
                     isEqual:@"com.holdsnow.nearpane.engine-fixture.a"] &&
                 [fields[(__bridge NSString *)kSecCodeInfoUnique] isEqual:hash] && birth(m->pid) == m->birth;
    if (info)
        CFRelease(info);
    if (image)
        CFRelease(image);
    return valid;
}
static NPGuardianRect ncg_measure_frame(NCFrame r) { return (NPGuardianRect){r.x, r.y, r.w, r.h}; }
static void ncg_fixture_read(NPGuardianFixtureRead *s, NCMember *m, NSString *path, NSString *hash,
                             BOOL hasScope, void **held, BOOL first) {
    s->uptime_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    s->kernel_generation = birth(m->pid) == m->birth;
    s->ax_trusted = AXIsProcessTrusted();
    if (!s->kernel_generation || !ncg_registered_fixture(m, path, hash))
        return;
    s->signature = 1;
    NCSample sample = {0};
    if (!liveCG(m, &sample))
        return;
    s->cg_owner = 1;
    s->cg_onscreen = sample.onscreen;
    s->cg = ncg_measure_frame(sample.cg);
    if (!s->ax_trusted || !hasScope)
        return;
    s->native_sample_attempted = 1;
    id actual = nil;
    s->native_sample_code = readMember(m, &actual, &sample);
    if (s->native_sample_code || !actual)
        return;
    s->ax = ncg_measure_frame(sample.ax);
    if (first)
        *held = (void *)CFBridgingRetain(actual);
    s->same_retained = *held && CFEqual(*held, (__bridge CFTypeRef)actual) && np_corner_same_window(m, *held);
    NCFrame fromHeld = {0};
    if (s->same_retained) {
        s->same_retained = pointSize((AXUIElementRef)*held, &fromHeld) && same(fromHeld, sample.cg);
        s->ax = ncg_measure_frame(fromHeld);
    }
}
int32_t ncg_observe_retained(int32_t pid, uint64_t start, uint32_t window, CFStringRef executable,
                             CFStringRef cdhash, uint64_t native, CFStringRef display, CFStringRef space,
                             CFTypeRef original, NPGuardianFixtureObservation *out) {
    @autoreleasepool {
        if (out->size != sizeof(*out) || out->version != 1)
            return 1;
        *out = (NPGuardianFixtureObservation){.size = sizeof(*out), .version = 1};
        NSString *path = (__bridge NSString *)executable, *hash = (__bridge NSString *)cdhash;
        if (pid <= 1 || pid == getpid() || !start || !window || ![path hasPrefix:@"/"] ||
            path.length >= PATH_MAX || (hash.length != 40 && hash.length != 64))
            return 1;
        NCMember m = {.pid = pid, .birth = start, .window = window, .native = native};
        NSUUID *d = nc_uuid((__bridge id)display), *sp = nc_uuid((__bridge id)space);
        BOOL hasScope = native > 0 && d && sp;
        [d getUUIDBytes:m.display];
        [sp getUUIDBytes:m.space];
        void *held = original ? (void *)CFRetain(original) : NULL;
        ncg_fixture_read(&out->first, &m, path, hash, hasScope, &held, original == NULL);
        if (out->first.signature) {
            usleep(25000);
            ncg_fixture_read(&out->second, &m, path, hash, hasScope, &held, NO);
        }
        out->held_in_caller = held != NULL;
        if (held) {
            np_corner_release_window(held);
            out->released = 1;
        }
        out->signatures_closed =
            out->first.signature && out->second.signature && ncg_registered_fixture(&m, path, hash);
        if (!out->signatures_closed) {
            out->first.cg = (NPGuardianRect){0};
            out->second.cg = (NPGuardianRect){0};
            out->first.ax = (NPGuardianRect){0};
            out->second.ax = (NPGuardianRect){0};
            return 2;
        }
        NPGuardianRect a = out->first.cg, b = out->second.cg;
        out->same_geometry =
            out->first.same_retained && out->second.same_retained &&
            same((NCFrame){a.x, a.y, a.width, a.height}, (NCFrame){b.x, b.y, b.width, b.height});
        return 0;
    }
}

int32_t np_guardian_observe_fixture(int32_t pid, uint64_t start, uint32_t window, CFStringRef executable,
                                    CFStringRef cdhash, uint64_t native, CFStringRef display, CFStringRef space,
                                    NPGuardianFixtureObservation *out) {
    return ncg_observe_retained(pid, start, window, executable, cdhash, native, display, space, NULL, out);
}
