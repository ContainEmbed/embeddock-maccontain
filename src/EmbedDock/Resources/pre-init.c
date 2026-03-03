/*
 * pre-init — Minimal init shim for the Containerization VM.
 *
 * The guest vminitd is a Swift binary whose runtime reads /proc/self/exe
 * during startup.  Since vminitd IS the init process (PID 1), /proc is
 * not yet mounted when the kernel execs it, causing a SIGSEGV.
 *
 * This tiny C program runs as the real PID 1 instead:
 *   1. mount procfs  on /proc   (Swift runtime needs /proc/self/exe)
 *   2. mount sysfs   on /sys
 *   3. mount devtmpfs on /dev    (may already be auto-mounted by kernel)
 *   4. exec /sbin/vminitd        (becomes the "real" init)
 *
 * Compiled with musl for static linking — zero runtime dependencies.
 *
 *   zig cc --target=aarch64-linux-musl -static -Os -o pre-init pre-init.c
 *   — or —
 *   musl-gcc -static -Os -o pre-init pre-init.c
 */

#include <sys/mount.h>
#include <unistd.h>
#include <stdio.h>

static void try_mount(const char *src, const char *target,
                      const char *fstype, unsigned long flags) {
    if (mount(src, target, fstype, flags, "") != 0) {
        /* Best-effort: some mounts may already exist (e.g. devtmpfs). */
        perror(target);
    }
}

int main(void) {
    try_mount("proc",     "/proc", "proc",     MS_NOSUID | MS_NODEV | MS_NOEXEC);
    try_mount("sysfs",    "/sys",  "sysfs",    MS_NOSUID | MS_NODEV | MS_NOEXEC);
    try_mount("devtmpfs", "/dev",  "devtmpfs", MS_NOSUID);

    char *const argv[] = { "/sbin/vminitd", NULL };
    char *const envp[] = { "HOME=/", "TERM=linux", NULL };

    execve("/sbin/vminitd", argv, envp);

    /* If execve returns, something went very wrong. */
    perror("execve /sbin/vminitd");
    return 1;
}
