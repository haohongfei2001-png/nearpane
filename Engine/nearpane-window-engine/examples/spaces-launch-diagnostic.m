// Own-process panel lifecycle diagnostic. No user or fixture window can be named.
// Link with the shipping platform.m; this does not grant third-party qualification.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <stdio.h>
#import "platform.h"

static atomic_bool finished;
static int allowed(void *context) { return context != NULL; }
static void releaseContext(void *context) { free(context); }
static void emit(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if(data){fwrite(data.bytes,1,data.length,stdout);puts("");fflush(stdout);}
}
static void run(void) {
    @autoreleasepool {
        void *token=np_stage_launch_candidate_token();
        emit(@{@"event":@"ownPanelEnvironment",@"accessibility":@(AXIsProcessTrusted()),
            @"symbols":@(np_stage_symbols()),@"supported":@(np_stage_candidate_supported()),@"token":@(token!=NULL)});
        if(token) {
            for(unsigned step=0;step<6;step++) {
                unsigned op=step==0?0:step==1?1:step==4?3:2;
                NPStageCanary panel={0};void *context=(op==1||op==3)?malloc(1):NULL;
                int result=np_stage_launch_call(token,op,context,allowed,releaseContext,&panel);
                uint64_t ids[128]={0};NPStageWindow cg={0};
                int count=panel.number?np_stage_membership(np_stage_connection(),panel.number,ids,128):-2;
                int read=panel.number?np_stage_window(panel.number,&cg):-2;
                NSMutableArray *spaces=[NSMutableArray array];for(int i=0;i<count;i++)[spaces addObject:@(ids[i])];
                emit(@{@"event":@"ownPanelCall",@"operation":@(op),@"result":@(result),@"number":@(panel.number),
                    @"registered":@(panel.registered),@"opened":@(panel.opened),@"absent":@(panel.absent),
                    @"focusSame":@(panel.focus_same),@"closeIssued":@(panel.close_issued),
                    @"membershipCount":@(count),@"membership":spaces,@"cgRead":@(read),@"onScreen":@(cg.onboard)});
                [NSThread sleepForTimeInterval:0.05];
            }
            np_stage_release(token);
        }
        atomic_store(&finished,true);
        dispatch_async(dispatch_get_main_queue(),^{[NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];});
    }
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
        atomic_init(&finished,false);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{run();});
        if(argc==2&&!strcmp(argv[1],"--manual-pump")) {
            while(!atomic_load(&finished))[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        } else { [NSApp run]; }
        return 0;
    }
}
