#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* A read-only pipe peer for DesktopOverviewReaderTests. No platform/window APIs
 * or interpreter startup: every test receives its own executable and markers. */
static int read_exact(void *buffer, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t size = read(STDIN_FILENO, (char *)buffer + offset, count - offset);
        if (size > 0) offset += (size_t)size;
        else if (size < 0 && errno == EINTR) continue;
        else return size == 0 && offset == 0 ? 0 : -1;
    }
    return 1;
}

static int write_exact(const void *buffer, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t size = write(STDOUT_FILENO, (const char *)buffer + offset, count - offset);
        if (size > 0) offset += (size_t)size;
        else if (size < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

static void header(uint8_t bytes[4], uint32_t count) {
    bytes[0] = (uint8_t)(count >> 24);
    bytes[1] = (uint8_t)(count >> 16);
    bytes[2] = (uint8_t)(count >> 8);
    bytes[3] = (uint8_t)count;
}

static void delay(long milliseconds) {
    struct timespec remaining = { milliseconds / 1000, (milliseconds % 1000) * 1000000 };
    while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

static int mark(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    return fd < 0 ? -1 : close(fd);
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--window-overview-service") != 0) return 2;
    const char *slash = strrchr(argv[0], '/');
    if (slash == NULL || slash == argv[0]) return 2;
    size_t length = (size_t)(slash - argv[0]);
    char directory[PATH_MAX];
    if (length >= sizeof(directory)) return 2;
    memcpy(directory, argv[0], length);
    directory[length] = '\0';
    if (chdir(directory) != 0) return 2;

    unsigned int count = 0;
    for (;;) {
        uint8_t frame[4];
        int result = read_exact(frame, sizeof(frame));
        if (result == 0) return 0;
        if (result != 1) return 2;
        uint32_t size = ((uint32_t)frame[0] << 24) | ((uint32_t)frame[1] << 16)
            | ((uint32_t)frame[2] << 8) | frame[3];
        char request[8193];
        if (size == 0 || size >= sizeof(request) || read_exact(request, size) != 1) return 2;
        request[size] = '\0';
        count++;

        /* Only the suite's exact private action/value envelope is understood.
         * A real DesktopReadRequest intentionally receives an invalid snapshot. */
        char action[16] = {0};
        long long value = 0;
        int parsed = sscanf(request, "{\"action\":\"%15[^\"]\",\"value\":%lld}", action, &value);
        if (strcmp(action, "slow") == 0) {
            if (mark("slow-ready") != 0) return 3;
            while (access("slow-release", F_OK) != 0) {
                if (errno != ENOENT) return 3;
                delay(5);
            }
        }
        if (strcmp(action, "hang") == 0) {
            if (mark("hang-ready") != 0) return 3;
            delay(30000);
        }
        if (strcmp(action, "oversize") == 0) {
            header(frame, 1048577);
            if (write_exact(frame, sizeof(frame)) != 0) return 3;
            delay(30000);
        }
        if (strcmp(action, "truncated") == 0) {
            header(frame, 100);
            if (write_exact(frame, sizeof(frame)) != 0 || write_exact("{", 1) != 0) return 3;
            return 0;
        }

        char number[32], reply[128];
        if (parsed == 2) snprintf(number, sizeof(number), "%lld", value);
        else snprintf(number, sizeof(number), "null");
        int reply_size = snprintf(reply, sizeof(reply), "{\"pid\":%ld,\"count\":%u,\"value\":%s}",
            (long)getpid(), count, number);
        if (reply_size <= 0 || (size_t)reply_size >= sizeof(reply)) return 3;
        header(frame, (uint32_t)reply_size);
        if (strcmp(action, "split") == 0) {
            if (write_exact(frame, 1) != 0) return 3;
            delay(1);
            if (write_exact(frame + 1, 3) != 0) return 3;
            for (size_t offset = 0; offset < (size_t)reply_size; offset += 3) {
                size_t chunk = (size_t)reply_size - offset;
                if (chunk > 3) chunk = 3;
                if (write_exact(reply + offset, chunk) != 0) return 3;
                delay(1);
            }
        } else if (write_exact(frame, sizeof(frame)) != 0 || write_exact(reply, (size_t)reply_size) != 0) {
            return 3;
        }
    }
}
