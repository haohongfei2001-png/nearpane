// Readback for a single marked gesture emitted by this process. Observing the
// decision cannot affect it. Unmarked input has no stored identifiers or coordinates.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <unistd.h>

#define NC_FIXTURE_GESTURE_PREFIX UINT64_C(0x4e50000000000000)
#define NC_FIXTURE_GESTURE_MASK UINT64_C(0xffff000000000000)

typedef struct {
    uint32_t type, dropped;
    int64_t button, targetWindow, targetPID;
    CGPoint point;
} NCGesturePhase;
typedef struct {
    uint32_t count;
    NCGesturePhase phases[3];
} NCGestureRead;
bool np_corner_witness_begin(uint64_t tag);
bool np_corner_witness_end(uint64_t tag, NCGestureRead *out);

#ifdef NP_CORNER_WITNESS_IMPL
static _Atomic uint64_t gestureTag;
static os_unfair_lock gestureLock = OS_UNFAIR_LOCK_INIT;
static NCGestureRead gestureReceipt;
bool np_corner_witness_begin(uint64_t tag) {
    if (!tag)
        return false;
    os_unfair_lock_lock(&gestureLock);
    bool ready = !atomic_load(&gestureTag);
    if (ready) {
        gestureReceipt = (NCGestureRead){0};
        atomic_store(&gestureTag, tag);
    }
    os_unfair_lock_unlock(&gestureLock);
    return ready;
}
static void recordGesture(CGEventType type, CGEventRef event, bool dropped) {
    uint64_t tag = atomic_load_explicit(&gestureTag, memory_order_relaxed);
    if (!tag || !event || (uint64_t)CGEventGetIntegerValueField(event, kCGEventSourceUserData) != tag ||
        CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != getpid() ||
        !os_unfair_lock_trylock(&gestureLock))
        return;
    if (atomic_load(&gestureTag) == tag && gestureReceipt.count < 4) {
        uint32_t i = gestureReceipt.count++;
        if (i < 3)
            gestureReceipt.phases[i] = (NCGesturePhase){
                type,
                dropped,
                CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber),
                CGEventGetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent),
                CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID),
                CGEventGetLocation(event)};
    }
    os_unfair_lock_unlock(&gestureLock);
}
bool np_corner_witness_end(uint64_t tag, NCGestureRead *out) {
    if (!tag || !out)
        return false;
    os_unfair_lock_lock(&gestureLock);
    bool owned = atomic_load(&gestureTag) == tag;
    if (owned) {
        *out = gestureReceipt;
        atomic_store(&gestureTag, 0);
        gestureReceipt = (NCGestureRead){0};
    }
    os_unfair_lock_unlock(&gestureLock);
    return owned;
}
#endif
