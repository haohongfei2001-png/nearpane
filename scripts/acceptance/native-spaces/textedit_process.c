// Read one enrolled PID. This executable has no window, Accessibility or signalling actions.
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>

int main(int argc, char **argv) {
    char *end = NULL;
    if (argc != 2) return 2;
    errno = 0;
    long value = strtol(argv[1], &end, 10);
    if (errno || end == argv[1] || *end || value <= 1 || value > INT_MAX) return 2;
    pid_t pid = (pid_t)value;
    struct proc_bsdinfo info = {0};
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (size == sizeof(info) && info.pbi_pid == (unsigned)pid &&
        info.pbi_start_tvsec > 0 && info.pbi_start_tvusec < 1000000) {
        unsigned long long birth = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
        printf("{\"pid\":%d,\"birth\":%llu}\n", pid, birth);
        return 0;
    }
    // Signal zero only tests for existence. A denied/incomplete lookup never proves exit.
    if (kill(pid, 0) == -1 && errno == ESRCH) {
        printf("{\"pid\":%d,\"absent\":true}\n", pid);
        return 0;
    }
    return 3;
}
