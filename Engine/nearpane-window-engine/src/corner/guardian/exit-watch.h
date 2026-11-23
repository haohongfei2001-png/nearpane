// Registration must bind the process generation on both sides of EV_ADD.
#include <errno.h>
#include <sys/event.h>
#include <time.h>

static int ncg_watch_exit(pid_t pid, uint64_t birth) {
    if (pid <= 1 || !birth || ncg_birth(pid, NULL) != birth) return -1;
    int queue = kqueue();
    if (queue < 0) return -1;
    struct kevent registration;
    EV_SET(&registration, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (!kevent(queue, &registration, 1, NULL, 0, NULL) && ncg_birth(pid, NULL) == birth) return queue;
    close(queue);
    return -1;
}

static BOOL ncg_saw_exit(int queue, pid_t pid, uint64_t birth, unsigned millis) {
    if (queue < 0 || !millis || millis > 8000) return NO;
    uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)millis * 1000000;
    for (;;) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now >= end) return NO;
        uint64_t remaining = end - now;
        struct timespec timeout = {(time_t)(remaining / 1000000000), (long)(remaining % 1000000000)};
        struct kevent event;
        int count = kevent(queue, NULL, 0, &event, 1, &timeout);
        if (count == -1 && errno == EINTR) continue;
        if (count != 1 || event.ident != (uintptr_t)pid || event.filter != EVFILT_PROC ||
            (event.flags & EV_ERROR) || !(event.fflags & NOTE_EXIT)) return NO;
        // NOTE_EXIT may arrive while the launching process is still reaping the zombie.
        while (ncg_birth(pid, NULL) == birth && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end) usleep(2000);
        return ncg_birth(pid, NULL) != birth;
    }
}
