// Isolated acceptance state survives a Host/process/OS restart. No preferences,
// ordinary Host data, foreign window title, or foreign window number is
// persisted.
#import <pwd.h>
static NSString *const activeLedgerName = @"active.jsonl";
static BOOL privateParent(int fd) {
  struct stat st = {0};
  return fd >= 0 && fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) &&
         st.st_uid == getuid() && !(st.st_mode & 0022);
}
static int ledgerBase(void) {
#ifdef NP_OFFLINE_JOURNAL_TEST
  extern const char *np_offline_journal_root;
  return open(np_offline_journal_root,
              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
#else
  struct passwd entry = {0}, *result = NULL;
  char scratch[8192], canonical[PATH_MAX];
  if (getpwuid_r(getuid(), &entry, scratch, sizeof(scratch), &result) != 0 ||
      !result || !entry.pw_dir || !realpath(entry.pw_dir, canonical) ||
      strcmp(canonical, entry.pw_dir) != 0) {
    errno = EPERM;
    return -1;
  }
  int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
  int fd = open(canonical, flags);
  for (NSString *name in @[ @"Library", @"Application Support" ]) {
    if (!privateParent(fd)) {
      if (fd >= 0)
        close(fd);
      errno = EPERM;
      return -1;
    }
    int next = openat(fd, name.fileSystemRepresentation, flags), err = errno;
    close(fd);
    fd = next;
    errno = err;
  }
  return fd;
#endif
}
static int receiptRoot(BOOL create) {
  int base = ledgerBase();
  if (base < 0)
    return -1;
  const char *name = "Nearpane-Spaces-Verification";
  if (!privateParent(base)) {
    close(base);
    errno = EPERM;
    return -1;
  }
  if (create && mkdirat(base, name, 0700) != 0 && errno != EEXIST) {
    int err = errno;
    close(base);
    errno = err;
    return -1;
  }
  int dir = openat(base, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
      err = errno;
  if (create && dir >= 0 && fsync(base) != 0) {
    err = errno;
    close(dir);
    dir = -1;
  }
  close(base);
  if (dir >= 0) {
    struct stat row = {0};
    if (fstat(dir, &row) != 0 || row.st_uid != getuid() ||
        !S_ISDIR(row.st_mode) || (row.st_mode & 0777) != 0700) {
      close(dir);
      errno = EPERM;
      return -1;
    }
  } else
    errno = err;
  return dir;
}
static int installedLedgerPrior(void) {
  int dir = receiptRoot(NO);
  if (dir < 0)
    return errno == ENOENT ? 0 : -1;
  struct stat st = {0};
  int found = fstatat(dir, activeLedgerName.fileSystemRepresentation, &st,
                      AT_SYMLINK_NOFOLLOW);
  int err = errno;
  close(dir);
  return found == 0 ? 1 : err == ENOENT ? 0 : -1;
}
static BOOL currentLedger(NPInstalledFixture *s) {
  struct stat a = {0}, b = {0};
  return s->ledger >= 0 && s->ledgerDir >= 0 && fstat(s->ledger, &a) == 0 &&
         S_ISREG(a.st_mode) && a.st_uid == getuid() &&
         (a.st_mode & 0777) == 0600 && a.st_nlink >= 1 && a.st_nlink <= 2 &&
         a.st_size <= 65536 &&
         fstatat(s->ledgerDir, activeLedgerName.fileSystemRepresentation, &b,
                 AT_SYMLINK_NOFOLLOW) == 0 &&
         a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
static BOOL appendLedger(NPInstalledFixture *s, NSDictionary *row) {
  if (!currentLedger(s))
    return NO;
  NSMutableDictionary *event = [row mutableCopy];
  event[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
  NSData *json = [NSJSONSerialization dataWithJSONObject:event
                                                 options:NSJSONWritingSortedKeys
                                                   error:NULL];
  if (!json || json.length > 32768)
    return NO;
  NSMutableData *line = [json mutableCopy];
  [line appendBytes:"\n" length:1];
  const char *bytes = line.bytes;
  size_t left = line.length;
  while (left) {
    ssize_t n = write(s->ledger, bytes, left);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return NO;
    bytes += n;
    left -= (size_t)n;
  }
  return fsync(s->ledger) == 0 && fcntl(s->ledger, F_FULLFSYNC) == 0;
}
uint32_t np_stage_fixture_first_journal(void *token, const NPStageDesktop *top,
                                        size_t nt, const uint64_t *all,
                                        size_t na, uint64_t home,
                                        const double frame[4],
                                        size_t homeMembers) {
  @autoreleasepool {
    @try {
      if (!token || !top || nt < 1 || nt > 512 || !all || na < 1 || na > 1024 ||
          !home || !frame)
        return 19;
      NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
      if (s->ledger >= 0 || s->ledgerDir >= 0)
        return 18;
      s->ledgerDir = receiptRoot(YES);
      if (s->ledgerDir < 0)
        return 19;
      NSString *archived = [s->challenge stringByAppendingString:@".jsonl"];
      struct stat past;
      if (fstatat(s->ledgerDir, archived.fileSystemRepresentation, &past,
                  AT_SYMLINK_NOFOLLOW) == 0 ||
          errno != ENOENT)
        return 18;
      s->ledger = openat(
          s->ledgerDir, activeLedgerName.fileSystemRepresentation,
          O_EXCL | O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
          0600);
      if (s->ledger < 0)
        return errno == EEXIST ? 18 : 19;
      NSMutableArray *spaces = [NSMutableArray arrayWithCapacity:na],
                     *topology = [NSMutableArray arrayWithCapacity:nt];
      for (size_t i = 0; i < na; i++)
        [spaces addObject:@(all[i])];
      for (size_t i = 0; i < nt; i++)
        [topology addObject:@{
          @"display" : [[NSUUID alloc] initWithUUIDBytes:top[i].display]
              .UUIDString,
          @"uuid" : [[NSUUID alloc] initWithUUIDBytes:top[i].uuid].UUIDString,
          @"id" : @(top[i].id),
          @"type" : @(top[i].kind),
          @"current" : @(top[i].current)
        }];
      NSString *boot = nil;
      char bootBytes[64] = {0};
      size_t capacity = sizeof(bootBytes);
      if (sysctlbyname("kern.bootsessionuuid", bootBytes, &capacity, NULL, 0) ==
          0)
        boot = @(bootBytes);
      if (!boot || ![[NSUUID alloc] initWithUUIDString:boot])
        return 19;
      NSDictionary *row = @{
        @"schema" : @1,
        @"event" : @"enrolledBeforeAnySystemWrite",
        @"challenge" : s->challenge,
        @"boot" : boot,
        @"hostPID" : @(getpid()),
        @"hostBirth" : @(birth(getpid())),
        @"fixturePID" : @(s->subject.pid),
        @"fixtureBirth" : @(s->subject.birth),
        @"fixtureWindow" : @(s->subject.window),
        @"fixtureCDHash" : enrolledFixtureCDHash,
        @"route" : @"bridge",
        @"home" : @(home),
        @"ordinaryMemberCount" : @(homeMembers),
        @"scope" : topology,
        @"spaceInventory" : spaces,
        @"frame" : @[ @(frame[0]), @(frame[1]), @(frame[2]), @(frame[3]) ],
        @"externalFocusAndHIDBound" : @YES
      };
      return appendLedger(s, row) && fsync(s->ledgerDir) == 0 ? 0 : 19;
    } @catch (NSException *e) {
      return 19;
    }
  }
}
uint32_t np_stage_fixture_journal(void *token, uint32_t event,
                                  uint32_t external, uint32_t number,
                                  uint64_t space, int32_t response) {
  @autoreleasepool {
    @try {
      if (!token || external > 1)
        return 19;
      NSArray *names = @[
        @"willCreateSpace", @"willHideWindow", @"willReturnWindow",
        @"willDestroySpace", @"createdSpaceResponse", @"hideResponse",
        @"returnResponse", @"destroyResponse", @"willOpenCanary",
        @"openedCanaryResponse", @"willCloseCanary", @"closedCanaryResponse",
        @"twoMembershipReads", @"canaryFullyRecovered",
        @"fixtureFullyRecovered", @"terminalRetained", @"terminalClean"
      ];
      if (event >= names.count)
        return 19;
      NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
      return appendLedger(
                 s, @{
                   @"event" : names[event],
                   @"owner" : external ? @"signedOrdinaryFixture"
                                       : @"installedHostCanary",
                   @"window" : @(number),
                   @"space" : @(space),
                   @"response" : @(response)
                 })
                 ? 0
                 : 19;
    } @catch (NSException *e) {
      return 19;
    }
  }
}
uint32_t np_stage_fixture_finish_journal(void *token, uint32_t clean) {
  @autoreleasepool {
    @try {
      if (!token)
        return 19;
      NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
      if (s->ledger < 0)
        return 0;
      if (np_stage_fixture_journal(token, clean ? 16 : 15, 0, 0, 0, clean) !=
              0 ||
          !currentLedger(s))
        return 19;
      if (!clean)
        return 0;
      NSString *name = [s->challenge stringByAppendingString:@".jsonl"];
      // Keep an inode-identical permanent archive. Any error leaves the global
      // interlock, including a crash between link and unlink, for human
      // reconciliation.
      if (linkat(s->ledgerDir, activeLedgerName.fileSystemRepresentation,
                 s->ledgerDir, name.fileSystemRepresentation, 0) != 0 ||
          fsync(s->ledgerDir) != 0 || !currentLedger(s))
        return 19;
      struct stat h = {0}, original = {0};
      if (fstat(s->ledger, &original) != 0 ||
          fstatat(s->ledgerDir, name.fileSystemRepresentation, &h,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
          h.st_dev != original.st_dev || h.st_ino != original.st_ino ||
          h.st_nlink != 2)
        return 19;
      if (unlinkat(s->ledgerDir, activeLedgerName.fileSystemRepresentation,
                   0) != 0 ||
          fsync(s->ledgerDir) != 0)
        return 19;
      return 0;
    } @catch (NSException *e) {
      return 19;
    }
  }
}
