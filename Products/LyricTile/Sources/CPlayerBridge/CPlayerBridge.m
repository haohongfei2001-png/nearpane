#import "CPlayerBridge.h"
#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import <math.h>
#import <libproc.h>
#import <sys/sysctl.h>

// Only selectors present in the Music/Spotify scripting dictionaries are declared.
// There are no generated third-party bridge headers or private entitlements here.
@protocol LTPApplication
@property (readonly) unsigned int playerState;
@property double playerPosition;
@property (readonly) SBObject *currentTrack;
- (void)play;
- (void)playOnce:(BOOL)once;
- (void)pause;
- (void)nextTrack;
- (void)previousTrack;
@end

@interface LTPErrorDelegate : NSObject <SBApplicationDelegate>
@property (nonatomic, strong, nullable) NSError *lastError;
@end
@implementation LTPErrorDelegate
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
    self.lastError = error;
    // Abort this bounded probe on the first failed event, instead of making N
    // further 1.5-second calls. The outer @catch converts it to a value for Swift.
    @throw [NSException exceptionWithName:@"LTPAppleEventError" reason:error.localizedDescription userInfo:nil];
}
@end

@interface LTPEntry : NSObject
@property (nonatomic, strong) SBApplication *application;
@property (nonatomic, strong) LTPErrorDelegate *errorDelegate;
@property (nonatomic, strong, nullable) NSDate *launchDate;
@end
@implementation LTPEntry
@end

static NSMutableDictionary<NSNumber *, LTPEntry *> *entries;

static NSData *json(NSDictionary *dictionary) {
    NSData *value = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
    return value ?: [@"{\"errorCode\":-1,\"error\":\"Invalid bridge response\"}" dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *failure(NSInteger code, NSString *message) {
    return json(@{@"errorCode": @(code), @"error": message ?: @"Apple Events unavailable"});
}

static LTPEntry *entryForPID(int32_t pid, BOOL spotify) {
    NSRunningApplication *running = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *expected = spotify ? @"com.spotify.client" : @"com.apple.Music";
    if (!running || running.terminated || ![running.bundleIdentifier isEqualToString:expected]) return nil;
    if (!entries) entries = [NSMutableDictionary dictionary];
    LTPEntry *entry = entries[@(pid)];
    if (entry && ![entry.launchDate isEqualToDate:running.launchDate]) {
        [entries removeObjectForKey:@(pid)]; entry = nil;
    }
    if (!entry) {
        SBApplication *application = [SBApplication applicationWithProcessIdentifier:pid];
        if (!application) return nil;
        entry = [LTPEntry new];
        entry.application = application;
        entry.launchDate = running.launchDate;
        entry.errorDelegate = [LTPErrorDelegate new];
        application.delegate = entry.errorDelegate;
        application.timeout = 90; // Apple Event ticks, 60 ticks/second.
        application.sendMode = kAEWaitReply | kAENeverInteract;
        entries[@(pid)] = entry;
    }
    entry.errorDelegate.lastError = nil;
    // Remove exited instances; the cache remains bounded by the two players.
    for (NSNumber *key in entries.allKeys) {
        NSRunningApplication *cached = [NSRunningApplication runningApplicationWithProcessIdentifier:key.intValue];
        if (!cached || cached.terminated) {
            [entries removeObjectForKey:key];
        }
    }
    return entry;
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:NSString.class] && [value length] <= 4096 ? value : nil;
}
static NSNumber *numberValue(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : nil;
}
static NSString *stateString(unsigned int value) {
    switch (value) {
        case 0x6b505350: return @"playing"; // kPSP
        case 0x6b505370: return @"paused";  // kPSp
        case 0x6b505353: return @"stopped"; // kPSS
        default: return @"unknown";
    }
}

NSData *LTPReadPlayer(int32_t pid, BOOL spotify, BOOL includeArtwork) {
    @synchronized (LTPEntry.class) {
        @autoreleasepool {
            LTPEntry *entry = nil;
            @try {
                entry = entryForPID(pid, spotify);
                if (!entry) return failure(-600, @"Player is not running");
                id<LTPApplication> app = (id<LTPApplication>)entry.application;
                unsigned int state = app.playerState;
                NSMutableDictionary *result = [@{@"pid": @(pid), @"state": stateString(state)} mutableCopy];
                if (state == 0x6b505353) return json(result);
                SBObject *track = app.currentTrack;
                NSDictionary *properties = [track valueForKey:@"properties"];
                if (![properties isKindOfClass:NSDictionary.class]) properties = @{};
                NSDictionary *mapping = @{@"name": @"title", @"artist": @"artist", @"album": @"album",
                                           @"persistentID": @"persistentID", @"id": @"trackID",
                                           @"spotifyUrl": @"spotifyURL", @"artworkUrl": @"artworkURL"};
                for (NSString *key in mapping) {
                    NSString *value = stringValue(properties[key]);
                    if (value) result[mapping[key]] = value;
                }
                NSNumber *duration = numberValue(properties[@"duration"]);
                if (duration && duration.doubleValue >= 0) result[@"duration"] = duration;
                double position = app.playerPosition;
                result[@"sampleEpochMicros"] = @((int64_t)(NSDate.date.timeIntervalSince1970 * 1000000));
                if (isfinite(position) && position >= 0) result[@"positionSeconds"] = @(position);
                // Do not combine the old track's metadata with the next track's
                // position if a transition occurs during the Apple Events round trip.
                NSString *identityKey = spotify ? @"id" : @"persistentID";
                NSString *beforeID = stringValue(properties[identityKey]);
                NSString *afterID = stringValue([app.currentTrack valueForKey:identityKey]);
                if (beforeID.length && afterID.length && ![beforeID isEqualToString:afterID]) {
                    return failure(-10001, @"Track changed during probe");
                }
                result[@"state"] = stateString(app.playerState);
                // Bulk properties omit raw artwork in both players. Fetch only on
                // an explicit track-generation request; the caller never asks per frame.
                if (includeArtwork && !spotify) {
                    @try {
                        SBElementArray *artworks = [track valueForKey:@"artworks"];
                        if (artworks.count > 0) {
                            id art = [artworks objectAtIndex:0];
                            id raw = [art valueForKey:@"rawData"];
                            if ([raw isKindOfClass:NSData.class] && [raw length] <= 8 * 1024 * 1024) {
                                result[@"artworkBase64"] = [raw base64EncodedStringWithOptions:0];
                            }
                        }
                    } @catch (NSException *artError) {
                        // Artwork is optional. Preserve valid metadata, not a fake image.
                        entry.errorDelegate.lastError = nil;
                    }
                }
                return json(result);
            } @catch (NSException *exception) {
                NSError *error = entry.errorDelegate.lastError;
                return failure(error ? error.code : -1, error.localizedDescription ?: exception.reason);
            }
        }
    }
}

NSData *LTPCommandPlayer(int32_t pid, BOOL spotify, NSString *command, double positionSeconds) {
    @synchronized (LTPEntry.class) {
        @autoreleasepool {
            LTPEntry *entry = nil;
            @try {
                entry = entryForPID(pid, spotify);
                if (!entry) return failure(-600, @"Player is not running");
                id<LTPApplication> app = (id<LTPApplication>)entry.application;
                if ([command isEqualToString:@"play"]) {
                    if (spotify) [app play]; else [app playOnce:NO];
                } else if ([command isEqualToString:@"pause"]) [app pause];
                else if ([command isEqualToString:@"next"]) [app nextTrack];
                else if ([command isEqualToString:@"previous"]) [app previousTrack];
                else if ([command isEqualToString:@"seek"] && isfinite(positionSeconds) && positionSeconds >= 0) {
                    app.playerPosition = positionSeconds;
                } else return failure(-1708, @"Unsupported transport command");
                return json(@{@"accepted": @YES});
            } @catch (NSException *exception) {
                NSError *error = entry.errorDelegate.lastError;
                return failure(error ? error.code : -1, error.localizedDescription ?: exception.reason);
            }
        }
    }
}

void LTPReleasePlayers(void) {
    @synchronized (LTPEntry.class) { entries = nil; }
}

uint64_t LTPProcessStartMicros(int32_t pid) {
    struct proc_bsdinfo info = {0};
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (size != sizeof(info)) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
}

NSString *LTPSystemBuild(void) {
    char build[256] = {0}; size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) != 0) return @"unknown";
    build[sizeof(build) - 1] = 0;
    return [NSString stringWithUTF8String:build] ?: @"unknown";
}
