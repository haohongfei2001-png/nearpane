#include <CoreGraphics/CGWindow.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// Read IDs only. The public onscreen list is checked against a still-visible sibling
// of the same enrolled fixture; no titles, images, or other IDs leave this process.
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    CGWindowID closed = (CGWindowID)strtoul(argv[1], NULL, 10);
    CGWindowID sibling = (CGWindowID)strtoul(argv[2], NULL, 10);
    if (!closed || !sibling || closed == sibling) return 64;
    CFArrayRef target = CGWindowListCreate(kCGWindowListOptionIncludingWindow, closed);
    CFArrayRef witness = CGWindowListCreate(kCGWindowListOptionIncludingWindow, sibling);
    CFArrayRef visible = CGWindowListCreate(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    const char *state = "unknown";
    if (target && witness && visible && CFArrayGetCount(witness) == 1) {
        CFRange all = CFRangeMake(0, CFArrayGetCount(visible));
        if (CFArrayContainsValue(visible, all, CFArrayGetValueAtIndex(witness, 0))) {
            if (CFArrayGetCount(target) == 0) state = "absent";
            if (CFArrayGetCount(target) == 1) {
                state = CFArrayContainsValue(visible, all, CFArrayGetValueAtIndex(target, 0))
                        ? "onscreen" : "registered-offscreen";
            }
        }
    }
    puts(state);
    if (target) CFRelease(target);
    if (witness) CFRelease(witness);
    if (visible) CFRelease(visible);
    return 0;
}
