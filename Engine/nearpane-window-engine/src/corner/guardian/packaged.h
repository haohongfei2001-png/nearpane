// This file is compiled into the installed helper only. The fixture executable has a distinct build and identity.
#include <arpa/inet.h>
#include <sys/file.h>
static NSString *const hostExe = @"/Applications/Nearpane.app/Contents/MacOS/NearpaneHost";
static NSString *const guardianExe = @"/Applications/Nearpane.app/Contents/Helpers/NearpaneCornerGuardian";
static NSData *signedProduct(pid_t pid, NSString *path, NSString *ident) {
    return ncg_rule_hash(
        pid, path,
        [NSString
            stringWithFormat:
                @"anchor apple generic and identifier \"%@\" and certificate 1[field.1.2.840.113635.100.6.2.6] "
                @"exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate "
                @"leaf[subject.OU] = \"ZB9D4T66QB\"",
                ident]);
}
static BOOL safeFile(int fd, BOOL dir) {
    struct stat s;
    return fstat(fd, &s) == 0 && s.st_uid == getuid() && !(s.st_mode & 022) &&
           (dir ? S_ISDIR(s.st_mode) : (S_ISREG(s.st_mode) && s.st_nlink == 1));
}
static NSDictionary *productFile(int dir, const char *name) {
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat start = {}, end = {}, live = {};
    if (!safeFile(fd, NO) || fstat(fd, &start) || start.st_size < 2 || start.st_size > 4 * 1024 * 1024) {
        if (fd >= 0)
            close(fd);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)start.st_size];
    BOOL ok = pread(fd, data.mutableBytes, data.length, 0) == (ssize_t)data.length && !fstat(fd, &end) &&
              !fstatat(dir, name, &live, AT_SYMLINK_NOFOLLOW) && start.st_dev == live.st_dev &&
              start.st_ino == live.st_ino && start.st_size == end.st_size &&
              start.st_mtimespec.tv_sec == end.st_mtimespec.tv_sec &&
              start.st_mtimespec.tv_nsec == end.st_mtimespec.tv_nsec;
    close(fd);
    id json = ok ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}
static BOOL number(id n) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n) != CFBooleanGetTypeID();
}
static BOOL uuidField(id x, const uint8_t expected[16]) {
    if (![x isKindOfClass:NSString.class])
        return NO;
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:x];
    uint8_t bytes[16];
    if (!u)
        return NO;
    [u getUUIDBytes:bytes];
    return !memcmp(bytes, expected, 16);
}
static BOOL decodeUUID(id x, uint8_t dest[16]) {
    if (![x isKindOfClass:NSString.class])
        return NO;
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:x];
    if (!u)
        return NO;
    [u getUUIDBytes:dest];
    uint8_t zero[16] = {0};
    return !!memcmp(dest, zero, 16);
}
static BOOL productFrame(id raw, NPRect *out) {
    NSArray *a = raw;
    if ([raw isKindOfClass:NSDictionary.class]) {
        for (NSString *k in @[ @"x", @"y", @"width", @"height" ])
            if (!number(raw[k]))
                return NO;
        a = @[ raw[@"x"], raw[@"y"], raw[@"width"], raw[@"height"] ];
    }
    if (![a isKindOfClass:NSArray.class] || a.count != 4)
        return NO;
    double v[4];
    for (unsigned i = 0; i < 4; i++) {
        if (!number(a[i]) || !isfinite((v[i] = [a[i] doubleValue])))
            return NO;
    }
    if (v[2] <= 0 || v[3] <= 0)
        return NO;
    *out = (NPRect){v[0], v[1], v[2], v[3]};
    return YES;
}
static BOOL sameWindow(NSDictionary *w, const NPRequest *r) {
    return [w isKindOfClass:NSDictionary.class] && number(w[@"pid"]) && number(w[@"number"]) &&
           number(w[@"birth"]) && [w[@"pid"] isEqual:@(r->pid)] && [w[@"number"] isEqual:@(r->window)] &&
           [w[@"birth"] isEqual:@(r->birth)];
}
static BOOL journalState(NSDictionary *s, const NPRequest *r, NSString *visibility, NPRect frame) {
    NPRect found;
    return [s isKindOfClass:NSDictionary.class] && sameWindow(s[@"window"], r) &&
           uuidField(s[@"lifetime"], r->lifetime) && [s[@"visibility"] isEqual:visibility] &&
           productFrame(s[@"frame"], &found) && closeFrame(convert(frame), convert(found));
}
static BOOL productScope(NSDictionary *scope, const NPRequest *r) {
    return [scope isKindOfClass:NSDictionary.class] && uuidField(scope[@"display"], r->display) &&
           uuidField(scope[@"nativeSpace"], r->native_space);
}
static BOOL activeProfile(Session *s) {
    struct stat lockFile = {}, actualLock = {}, generationProfile = {}, heldProfile = {};
    if (fstat(s->writer, &lockFile) || fstatat(s->root, "writer.lock", &actualLock, AT_SYMLINK_NOFOLLOW) ||
        lockFile.st_dev != actualLock.st_dev || lockFile.st_ino != actualLock.st_ino)
        return NO;
    int generations = openat(s->root, "generations", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int generation = openat(generations, [(__bridge NSString *)s->profileID fileSystemRepresentation],
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    BOOL present = generations >= 0 && generation >= 0 &&
                   !fstatat(generation, "Nearpane", &generationProfile, AT_SYMLINK_NOFOLLOW) &&
                   !fstat(s->profile, &heldProfile) && heldProfile.st_dev == generationProfile.st_dev &&
                   heldProfile.st_ino == generationProfile.st_ino;
    if (generation >= 0)
        close(generation);
    if (generations >= 0)
        close(generations);
    if (!present)
        return NO;
    NSDictionary *index = productFile(s->root, "profile-index.json");
    struct stat st;
    if (fstatat(s->root, "transaction.json", &st, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT)
        return NO;
    return [index[@"format"] isEqual:@1] && [index[@"active"] isEqual:(__bridge NSString *)s->profileID] &&
           [index[@"imports"] isKindOfClass:NSDictionary.class];
}
static BOOL productOpen(Session *s, NSString *folder) {
    char resolved[PATH_MAX];
    if (!realpath(folder.fileSystemRepresentation, resolved))
        return NO;
    NSString *path = [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved
                                                                               length:strlen(resolved)];
    NSString *jobs = path.stringByDeletingLastPathComponent, *profile = jobs.stringByDeletingLastPathComponent,
             *generation = profile.stringByDeletingLastPathComponent,
             *all = generation.stringByDeletingLastPathComponent, *root = all.stringByDeletingLastPathComponent;
    if (![[NSUUID alloc] initWithUUIDString:path.lastPathComponent] ||
        ![jobs.lastPathComponent isEqual:@".corner-guardians"] ||
        ![profile.lastPathComponent isEqual:@"Nearpane"] ||
        ![[NSUUID alloc] initWithUUIDString:generation.lastPathComponent] ||
        ![all.lastPathComponent isEqual:@"generations"] ||
        ![root.lastPathComponent isEqual:@"Nearpane Alpha Profiles"])
        return NO;
    s->profile = open(profile.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    s->root = open(root.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    s->writer = openat(s->root, "writer.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    int jobRoot = openat(s->profile, ".corner-guardians", O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    s->serializer = openat(jobRoot, "restore.lock", O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0600);
    BOOL validJobs = fileOK(jobRoot, YES) && fileOK(s->serializer, NO);
    if (jobRoot >= 0)
        close(jobRoot);
    if (!validJobs)
        return NO;
    s->profileID = (__bridge_retained void *)generation.lastPathComponent;
    if (!safeFile(s->profile, YES) || !safeFile(s->root, YES) || !safeFile(s->writer, NO) || !activeProfile(s))
        return NO;
    if (flock(s->writer, LOCK_EX | LOCK_NB) == 0) {
        flock(s->writer, LOCK_UN);
        return NO;
    }
    return errno == EWOULDBLOCK;
}
static BOOL productDirectory(Session *s) {
    NPRequest *r = &s->pre.lease;
    NSDictionary *directory = productFile(s->profile, "stage-groups-v2.json");
    if (![directory[@"version"] isEqual:@2])
        return NO;
    unsigned hits = 0;
    for (NSDictionary *d in directory[@"displays"])
        if (uuidField(d[@"id"], r->display)) {
            for (NSDictionary *g in d[@"groups"])
                if (uuidField(g[@"id"], r->group) && uuidField(g[@"nativeSpace"], r->native_space)) {
                    for (NSDictionary *m in g[@"members"])
                        if (uuidField(m[@"id"], r->member) && sameWindow(m[@"windowHint"], r))
                            hits++;
                }
        }
    return hits == 1;
}
static BOOL productJournalContents(Session *s, NSDictionary *l, BOOL confirmed, BOOL released) {
    if (!activeProfile(s))
        return NO;
    const NPRequest *r = &s->pre.lease;
    NSDictionary *owner = l[@"owner"], *p = l[@"pending"];
    if (![l[@"version"] isEqual:@1] || ![owner isKindOfClass:NSDictionary.class] ||
        ![owner[@"backend"] isEqual:@"corner"] || !uuidField(owner[@"generation"], r->generation) ||
        ![owner[@"environment"][@"sipEnabled"] isEqual:@YES] ||
        ![owner[@"environment"][@"hostCDHash"] isEqual:s->hostHash] || ![l[@"owned"] isKindOfClass:NSArray.class])
        return NO;
    uint8_t evidence[16];
    if (!decodeUUID(owner[@"evidence"], evidence) || !np_engine_evidence_is_reviewed(NP_CORNER, evidence))
        return NO;
    if (s->stamp && ![s->stamp isEqual:owner])
        return NO;
    unsigned pending = 0, owned = 0;
    if (p) {
        if (![p isKindOfClass:NSDictionary.class] || ![p[@"owner"] isEqual:owner] ||
            ![p[@"entries"] isKindOfClass:NSArray.class])
            return NO;
        for (NSDictionary *e in p[@"entries"])
            if (sameWindow(e[@"before"][@"window"], r)) {
                BOOL sameIntent = uuidField(e[@"intent"], r->intent);
                if (!released && sameIntent && [e[@"action"][@"hide"] isKindOfClass:NSDictionary.class] &&
                    journalState(e[@"before"], r, @"visible", r->frame) &&
                    uuidField(p[@"generation"], r->generation) && [p[@"nativeID"] isEqual:@(r->native_id)] &&
                    productScope(p[@"scope"], r) &&
                    (!confirmed || journalState(e[@"after"], r, @"parked", s->sealed.result.frame)))
                    pending++;
                else if (!released || !e[@"after"])
                    return NO;
            }
    }
    for (NSDictionary *o in l[@"owned"])
        if (sameWindow(o[@"hidden"][@"window"], r)) {
            if (![o[@"owner"] isEqual:owner] || !uuidField(o[@"group"], r->group) ||
                !uuidField(o[@"member"], r->member) || !productScope(o[@"scope"], r) ||
                ![o[@"nativeID"] isEqual:@(r->native_id)] ||
                !journalState(o[@"original"], r, @"visible", r->frame) ||
                !journalState(o[@"hidden"], r, @"parked", s->sealed.result.frame))
                return NO;
            owned++;
        }
    for (NSDictionary *release in l[@"releases"])
        if (sameWindow(release[@"owned"][@"hidden"][@"window"], r))
            return NO;
    if (released)
        return owned == 0;
    if (!confirmed)
        return pending == 1 && owned == 0 && productDirectory(s);
    return owned == 1 && pending <= 1;
}
static BOOL productJournal(Session *s, BOOL confirmed, BOOL released) {
    return productJournalContents(s, productFile(s->profile, "stage-visibility-v1.json"), confirmed, released);
}

// A withdrawal applies only to the last prepared, unconfirmed primitive. This helper never edits that WAL.
static NSDictionary *withdrawableJournal(Session *s) {
    NSDictionary *l = productFile(s->profile, "stage-visibility-v1.json");
    if (!productJournalContents(s, l, NO, NO) || [l[@"releases"] count]) return nil;
    NSDictionary *p = l[@"pending"], *last = [p[@"entries"] lastObject];
    uint8_t transaction[16];
    if (!decodeUUID(p[@"intent"], transaction) || memcmp(transaction, s->preparedTransaction, 16) ||
        !uuidField(last[@"intent"], s->pre.lease.intent) ||
        !sameWindow(last[@"before"][@"window"], &s->pre.lease) || ![last[@"action"] isEqual:@{@"hide": @{}}] ||
        last[@"after"] || last[@"undoIntent"] || last[@"guardianPending"]) return nil;
    return l;
}
static BOOL withdrawalMessage(Session *s, NSDictionary *m) {
    return [m[@"phase"] isEqual:@"withdrawUnsubmitted"] && uuidField(m[@"intent"], s->pre.lease.intent) &&
           number(m[@"epoch"]) && [m[@"epoch"] isEqual:@(s->pre.lease.epoch)];
}
static BOOL withdrawalWitness(Session *s, NSDictionary *expected) {
    uint8_t digest[32] = {0};
    return expected && s->held && s->facts.retained_before_park && !s->facts.parked_confirmed &&
           getppid() == s->pre.host && ncg_birth(getppid(), NULL) == s->pre.host_birth &&
           [s->hostDigest isEqual:signedProduct(getppid(), hostExe, @"com.holdsnow.nearpane.alpha")] &&
           np_corner_signed_fingerprint(s->member.pid, s->member.birth, digest) &&
           [s->hash isEqual:[NSData dataWithBytes:digest length:sizeof(digest)]] &&
           [expected isEqual:withdrawableJournal(s)] && displayIs(s) && stable(s, convert(s->pre.lease.frame)) &&
           np_corner_same_window(&s->member, s->held);
}
static NSDictionary *productMessage(void) {
    uint32_t size = 0;
    if (!readPacket(STDIN_FILENO, &size, sizeof(size)))
        return nil;
    size = ntohl(size);
    if (size < 2 || size > 8000)
        return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!readPacket(STDIN_FILENO, data.mutableBytes, size))
        return nil;
    id m = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [m isKindOfClass:NSDictionary.class] ? m : nil;
}
static BOOL productPrepare(Session *s, NSDictionary *m, NSString *folder) {
    NCGuardianEntry *p = &s->pre;
    NPRequest *r = &p->lease;
    p->version = 1;
    p->phase = NCG_PREPARE;
    p->host = getppid();
    p->host_birth = ncg_birth(p->host, NULL);
    r->size = sizeof(*r);
    r->version = 1;
    r->backend = NP_CORNER;
    r->operation = NP_HIDE;
    if (![m[@"phase"] isEqual:@"prepare"] || !productFrame(m[@"frame"], &r->frame) ||
        !decodeUUID(m[@"intent"], r->intent) || !uuidField(folder.lastPathComponent, r->intent) ||
        !decodeUUID(m[@"group"], r->group) || !decodeUUID(m[@"member"], r->member) ||
        !decodeUUID(m[@"lifetime"], r->lifetime) || !decodeUUID(m[@"generation"], r->generation) ||
        !decodeUUID(m[@"space"], r->native_space) || !decodeUUID(m[@"display"], r->display))
        return NO;
    for (NSString *key in @[ @"epoch", @"native", @"pid", @"number", @"birth" ])
        if (!number(m[key]) || [m[key] unsignedLongLongValue] == 0)
            return NO;
    r->epoch = [m[@"epoch"] unsignedLongLongValue];
    r->native_id = [m[@"native"] unsignedLongLongValue];
    r->pid = [m[@"pid"] intValue];
    r->window = [m[@"number"] unsignedIntValue];
    r->birth = [m[@"birth"] unsignedLongLongValue];
    r->target = r->frame;
    np_corner_inputs(p->hid);
    return productJournal(s, NO, NO);
}
static BOOL productSeal(Session *s, NSDictionary *m) {
    s->sealed = s->pre;
    s->sealed.phase = NCG_CONFIRMED;
    NPReceipt *r = &s->sealed.result;
    NPRect independently;
    r->size = sizeof(*r);
    r->version = 1;
    if (![m[@"phase"] isEqual:@"confirm"] || !decodeUUID(m[@"intent"], r->intent) ||
        !productFrame(m[@"frame"], &r->frame) || !productFrame(m[@"verified"], &independently) ||
        !closeFrame(convert(r->frame), convert(independently)))
        return NO;
    for (NSString *key in @[ @"status", @"flags", @"epoch", @"native", @"owned" ])
        if (!number(m[key]))
            return NO;
    r->epoch = [m[@"epoch"] unsignedLongLongValue];
    r->native_id = [m[@"native"] unsignedLongLongValue];
    r->flags = [m[@"flags"] unsignedIntValue];
    r->status = [m[@"status"] unsignedIntValue];
    r->owned = [m[@"owned"] unsignedIntValue];
    np_corner_inputs(s->sealed.hid);
    return r->owned > 0 && ncg_correlates(&s->pre, &s->sealed) && productJournal(s, YES, NO);
}

// After a genuine Host exit the active profile stays protected by its writer lock and our
// exclusive recovery mutex. Resolve only this exact, fully committed primitive. An interrupted
// batch remains available to the coordinator for a full independent reconciliation.
static NSDictionary *ledgerAfterRemovingOnlyThisMember(NSDictionary *old, const NPRequest *r) {
    if (![old isKindOfClass:NSDictionary.class] || old[@"pending"] || [old[@"releases"] count] ||
        ![old[@"owned"] isKindOfClass:NSArray.class])
        return nil;
    NSMutableArray *remain = [NSMutableArray array];
    for (NSDictionary *o in old[@"owned"])
        if (!sameWindow(o[@"hidden"][@"window"], r))
            [remain addObject:o];
    if (remain.count + 1 != [old[@"owned"] count])
        return nil;
    NSMutableDictionary *new = [ old mutableCopy ];
    new[@"owned"] = remain;
    return new;
}
static NSString *settleCommitted(Session *s) {
    if (!s->serializedRecovery || !s->facts.kernel_parent_exit || !s->facts.parent_generation_gone ||
        !s->facts.lifetime_exact || s->facts.unspent || !activeProfile(s))
        return @"ownershipRetained";
    NSDictionary *old = productFile(s->profile, "stage-visibility-v1.json");
    if (!old || old[@"pending"] || [old[@"releases"] count])
        return @"interruptedBatchRetained";
    if (!productJournal(s, YES, NO))
        return @"ownershipChanged";
    const NPRequest *r = &s->pre.lease;
    NSDictionary *new = ledgerAfterRemovingOnlyThisMember(old, r);
    if (!new)
        return @"ownershipChanged";
    NSData *data = [NSJSONSerialization dataWithJSONObject:new options:NSJSONWritingSortedKeys error:NULL];
    if (!data || data.length > 4 * 1024 * 1024)
        return @"couldNotEncodeOwnedRemoval";
    NSString *name = [@".guardian-txn-" stringByAppendingString:NSUUID.UUID.UUIDString];
    const char *temporary = name.fileSystemRepresentation;
    int fd = openat(s->profile, temporary, O_EXCL | O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0)
        return @"couldNotPrepareOwnedRemoval";
    BOOL ok = write(fd, data.bytes, data.length) == (ssize_t)data.length && !fsync(fd);
    close(fd);
    uint32_t hid[13];
    np_corner_inputs(hid);
    if (ok)
        ok = !memcmp(hid, s->takeoverInput, sizeof(hid)) && displayIs(s) && stable(s, convert(r->frame)) &&
             activeProfile(s) && [old isEqual:productFile(s->profile, "stage-visibility-v1.json")];
    if (ok)
        ok = renameat(s->profile, temporary, s->profile, "stage-visibility-v1.json") == 0;
    if (!ok) {
        unlinkat(s->profile, temporary, 0);
        return @"ownershipChangedOrRemovalUnconfirmed";
    }
    if (fsync(s->profile) || ![new isEqual:productFile(s->profile, "stage-visibility-v1.json")])
        return @"removedButPersistenceUnconfirmed";
    return @"exactCommittedOwnershipRemoved";
}
