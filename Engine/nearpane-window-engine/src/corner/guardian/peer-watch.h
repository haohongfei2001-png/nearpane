// Included after identity.h. These checks only observe the direct child and its pipe.
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/event.h>
#include <sys/proc.h>

static inline BOOL ncg_live_child(pid_t child, uint64_t birth) {
    struct proc_bsdinfo info = {0};
    return child > 1 && birth && proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
           info.pbi_pid == (uint32_t)child && info.pbi_ppid == (uint32_t)getpid() && info.pbi_uid == getuid() &&
           info.pbi_status != SZOMB && info.pbi_status != SSTOP &&
           info.pbi_start_tvsec * UINT64_C(1000000) + info.pbi_start_tvusec == birth;
}

static inline int ncg_open_child_watch(pid_t child, uint64_t birth) {
    if (!ncg_live_child(child, birth)) return -1;
    int queue = kqueue();
    if (queue < 0) return -1;
    struct kevent event;
    EV_SET(&event, (uintptr_t)child, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXEC | NOTE_EXIT, 0, NULL);
    if (!fcntl(queue, F_SETFD, FD_CLOEXEC) && !kevent(queue, &event, 1, NULL, 0, NULL) &&
        ncg_live_child(child, birth)) return queue;
    close(queue);
    return -1;
}

// The caller permanently retires the watch after any negative result.
static inline BOOL ncg_child_watch_live(int queue, pid_t child, uint64_t birth) {
    if (queue < 0 || !ncg_live_child(child, birth)) return NO;
    struct timespec now = {0, 0};
    struct kevent event;
    return kevent(queue, NULL, 0, &event, 1, &now) == 0;
}

// The packet timeout starts with the first byte. EOF without a sealed postimage never authorizes recovery.
static inline BOOL ncg_wait_for_host_message(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int rc;
    do { rc = poll(&p, 1, -1); } while (rc < 0 && errno == EINTR);
    return rc == 1 && (p.revents & POLLIN) && !(p.revents & (POLLERR | POLLNVAL));
}
