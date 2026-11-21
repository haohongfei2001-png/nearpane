// Only compiles into an unsigned command-line unit test. It never enters AppKit
// or the window/Space API. Each test supplies a fresh private directory as the
// journal base.
#define NP_OFFLINE_JOURNAL_TEST 1
#include "../../../../Engine/nearpane-window-engine/src/spaces/platform.m"
const char *np_offline_journal_root;
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 4)
      return 2;
    if (!strcmp(argv[2], "inventory")) {
      NPStageDesktop managed[] = {{.id=6, .kind=0}, {.id=7, .kind=4}};
      uint64_t valid[] = {7, 8, 6, 7}, ordinary[] = {6, 6, 7}, unknown[] = {6, 7, 8, 8};
      uint64_t triple[] = {6, 7, 7, 7}, missing[] = {6, 8}, zero[] = {0, 6, 7};
      if (!validateInventory(valid, 4, managed, 2) || memcmp(valid, (uint64_t[]){6, 7, 7, 8}, sizeof(valid))) return 3;
      if (validateInventory(ordinary, 3, managed, 2) || validateInventory(unknown, 4, managed, 2) ||
          validateInventory(triple, 4, managed, 2) || validateInventory(missing, 2, managed, 2) ||
          validateInventory(zero, 3, managed, 2)) return 4;
      managed[0] = managed[1];
      return validateInventory(valid, 4, managed, 2) ? 5 : 0;
    }
    np_offline_journal_root = argv[1];
    if (!strcmp(argv[2], "pending"))
      return installedLedgerPrior() == 1 ? 0 : 3;
    NPInstalledFixture *s = [NPInstalledFixture new];
    s->challenge = [[[NSUUID alloc] initWithUUIDString:@(argv[3])] UUIDString]
                       .lowercaseString;
    if (!s->challenge)
      return 2;
    s->panelOnly = !strcmp(argv[2], "panel");
    if (!s->panelOnly) s->subject = (NPInstalledSubject){4242, 101, 100};
    NPStageDesktop top = {
        .display = {1}, .uuid = {2}, .id = 6, .kind = 0, .current = 1};
    double frame[] = {10, 20, 100, 80};
    uint64_t ids[] = {6};
    uint32_t rc = np_stage_fixture_first_journal((__bridge void *)s, &top, 1,
                                                 ids, 1, 6, s->panelOnly ? NULL : frame, 1);
    if (!strcmp(argv[2], "refuse"))
      return rc == 18 ? 0 : 4;
    if (rc != 0)
      return (int)rc;
    // A persist-before-dispatch record with no matching delivery remains
    // unresolved.
    if (np_stage_fixture_journal((__bridge void *)s, 0, 0, 0, 0, 0) != 0)
      return 5;
    if (!strcmp(argv[2], "crash"))
      _exit(91);
    if (!strcmp(argv[2], "retain"))
      return np_stage_fixture_finish_journal((__bridge void *)s, 0);
    if (!strcmp(argv[2], "clean") || s->panelOnly)
      return np_stage_fixture_finish_journal((__bridge void *)s, 1);
    return 2;
  }
}
