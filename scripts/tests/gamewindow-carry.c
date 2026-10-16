// The exec chain wine uses for an i386 process when x87 acceleration is on, with a stand-in for
// the client at the end of it:
//
//   carry wine <self>   exec ROSETTA_X87_PATH --cooperative <self> probe "two words" "q'u\"o te"
//                       exactly as athei's wine does (ntdll preloader_exec, commit 3804c30b)
//   carry probe ...     report what arrived: DYLD_INSERT_LIBRARIES, whether gamewindow.dylib is
//                       mapped, the pid, and the arguments
//
// Built x86_64 and run directly (not through arch(1), which strips DYLD_*), so both halves run
// under Rosetta the way wine does. Build/run: scripts/tests/gamewindow-test.sh
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int mapped(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "gamewindow.dylib")) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "wine") == 0) {
        const char *sidecar = getenv("ROSETTA_X87_PATH");
        if (!sidecar) { puts("wine: ROSETTA_X87_PATH not set"); return 2; }
        printf("wine: pid=%d mapped=%d\n", (int)getpid(), mapped());
        fflush(stdout);
        char *args[] = { (char *)sidecar, "--cooperative", argv[2], "probe", "two words",
                         "q'u\"o te", NULL };
        execv(sidecar, args);
        perror("wine: execv");
        return 127;
    }
    if (argc >= 2 && strcmp(argv[1], "probe") == 0) {
        const char *ins = getenv("DYLD_INSERT_LIBRARIES");
        printf("probe: pid=%d mapped=%d insert=%s\n", (int)getpid(), mapped(), ins ? ins : "(unset)");
        for (int i = 2; i < argc; i++) printf("probe: arg%d=[%s]\n", i - 1, argv[i]);
        return 0;
    }
    puts("usage: carry wine <path-to-this-binary> | carry probe ...");
    return 2;
}
