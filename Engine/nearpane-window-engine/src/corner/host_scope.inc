// Linked into the real engine/Host. Only the getters needed by the explicit read-only diagnostic are resolved.
#include "../../include/nearpane_host_scope.h"
typedef struct {
    int32_t (*connection)(void);
    CFArrayRef (*managed)(int32_t);
    uint64_t (*direct)(int32_t, CFStringRef);
    CFArrayRef (*reverse)(int32_t, int32_t, CFArrayRef);
    CFArrayRef (*forward)(int32_t, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
} NPScopeReaders;
static const NPScopeReaders *np_scope_readers(void) {
    static NPScopeReaders r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *lib =
          dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
      if (!lib)
          return;
      r.connection = dlsym(lib, "SLSMainConnectionID");
      r.managed = dlsym(lib, "SLSCopyManagedDisplaySpaces");
      r.direct = dlsym(lib, "SLSManagedDisplayGetCurrentSpace");
      r.reverse = dlsym(lib, "SLSCopySpacesForWindows");
      r.forward = dlsym(lib, "SLSCopyWindowsWithOptionsAndTags");
    });
    return &r;
}
static BOOL np_scope_connected(const NPScopeReaders *r, int32_t expected, int32_t *error) {
    if (!r->connection) {
        *error = NP_SCOPE_NO_SYMBOL;
        return NO;
    }
    if (expected <= 0 || r->connection() != expected) {
        *error = NP_SCOPE_CONNECTION;
        return NO;
    }
    *error = NP_SCOPE_OK;
    return YES;
}
static NSArray *np_scope_array(CFArrayRef copy, NSUInteger maximum, int32_t *error) {
    id list = CFBridgingRelease(copy);
    if (!list) {
        *error = NP_SCOPE_NO_REPLY;
        return nil;
    }
    if (![list isKindOfClass:NSArray.class] || [list count] > maximum) {
        *error = NP_SCOPE_SHAPE;
        return nil;
    }
    return list;
}
static NSDictionary *np_scope_space(id obj) {
    if (![obj isKindOfClass:NSDictionary.class])
        return @{};
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"id64", @"ManagedSpaceID", @"type" ])
        if (obj[key])
            row[key] = nc_integer(obj[key]) ?: NSNull.null;
    if (obj[@"uuid"])
        row[@"uuid"] = nc_uuid(obj[@"uuid"]).UUIDString ?: NSNull.null;
    return row;
}
CFArrayRef np_host_scope_copy_managed(int32_t *connection, int32_t *error) {
    @autoreleasepool {
        const NPScopeReaders *r = np_scope_readers();
        *connection = r->connection ? r->connection() : 0;
        if (!np_scope_connected(r, *connection, error))
            return NULL;
        if (!r->managed) {
            *error = NP_SCOPE_NO_SYMBOL;
            return NULL;
        }
        NSArray *raw = np_scope_array(r->managed(*connection), 32, error);
        if (!raw)
            return NULL;
        NSMutableArray *result = [NSMutableArray array];
        for (id d in raw) {
            if (![d isKindOfClass:NSDictionary.class]) {
                *error = NP_SCOPE_SHAPE;
                return NULL;
            }
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            id token = d[@"Display Identifier"];
            if (token)
                row[@"Display Identifier"] =
                    [token isEqual:@"Main"] ? @"Main" : (nc_uuid(token) ? token : NSNull.null);
            if ([d[@"Current Space"] isKindOfClass:NSDictionary.class])
                row[@"Current Space"] = np_scope_space(d[@"Current Space"]);
            id spaces = d[@"Spaces"];
            if ([spaces isKindOfClass:NSArray.class]) {
                if ([spaces count] > 256) {
                    *error = NP_SCOPE_SHAPE;
                    return NULL;
                }
                NSMutableArray *members = [NSMutableArray array];
                for (id space in spaces)
                    [members addObject:np_scope_space(space)];
                row[@"Spaces"] = members;
            }
            [result addObject:row];
        }
        if (!np_scope_connected(r, *connection, error))
            return NULL;
        return CFBridgingRetain(result);
    }
}
uint64_t np_host_scope_direct(int32_t connection, CFStringRef display, int32_t *error) {
    @autoreleasepool {
        const NPScopeReaders *r = np_scope_readers();
        if (!np_scope_connected(r, connection, error))
            return 0;
        if (!r->direct) {
            *error = NP_SCOPE_NO_SYMBOL;
            return 0;
        }
        id token = (__bridge id)display;
        if (![token isEqual:@"Main"] && !nc_uuid(token)) {
            *error = NP_SCOPE_ARGUMENT;
            return 0;
        }
        uint64_t value = r->direct(connection, display);
        if (!np_scope_connected(r, connection, error))
            return 0;
        if (!value)
            *error = NP_SCOPE_NO_REPLY;
        return value;
    }
}
CFArrayRef np_host_scope_reverse(int32_t connection, uint32_t window, int32_t *error) {
    @autoreleasepool {
        const NPScopeReaders *r = np_scope_readers();
        if (!np_scope_connected(r, connection, error))
            return NULL;
        if (!r->reverse) {
            *error = NP_SCOPE_NO_SYMBOL;
            return NULL;
        }
        if (!window) {
            *error = NP_SCOPE_ARGUMENT;
            return NULL;
        }
        NSArray *raw =
            np_scope_array(r->reverse(connection, 7, (__bridge CFArrayRef) @[ @(window) ]), 256, error);
        if (!raw)
            return NULL;
        for (id n in raw)
            if (!nc_integer(n) || [n unsignedLongLongValue] == 0) {
                *error = NP_SCOPE_SHAPE;
                return NULL;
            }
        if (!np_scope_connected(r, connection, error))
            return NULL;
        return CFBridgingRetain(raw);
    }
}
int32_t np_host_scope_forward_hits(int32_t connection, uint64_t space, uint32_t window, int32_t *error) {
    @autoreleasepool {
        const NPScopeReaders *r = np_scope_readers();
        if (!np_scope_connected(r, connection, error))
            return -1;
        if (!r->forward) {
            *error = NP_SCOPE_NO_SYMBOL;
            return -1;
        }
        if (!window || !space) {
            *error = NP_SCOPE_ARGUMENT;
            return -1;
        }
        uint64_t set = 0, clear = 0;
        NSArray *raw = np_scope_array(
            r->forward(connection, 0, (__bridge CFArrayRef) @[ @(space) ], 7, &set, &clear), 8192, error);
        if (!raw)
            return -1;
        int32_t hits = 0;
        for (id n in raw) {
            if (!nc_integer(n) || ![n unsignedLongLongValue] || [n unsignedLongLongValue] > UINT32_MAX) {
                *error = NP_SCOPE_SHAPE;
                return -1;
            }
            if ([n unsignedIntValue] == window)
                hits++;
        }
        return np_scope_connected(r, connection, error) ? hits : -1;
    }
}
