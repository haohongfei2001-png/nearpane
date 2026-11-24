// Included after identity.h. These checks only observe the direct child and its pipe.
#pragma once
#include "../../../include/nearpane_guardian_observation.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/event.h>
#include <sys/ioctl.h>
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

// Registered against the signed original image. The consumer retains the first terminal result.
static inline int ncg_child_image_state(int queue, pid_t child, uint64_t birth) {
    if (queue < 0 || child <= 1 || !birth) return NP_GUARDIAN_IMAGE_LOST;
    struct timespec now = {0, 0};
    struct kevent event;
    int count;
    do { count = kevent(queue, NULL, 0, &event, 1, &now); } while (count < 0 && errno == EINTR);
    if (!count) return ncg_live_child(child, birth) ? NP_GUARDIAN_IMAGE_LIVE : NP_GUARDIAN_IMAGE_UNAVAILABLE;
    if (count == 1 && event.ident == (uintptr_t)child && event.filter == EVFILT_PROC &&
        !(event.flags & EV_ERROR) && !(event.fflags & NOTE_EXEC) && (event.fflags & NOTE_EXIT)) return NP_GUARDIAN_IMAGE_EXITED;
    return NP_GUARDIAN_IMAGE_LOST;
}

static inline BOOL ncg_child_watch_live(int queue, pid_t child, uint64_t birth) {
    return ncg_child_image_state(queue, child, birth) == NP_GUARDIAN_IMAGE_LIVE;
}

// The packet timeout starts with the first byte. EOF without a sealed postimage never authorizes recovery.
static inline BOOL ncg_wait_for_host_message(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int rc;
    do { rc = poll(&p, 1, -1); } while (rc < 0 && errno == EINTR);
    return rc == 1 && (p.revents & POLLIN) && !(p.revents & (POLLERR | POLLNVAL));
}

// Only a clean EOF before a packet starts can resume a committed handoff. A
// truncated frame, malformed message or failed poll is never treated as EOF.
static inline int ncg_next_host_packet(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int rc, bytes = 0;
    do { rc = poll(&p, 1, -1); } while (rc < 0 && errno == EINTR);
    if (rc != 1 || p.revents & (POLLERR | POLLNVAL) || ioctl(fd, FIONREAD, &bytes)) return -1;
    if (bytes > 0) return 1;
    return (p.revents & POLLHUP) ? 0 : -1;
}

// Called only after the signed Host's park receipt, matching committed WAL
// and two postimage observations. A lost reply alone never authorizes a restore.
typedef enum { NCG_ACK_ERROR, NCG_ACK_SENT, NCG_ACK_CLOSED } NCGSealAck;
static inline NCGSealAck ncg_ack_park_witness(int fd, char acknowledgement) {
    ssize_t count;
    do { count = write(fd, &acknowledgement, 1); } while (count < 0 && errno == EINTR);
    if (count == 1) return NCG_ACK_SENT;
    return count < 0 && errno == EPIPE ? NCG_ACK_CLOSED : NCG_ACK_ERROR;
}
static inline NCGSealAck ncg_ack_committed_park(int fd) { return ncg_ack_park_witness(fd, 'P'); }
