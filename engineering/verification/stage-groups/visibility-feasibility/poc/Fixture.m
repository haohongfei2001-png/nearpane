#import "Lab.h"

@interface Receiver : NSView
@property NSInteger keys, clicks;
@end
@implementation Receiver
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)keyDown:(NSEvent *)event { if (event.keyCode == 7) self.keys++; }
- (void)mouseDown:(NSEvent *)event { self.clicks++; }
@end
@interface Catcher : NSPanel @end
@implementation Catcher
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
@interface Fixture : NSObject <NSApplicationDelegate>
@property NSString *root, *name, *last;
@property NSMutableArray<NSWindow *> *windows;
@property NSArray *tokens;
@property NSTimer *timer;
@end
@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *expected = [labID stringByAppendingString:self.name.lowercaseString];
    if (![NSRunningApplication.currentApplication.bundleIdentifier isEqual:expected] ||
        ![NSRunningApplication.currentApplication.bundleURL.URLByResolvingSymlinksInPath.path isEqual:NSBundle.mainBundle.bundleURL.URLByResolvingSymlinksInPath.path]) exit(65);
    self.windows = [NSMutableArray array];
    self.tokens = @[NSUUID.UUID.UUIDString, NSUUID.UUID.UUIDString];
    BOOL ownerA = [self.name isEqual:@"A"];
    NSRect area = NSScreen.mainScreen.visibleFrame;
    CGFloat w = MIN(215, floor(area.size.width / 4.2)), h = MIN(155, area.size.height / 3.0);
    for (int index = 0; index < 2; index++) {
        CGFloat x = area.origin.x + 40 + (index == 0 ? 0 : (ownerA ? 1 : 2) * (w + 28));
        NSRect rect = NSMakeRect(x, NSMidY(area) - h/2, w, h);
        NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        NSWindow *win;
        if (!ownerA && index == 0) {
            win = [[Catcher alloc] initWithContentRect:rect styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskNonactivatingPanel) backing:NSBackingStoreBuffered defer:NO];
            [(NSPanel *)win setHidesOnDeactivate:NO];
            win.level = NSNormalWindowLevel;
        } else win = [[NSWindow alloc] initWithContentRect:rect styleMask:mask backing:NSBackingStoreBuffered defer:NO];
        NSString *label = [NSString stringWithFormat:@"%@%d", self.name, index];
        win.title = label; [win setAccessibilityIdentifier:label];
        win.releasedWhenClosed = NO;
        win.contentView = [Receiver new]; [win makeFirstResponder:win.contentView];
        win.backgroundColor = ownerA ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        [self.windows addObject:win]; [win orderFront:nil];
    }
    NSArray *ids = [self.windows valueForKey:@"windowNumber"];
    saveJSON(@{@"pid":@(getpid()),@"generation":@(generation(getpid())),@"bundle":expected,@"windows":ids},
             [self.root stringByAppendingPathComponent:[self.name stringByAppendingString:@".json"]]);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:.025 repeats:YES block:^(__unused NSTimer *timer) { [self tick]; }];
}
- (void)tick {
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self.root stringByAppendingPathComponent:@"stop"]]) { [NSApp terminate:nil]; return; }
    NSDictionary *cmd = readJSON([self.root stringByAppendingPathComponent:[self.name stringByAppendingString:@".command"]]);
    NSString *nonce = cmd[@"nonce"], *op = cmd[@"op"];
    if (![[NSUUID alloc] initWithUUIDString:nonce ?: @""] || [self.last isEqual:nonce]) return;
    self.last = nonce;
    NSUInteger index = [cmd[@"index"] unsignedIntegerValue];
    if (index >= self.windows.count) return;
    NSWindow *target = self.windows[index]; NSDictionary *action = @{};
    if ([op isEqual:@"seed"] && [self.name isEqual:@"A"]) { [NSApp activateIgnoringOtherApps:YES]; [target makeKeyAndOrderFront:nil]; [target makeFirstResponder:target.contentView]; }
    if ([op isEqual:@"front"]) [target orderFront:nil];
    if ([op isEqual:@"present-for-setup"]) [target orderFrontRegardless];
    if ([op isEqual:@"owner-out"]) [target orderOut:nil];
    if ([op isEqual:@"reset"]) { if (target.isMiniaturized) [target deminiaturize:nil]; [target orderFront:nil]; }
    if ([op isEqual:@"mini"]) [target miniaturize:nil];
    if ([op isEqual:@"raw-out"] || [op isEqual:@"raw-in"]) {
        MainConnection main = sky(@"SLSMainConnectionID");
        action = directOrder(main ? main() : 0, (uint32_t)target.windowNumber, [op isEqual:@"raw-out"]);
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.windows.count; i++) {
        NSWindow *w = self.windows[i]; Receiver *v = (Receiver *)w.contentView;
        [rows addObject:@{@"id":@(w.windowNumber),@"visible":@(w.isVisible),@"mini":@(w.isMiniaturized),@"key":@(w.isKeyWindow),
                          @"activeSpace":@(w.isOnActiveSpace),@"frame":rectArray(w.frame),@"keys":@(v.keys),@"clicks":@(v.clicks),
                          @"content":self.tokens[i],@"display":w.screen.deviceDescription[@"NSScreenNumber"] ?: none()}];
    }
    saveJSON(@{@"action":action,@"windows":rows}, [self.root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.json",self.name,nonce]]);
}
@end
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3 || !hosted()) return 64;
    NSString *name = @(argv[1]); if (![@[@"A",@"B"] containsObject:name]) return 64;
    NSApplication *app = NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    Fixture *owner = [Fixture new]; owner.name = name; owner.root = @(argv[2]); app.delegate = owner;
    [app run]; return owner == nil;
}}
