// The same Rust Spaces engine owns its WindowServer connection and live AX leases
// here. Losing the Host channel enters release-only cleanup, never a new writer.
#import "nearpane_spaces_worker.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <libproc.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <unistd.h>

_Static_assert(sizeof(NPSpacesWorkerRequest)==264,"Spaces worker request ABI");
_Static_assert(sizeof(NPSpacesWorkerReply)==144,"Spaces worker reply ABI");
static uint64_t engine;
static pid_t parentPID;
static uint64_t parentBirth;
static int parentWatch=-1;
static NSMutableSet<NSNumber *> *pending;

static uint64_t processBirth(pid_t pid) {
    struct proc_bsdinfo row={0};
    return pid>1 && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&row,sizeof(row))==(int)sizeof(row) &&
        row.pbi_uid==getuid() && row.pbi_start_tvsec && row.pbi_start_tvusec<1000000
        ? row.pbi_start_tvsec*1000000+row.pbi_start_tvusec : 0;
}
static void record(const char *phase,uint32_t transport,const NPReceipt *receipt) {
    fprintf(stderr,"{\"event\":\"spacesWorker\",\"phase\":\"%s\",\"pid\":%d,\"parentPID\":%d,\"transport\":%u,\"status\":%u,\"detail\":%u,\"flags\":%u,\"owned\":%u}\n",
        phase,getpid(),parentPID,transport,receipt?receipt->status:0,receipt?receipt->detail:0,receipt?receipt->flags:0,receipt?receipt->owned:0);
    fflush(stderr);
}
static BOOL privatePipesAndParent(void) {
    struct stat input={0},output={0};
    if(fstat(STDIN_FILENO,&input)||fstat(STDOUT_FILENO,&output)||!S_ISFIFO(input.st_mode)||!S_ISFIFO(output.st_mode))return NO;
    parentPID=getppid();parentBirth=processBirth(parentPID);
    char ownPath[PROC_PIDPATHINFO_MAXSIZE]={0},hostPath[PROC_PIDPATHINFO_MAXSIZE]={0};
    char ownReal[PATH_MAX]={0},hostReal[PATH_MAX]={0};
    if(!parentBirth || proc_pidpath(getpid(),ownPath,sizeof(ownPath))<=0 ||
       proc_pidpath(parentPID,hostPath,sizeof(hostPath))<=0 || !realpath(ownPath,ownReal) || !realpath(hostPath,hostReal))return NO;
    NSString *own=@(ownReal), *host=@(hostReal);
    NSString *contents=own.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    if(![own.lastPathComponent isEqual:@"NearpaneSpacesEngine"] ||
       ![own.stringByDeletingLastPathComponent.lastPathComponent isEqual:@"Helpers"] ||
       ![host isEqual:[contents stringByAppendingPathComponent:@"MacOS/NearpaneHost"]])return NO;
    parentWatch=kqueue();if(parentWatch<0)return NO;
    struct kevent event;EV_SET(&event,(uintptr_t)parentPID,EVFILT_PROC,EV_ADD|EV_ENABLE,NOTE_EXIT|NOTE_EXEC,0,NULL);
    if(kevent(parentWatch,&event,1,NULL,0,NULL)!=0 || getppid()!=parentPID || processBirth(parentPID)!=parentBirth)return NO;
    return YES;
}
static BOOL parentStillOwnsChannel(void) {
    struct kevent event={0};struct timespec now={0};
    int count=kevent(parentWatch,NULL,0,&event,1,&now);
    return count==0 && getppid()==parentPID && processBirth(parentPID)==parentBirth;
}
static BOOL writeReply(NPSpacesWorkerReply *reply) {
    reply->magic=NP_SW_MAGIC;reply->version=NP_SW_VERSION;reply->size=sizeof(*reply);
    if(engine)(void)np_engine_epoch(engine,&reply->epoch);
    const uint8_t *bytes=(const uint8_t *)reply;size_t offset=0;
    while(offset<sizeof(*reply)) {
        ssize_t n=write(STDOUT_FILENO,bytes+offset,sizeof(*reply)-offset);
        if(n>0){offset+=(size_t)n;continue;}
        if(n<0 && errno==EINTR)continue;
        if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) {
            struct pollfd fd={.fd=STDOUT_FILENO,.events=POLLOUT};
            if(poll(&fd,1,1000)>0 && !(fd.revents&(POLLERR|POLLHUP|POLLNVAL)))continue;
        }
        return NO; // EPIPE joins EOF cleanup; it must never kill a Space owner.
    }
    return YES;
}
static NPReceipt emptyReceipt(void) {
    return (NPReceipt){.size=sizeof(NPReceipt),.version=NP_ENGINE_ABI};
}
static void consumePending(void) {
    while(pending.count) {
        @autoreleasepool {
            for(NSNumber *key in pending.allObjects) {
                NPReceipt result=emptyReceipt();
                uint32_t code=np_engine_poll(engine,key.unsignedLongLongValue,&result);
                if(code!=NP_PENDING)[pending removeObject:key];
            }
        }
        if(pending.count)[NSThread sleepForTimeInterval:.01];
    }
}
static void releaseAfterChannelLoss(const char *reason) {
    record(reason,NP_OK,NULL);
    (void)np_engine_revoke(engine);
    consumePending();
    unsigned attempts=0;
    for(;;) {
        // The ABI refuses destroy while a worker, lease or owned Space survives.
        if(np_engine_destroy(engine)==NP_OK){engine=0;record("released",NP_OK,NULL);return;}
        @autoreleasepool {
            uint64_t epoch=0,ticket=0;
            uint32_t code=np_engine_epoch(engine,&epoch);
            NPRequest request={.size=sizeof(request),.version=NP_ENGINE_ABI,.backend=NP_SPACES,
                .operation=NP_RELEASE_SPACES,.timeout_ms=10000,.epoch=epoch};
            [NSUUID.UUID getUUIDBytes:request.intent];
            if(code==NP_OK)code=np_engine_submit(engine,&request,&ticket);
            NPReceipt result=emptyReceipt();
            if(code==NP_OK) {
                do {code=np_engine_poll(engine,ticket,&result);if(code==NP_PENDING)[NSThread sleepForTimeInterval:.01];}
                while(code==NP_PENDING);
            }
            if(code==NP_OK && result.status==NP_PASS && result.owned==0 && !(result.flags&NP_OWNED) &&
               np_engine_destroy(engine)==NP_OK){engine=0;record("released",NP_OK,&result);return;}
            // Keep the original engine/AX leases if recovery is unknown. No Corner,
            // new identity lookup, forced exit or fabricated restoration is allowed.
            if(attempts++%15==0)record("release-pending",code,&result);
        }
        [NSThread sleepForTimeInterval:2];
    }
}
static int serve(void) {
    @autoreleasepool {
        pending=[NSMutableSet set];
        uint32_t created=np_engine_create_spaces_candidate(&engine);
        record("ready",created,NULL);
        NPSpacesWorkerReply ready={.operation=NP_SW_READY,.transport=created};
        if(!writeReply(&ready)){if(engine)releaseAfterChannelLoss("ready-channel-lost");return 1;}
        if(created!=NP_OK)return 1;
        uint8_t buffer[sizeof(NPSpacesWorkerRequest)]={0};size_t used=0;
        const char *ended="host-eof";
        for(;;) {@autoreleasepool {
            if(!parentStillOwnsChannel()){ended="parent-exited-or-execed";break;}
            struct pollfd sources[2]={{.fd=STDIN_FILENO,.events=POLLIN},{.fd=parentWatch,.events=POLLIN}};
            int observed=poll(sources,2,500);
            if(observed<0 && errno==EINTR)continue;
            if(observed<0){ended="channel-poll-failed";break;}
            if(sources[1].revents){ended="parent-exited-or-execed";break;}
            if(!sources[0].revents)continue;
            if(sources[0].revents&(POLLERR|POLLNVAL)){ended="host-channel-failed";break;}
            ssize_t n=read(STDIN_FILENO,buffer+used,sizeof(buffer)-used);
            if(n<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK))continue;
            if(n<=0){ended=used?"host-eof-partial-packet":"host-eof";break;}
            used+=(size_t)n;if(used<sizeof(buffer))continue;
            NPSpacesWorkerRequest message;memcpy(&message,buffer,sizeof(message));used=0;
            if(!np_spaces_worker_packet_valid(&message)){ended="protocol-rejected";break;}
            if(message.operation==NP_SW_REVOKE){(void)np_engine_revoke(engine);continue;}
            if(message.operation==NP_SW_CANCEL){(void)np_engine_cancel(engine,message.ticket);continue;}
            NPSpacesWorkerReply response={.operation=message.operation,.serial=message.serial,.ticket=message.ticket,
                .receipt=emptyReceipt()};
            if(message.operation==NP_SW_SUBMIT) {
                response.transport=np_engine_submit(engine,&message.request,&response.ticket);
                if(response.transport==NP_OK)[pending addObject:@(response.ticket)];
            } else if(message.operation==NP_SW_POLL) {
                response.transport=np_engine_poll(engine,message.ticket,&response.receipt);
                if(response.transport!=NP_PENDING)[pending removeObject:@(message.ticket)];
            } else {
                response.transport=np_engine_destroy(engine);
                if(response.transport==NP_OK)engine=0;
            }
            if(!writeReply(&response)){ended="reply-channel-lost";break;}
            if(!engine){record("closed",NP_OK,NULL);return 0;}
        }}
        if(engine)releaseAfterChannelLoss(ended);
        return 0;
    }
}
static int protocolSelfTest(void) {
    NPSpacesWorkerRequest p={.magic=NP_SW_MAGIC,.version=NP_SW_VERSION,.size=sizeof(p),.operation=NP_SW_SUBMIT,.serial=1,
        .request={.size=sizeof(NPRequest),.version=NP_ENGINE_ABI,.backend=NP_SPACES}};
    if(!np_spaces_worker_packet_valid(&p))return 1;
    p.request.backend=NP_CORNER;if(np_spaces_worker_packet_valid(&p))return 2;
    p.request.backend=NP_SPACES;p.size--;if(np_spaces_worker_packet_valid(&p))return 3;
    p.size=sizeof(p);p.operation=NP_SW_REVOKE;if(np_spaces_worker_packet_valid(&p))return 4;
    p.serial=0;if(!np_spaces_worker_packet_valid(&p))return 5;
    p.operation=NP_SW_CANCEL;if(np_spaces_worker_packet_valid(&p))return 6;
    p.ticket=1;if(!np_spaces_worker_packet_valid(&p))return 7;
    puts("Spaces worker protocol: PASS (sizes, correlation and Spaces-only boundary)");return 0;
}
int main(int argc,const char **argv) {
    if(argc==2 && !strcmp(argv[1],"--protocol-selftest"))return protocolSelfTest();
    if(argc!=2 || strcmp(argv[1],"--stdio"))return 2;
    signal(SIGPIPE,SIG_IGN);
    @autoreleasepool {
        if(!privatePipesAndParent())return 3;
        for(int fd=STDIN_FILENO;fd<=STDOUT_FILENO;fd++) {
            int flags=fcntl(fd,F_GETFL);if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)return 4;
        }
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
        dispatch_async(dispatch_get_main_queue(),^{
            // Start only after the native event loop services its first callback.
            // The callback itself does not wait for Rust, IPC or Accessibility.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                int code=serve();dispatch_async(dispatch_get_main_queue(),^{exit(code);});
            });
        });
        [NSApp run];return 5;
    }
}
