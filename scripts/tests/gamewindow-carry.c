// The exec chain wine uses for an i386 process when x87 acceleration is on, with a stand-in for
// the client at the end of it:
//
//   carry wine <self>   exec ROSETTA_X87_PATH --cooperative <self> probe "two words" "q'u\"o te"
//                       exactly as athei's wine does (ntdll preloader_exec, commit 3804c30b)
//   carry probe ...     report what arrived: DYLD_INSERT_LIBRARIES, whether gamewindow.dylib is
//                       mapped, the pid, and the arguments; then, when the sidecar named this pid
//                       (X87_SIDECAR_BOOTSTRAP), do the cooperative handshake exactly as wine's
//                       x87_cooperative_handshake does (athei/wine 3804c30b, loader.c), wait for the
//                       sidecar's reply (its x87 JIT hook installed), run x87 arithmetic and report
//
// Built x86_64 and run directly (not through arch(1), which strips DYLD_*), so both halves run
// under Rosetta the way wine does. Build/run: scripts/tests/gamewindow-test.sh
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// athei/x87sidecar rosetta_loader/src/coop_proto.h (238a214)
#define X87_COOP_ENV "X87_SIDECAR_BOOTSTRAP"
#define X87_COOP_MSGH_ID 0x78383721
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t task_port;
    mach_msg_port_descriptor_t thread_port;
} coop_request_t;
typedef struct {
    mach_msg_header_t header;
    uint64_t icache_addr[2];
    uint64_t icache_len[2];
} coop_reply_t;

static int mapped(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "gamewindow.dylib")) return 1;
    }
    return 0;
}

/// 0 when the sidecar accepted this process and replied; negative before a message was sent,
/// 0x1000 + kr when its reply did not come.
static int handshake(void) {
    const char *name = getenv(X87_COOP_ENV);
    if (!name || !*name) return -1;
    const char *dot = strrchr(name, '.');
    if (!dot || atoi(dot + 1) != (int)getpid()) return -2;   // named for another pid
    mach_port_t bootstrap = MACH_PORT_NULL, service = MACH_PORT_NULL, reply = MACH_PORT_NULL;
    if (task_get_bootstrap_port(mach_task_self(), &bootstrap) != KERN_SUCCESS) return -3;
    if (bootstrap_look_up(bootstrap, name, &service) != KERN_SUCCESS) return -4;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
    coop_request_t msg;
    memset(&msg, 0, sizeof(msg));
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE)
                         | MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = service;
    msg.header.msgh_local_port = reply;
    msg.header.msgh_id = X87_COOP_MSGH_ID;
    msg.body.msgh_descriptor_count = 2;
    msg.task_port.name = mach_task_self();
    msg.task_port.disposition = MACH_MSG_TYPE_COPY_SEND;
    msg.task_port.type = MACH_MSG_PORT_DESCRIPTOR;
    msg.thread_port.name = mach_thread_self();
    msg.thread_port.disposition = MACH_MSG_TYPE_COPY_SEND;
    msg.thread_port.type = MACH_MSG_PORT_DESCRIPTOR;
    if (mach_msg(&msg.header, MACH_SEND_MSG, sizeof(msg), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE,
                 MACH_PORT_NULL) != KERN_SUCCESS) return -5;
    struct { coop_reply_t r; mach_msg_trailer_t t; char slack[64]; } rep;
    memset(&rep, 0, sizeof(rep));
    kern_return_t kr = mach_msg(&rep.r.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(rep), reply,
                                30000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) return 0x1000 + kr;
    for (int i = 0; i < 2; i++)
        if (rep.r.icache_len[i])
            sys_icache_invalidate((void *)(uintptr_t)rep.r.icache_addr[i], (size_t)rep.r.icache_len[i]);
    unsetenv(X87_COOP_ENV);
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
        fflush(stdout);
        if (getenv(X87_COOP_ENV)) {
            int h = handshake();
            volatile long double x = 0.5L;   // long double: x87 arithmetic on x86_64
            long double sum = 0;
            for (int i = 0; i < 1000; i++) sum += x * (long double)i;
            printf("probe: x87 handshake=%d sum=%.1Lf\n", h, sum);
        }
        return 0;
    }
    puts("usage: carry wine <path-to-this-binary> | carry probe ...");
    return 2;
}
