#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdio.h>

static bool secure;
static uint32_t hardware, session;
static bool readButton(CGEventSourceStateID source, CGMouseButton button) {
    assert(button < 32);
    assert(source == kCGEventSourceStateHIDSystemState || source == kCGEventSourceStateCombinedSessionState);
    const uint32_t mask = source == kCGEventSourceStateHIDSystemState ? hardware : session;
    return (mask & (UINT32_C(1) << button)) != 0;
}

#define CGEventSourceButtonState readButton
#define IsSecureEventInputEnabled() secure
#include "input_state.h"

int main(void) {
    assert(!np_stage_input_interrupted());
    for (unsigned i = 0; i < 32; ++i) {
        hardware = UINT32_C(1) << i;
        assert(np_stage_input_interrupted());
        hardware = 0;
        session = UINT32_C(1) << i;
        assert(np_stage_input_interrupted());
        session = 0;
    }
    secure = true;
    assert(np_stage_input_interrupted());
    puts("{\"quiet\":true,\"heldButtonCases\":64,\"secureInputRejected\":true,\"systemInputEvents\":0}");
}
