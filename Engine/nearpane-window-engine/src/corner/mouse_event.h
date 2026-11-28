#pragma once
#include "macos.h"
#import <CoreGraphics/CoreGraphics.h>

static inline int nc_mouse_decision(CGEventType type, CGEventRef event, void *context, NCDecide decide) {
    CGPoint point = CGEventGetLocation(event);
    return decide(context, type, point.x, point.y,
                  CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber),
                  CGEventGetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent),
                  CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID));
}
