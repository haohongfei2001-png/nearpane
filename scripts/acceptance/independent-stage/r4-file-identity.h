// R4 acceptance input only. Path aliases must resolve to the same canonical
// regular file and to the device/inode captured by the launching Host.
#ifndef NEARPANE_R4_FILE_IDENTITY_H
#define NEARPANE_R4_FILE_IDENTITY_H

#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    char canonical[PATH_MAX];
    uint64_t device;
    uint64_t inode;
} R4FileIdentity;

static bool r4ReadFileIdentity(const char *path, R4FileIdentity *identity) {
    if (!path || path[0] != '/' || !identity) return false;
    R4FileIdentity found = {0};
    if (!realpath(path, found.canonical)) return false;
    int descriptor = open(found.canonical, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (descriptor < 0) return false;
    struct stat opened = {0}, current = {0};
    char resolved[PATH_MAX] = {0};
    bool valid = fstat(descriptor, &opened) == 0 && S_ISREG(opened.st_mode) &&
        realpath(path, resolved) && strcmp(found.canonical, resolved) == 0 &&
        lstat(resolved, &current) == 0 && S_ISREG(current.st_mode) &&
        opened.st_dev == current.st_dev && opened.st_ino == current.st_ino;
    close(descriptor);
    if (!valid) return false;
    found.device = (uint64_t)opened.st_dev;
    found.inode = (uint64_t)opened.st_ino;
    *identity = found;
    return true;
}

static bool r4SameFileIdentity(const R4FileIdentity *a, const R4FileIdentity *b) {
    return a->device == b->device && a->inode == b->inode &&
        strcmp(a->canonical, b->canonical) == 0;
}

static bool r4FileIdentityMatches(const char *requested, const char *kernel,
                                  uint64_t device, uint64_t inode) {
    R4FileIdentity before = {0}, live = {0}, after = {0};
    return r4ReadFileIdentity(requested, &before) &&
        before.device == device && before.inode == inode &&
        r4ReadFileIdentity(kernel, &live) && r4SameFileIdentity(&before, &live) &&
        r4ReadFileIdentity(requested, &after) && r4SameFileIdentity(&before, &after);
}

#endif
