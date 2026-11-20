#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Bind the actual Apple symbolic action (not only a matching shortcut in another app).
static BOOL matches(id node, NSNumber *identifier, NSNumber *key) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id item in node) if (matches(item, identifier, key)) return YES;
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        if ([node[@"sybmolichotkey"] isEqual:identifier] && [node[@"key"] isEqual:key] &&
            [node[@"modifier"] unsignedIntegerValue] == kCGEventFlagMaskControl &&
            [node[@"name"] isEqual:[identifier intValue] == 79 ? @"DO_NOT_LOCALIZE: Move to previous space" : @"DO_NOT_LOCALIZE: Move to next space"]) return YES;
        for (id child in [node allValues]) if (matches(child, identifier, key)) return YES;
    }
    return NO;
}
int NPP0SystemArrowEnabled(int code) {
    if (code != kVK_LeftArrow && code != kVK_RightArrow) return 0;
    NSNumber *ident = @(code == kVK_LeftArrow ? 79 : 81), *key = @(code);
    NSString *path = @"/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/Resources/en.lproj/DefaultShortcutsTable.xml";
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    id table = bytes ? [NSPropertyListSerialization propertyListWithData:bytes options:0 format:nil error:nil] : nil;
    if (!matches(table,ident,key)) return 0;
    NSDictionary *prefs=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AppleSymbolicHotKeys"),CFSTR("com.apple.symbolichotkeys")));
    NSDictionary *action=prefs[ident.stringValue];
    if (![action[@"enabled"] boolValue]) return 0;
    NSArray *override=action[@"value"][@"parameters"];
    if (override && (override.count!=3 || ![override[1] isEqual:key] || [override[2] unsignedIntegerValue]!=kCGEventFlagMaskControl)) return 0;
    CFArrayRef result=NULL;
    if(CopySymbolicHotKeys(&result)!=noErr || !result) return 0;
    for (NSDictionary *entry in CFBridgingRelease(result)) {
        NSUInteger flags=[entry[(__bridge NSString *)kHISymbolicHotKeyModifiers] unsignedIntegerValue];
        if ([entry[(__bridge NSString *)kHISymbolicHotKeyCode] isEqual:key] &&
            [entry[(__bridge NSString *)kHISymbolicHotKeyEnabled] boolValue] &&
            (flags==controlKey || flags==(controlKey | kEventKeyModifierFnMask))) return 1;
    }
    return 0;
}
