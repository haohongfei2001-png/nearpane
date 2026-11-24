#pragma once
#import <ApplicationServices/ApplicationServices.h>

static inline AXUIElementRef cornerFocusedWindow(pid_t pid) {
    if (pid <= 1) return NULL;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef window = NULL;
    if (app) {
        AXUIElementSetMessagingTimeout(app, .15);
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &window);
        CFRelease(app);
    }
    if (window && CFGetTypeID(window) == AXUIElementGetTypeID()) return (AXUIElementRef)window;
    if (window) CFRelease(window);
    return NULL;
}
