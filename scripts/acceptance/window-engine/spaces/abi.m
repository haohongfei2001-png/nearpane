// Read-only symbol/type/target report. This process does not create an NSApplication or connect to WindowServer.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "platform.h"
int main(void) {
    @autoreleasepool {
        int flags=np_stage_symbols();
        Class cls=objc_lookUpClass("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation");
        Method init=cls?class_getInstanceMethod(cls,sel_registerName("initWithSpaceID:windows:options:")):NULL;
        Method perform=cls?class_getInstanceMethod(cls,sel_registerName("performWithWMBridgeDelegate")):NULL;
        NSDictionary *data=@{@"kind":@"passiveABI",@"status":@"NOT_QUALIFIED",@"targetExactBuildSIP":@(np_stage_target_build()),
            @"core":@((flags&1)!=0),@"classic":@((flags&2)!=0),@"bridgeTyped":@((flags&4)!=0),
            @"initializerEncoding":init?[NSString stringWithUTF8String:method_getTypeEncoding(init)]:@"absent",
            @"performEncoding":perform?[NSString stringWithUTF8String:method_getTypeEncoding(perform)]:@"absent",
            @"systemWrites":@0,@"fixtureWindows":@0};
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingSortedKeys error:NULL];
        fwrite(bytes.bytes,1,bytes.length,stdout);puts("");
    } return 0;
}
