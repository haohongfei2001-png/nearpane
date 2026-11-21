#import "Lab.h"

// Runtime-only declarations for the four classes used by AgentDesk. No framework is embedded.
@protocol Descriptor <NSObject>
- (void)setDispatchQueue:(dispatch_queue_t)q;
- (void)setName:(NSString *)name;
- (void)setVendorID:(unsigned int)n;
- (void)setProductID:(unsigned int)n;
- (void)setSerialNum:(unsigned int)n;
- (void)setSerialNumber:(unsigned int)n;
- (void)setSizeInMillimeters:(CGSize)s;
- (void)setMaxPixelsWide:(unsigned int)n;
- (void)setMaxPixelsHigh:(unsigned int)n;
- (void)setWhitePoint:(CGPoint)p;
- (void)setRedPrimary:(CGPoint)p;
- (void)setGreenPrimary:(CGPoint)p;
- (void)setBluePrimary:(CGPoint)p;
@end
@protocol Display
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (CGDirectDisplayID)displayID;
@end
@protocol Mode
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)hz;
@end
@protocol Settings
- (void)setModes:(NSArray *)modes;
@end
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2 || !hosted() || !fixtureIdentity(@(argv[1]),@"A")) return 64;
    [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
    Class dClass = NSClassFromString(@"CGVirtualDisplayDescriptor"), vClass = NSClassFromString(@"CGVirtualDisplay");
    Class mClass = NSClassFromString(@"CGVirtualDisplayMode"), sClass = NSClassFromString(@"CGVirtualDisplaySettings");
    NSString *file = [@(argv[1]) stringByAppendingPathComponent:@"display.json"];
    id<Descriptor> d = [dClass new];
    if (![d respondsToSelector:@selector(setSerialNumber:)] || !vClass || !mClass || !sClass) {
        saveJSON(@{@"status":@"BLOCKED",@"reason":@"private display ABI unavailable"},file); return 0;
    }
    [d setDispatchQueue:dispatch_get_main_queue()]; [d setName:@"Nearpane disposable visibility fixture"];
    [d setVendorID:0x4e50]; [d setProductID:0x22]; [d setSerialNum:52190]; [d setSerialNumber:52190];
    [d setMaxPixelsWide:800]; [d setMaxPixelsHigh:600]; [d setSizeInMillimeters:CGSizeMake(211,158)];
    [d setWhitePoint:CGPointMake(.3127,.329)]; [d setRedPrimary:CGPointMake(.64,.33)];
    [d setGreenPrimary:CGPointMake(.30,.60)]; [d setBluePrimary:CGPointMake(.15,.06)];
    id<Display> __attribute__((objc_precise_lifetime)) v = [(id<Display>)[vClass alloc] initWithDescriptor:d];
    id<Mode> m = [(id<Mode>)[mClass alloc] initWithWidth:800 height:600 refreshRate:60]; id<Settings> settings = [sClass new];
    if (m) [settings setModes:@[m]];
    if (!v || !m || ![v applySettings:settings]) {
        saveJSON(@{@"status":@"BLOCKED",@"reason":@"virtual display allocation or mode denied"},file); return 0;
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.25]];
    CGDirectDisplayID display = v.displayID;
    CGRect main = CGDisplayBounds(CGMainDisplayID()); CGDisplayConfigRef config = NULL;
    CGError start = CGBeginDisplayConfiguration(&config), origin = kCGErrorFailure, done = kCGErrorFailure;
    if (start == 0) {
        origin = CGConfigureDisplayOrigin(config,display,CGRectGetMaxX(main),CGRectGetMaxY(main));
        if (!origin) done = CGCompleteDisplayConfiguration(config,kCGConfigureForSession); else CGCancelDisplayConfiguration(config);
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.6]];
    saveJSON(@{@"status":(!start && !origin && !done) ? @"READY" : @"BLOCKED",@"id":@(display),@"create":@(start),
               @"origin":@(origin),@"commit":@(done),@"actual":rectArray(CGDisplayBounds(display))},file);
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:100];
    while ([limit timeIntervalSinceNow] > 0 && ![NSFileManager.defaultManager fileExistsAtPath:[@(argv[1]) stringByAppendingPathComponent:@"display-stop"]])
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    return 0;
}}
