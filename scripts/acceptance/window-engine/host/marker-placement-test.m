// Offline geometry tests. The fixture entry point is linked but never run.
#define NP_SURVIVAL_WINDOW 1
#define NP_FIXTURE_VISUAL_WINDOW 1
#define main membershipFixtureMain
#import "membership-window.m"
#undef main

int main(void) {
    @autoreleasepool {
        NSRect screen = NSMakeRect(20, 30, 800, 600);
        CGRect display = CGRectMake(1000, -100, 800, 600);
        NSRect frame = NSMakeRect(60, 200, 220, 143);
        NSRect farPointer = NSMakeRect(700, 560, 64, 64);
        // The complete Quartz frame starts at (1040, 187). The observer's
        // eight-point sampling band starts at Y = 187 + 143/2 - 4 = 254.
        NSValue *aboveBand = [NSValue valueWithRect:NSMakeRect(1040, 210, 220, 11)];
        NSValue *overBand = [NSValue valueWithRect:NSMakeRect(1040, 211, 220, 12)];
        BOOL whole = NO;
        NSRect result = chooseMarkerFrame(frame, frame, screen, display, farPointer, @[aboveBand], &whole);
        if (!NSEqualRects(result,frame) || whole) return 1;
        result = chooseMarkerFrame(frame, frame, screen, display, farPointer, @[overBand], &whole);
        if (!NSIsEmptyRect(result)) return 2;
        result = chooseMarkerFrame(frame, frame, screen, display, frame, @[], &whole);
        if (!NSIsEmptyRect(result)) return 3;
        NSRect wider = NSMakeRect(frame.origin.x,frame.origin.y,680,frame.size.height);
        result = chooseMarkerFrame(frame, wider, screen, display, farPointer, @[aboveBand], &whole);
        if (!whole || NSMinX(result) <= NSMinX(frame)) return 4;
        NSValue *acrossTop = [NSValue valueWithRect:NSMakeRect(1040, 210, 680, 11)];
        result = chooseMarkerFrame(frame, wider, screen, display, farPointer, @[acrossTop,overBand], &whole);
        if (whole || NSMinX(result) <= NSMinX(frame)+220+32) return 5;
        return 0;
    }
}
