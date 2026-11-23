// Enrollment of two reviewed ordinary applications for the installed diagnostic Host.
#import "../../include/nearpane_interactive_fixture_pins.h"
static NSString *const interactiveOwnerID = @"com.holdsnow.nearpane.stage-interactive-fixture";
static NSString *const interactiveOtherID = @"com.holdsnow.nearpane.stage-interactive-bystander";
static NSString *const interactiveOwnerHash = @NP_INTERACTIVE_OWNER_CDHASH;
static NSString *const interactiveOtherHash = @NP_INTERACTIVE_BYSTANDER_CDHASH;

static BOOL bindInteractiveRow(NPInstalledFixture *part, NSDictionary *ready, NSDictionary *snapshot,
                               NSDictionary *row, NSString *nonce, NSString *role) {
  NSDictionary *owner = ready[@"owner"];
  uint64_t pid = 0, started = 0, window = 0;
  NSArray *frame = row[@"frame"];
  if (![ready[@"challenge"] isEqual:nonce] || ![snapshot[@"challenge"] isEqual:nonce] ||
      ![owner[@"identifier"] isEqual:part->expectedID] || ![owner[@"cdhash"] isEqual:part->expectedHash] ||
      ![snapshot[@"pid"] isEqual:owner[@"pid"]] || ![snapshot[@"birth"] isEqual:owner[@"birth"]] ||
      !exactNumber(owner[@"pid"], &pid, NO) || pid <= 1 || pid > INT_MAX || pid == (uint64_t)getpid() ||
      !exactNumber(owner[@"birth"], &started, NO) || !exactNumber(row[@"window"], &window, NO) || window > UINT32_MAX ||
      ![row[@"role"] isEqual:role] || ![[NSUUID alloc] initWithUUIDString:row[@"lifetime"]] ||
      ![frame isKindOfClass:NSArray.class] || frame.count != 4 || ![row[@"alpha"] isEqual:@1] ||
      !fixtureFlag(row[@"sameOriginal"], YES) || !fixtureFlag(row[@"visible"], YES) ||
      !fixtureFlag(row[@"onActiveSpace"], YES) || !fixtureFlag(row[@"minimized"], NO) ||
      !fixtureFlag(row[@"acceptsMouse"], YES)) return NO;
  for (id n in frame)
    if (![n isKindOfClass:NSNumber.class] || !isfinite([n doubleValue])) return NO;
  part->subject = (NPInstalledSubject){(pid_t)pid, (uint32_t)window, started};
  if (!signedFixture(part)) return NO;
  part->document = boundWindow((uint32_t)window, (pid_t)pid, started, NULL);
  CFTypeRef identifier = NULL;
  if (!part->document || AXUIElementCopyAttributeValue(part->document,kAXIdentifierAttribute,&identifier) != kAXErrorSuccess) return NO;
  NSString *axID = CFBridgingRelease(identifier);
  NPStageWindow cg = {0};
  if (![axID isEqual:[@"nearpane.fixture." stringByAppendingString:role]] ||
      !documentGeometry(part->document,&part->geometry) || np_stage_window((uint32_t)window,&cg) != 1 ||
      cg.pid != (int32_t)pid || cg.birth != started || cg.layer_zero != 1 || cg.onboard != 1 ||
      !np_stage_fixture_same((__bridge void *)part,(void *)part->document,cg.rect)) return NO;
  for (NSUInteger i=0; i<4; ++i) if (fabs([frame[i] doubleValue] - cg.rect[i]) > .75) return NO;
  return YES;
}

static BOOL interactiveRoster(NPInstalledFixture *s, BOOL hiddenAllowed) {
  if (s->protectedWindows.count != 2) return NO;
  NPInstalledFixture *sibling = s->protectedWindows[0];
  AXUIElementRef app = AXUIElementCreateApplication(s->subject.pid);
  CFTypeRef raw = NULL;
  BOOL read = app && AXUIElementSetMessagingTimeout(app,.1f) == kAXErrorSuccess &&
      AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&raw) == kAXErrorSuccess;
  if (app) CFRelease(app);
  NSArray *ax = CFBridgingRelease(raw);
  if (!read || ![ax isKindOfClass:NSArray.class]) return NO;
  BOOL targetFound = NO, siblingFound = NO;
  for (id item in ax) {
    if (!targetFound && CFEqual((__bridge CFTypeRef)item,s->document)) targetFound = YES;
    else if (!siblingFound && CFEqual((__bridge CFTypeRef)item,sibling->document)) siblingFound = YES;
    else return NO;
  }
  return siblingFound && (targetFound || hiddenAllowed);
}

static BOOL protectedVisible(NPInstalledFixture *part, uint64_t home, int connection) {
  NPStageWindow row = {0};
  if (!fixtureImagePath(part) || np_stage_window(part->subject.window,&row) != 1 ||
      row.pid != part->subject.pid || row.birth != part->subject.birth || row.layer_zero != 1 || row.onboard != 1 ||
      !np_stage_fixture_same((__bridge void *)part,(void *)part->document,row.rect)) return NO;
  uint64_t forward[2], occupants[4096];
  if (np_stage_membership(connection,part->subject.window,forward,2) != 1 || forward[0] != home) return NO;
  int count = np_stage_occupants(connection,home,occupants,4096);
  if (count <= 0 || count > 4096) return NO;
  int matched = 0;
  for (int i=0; i<count; ++i) matched += occupants[i] == part->subject.window;
  return matched == 1;
}

int32_t np_stage_fixture_companions(void *token, uint64_t home, uint32_t hidden) {
  @autoreleasepool { @try {
    NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
    if (!s) return 0;
    if (!s->interactive) return 1;
    int connection = np_stage_connection();
    if (home != s->interactiveHome || connection <= 0 || !interactiveRoster(s,hidden != 0)) return 0;
    for (NPInstalledFixture *p in s->protectedWindows) if (!protectedVisible(p,home,connection)) return 0;
    return 1;
  } @catch (NSException *exception) { return 0; } }
}

static BOOL registerInteractiveWindows(NPInstalledFixture *s, NSString *nonce, uint32_t *bits, uint32_t *reason) {
  NSString *root = [@"/private/tmp/nearpane-membership." stringByAppendingString:nonce];
  s->owner = privateFixtureDirectory(root);
  if (s->owner < 0) return NO;
  NSDictionary *pin = fixtureDocument(s->channel,"fixture.json");
  if (![pin[@"challenge"] isEqual:nonce] || ![pin[@"kind"] isEqual:@"interactiveWindowPair"] ||
      ![pin[@"cdhash"] isEqual:interactiveOwnerHash] || ![pin[@"bystanderCDHash"] isEqual:interactiveOtherHash]) return NO;
  NSDictionary *a = fixtureDocument(s->owner,"interactive-windows.json"), *b = fixtureDocument(s->owner,"bystander-windows.json");
  NSDictionary *ra = fixtureDocument(s->owner,"interactive-ready.json"), *rb = fixtureDocument(s->owner,"bystander-ready.json");
  NSArray *pair = a[@"windows"], *separate = b[@"windows"];
  double now = NSProcessInfo.processInfo.systemUptime, limit = DBL_MAX;
  for (NSDictionary *ready in @[ra ?: @{}, rb ?: @{}]) {
    double start = 0, end = 0;
    if (!fixtureUptime(ready[@"startedUptime"],&start) || !fixtureUptime(ready[@"deadlineUptime"],&end) ||
        start > now || fabs(end-start-75) > .0001 || end < now + 20) return NO;
    limit = MIN(limit,end);
  }
  s->expires = limit;
  if (![pair isKindOfClass:NSArray.class] || pair.count != 2 || ![separate isKindOfClass:NSArray.class] || separate.count != 1 ||
      ![a[@"scope"] isEqual:b[@"scope"]] || !exactNumber(a[@"scope"][@"nativeID"],&s->interactiveHome,NO)) return NO;
  *bits |= 16;
  *reason = 7;
  NPInstalledFixture *sibling = [NPInstalledFixture new], *other = [NPInstalledFixture new];
  s->expectedID = sibling->expectedID = interactiveOwnerID;
  s->expectedHash = sibling->expectedHash = interactiveOwnerHash;
  s->executable = sibling->executable = [root stringByAppendingPathComponent:@"Interactive Windows.app/Contents/MacOS/InteractiveWindows"];
  other->expectedID = interactiveOtherID; other->expectedHash = interactiveOtherHash;
  other->executable = [root stringByAppendingPathComponent:@"Interactive Bystander.app/Contents/MacOS/InteractiveBystander"];
  if (!bindInteractiveRow(s,ra,a,pair[0],nonce,@"target") || !bindInteractiveRow(sibling,ra,a,pair[1],nonce,@"sibling") ||
      !bindInteractiveRow(other,rb,b,separate[0],nonce,@"bystander") || other->subject.pid == s->subject.pid ||
      sibling->subject.pid != s->subject.pid || sibling->subject.birth != s->subject.birth ||
      [NSSet setWithArray:@[@(s->subject.window),@(sibling->subject.window),@(other->subject.window)]].count != 3) return NO;
  s->protectedWindows = @[sibling,other];
  *bits |= 32;
  *reason = 8;
  if (!np_stage_fixture_companions((__bridge void *)s,s->interactiveHome,0)) return NO;
  *bits |= 64;
  return YES;
}

// A bounded rendezvous after both parked proofs. A missing or negative observation
// returns to Rust's existing recovery path without poisoning its authority to return.
int32_t np_stage_fixture_parked_input(void *token, uint64_t parking) {
  @autoreleasepool { @try {
    NPInstalledFixture *s = (__bridge NPInstalledFixture *)token;
    if (!s) return 0;
    if (!s->interactive) return 1;
    if (s->protectedWindows.count != 2 || !parking || parking == s->interactiveHome) return 0;
    NPInstalledFixture *other = s->protectedWindows[1];
    if (s->front != other->subject.pid || s->frontBirth != other->subject.birth ||
        s->frontWindow != other->subject.window || !ownerLeaseMarker(s,"interactive-parked")) return 0;
    double end = NSProcessInfo.processInfo.systemUptime + 3.5;
    while (NSProcessInfo.processInfo.systemUptime < end) {
      NSDictionary *ack = fixtureDocument(s->owner,"interactive-input.json");
      if (ack) return [ack[@"challenge"] isEqual:s->challenge] && [ack[@"target"] isEqual:@(s->subject.window)] &&
          [ack[@"receiver"] isEqual:@(other->subject.window)] && [ack[@"status"] isEqual:@"PASS"] &&
          np_stage_fixture_companions(token,s->interactiveHome,1) == 1;
      if (!fileAbsent(s->channel,"abort")) return 0;
      for (unsigned i=0; i<hidCount; i++) if (s->counters[i] !=
          CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,installedHIDTypes[i])) return 0;
      usleep(16000);
    }
    return 0;
  } @catch (NSException *exception) { return 0; } }
}
