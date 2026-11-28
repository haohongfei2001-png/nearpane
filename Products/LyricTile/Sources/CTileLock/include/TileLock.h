#ifndef LYRICTILE_LOCK_H
#define LYRICTILE_LOCK_H
#include <stddef.h>
#include <stdint.h>
// Returns an owned close-on-exec descriptor, -2 for contention, or -1 + errno.
int lt_lock_acquire(const char *path, int *error_number);
void lt_lock_release(int descriptor);
int lt_process_token(int32_t pid, char *buffer, size_t capacity);
#endif
