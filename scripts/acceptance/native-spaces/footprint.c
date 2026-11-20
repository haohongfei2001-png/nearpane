// Per-process physical footprint from the kernel, including process birth and parent identity.
#include <errno.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
int main(int argc, char **argv) {
    mach_timebase_info_data_t clock;
    if (mach_timebase_info(&clock) != KERN_SUCCESS || !clock.denom) return 2;
    for (int i = 1; i < argc; ++i) {
        char *end = NULL;
        long id = strtol(argv[i], &end, 10);
        if (*end || id <= 1 || id > INT32_MAX) return 2;
        struct proc_bsdinfo proc = {0};
        struct rusage_info_v4 usage = {0};
        if (proc_pidinfo((int)id, PROC_PIDTBSDINFO, 0, &proc, sizeof(proc)) != sizeof(proc) ||
            proc_pid_rusage((int)id, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return 3;
        printf("%ld %u %llu %llu %llu %llu %llu\n", id, proc.pbi_ppid, (unsigned long long)proc.pbi_start_tvsec,
               (unsigned long long)proc.pbi_start_tvusec, (unsigned long long)usage.ri_phys_footprint,
               (unsigned long long)(((__uint128_t)usage.ri_user_time * clock.numer) / clock.denom),
               (unsigned long long)(((__uint128_t)usage.ri_system_time * clock.numer) / clock.denom));
    }
    return argc > 1 ? 0 : 2;
}
