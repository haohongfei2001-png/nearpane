#import <Foundation/Foundation.h>
#import <libproc.h>
#import <sys/stat.h>
#import <unistd.h>
#import <limits.h>
#import <errno.h>
#import <stdlib.h>

static NSDictionary *inspectPath(NSString *path) {
    if (!path) return @{ @"input": NSNull.null };
    char resolved[PATH_MAX] = {0};
    errno = 0;
    BOOL canonical = realpath(path.fileSystemRepresentation, resolved) != NULL;
    int canonicalError = errno;
    struct stat info = {0};
    errno = 0;
    BOOL exists = stat(path.fileSystemRepresentation, &info) == 0;
    int statError = errno;
    return @{ @"input": path,
              @"realpath": canonical ? @(resolved) : (id)NSNull.null,
              @"realpathError": @(canonical ? 0 : canonicalError),
              @"statSucceeded": @(exists), @"statError": @(exists ? 0 : statError),
              @"regularFile": @(exists && S_ISREG(info.st_mode)),
              @"device": exists ? @((unsigned long long)info.st_dev) : (id)NSNull.null,
              @"inode": exists ? @((unsigned long long)info.st_ino) : (id)NSNull.null };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        char kernel[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int count = proc_pidpath(getpid(), kernel, sizeof(kernel));
        NSString *raw = count > 0 ? @(kernel) : nil;
        NSString *foundation = raw ? [NSURL fileURLWithPath:raw].URLByResolvingSymlinksInPath.path : nil;
        NSDictionary *result = @{ @"purpose": @"readOnlySelfExecutablePathProbe",
            @"pid": @(getpid()), @"parentPID": @(getppid()), @"procPIDPathResult": @(count),
            @"invocation": inspectPath(argc > 0 ? @(argv[0]) : nil),
            @"kernel": inspectPath(raw), @"foundation": inspectPath(foundation),
            @"rawStringMatchesFoundation": @(raw && [raw isEqualToString:foundation]) };
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        if (!data) return 2;
        [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
        [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        return count > 0 ? 0 : 2;
    }
}
