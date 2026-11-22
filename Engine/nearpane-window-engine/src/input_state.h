#pragma once
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>

// A button held before the first HID-counter sample produces no new event while stationary.
static inline bool np_stage_mouse_held(void) {
    for (CGMouseButton button = 0; button < 32; ++button)
        if (CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, button) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, button)) return true;
    return false;
}

static inline bool np_stage_input_interrupted(void) {
    return IsSecureEventInputEnabled() || np_stage_mouse_held();
}
