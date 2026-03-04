#include <sys/mount.h>
#include <unistd.h>
#include <stdio.h>

int main(void) {
    // Mount /proc before exec'ing vminitd — the Swift runtime needs /proc/self/exe.
    // Only /proc is mounted here; all other filesystems (/sys, /tmp, /dev/pts, cgroup2)
    // are mounted later by vminitd's standardSetup() over gRPC.
    if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "") != 0) {
        perror("/proc");
    }

    char *const argv[] = { "/sbin/vminitd", NULL };
    char *const envp[] = { "HOME=/", "TERM=linux", NULL };
    execve("/sbin/vminitd", argv, envp);

    perror("execve /sbin/vminitd");
    return 1;
}
