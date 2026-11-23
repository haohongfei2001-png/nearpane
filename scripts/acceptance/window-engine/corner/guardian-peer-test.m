// Real disposable children and kernel notifications. No AX, event posting or WindowServer requests.
#import "guardian/identity.h"
#import "guardian/exit-watch.h"
#import "guardian/peer-watch.h"
#include <signal.h>
#include <sys/wait.h>

static BOOL readByte(int fd, char expected) {
    char value;
    return read(fd, &value, 1) == 1 && value == expected;
}

static int testPeer(const char *program) {
    int command[2], response[2];
    if (pipe(command) || pipe(response)) return 2;
    pid_t child = fork();
    if (child < 0) return 3;
    if (!child) {
        close(command[1]); close(response[0]);
        if (dup2(command[0], STDIN_FILENO) < 0 || dup2(response[1], STDOUT_FILENO) < 0) _exit(4);
        close(command[0]); close(response[1]);
        if (write(STDOUT_FILENO, "R", 1) != 1 || !readByte(STDIN_FILENO, 'X')) _exit(5);
        execl(program, program, "--after-exec", NULL);
        _exit(6);
    }
    close(command[0]); close(response[1]);
    BOOL ready = readByte(response[0], 'R');
    uint64_t birth = ncg_birth(child, NULL);
    int watch = ncg_open_child_watch(child, birth);
    int mustNotSeeExit = ncg_watch_exit(child, birth);
    int wrong = ncg_open_child_watch(child, birth + 1);
    BOOL live = ncg_child_watch_live(watch, child, birth);
    BOOL replaced = write(command[1], "X", 1) == 1 && readByte(response[0], 'E');
    BOOL execRejected = replaced && ncg_live_child(child, birth) && !ncg_child_watch_live(watch, child, birth);
    BOOL execNotExit = replaced && mustNotSeeExit >= 0 && !ncg_saw_exit(mustNotSeeExit, child, birth, 2000);
    if (mustNotSeeExit >= 0) close(mustNotSeeExit);
    int next = ncg_open_child_watch(child, birth);
    int exitWatch = ncg_watch_exit(child, birth);
    BOOL newLive = ncg_child_watch_live(next, child, birth);
    close(command[1]);
    int status = 0;
    BOOL exited = waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status);
    BOOL exitRejected = exited && !ncg_child_watch_live(next, child, birth);
    BOOL kernelExit = exited && ncg_saw_exit(exitWatch, child, birth, 2000);
    if (exitWatch >= 0) close(exitWatch);
    close(response[0]);
    if (watch >= 0) close(watch);
    if (next >= 0) close(next);
    if (wrong >= 0) close(wrong);

    int channel[2];
    if (pipe(channel)) return 7;
    pid_t sender = fork();
    if (sender < 0) return 8;
    if (!sender) {
        close(channel[0]);
        sleep(9); // Exceeds the former eight-second packet deadline.
        _exit(write(channel[1], "C", 1) == 1 ? 0 : 9);
    }
    close(channel[1]);
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL delayed = ncg_wait_for_host_message(channel[0]) && ncg_next_host_packet(channel[0]) == 1 && readByte(channel[0], 'C');
    uint64_t elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1000000;
    BOOL clean = waitpid(sender, &status, 0) == sender && WIFEXITED(status) && !WEXITSTATUS(status);
    char byte;
    BOOL eof = ncg_next_host_packet(channel[0]) == 0 && read(channel[0], &byte, 1) == 0;
    close(channel[0]);
    int ackPipe[2];
    if (pipe(ackPipe)) return 12;
    BOOL delivered = ncg_ack_committed_park(ackPipe[1]) == NCG_ACK_SENT && readByte(ackPipe[0], 'P');
    close(ackPipe[0]);
    BOOL closed = ncg_ack_committed_park(ackPipe[1]) == NCG_ACK_CLOSED;
    close(ackPipe[1]);
    BOOL badFD = ncg_ack_committed_park(-1) == NCG_ACK_ERROR;
    printf("{\"scope\":\"disposableKernelPeersOnly\",\"pid\":%d,\"birth\":%llu,\"wrongBirthRefused\":%s,"
           "\"liveBeforeExec\":%s,\"sameGenerationExecRejected\":%s,\"liveAfterRebindForTest\":%s,"
           "\"childExitRejected\":%s,\"idleMilliseconds\":%llu,\"delayedCommandReceived\":%s,"
           "\"eofWithoutCommand\":%s,\"childrenReaped\":%s,\"ackDelivered\":%s,\"ackPeerClosed\":%s,"
           "\"otherAckErrorRejected\":%s,\"execIsNotExit\":%s,\"exitIndependentlyObserved\":%s,\"windowWrites\":0}\n",
           child, (unsigned long long)birth, wrong < 0 ? "true":"false", live ? "true":"false",
           execRejected ? "true":"false", newLive ? "true":"false", exitRejected ? "true":"false",
           (unsigned long long)elapsed, delayed ? "true":"false", eof ? "true":"false", clean && exited ? "true":"false",
           delivered ? "true":"false", closed ? "true":"false", badFD ? "true":"false",
           execNotExit ? "true":"false", kernelExit ? "true":"false");
    return ready && wrong < 0 && live && execRejected && newLive && exitRejected &&
           delayed && elapsed > 8000 && eof && clean && delivered && closed && badFD && execNotExit && kernelExit ? 0 : 1;
}

int main(int argc, char **argv) {
    alarm(25);
    signal(SIGPIPE, SIG_IGN);
    if (argc == 2 && !strcmp(argv[1], "--after-exec")) {
        char value;
        return write(STDOUT_FILENO, "E", 1) == 1 && read(STDIN_FILENO, &value, 1) == 0 ? 0 : 10;
    }
    return argc == 1 ? testPeer(argv[0]) : 11;
}
