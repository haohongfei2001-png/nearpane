// HOLDSNOW capture-environment helper. Not product code.
// Private CGVirtualDisplay interfaces and creation strategy independently adapted
// from Chromium's BSD-licensed virtual_display_util_mac.mm (see companion notes).
// No captureDisplay/cacheDisplay, view scaling, mirroring, SIP changes or reboot.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@property(strong, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(strong, nonatomic) id queue;
@property(copy, nonatomic) id terminationHandler;
@end
@interface CGVirtualDisplayMode : NSObject
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)hz;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(strong, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

static CGVirtualDisplay *heldDisplay;
static volatile sig_atomic_t stopped = 0;
static void stopSignal(int signalNumber) { stopped = 1; }
static void pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!stopped && [end timeIntervalSinceNow] > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
}
static NSDictionary *rect(CGRect r) {
    return @{ @"x":@(r.origin.x), @"y":@(r.origin.y),
              @"width":@(r.size.width), @"height":@(r.size.height) };
}
static NSDictionary *modeInfo(CGDisplayModeRef m) {
    if (!m) return @{};
    size_t w=CGDisplayModeGetWidth(m), h=CGDisplayModeGetHeight(m);
    size_t pw=CGDisplayModeGetPixelWidth(m), ph=CGDisplayModeGetPixelHeight(m);
    return @{ @"modeID":@(CGDisplayModeGetIODisplayModeID(m)), @"width":@(w), @"height":@(h),
      @"pixelWidth":@(pw), @"pixelHeight":@(ph), @"scaleX":@(w ? (double)pw/w : 0),
      @"scaleY":@(h ? (double)ph/h : 0), @"refreshRate":@(CGDisplayModeGetRefreshRate(m)),
      @"ioFlags":@(CGDisplayModeGetIOFlags(m)), @"desktopUsable":@(CGDisplayModeIsUsableForDesktopGUI(m)) };
}
static NSArray *displayModes(CGDirectDisplayID display) {
    NSDictionary *options=@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES};
    CFArrayRef copied=CGDisplayCopyAllDisplayModes(display,(__bridge CFDictionaryRef)options);
    return copied ? CFBridgingRelease(copied) : @[];
}
static BOOL hidpiMode(CGDisplayModeRef mode) {
    if (!mode) return NO;
    size_t w=CGDisplayModeGetWidth(mode), h=CGDisplayModeGetHeight(mode);
    return w>=640 && h>=400 && CGDisplayModeGetPixelWidth(mode)>=w*2 &&
           CGDisplayModeGetPixelHeight(mode)>=h*2 && CGDisplayModeIsUsableForDesktopGUI(mode);
}
static CGDisplayModeRef bestHiDPI(CGDirectDisplayID display) {
    CGDisplayModeRef current=CGDisplayCopyDisplayMode(display);
    if (hidpiMode(current)) return current;
    if(current) CGDisplayModeRelease(current);
    CGDisplayModeRef best=NULL;
    size_t bestPixels=SIZE_MAX;
    for(id object in displayModes(display)) {
        CGDisplayModeRef mode=(__bridge CGDisplayModeRef)object;
        size_t pixels=CGDisplayModeGetPixelWidth(mode)*CGDisplayModeGetPixelHeight(mode);
        if(hidpiMode(mode) && pixels<bestPixels) {
            if(best) CGDisplayModeRelease(best);
            best=CGDisplayModeRetain(mode); bestPixels=pixels;
        }
    }
    return best;
}
static NSScreen *screenFor(CGDirectDisplayID display) {
    for(NSScreen *screen in NSScreen.screens)
        if([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]==display) return screen;
    return nil;
}
static NSDictionary *displayInfo(CGDirectDisplayID display) {
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(display);
    NSScreen *screen=screenFor(display);
    uint32_t count=0; CGDirectDisplayID ids[32]={0};
    NSInteger activeIndex=0, onlineIndex=0, screenIndex=0;
    if(CGGetActiveDisplayList(32,ids,&count)==kCGErrorSuccess)
        for(uint32_t i=0;i<count;i++) if(ids[i]==display) activeIndex=i+1;
    if(CGGetOnlineDisplayList(32,ids,&count)==kCGErrorSuccess)
        for(uint32_t i=0;i<count;i++) if(ids[i]==display) onlineIndex=i+1;
    for(NSUInteger i=0;i<NSScreen.screens.count;i++)
        if([NSScreen.screens[i].deviceDescription[@"NSScreenNumber"] unsignedIntValue]==display) screenIndex=i+1;
    BOOL ready=hidpiMode(mode) && screen && screen.backingScaleFactor>=2 &&
               CGDisplayMirrorsDisplay(display)==kCGNullDirectDisplay;
    NSMutableArray *modes=[NSMutableArray array];
    for(id object in displayModes(display)) [modes addObject:modeInfo((__bridge CGDisplayModeRef)object)];
    NSDictionary *result=@{ @"displayID":@(display), @"ready":@(ready),
      @"main":@(display==CGMainDisplayID()), @"online":@(CGDisplayIsOnline(display)),
      @"active":@(CGDisplayIsActive(display)), @"mirrorOf":@(CGDisplayMirrorsDisplay(display)),
      @"vendor":@(CGDisplayVendorNumber(display)), @"model":@(CGDisplayModelNumber(display)),
      @"cgBounds":rect(CGDisplayBounds(display)), @"currentMode":modeInfo(mode),
      @"nsScreenFound":@(screen!=nil), @"backingScaleFactor":@(screen ? screen.backingScaleFactor : 0),
      @"nsFrame":screen ? rect(NSRectToCGRect(screen.frame)) : @{},
      @"nsVisibleFrame":screen ? rect(NSRectToCGRect(screen.visibleFrame)) : @{},
      @"activeDisplayIndexCandidate":@(activeIndex), @"onlineDisplayIndexCandidate":@(onlineIndex),
      @"nsScreenIndexCandidate":@(screenIndex),
      @"indexWarning":@"These are candidates, not verified screencapture -D indices. Verify a full-display PNG pixel size before video capture, or target CGDisplayID with ScreenCaptureKit.",
      @"modes":modes };
    if(mode) CGDisplayModeRelease(mode);
    return result;
}
static NSArray *allDisplays(void) {
    uint32_t count=0; CGDirectDisplayID ids[32]={0}; NSMutableArray *out=[NSMutableArray array];
    if(CGGetOnlineDisplayList(32,ids,&count)==kCGErrorSuccess)
        for(uint32_t i=0;i<count;i++) [out addObject:displayInfo(ids[i])];
    return out;
}
static void emit(NSDictionary *object,NSString *path) {
    NSError *error=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    if(!data) { fprintf(stderr,"JSON error: %s\n",error.description.UTF8String); return; }
    if(path) [data writeToFile:path options:NSDataWritingAtomic error:&error];
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout); fflush(stdout);
    if(error) fprintf(stderr,"Write error: %s\n",error.description.UTF8String);
}
static NSString *arg(NSArray<NSString *> *args,NSString *name,NSString *fallback) {
    NSUInteger i=[args indexOfObject:name];
    return i!=NSNotFound && i+1<args.count ? args[i+1] : fallback;
}
int main(int argc,const char *argv[]) {
 @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSArray<NSString *> *args=NSProcessInfo.processInfo.arguments;
    NSString *output=arg(args,@"--output",nil);
    BOOL create=[args containsObject:@"--create"], select=[args containsObject:@"--select-existing"];
    if(!create && !select) { emit(@{@"operation":@"probe",@"displays":allDisplays()},output); return 0; }
    if(select) {
        NSMutableArray *attempts=[NSMutableArray array];
        for(NSDictionary *item in allDisplays()) {
            CGDirectDisplayID display=[item[@"displayID"] unsignedIntValue];
            if([item[@"ready"] boolValue]) { emit(@{@"operation":@"existing",@"selected":item,@"ready":@YES},output); return 0; }
            CGDisplayModeRef candidate=bestHiDPI(display); if(!candidate) continue;
            CGError error=CGDisplaySetDisplayMode(display,candidate,NULL);
            [attempts addObject:@{@"displayID":@(display),@"mode":modeInfo(candidate),@"setError":@(error)}];
            CGDisplayModeRelease(candidate); pump(.5);
            NSDictionary *updated=displayInfo(display);
            if([updated[@"ready"] boolValue]) { emit(@{@"operation":@"select-existing",@"selected":updated,@"attempts":attempts,@"ready":@YES},output); return 0; }
        }
        emit(@{@"operation":@"select-existing",@"ready":@NO,@"attempts":attempts,@"displays":allDisplays()},output); return 2;
    }
    Class descriptorClass=NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass=NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass=NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass=NSClassFromString(@"CGVirtualDisplayMode");
    if(!descriptorClass||!displayClass||!settingsClass||!modeClass) {
        emit(@{@"operation":@"create",@"ready":@NO,@"error":@"CGVirtualDisplay private classes unavailable",@"displays":allDisplays()},output); return 3;
    }
    unsigned int width=(unsigned int)[arg(args,@"--width",@"1920") intValue];
    unsigned int height=(unsigned int)[arg(args,@"--height",@"1080") intValue];
    if(width<1280||height<800||width>4096||height>3072||width%2||height%2) { fprintf(stderr,"Expected even physical dimensions within 1280x800–4096x3072\n"); return 64; }
    CGVirtualDisplayDescriptor *descriptor=[[descriptorClass alloc] init];
    descriptor.name=@"Nearpane Capture Retina 2x";
    descriptor.queue=dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0);
    descriptor.vendorID=505; descriptor.productID=0x4e50;
    descriptor.serialNum=(unsigned int)getpid()+270000;
    if([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber=descriptor.serialNum;
    descriptor.maxPixelsWide=width; descriptor.maxPixelsHigh=height;
    descriptor.sizeInMillimeters=CGSizeMake(width*25.4/220,height*25.4/220);
    descriptor.whitePoint=CGPointMake(.3125,.3291); descriptor.redPrimary=CGPointMake(.6797,.3203);
    descriptor.greenPrimary=CGPointMake(.2559,.6983); descriptor.bluePrimary=CGPointMake(.1494,.0557);
    descriptor.terminationHandler=nil;
    heldDisplay=[[displayClass alloc] initWithDescriptor:descriptor];
    if(!heldDisplay) { emit(@{@"operation":@"create",@"ready":@NO,@"error":@"initWithDescriptor returned nil; headless/VM support is not guaranteed",@"displays":allDisplays()},output); return 4; }
    CGVirtualDisplaySettings *settings=[[settingsClass alloc] init]; settings.hiDPI=1; settings.rotation=0;
    settings.modes=@[[[modeClass alloc] initWithWidth:width/2 height:height/2 refreshRate:60]];
    BOOL applied=[heldDisplay applySettings:settings];
    CGDirectDisplayID display=heldDisplay.displayID;
    if(!applied||!display) { emit(@{@"operation":@"create",@"ready":@NO,@"applied":@(applied),@"displayID":@(display),@"error":@"applySettings failed or displayID is zero",@"displays":allDisplays()},output); return 5; }
    pump(.4);
    CGDisplayConfigRef configuration=NULL; CGError configError=CGBeginDisplayConfiguration(&configuration);
    if(configError==kCGErrorSuccess) {
        CGRect main=CGDisplayBounds(CGMainDisplayID());
        CGConfigureDisplayMirrorOfDisplay(configuration,display,kCGNullDirectDisplay);
        CGConfigureDisplayOrigin(configuration,display,(int32_t)CGRectGetMaxX(main),0);
        configError=CGCompleteDisplayConfiguration(configuration,kCGConfigureForSession);
    }
    NSDictionary *selected=nil;
    for(int attempt=0;attempt<50;attempt++) {
        selected=displayInfo(display); if([selected[@"ready"] boolValue]) break;
        CGDisplayModeRef candidate=bestHiDPI(display);
        if(candidate) { CGDisplaySetDisplayMode(display,candidate,NULL); CGDisplayModeRelease(candidate); }
        pump(.1);
    }
    BOOL ready=[selected[@"ready"] boolValue];
    emit(@{@"operation":@"create",@"ready":@(ready),@"pid":@(getpid()),@"selected":selected ?: @{},
      @"configurationError":@(configError),@"requestedPhysicalWidth":@(width),@"requestedPhysicalHeight":@(height),
      @"headlessCaution":@"Chromium currently excludes headless bots from its support check; this helper reports actual mode and AppKit scale instead of assuming success.",
      @"displays":allDisplays()},output);
    if(!ready) return 6;
    signal(SIGTERM,stopSignal); signal(SIGINT,stopSignal);
    double seconds=[arg(args,@"--seconds",@"1800") doubleValue];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:MAX(1,seconds)];
    while(!stopped && [end timeIntervalSinceNow]>0) pump(.1);
    // Holding the object for the process lifetime keeps the display connected.
    // The temporary display is removed when this helper process exits.
    return 0;
 }
}
