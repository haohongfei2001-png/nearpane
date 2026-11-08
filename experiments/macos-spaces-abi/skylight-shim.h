#ifndef NEARPANE_SKYLIGHT_SHIM_H
#define NEARPANE_SKYLIGHT_SHIM_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stddef.h>

// Experimental CLI only. No Host target imports this header.
// Exact declarations cross-checked against asmvik/yabai at
// dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:9,22,60.
extern int SLSMainConnectionID(void);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid);

typedef int (*NPMainFunction)(void);
typedef CFArrayRef (*NPManagedFunction)(int);
typedef CFArrayRef (*NPMembershipFunction)(int, int, CFArrayRef);

typedef struct {
    uint64_t main_calls, managed_calls, membership_calls;
    uint64_t managed_nonnull, membership_nonnull, output_releases;
    uint64_t input_creates, input_releases, number_creates, number_releases;
    uint64_t rejected_inputs;
} NPCounters;
typedef struct {
    uint64_t resident_bytes, malloc_bytes, malloc_blocks;
    int memory_status;
} NPMemory;
typedef struct {
    uint64_t allocations, deallocations, reallocations, outstanding_blocks, outstanding_bytes;
} NPAllocatorCounters;

// Live loading is compiled out by default and has no CLI entry point.
int NPInitialize(int fault, char *error, size_t capacity);
// Fixture faults: 1/2 loader/symbol, 3 NULL managed, 4 malformed managed,
// 5 NULL membership, 6 wrong membership top type. No OS APIs are called.
int NPInitializeFixtures(int fault, char *error, size_t capacity);
int NPLiveBackendCompiled(void);
int NPIsFixtureBackend(void);
int NPShutdown(void);
int NPMainConnection(void);
void *NPFunctionAddress(int index); // 0 main, 1 managed, 2 membership only
const void *NPCopyManaged(void);
// Deliberately no selector argument: 0x7 is the only permitted call value.
const void *NPCopyMembership(const void *windows);
// Raw pointers deliberately keep C releases observable, avoiding importer ARC.
const void *NPCreateSInt32Windows(const uint32_t *ids, size_t count);
void NPReleaseInput(const void *input);
void NPReleaseOutput(const void *output);
int NPValidateInput(const void *windows);
int NPLastError(void);
NPCounters NPGetCounters(void);
NPMemory NPGetMemory(void);
NPAllocatorCounters NPGetFixtureAllocatorCounters(void);
int NPIntBytes(void);
int NPWindowIDBytes(void);
#endif
