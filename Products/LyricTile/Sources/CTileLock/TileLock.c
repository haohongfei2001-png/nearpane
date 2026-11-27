#include "TileLock.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#endif

int lt_lock_acquire(const char *path, int *error_number) {
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) { if (error_number) *error_number = errno; return -1; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid()) {
        if (error_number) *error_number = EACCES;
        close(fd); return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        int e = errno; close(fd);
        if (error_number) *error_number = e;
        return (e == EWOULDBLOCK || e == EAGAIN) ? -2 : -1;
    }
    return fd;
}
void lt_lock_release(int fd) {
    if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
}
int lt_process_token(int32_t pid, char *buffer, size_t capacity) {
    if (pid <= 0 || !buffer || capacity < 40) return 0;
#ifdef __APPLE__
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (size != sizeof(info)) return 0;
    snprintf(buffer, capacity, "%d:%llu:%llu", pid,
             (unsigned long long)info.pbi_start_tvsec,
             (unsigned long long)info.pbi_start_tvusec);
    return 1;
#else
    char path[64], line[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char *ok = fgets(line, sizeof(line), f); fclose(f);
    if (!ok) return 0;
    char *after = strrchr(line, ')');
    if (!after || after[1] != ' ') return 0;
    char *save = NULL, *field = strtok_r(after + 2, " ", &save);
    for (int i = 0; i < 19 && field; ++i) field = strtok_r(NULL, " ", &save);
    if (!field) return 0;
    snprintf(buffer, capacity, "%d:%s", pid, field);
    return 1;
#endif
}
