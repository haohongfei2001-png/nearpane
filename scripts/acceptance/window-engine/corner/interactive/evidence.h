// Per-intent receipt from the owner's AppKit queue and the actual receiving content view.
// This structure deliberately has no field for an unmarked character or screen coordinate.
#import <Foundation/Foundation.h>

typedef NS_ENUM(unsigned, NPInputPhase) { NPDown, NPDrag, NPUp, NPKeyDown, NPKeyUp };
typedef NS_ENUM(unsigned, NPReceiver) { NPQueue, NPContent };
typedef struct { unsigned down, drag, up; BOOL badOrder; } NPSequence;

@interface NPInputWitness : NSObject {
    NPSequence streams[2][2];
}
@property(readonly) NSUUID *intent;
@property(readonly) uint64_t tag;
@property(readonly) NSString *marker;
@property(readonly) pid_t source;
@property(readonly) unsigned slot;
@property(readonly) BOOL keyboard;
@property(readonly) double started;
@property(readonly) double deadline;
@property BOOL interrupted;
- (instancetype)initWithIntent:(NSUUID *)intent source:(pid_t)source slot:(unsigned)slot keyboard:(BOOL)key now:(double)now;
- (void)receive:(NPInputPhase)phase from:(pid_t)source tag:(uint64_t)tag slot:(unsigned)slot stream:(NPReceiver)stream
            now:(double)now markerMatches:(BOOL)matches;
- (NSDictionary *)resultAt:(double)now;
@end

@implementation NPInputWitness
- (instancetype)initWithIntent:(NSUUID *)intent source:(pid_t)source slot:(unsigned)slot keyboard:(BOOL)key now:(double)now {
    if ((self = [super init])) {
        _intent = [intent copy];
        _source = source;
        _slot = slot;
        _keyboard = key;
        _started = now;
        _deadline = now + 5;
        uint64_t random;
        arc4random_buf(&random, sizeof(random));
        _tag = NC_FIXTURE_GESTURE_PREFIX | (random & ~NC_FIXTURE_GESTURE_MASK);
        _marker = key ? NSUUID.UUID.UUIDString.lowercaseString : nil;
    }
    return self;
}
- (void)receive:(NPInputPhase)phase from:(pid_t)source tag:(uint64_t)tag slot:(unsigned)slot stream:(NPReceiver)stream
            now:(double)now markerMatches:(BOOL)matches {
    if (slot >= 2 || stream > NPContent) return;
    if (source != _source || tag != _tag || now < _started || now > _deadline) {
        _interrupted = YES;
        return;
    }
    NPSequence *s = &streams[slot][stream];
    if (_keyboard != (phase == NPKeyDown || phase == NPKeyUp)) {
        s->badOrder = YES;
        return;
    }
    switch (phase) {
        case NPDown: case NPKeyDown:
            if (s->down || s->drag || s->up || (_keyboard && !matches)) s->badOrder = YES;
            s->down++;
            break;
        case NPDrag:
            if (s->down != 1 || s->up) s->badOrder = YES;
            s->drag++;
            break;
        case NPUp: case NPKeyUp:
            if (s->down != 1 || s->up || (!_keyboard && !s->drag)) s->badOrder = YES;
            s->up++;
            break;
    }
}
- (NSDictionary *)resultAt:(double)now {
    NSMutableArray *observed = [NSMutableArray array];
    BOOL complete = YES, absent = YES, violated = NO;
    for (unsigned role = 0; role < 2; role++) {
        NSMutableArray *stages = [NSMutableArray array];
        for (unsigned stream = 0; stream < 2; stream++) {
            NPSequence s = streams[role][stream];
            BOOL any = (s.down || s.drag || s.up || s.badOrder);
            absent &= !any;
            violated |= s.badOrder || (role != _slot && any);
            if (role == _slot) complete &= s.down == 1 && s.up == 1 && (_keyboard ? s.drag == 0 : s.drag > 0);
            [stages addObject:@{@"down":@(s.down), @"drag":@(s.drag), @"up":@(s.up), @"orderConflict":@(s.badOrder)}];
        }
        if (role == _slot) {
            NPSequence a = streams[role][NPQueue], b = streams[role][NPContent];
            complete &= a.down == b.down && a.drag == b.drag && a.up == b.up;
        }
        [observed addObject:@{@"role":role == 0 ? @"target" : @"sibling", @"appQueue":stages[0], @"contentView":stages[1]}];
    }
    NSString *reason = _interrupted ? @"sourceOrInputInterrupted" : now > _deadline ? @"intentExpired"
                    : violated ? @"wrongReceiverMarkerOrOrder" : complete ? @"matchingQueueAndContentDelivery"
                    : absent ? @"noMatchingDelivery" : @"incompleteDelivery";
    NSString *status = [reason isEqual:@"matchingQueueAndContentDelivery"] ? @"PASS" :
                       [reason isEqual:@"wrongReceiverMarkerOrOrder"] ? @"FAIL" : @"UNKNOWN";
    return @{@"status":status, @"reason":reason, @"intent":_intent.UUIDString.lowercaseString,
             @"receiver":_slot == 0 ? @"target" : @"sibling", @"kind":_keyboard ? @"key" : @"mouse",
             @"sourcePID":@(_source), @"receivers":observed, @"deadlineUptime":@(_deadline)};
}
@end
