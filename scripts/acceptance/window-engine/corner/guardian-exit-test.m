// A disposable parent exits normally. Its real child observes NOTE_EXIT while a third process reaps the parent.
#import "guardian/identity.h"
#import "guardian/exit-watch.h"
#include <stdio.h>
#include <sys/wait.h>

int main(void) {
    int result[2];
    if (pipe(result)) return 2;
    pid_t parent = fork();
    if (parent < 0) return 2;
    if (!parent) {
        int armed[2];
        if (pipe(armed)) _exit(3);
        pid_t child = fork();
        if (child < 0) _exit(3);
        if (!child) {
            close(armed[0]); close(result[0]);
            pid_t observed = getppid();
            uint64_t birth = ncg_birth(observed, NULL);
            int queue = ncg_watch_exit(observed, birth);
            BOOL wrongRefused = ncg_watch_exit(observed, birth + 1) < 0;
            BOOL liveNotExited = queue >= 0 && !ncg_saw_exit(queue, observed, birth, 30) && ncg_birth(observed, NULL) == birth;
            char ready = liveNotExited ? 'A' : 'X';
            if (write(armed[1], &ready, 1) != 1) _exit(4);
            close(armed[1]);
            BOOL exitSeen = queue >= 0 && ncg_saw_exit(queue, observed, birth, 3000);
            if (queue >= 0) close(queue);
            char flags[3] = {wrongRefused, liveNotExited, exitSeen};
            _exit(write(result[1], flags, sizeof(flags)) == sizeof(flags) ? 0 : 5);
        }
        close(armed[1]); close(result[0]); close(result[1]);
        char value;
        _exit(read(armed[0], &value, 1) == 1 && value == 'A' ? 0 : 6);
    }
    close(result[1]);
    int status;
    if (waitpid(parent, &status, 0) != parent) return 7;
    char flags[3] = {0};
    if (read(result[0], flags, sizeof(flags)) != sizeof(flags)) return 8;
    BOOL normal = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    printf("{\"scope\":\"kernelParentExitOnly\",\"normalExit\":%s,\"foreignBirthRejected\":%s,"
           "\"livingParentRejected\":%s,\"kernelExitAndGenerationGone\":%s,\"windowWrites\":0}\n",
           normal ? "true":"false", flags[0] ? "true":"false", flags[1] ? "true":"false", flags[2] ? "true":"false");
    return normal && flags[0] && flags[1] && flags[2] ? 0 : 1;
}
