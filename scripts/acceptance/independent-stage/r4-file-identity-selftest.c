// Exercises the exact R4 path comparator without AppKit, AX, or window actions.
#include "r4-file-identity.h"
#include <errno.h>
#include <stdio.h>

static unsigned passed = 0, failed = 0;

static void check(const char *name, bool condition) {
    if (condition) passed++;
    else { failed++; fprintf(stderr, "FAIL: %s\n", name); }
}

static bool make_file(const char *path) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return false;
    bool valid = write(descriptor, "x", 1) == 1;
    return close(descriptor) == 0 && valid;
}

static bool child_path(char *output, size_t size, const char *directory, const char *name) {
    int count = snprintf(output, size, "%s/%s", directory, name);
    return count > 0 && (size_t)count < size;
}

int main(void) {
    char directory[] = "/tmp/nearpane-r4-file-identity.XXXXXX";
    if (!mkdtemp(directory)) { perror("mkdtemp"); return 2; }
    char original[PATH_MAX] = {0}, other[PATH_MAX] = {0}, alias[PATH_MAX] = {0};
    char hardlink[PATH_MAX] = {0}, missing[PATH_MAX] = {0}, retained[PATH_MAX] = {0};
    bool setup = child_path(original, sizeof(original), directory, "original") &&
        child_path(other, sizeof(other), directory, "other") &&
        child_path(alias, sizeof(alias), directory, "alias") &&
        child_path(hardlink, sizeof(hardlink), directory, "hardlink") &&
        child_path(missing, sizeof(missing), directory, "missing") &&
        child_path(retained, sizeof(retained), directory, "retained") &&
        make_file(original) && make_file(other) && symlink(original, alias) == 0 &&
        link(original, hardlink) == 0;
    R4FileIdentity identity = {0};
    if (!setup || !r4ReadFileIdentity(original, &identity)) {
        check("fixture setup", false);
        goto cleanup;
    }
    check("same canonical file", r4FileIdentityMatches(original, original, identity.device, identity.inode));
    check("symlink alias", r4FileIdentityMatches(alias, original, identity.device, identity.inode));
    check("kernel path alias", r4FileIdentityMatches(original, alias, identity.device, identity.inode));
    check("different file", !r4FileIdentityMatches(original, other, identity.device, identity.inode));
    check("different canonical hardlink", !r4FileIdentityMatches(original, hardlink, identity.device, identity.inode));
    check("missing file", !r4FileIdentityMatches(missing, original, identity.device, identity.inode));
    check("directory", !r4FileIdentityMatches(directory, directory, identity.device, identity.inode));
    check("relative path", !r4FileIdentityMatches("original", original, identity.device, identity.inode));
    check("changed device", !r4FileIdentityMatches(original, original, identity.device ^ 1, identity.inode));
    check("changed inode", !r4FileIdentityMatches(original, original, identity.device, identity.inode ^ 1));

    if (unlink(alias) != 0 || symlink(other, alias) != 0) {
        check("retarget setup", false);
        goto cleanup;
    }
    check("retargeted alias", !r4FileIdentityMatches(alias, original, identity.device, identity.inode));
    check("both paths retargeted from original identity",
          !r4FileIdentityMatches(alias, other, identity.device, identity.inode));

    // Keep the original inode allocated so replacement cannot reuse it. A match
    // of the two current path strings must not replace the pinned Host identity.
    if (rename(original, retained) != 0 || !make_file(original)) {
        check("replacement setup", false);
        goto cleanup;
    }
    check("replaced canonical file", !r4FileIdentityMatches(original, original, identity.device, identity.inode));
cleanup: {
    const char *paths[] = {alias, hardlink, original, other, retained};
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (paths[i][0] && unlink(paths[i]) != 0 && errno != ENOENT) check("fixture cleanup", false);
    }
    if (rmdir(directory) != 0) check("directory cleanup", false);
    printf("{\"schema\":1,\"status\":\"%s\",\"passed\":%u,\"failed\":%u,\"windowWrites\":0}\n",
           failed ? "FAIL" : "PASS", passed, failed);
    return failed ? 1 : 0;
    }
}
