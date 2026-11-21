// Exercise the shipping C ABI with a passive Host handle. This process never creates an NSApplication.
#import <Foundation/Foundation.h>
#import <unistd.h>
#import "nearpane_window_engine.h"
#import "platform.h"

static NSDictionary *passiveReceipt(uint64_t handle, uint64_t epoch, uint32_t operation) {
    NPRequest request = {
        .size = sizeof(request), .version = NP_ENGINE_ABI, .backend = NP_SPACES,
        .operation = operation, .timeout_ms = 500, .epoch = epoch
    };
    [NSUUID.UUID getUUIDBytes:request.intent];
    uint64_t ticket = 0;
    uint32_t submit = np_engine_submit(handle, &request, &ticket);
    if (submit != NP_OK) return @{@"refusedWithoutOwnership": @NO, @"submit": @(submit)};

    NPReceipt read = {.size = sizeof(read), .version = NP_ENGINE_ABI};
    double deadline = NSProcessInfo.processInfo.systemUptime + 1;
    uint32_t poll;
    do {
        poll = np_engine_poll(handle, ticket, &read);
        if (poll == NP_PENDING) usleep(1000);
    } while (poll == NP_PENDING && NSProcessInfo.processInfo.systemUptime < deadline);
    BOOL refused = poll == NP_OK && read.status == NP_UNSUPPORTED && read.flags == 0 && read.owned == 0;
    return @{
        @"refusedWithoutOwnership": @(refused), @"submit": @(submit), @"poll": @(poll),
        @"status": @(read.status), @"flags": @(read.flags), @"owned": @(read.owned)
    };
}

int main(void) {
    @autoreleasepool {
        NPConfig config = {.size = sizeof(config), .version = NP_ENGINE_ABI, .mode = NP_HOST};
        uint64_t handle = 0, epoch = 0, unapprovedHandle = 0;
        uint8_t unreviewedEvidence[16] = {1};
        BOOL unapproved = np_engine_create_qualified(NP_SPACES, unreviewedEvidence, &unapprovedHandle)
            == NP_INCOMPATIBLE && unapprovedHandle == 0;
        if (np_engine_create(&config, &handle) != NP_OK || np_engine_epoch(handle, &epoch) != NP_OK) return 2;
        NSDictionary *launch = passiveReceipt(handle, epoch, NP_LAUNCH);
        NSDictionary *cleanup = passiveReceipt(handle, epoch, NP_CLEAN_LAUNCH);
        void *token = np_stage_launch_token();
        BOOL wrongProcessRefused = token == NULL;
        if (token) np_stage_release(token);
        BOOL closed = np_engine_destroy(handle) == NP_OK;
        NSDictionary *report = @{
            @"schema": @1, @"unreviewedEvidenceRefused": @(unapproved),
            @"passiveHostLaunch": launch, @"passiveHostCleanup": cleanup,
            @"wrongExecutableCannotCreateProbeToken": @(wrongProcessRefused),
            @"closedWithoutOwnedResources": @(closed), @"physicalWindowOperations": @0
        };
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        fwrite(encoded.bytes, 1, encoded.length, stdout);
        puts("");
        return unapproved && [launch[@"refusedWithoutOwnership"] boolValue] &&
            [cleanup[@"refusedWithoutOwnership"] boolValue] && wrongProcessRefused && closed ? 0 : 2;
    }
}
