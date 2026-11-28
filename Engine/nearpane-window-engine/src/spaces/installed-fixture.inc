// Installed diagnostic admission only. No actor-supplied process, Space or
// window is a parameter, and no TCC request or system write exists in this
// file.
#import <fcntl.h>
#import <sys/stat.h>
#import "../input_state.h"

// Compiled from the separately shipped test source; a re-sign/rebuild requires
// review.
static NSString *const enrolledFixtureCDHash =
    @"d13992d0ce5f73ce8c7ad8b019a0ecec39c5bd37";
static const CGEventType installedHIDTypes[] = {
    kCGEventKeyDown,           kCGEventKeyUp,
    kCGEventFlagsChanged,      kCGEventScrollWheel,
    kCGEventMouseMoved,        kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,       kCGEventRightMouseDown,
    kCGEventRightMouseUp,      kCGEventOtherMouseDown,
    kCGEventOtherMouseUp,      kCGEventLeftMouseDragged,
    kCGEventRightMouseDragged, kCGEventOtherMouseDragged};
enum { hidCount = sizeof(installedHIDTypes) / sizeof(installedHIDTypes[0]) };
typedef struct {
  int32_t pid;
  uint32_t window;
  uint64_t birth;
} NPInstalledSubject;
@interface NPInstalledFixture : NSObject {
@public
  NPInstalledSubject subject;
  int channel, owner;
  BOOL panelOnly, interactive;
  uint64_t interactiveHome;
  NSString *expectedID, *expectedHash;
  NSArray<NPInstalledFixture *> *protectedWindows;
  NSString *executable;
  pid_t front;
  uint64_t frontBirth;
  uint32_t frontWindow;
  AXUIElementRef frontDesktopFocus;
  uint32_t counters[hidCount];
  SecuritySessionId session;
  AXUIElementRef document;
  CGRect geometry;
  double expires;
  CGDirectDisplayID display;
  NSString *challenge;
  int ledgerDir, ledger;
}
@end
@implementation NPInstalledFixture
- (instancetype)init {
  if ((self = [super init])) {
    channel = -1;
    owner = -1;
    ledgerDir = -1;
    ledger = -1;
  }
  return self;
}
- (void)dealloc {
  if (frontDesktopFocus)
    CFRelease(frontDesktopFocus);
  if (document)
    CFRelease(document);
  if (channel >= 0)
    close(channel);
  if (owner >= 0)
    close(owner);
  if (ledger >= 0)
    close(ledger);
  if (ledgerDir >= 0)
    close(ledgerDir);
}
@end
#include "installed-journal.inc"

static int privateFixtureDirectory(NSString *path) {
  int fd = open(path.fileSystemRepresentation,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat s = {0};
  if (fd >= 0 && fstat(fd, &s) == 0 && S_ISDIR(s.st_mode) &&
      s.st_uid == getuid() && (s.st_mode & 0777) == 0700)
    return fd;
  if (fd >= 0)
    close(fd);
  return -1;
}
static NSDictionary *fixtureDocument(int dir, const char *file) {
  int fd = openat(dir, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0)
    return nil;
  struct stat st = {0};
  uint8_t bytes[4097];
  BOOL ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
            st.st_uid == getuid() && (st.st_mode & 0777) == 0600 &&
            st.st_size > 0 && st.st_size < sizeof(bytes);
  ssize_t n = ok ? read(fd, bytes, sizeof(bytes)) : -1;
  char extra;
  ok = ok && n == st.st_size && read(fd, &extra, 1) == 0;
  close(fd);
  if (!ok)
    return nil;
  id obj = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)n]
                 options:0
                   error:NULL];
  return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}
static BOOL fileAbsent(int dir, const char *name) {
  struct stat st;
  return fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT;
}
static BOOL fixtureFlag(id value, BOOL yes) {
  return [value isKindOfClass:NSNumber.class] &&
         ([value isEqual:@(yes)] && ([value isEqual:@0] || [value isEqual:@1]));
}
static BOOL fixtureBoolFields(NSDictionary *owner) {
  for (NSString *key in @[
         @"regularApplication", @"ordinaryWindow", @"visible", @"onActiveSpace",
         @"sameFront", @"ignoresMouseEvents"
       ])
    if (!fixtureFlag(owner[key], YES))
      return NO;
  for (NSString *key in @[ @"active", @"key", @"main" ])
    if (!fixtureFlag(owner[key], NO))
      return NO;
  return [owner[@"alpha"] isKindOfClass:NSNumber.class] &&
         [owner[@"alpha"] isEqual:@0];
}
static BOOL fixtureUptime(id value, double *out) {
  if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFNumberGetTypeID())
    return NO;
  *out = [value doubleValue];
  return isfinite(*out) && *out > 0;
}
static BOOL sessionReady(SecuritySessionId *out) {
  SecuritySessionId sid = 0;
  NSDictionary *s = CFBridgingRelease(CGSessionCopyCurrentDictionary());
  uint64_t user = 0;
  if (SessionGetInfo(callerSecuritySession, &sid, NULL) != errSecSuccess ||
      !sid ||
      !exactNumber(s[(__bridge NSString *)kCGSessionUserIDKey], &user, NO) ||
      user != getuid() ||
      !fixtureFlag(s[(__bridge NSString *)kCGSessionOnConsoleKey], YES) ||
      !fixtureFlag(s[(__bridge NSString *)kCGSessionLoginDoneKey], YES) ||
      (s[@"CGSSessionScreenIsLocked"] &&
       !fixtureFlag(s[@"CGSSessionScreenIsLocked"], NO)))
    return NO;
  *out = sid;
  return YES;
}
static BOOL sameDisplay(CGDirectDisplayID *out) {
  uint32_t n = 0;
  CGDirectDisplayID only = 0;
  if (CGGetActiveDisplayList(0, NULL, &n) != kCGErrorSuccess || n != 1 ||
      CGGetActiveDisplayList(1, &only, &n) != kCGErrorSuccess || n != 1 ||
      !only || only != CGMainDisplayID() || !CGDisplayIsActive(only) ||
      !CGDisplayIsOnline(only) ||
      CGDisplayMirrorsDisplay(only) != kCGNullDirectDisplay)
    return NO;
  *out = only;
  return YES;
}
static BOOL fixtureImagePath(NPInstalledFixture *s) {
  char raw[PROC_PIDPATHINFO_MAXSIZE], kernel[PATH_MAX], bundlePath[PATH_MAX];
  NSRunningApplication *app = [NSRunningApplication
      runningApplicationWithProcessIdentifier:s->subject.pid];
  if (birth(s->subject.pid) != s->subject.birth || !app || app.terminated ||
      (app.active && ![s->expectedID isEqual:@"com.holdsnow.nearpane.stage-interactive-bystander"]) ||
      app.activationPolicy != NSApplicationActivationPolicyRegular ||
      ![app.bundleIdentifier
          isEqual:(s->expectedID ?: @"com.holdsnow.nearpane.engine-fixture.a")] ||
      !app.executableURL ||
      !realpath(app.executableURL.fileSystemRepresentation, bundlePath) ||
      proc_pidpath(s->subject.pid, raw, sizeof(raw)) <= 0 ||
      !realpath(raw, kernel) || strcmp(kernel, bundlePath) ||
      strcmp(kernel, s->executable.fileSystemRepresentation))
    return NO;
  return YES;
}
static BOOL signedFixture(NPInstalledFixture *s) {
  if (!fixtureImagePath(s))
    return NO;
  SecCodeRef guest = NULL;
  SecStaticCodeRef disk = NULL, running = NULL;
  SecRequirementRef rule = NULL;
  NSURL *url =
      [[[[NSURL fileURLWithPath:s->executable] URLByDeletingLastPathComponent]
          URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
  NSDictionary *attr =
      @{(__bridge NSString *)kSecGuestAttributePid : @(s->subject.pid)};
  NSString *identifier = s->expectedID ?: @"com.holdsnow.nearpane.engine-fixture.a";
  NSString *requirement = [NSString stringWithFormat:
      @"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" "
       "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate 1[field.1.2.840.113635.100.6.2.6] exists",identifier];
  BOOL ok =
      SecRequirementCreateWithString(
          (__bridge CFStringRef)requirement,
          kSecCSDefaultFlags, &rule) == errSecSuccess &&
      SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attr, 0,
                                     &guest) == errSecSuccess &&
      SecCodeCheckValidity(guest, kSecCSStrictValidate, rule) ==
          errSecSuccess &&
      SecCodeCopyStaticCode(guest, 0, &running) == errSecSuccess &&
      SecStaticCodeCreateWithPath((__bridge CFURLRef)url, 0, &disk) ==
          errSecSuccess &&
      SecStaticCodeCheckValidity(disk, kSecCSStrictValidate, rule) ==
          errSecSuccess;
  SecStaticCodeRef codes[] = {running, disk};
  for (unsigned i = 0; ok && i < 2; i++) {
    CFDictionaryRef dict = NULL;
    ok = SecCodeCopySigningInformation(codes[i], kSecCSSigningInformation,
                                       &dict) == errSecSuccess;
    NSDictionary *info = CFBridgingRelease(dict);
    NSData *hash = info[(__bridge NSString *)kSecCodeInfoUnique];
    if (![hash isKindOfClass:NSData.class] || hash.length != 20) {
      ok = NO;
      break;
    }
    const uint8_t *bytes = hash.bytes;
    char hex[41] = {0};
    for (unsigned j = 0; j < 20; j++)
      snprintf(hex + j * 2, 3, "%02x", bytes[j]);
    ok = ok && [(s->expectedHash ?: enrolledFixtureCDHash)
                   isEqualToString:[NSString stringWithUTF8String:hex]];
  }
  if (disk)
    CFRelease(disk);
  if (running)
    CFRelease(running);
  if (guest)
    CFRelease(guest);
  if (rule)
    CFRelease(rule);
  return ok && birth(s->subject.pid) == s->subject.birth;
}
// Only the selected, retained ordinary object's AX position and size are read.
static BOOL documentGeometry(AXUIElementRef element, CGRect *result) {
  CFTypeRef pos = NULL, size = NULL;
  CGPoint point;
  CGSize extent;
  BOOL ok = element &&
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute,
                                          &pos) == kAXErrorSuccess &&
            pos && CFGetTypeID(pos) == AXValueGetTypeID() &&
            AXValueGetValue((AXValueRef)pos, kAXValueCGPointType, &point) &&
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size) ==
                kAXErrorSuccess &&
            size && CFGetTypeID(size) == AXValueGetTypeID() &&
            AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &extent) &&
            isfinite(point.x) && isfinite(point.y) && isfinite(extent.width) &&
            isfinite(extent.height) && extent.width > 0 && extent.height > 0;
  if (pos)
    CFRelease(pos);
  if (size)
    CFRelease(size);
  if (ok)
    *result = (CGRect){point, extent};
  return ok;
}
static BOOL interactiveRoster(NPInstalledFixture *s, BOOL hiddenAllowed);
static BOOL singleRegisteredDocument(NPInstalledFixture *s, BOOL permitEmpty) {
  if (s->interactive) return interactiveRoster(s,permitEmpty);
  AXUIElementRef app = AXUIElementCreateApplication(s->subject.pid);
  CFIndex count = 0;
  CFArrayRef windows = NULL;
  BOOL ok =
      app && AXUIElementSetMessagingTimeout(app, .1f) == kAXErrorSuccess &&
      AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute, &count) ==
          kAXErrorSuccess &&
      (count == 1 || (permitEmpty && count == 0));
  if (ok && count == 1)
    ok = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute, 0, 1,
                                        &windows) == kAXErrorSuccess &&
         windows && CFGetTypeID(windows) == CFArrayGetTypeID() &&
         CFArrayGetCount(windows) == 1 &&
         CFEqual(s->document, CFArrayGetValueAtIndex(windows, 0));
  if (windows)
    CFRelease(windows);
  if (app)
    CFRelease(app);
  return ok;
}
int32_t np_stage_fixture_home_ax(void *token) {
  @autoreleasepool {
    @try {
      return token &&
             singleRegisteredDocument((__bridge NPInstalledFixture *)token, NO);
    } @catch (NSException *e) {
      return 0;
    }
  }
}
uint32_t np_stage_fixture_guard(void *token, uint32_t committing) {
  @autoreleasepool {
    @try {
      if (!token)
        return 7;
      NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
      if (s->ledger >= 0 && !currentLedger(s))
        return 19;
      if (NSProcessInfo.processInfo.systemUptime >= s->expires ||
          !fileAbsent(s->channel, "abort") || (!s->panelOnly &&
          (!fileAbsent(s->owner, "stop") || !fileAbsent(s->owner, "owner-closed.json") ||
           (s->interactive && (!fileAbsent(s->owner,"interactive-closed.json") || !fileAbsent(s->owner,"bystander-closed.json"))))))
        return 13;
      if (!AXIsProcessTrusted())
        return 3;
      SecuritySessionId sid = 0;
      CGDirectDisplayID display = 0;
      if (!sessionReady(&sid) || sid != s->session || !sameDisplay(&display) ||
          display != s->display)
        return 4;
      if (np_stage_input_interrupted()) return 10;
      for (unsigned j = 0; j < hidCount; j++)
        if (s->counters[j] !=
            CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,
                                             installedHIDTypes[j]))
          return 10;
      pid_t pid = 0;
      uint64_t started = 0;
      uint32_t window = 0;
      AXUIElementRef desktop = NULL;
      BOOL sameFocus = readFocus(&pid, &started, &window, &desktop) && pid == s->front &&
          started == s->frontBirth && window == s->frontWindow &&
          ((!s->frontDesktopFocus && !desktop) ||
           (s->frontDesktopFocus && desktop && CFEqual(s->frontDesktopFocus, desktop)));
      if (desktop) CFRelease(desktop);
      if (!sameFocus)
        return 9;
      if (!s->panelOnly && (birth(s->subject.pid) != s->subject.birth || !fixtureImagePath(s) ||
          (committing && !signedFixture(s))))
        return 7;
      if (!s->panelOnly && committing && !singleRegisteredDocument(s, YES))
        return 8;
      // The stronger Security/AX checks took time. Re-read the physical
      // counters immediately at the boundary.
      for (unsigned j = 0; j < hidCount; j++)
        if (s->counters[j] !=
            CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,
                                             installedHIDTypes[j]))
          return 10;
      return np_stage_input_interrupted() ? 10 : 0;
    } @catch (NSException *e) {
      return 17;
    }
  }
}
int32_t np_stage_fixture_same(void *token, void *candidate,
                              const double rect[4]) {
  @autoreleasepool {
    @try {
      if (!token || !candidate || !rect)
        return 0;
      NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
      CGRect value = CGRectNull,
             cg = CGRectMake(rect[0], rect[1], rect[2], rect[3]);
      return CFEqual(s->document, (CFTypeRef)candidate) &&
             documentGeometry(s->document, &value) &&
             CGRectEqualToRect(value, cg) &&
             CGRectEqualToRect(value, s->geometry);
    } @catch (NSException *e) {
      return 0;
    }
  }
}
#import "installed-interactive.inc"

static BOOL registerFixtureWindow(NPInstalledFixture *s, NSString *idString, uint32_t *bits, uint32_t *reason) {
  NSString *owner = [@"/private/tmp/nearpane-membership."
      stringByAppendingString:idString];
  s->owner = privateFixtureDirectory(owner);
  if (s->owner < 0)
    return NO;
  NSDictionary *reg = fixtureDocument(s->channel, "fixture.json"),
               *start = fixtureDocument(s->owner, "owner-start.json");
  s->executable =
      [owner stringByAppendingString:
                 @"/Membership Window.app/Contents/MacOS/MembershipWindow"];
  uint64_t pid = 0, w = 0, started = 0, rpid = 0, rw = 0, rstarted = 0;
  if (![s->executable isEqual:reg[@"executable"]] ||
      ![enrolledFixtureCDHash isEqual:reg[@"cdhash"]] ||
      !exactNumber(reg[@"pid"], &pid, NO) || pid <= 1 || pid > INT_MAX ||
      pid == getpid() || !exactNumber(reg[@"birth"], &started, NO) ||
      !exactNumber(reg[@"window"], &w, NO) || w > UINT32_MAX ||
      !exactNumber(start[@"pid"], &rpid, NO) ||
      !exactNumber(start[@"birth"], &rstarted, NO) ||
      !exactNumber(start[@"window"], &rw, NO) || pid != rpid || w != rw ||
      started != rstarted || !fixtureBoolFields(start))
    return NO;
  double began = 0, now = NSProcessInfo.processInfo.systemUptime;
  *reason = 13;
  if (!fixtureUptime(start[@"startedUptime"], &began) ||
      !fixtureUptime(start[@"deadlineUptime"], &s->expires) ||
      began > now || s->expires <= now + 20 ||
      fabs((s->expires - began) - 75) > .0001)
    return NO;
  *bits |= 16;
  *reason = 7;
  s->subject = (NPInstalledSubject){(pid_t)pid, (uint32_t)w, started};
  if (!signedFixture(s))
    return NO;
  *bits |= 32;
  *reason = 8;
  s->document = boundWindow((uint32_t)w, (pid_t)pid, started, NULL, NO);
  NPStageWindow row = {0};
  if (!s->document || !singleRegisteredDocument(s, NO) ||
      !documentGeometry(s->document, &s->geometry) ||
      np_stage_window((uint32_t)w, &row) != 1 || row.pid != (pid_t)pid ||
      row.birth != started || !row.layer_zero ||
      !np_stage_fixture_same((__bridge void *)s, (void *)s->document,
                             row.rect))
    return NO;
  *bits |= 64;
  return YES;
}

void *np_stage_fixture_enroll(const uint8_t nonce[16], uint32_t panelOnly, NPInstalledSubject *out,
                              uint32_t *bits, uint32_t *reason) {
  @autoreleasepool {
    @try {
      if (!nonce || !out || !bits || !reason || panelOnly > 1)
        return NULL;
      *reason = 1;
      if (getuid() == 0 || geteuid() != getuid() || !signedInstalledHost())
        return NULL;
      *bits |= 1;
      *reason = 18;
      if (installedLedgerPrior() != 0)
        return NULL;
      *reason = 2;
      if (!np_stage_target_build())
        return NULL;
      *bits |= 2;
      *reason = 3;
      if (!AXIsProcessTrusted())
        return NULL;
      *bits |= 4;
      *reason = 4;
      NPInstalledFixture *s = [NPInstalledFixture new];
      if (!sessionReady(&s->session) || !sameDisplay(&s->display))
        return NULL;
      *bits |= 8;
      *reason = 5;
      NSString *idString =
          [[NSUUID alloc] initWithUUIDBytes:nonce].UUIDString.lowercaseString;
      s->challenge = idString;
      s->panelOnly = panelOnly == 1;
      NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
      NSRunningApplication *me = NSRunningApplication.currentApplication;
      if (!me || me.active ||
          me.activationPolicy != NSApplicationActivationPolicyProhibited)
        return NULL;
      s->interactive = !s->panelOnly && [args containsObject:@"--interactive-spaces-cycle"];
      NSArray *options = s->interactive ? @[@"--private-receipt", @"--interactive-spaces-cycle"] : s->panelOnly ? @[@"--private-receipt", @"--installed-spaces-canary"]
          : @[@"--private-receipt", @"--await-registered-window", @"--enrolled-spaces-cycle"];
      if (args.count != options.count + 3 || ![args[1] isEqual:@"--read-stage-engine-scope"] ||
          ![[[NSUUID alloc] initWithUUIDString:args[2]] isEqual:[[NSUUID alloc] initWithUUIDBytes:nonce]] ||
          ![[NSSet setWithArray:[args subarrayWithRange:NSMakeRange(3, options.count)]]
              isEqual:[NSSet setWithArray:options]]) return NULL;
      NSString *channel = [@"/private/tmp/nearpane-host-scope."
          stringByAppendingString:idString];
      s->channel = privateFixtureDirectory(channel);
      if (s->channel < 0) return NULL;
      if (s->panelOnly) {
        if (!fileAbsent(s->channel, "fixture.json")) return NULL;
        s->expires = NSProcessInfo.processInfo.systemUptime + 12;
      } else if (s->interactive) {
        if (!registerInteractiveWindows(s,idString,bits,reason)) return NULL;
      } else if (!registerFixtureWindow(s, idString, bits, reason)) {
        return NULL;
      }
      *reason = 9;
      if (!readFocus(&s->front, &s->frontBirth, &s->frontWindow, &s->frontDesktopFocus) ||
          s->front == getpid() || s->front == s->subject.pid)
        return NULL;
      for (unsigned j = 0; j < hidCount; j++)
        s->counters[j] = CGEventSourceCounterForEventType(
            kCGEventSourceStateHIDSystemState, installedHIDTypes[j]);
      *bits |= 128;
      *reason = np_stage_fixture_guard((__bridge void *)s, 1);
      if (*reason)
        return NULL;
      // A new process with the same nonce cannot replay a physical transaction.
      *reason = 11;
      int claim =
          openat(s->channel, "spaces-cycle.claim",
                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
      if (claim < 0)
        return NULL;
      close(claim);
      *out = s->subject;
      *bits |= 256;
      *reason = 0;
      return (void *)CFBridgingRetain(s);
    } @catch (NSException *e) {
      if (reason)
        *reason = 17;
      return NULL;
    }
  }
}
