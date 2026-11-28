// Pure data cases for target-only relocation policy. No WindowServer or GUI calls.
#define main unusedOccupancyCLI
#include "secondary-occupancy.m"
#undef main

int main(void) { @autoreleasepool {
    NSSet *empty = [NSSet set], *w = [NSSet setWithObject:@42];
    NSArray *order = @[@"A", @"B"];
    NSSet *AB = [NSSet setWithArray:order], *B = [NSSet setWithObject:@"B"];
    NSArray *cases = @[
        // targets, public all, public non-desktop, reverse A, reverse B, forward, expected
        @[empty, w, w, empty, empty, @{}, @"absent"],
        @[w, w, w, empty, w, @{@42:B}, @"blocking"],
        @[w, w, w, w, w, @{@42:AB}, @"shared"],
        @[w, w, w, empty, w, @{@42:AB}, @"blocking"],
        @[w, w, w, w, w, @{}, @"blocking"],
        @[w, empty, empty, empty, w, @{}, @"blocking"],
        @[w, w, empty, empty, w, @{}, @"desktop"],
        @[w, w, w, w, empty, @{@42:AB}, @"blocking"],
    ];
    for (NSArray *c in cases) {
        NSDictionary *result = classifyTargetWindows(c[0], c[1], c[2], order, @{@"A":c[3],@"B":c[4]}, c[5]);
        BOOL absent = [c[6] isEqual:@"absent"];
        NSUInteger total = [result[@"blocking"] count] + [result[@"desktop"] count] + [result[@"shared"] count];
        if ((absent && total != 0) || (!absent && (total != 1 || ![result[c[6]] isEqual:w]))) return 1;
    }
    NSArray *crossChecks = @[
        @[AB, @{@42:AB}, @{@"A":w,@"B":w}, @YES],
        @[AB, @{@42:B}, @{@"A":w,@"B":w}, @NO],
        @[AB, @{@42:AB}, @{@"A":empty,@"B":w}, @NO],
        @[empty, @{}, @{}, @NO],
    ];
    for (NSArray *c in crossChecks) {
        if (verifiedOnAllDesktopRecords(c[0], @42, c[1], c[2]) != [c[3] boolValue]) return 1;
    }
    printf("%lu current-display shared membership cases passed\n",(unsigned long)crossChecks.count);
    printf("%lu target occupancy cases passed\n", (unsigned long)cases.count);
    return 0;
}}
