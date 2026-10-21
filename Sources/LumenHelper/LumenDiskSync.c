#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// QEMU on macOS uses fsync. Upgrade only this VM's disk to F_FULLFSYNC
// in Maximum safety mode; firmware, pipes and unrelated files retain fsync.
// Balanced continues to acknowledge every flush after fsync completes.
static struct stat lumenDisk;
static int fullDiskSync;

__attribute__((constructor)) static void configureDiskSync(void) {
    const char *mode = getenv("LUMEN_VM_DISK_SYNC");
    const char *path = getenv("LUMEN_VM_DISK_PATH");
    fullDiskSync = mode && path && !strcmp(mode, "safest") &&
        stat(path, &lumenDisk) == 0 && S_ISREG(lumenDisk.st_mode);
}

static int lumen_fsync(int fd) {
    struct stat file;
    if (fullDiskSync && fstat(fd, &file) == 0 &&
        file.st_dev == lumenDisk.st_dev && file.st_ino == lumenDisk.st_ino) {
        return fcntl(fd, F_FULLFSYNC);
    }
    return fsync(fd);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } lumenSyncInterpose = {
    (const void *)lumen_fsync, (const void *)fsync
};
