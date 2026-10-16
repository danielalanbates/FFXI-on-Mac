// gamewindow — keep the game's picture in proportion when the player resizes its window.
//
// The problem
// -----------
// FFXI creates its Direct3D back buffer once, at [ffxi.registry] 0001 x 0002, and never resizes
// it. Wine's Mac driver lets the window be dragged to any shape and the renderer scales that fixed
// buffer to fill whatever the window became, so a window dragged wider than it is tall squeezes
// every character and name sideways, and the reverse stretches them.
//
// The fix
// -------
// AppKit already knows how to resize a window in proportion: -[NSWindow setContentAspectRatio:].
// This dylib is inserted into the wine processes (DYLD_INSERT_LIBRARIES, like audiofollow.dylib)
// and, in the one that owns the game window, sets that ratio on it:
//
//   1. the launcher puts the size the client is launched at into HXI_GAME_ASPECT ("1920x1080");
//   2. a constructor observes NSWindowDidBecomeKeyNotification and
//      NSWindowWillStartLiveResizeNotification on the process's local notification center
//      (CFNotificationCenterGetLocalCenter; what AppKit posts through NSNotificationCenter's
//      defaultCenter reaches its observers — the native test checks exactly that);
//   3. for a titled, resizable window of at least 320x240 points, on the main thread, it calls
//      setContentAspectRatio: with that size. AppKit then keeps every drag of an edge or a corner
//      in that proportion.
//
// Without a valid HXI_GAME_ASPECT nothing is observed at all. The window's own shape is not used
// instead: the window cannot be told apart from any other titled window in the process, and the
// shape it has may already be wrong (a window bigger than the screen is cut down on one side only),
// so guessing could lock in exactly the squeeze this is meant to prevent.
//
// The x87 sidecar
// ---------------
// With x87 acceleration on, the game's wine re-execs every i386 process through x87sidecar-coop
// (ROSETTA_X87_PATH, docs/X87-SIDECAR.md). That binary is signed with the hardened runtime, so
// dyld strips every DYLD_* variable from its environment before main(), and the client it execs
// starts without DYLD_INSERT_LIBRARIES: no inserted dylib (this one or audiofollow) ever reaches
// the game. Measured 2026-10-16 with the shipped sidecar: an unsigned child exec'd through it sees
// no DYLD_INSERT_LIBRARIES; the same child exec'd directly does.
//
// So this dylib also carries the list across that one exec. It copies DYLD_INSERT_LIBRARIES into
// HXI_DYLD_INSERT_LIBRARIES at load (a name dyld does not touch), and when wine execs
// "<ROSETTA_X87_PATH> --cooperative <loader> <args>" it asks the sidecar to run
// "/bin/sh -c 'export DYLD_INSERT_LIBRARIES=...; exec "$@"' hxi-carry <loader> <args>" instead.
// The sidecar's handshake is unaffected: sh execs the loader in place, so the pid the sidecar
// registered under is still the client's. Only DYLD_INSERT_LIBRARIES is carried; every other DYLD_*
// variable stays stripped, so the client resolves its libraries exactly as it did before.
// FFXI_GAMEWINDOW_CARRY=0 turns this off. If the rewritten exec fails, wine's own exec runs.
//
// Deliberately conservative:
//   * nothing but libSystem and the Objective-C runtime (in every process already) is linked.
//     CoreFoundation is opened at load only when there is a ratio to keep, and never in
//     wineserver: on macOS 27 it brings Foundation and ~300 other images with it. Every other wine
//     process loads it anyway (wine's ntdll.so links it). AppKit is never loaded by this file: in a
//     process without AppKit windows (services.exe, a plain command-line tool) nothing is ever
//     posted and nothing happens;
//   * every Objective-C call is guarded (class check, respondsToSelector:), on the main thread only,
//     and the only thing ever changed is the content aspect ratio of a qualifying window;
//   * full-screen windows are left alone;
//   * no allocation on the notification path; the carry builds its argv on the stack.
//
// Debug output: set FFXI_GAMEWINDOW_DEBUG=1 to get one stderr line per action.

#include <CoreFoundation/CoreFoundation.h>   // types only: CoreFoundation is not linked (see above)
#include <dlfcn.h>
#include <errno.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// NSSize and NSRect on 64-bit (CGFloat is double): declared here so nothing pulls in AppKit.
typedef struct { double width, height; } gw_size;
typedef struct { double x, y, width, height; } gw_rect;

// NSWindowStyleMask bits (AppKit's values; stable since 10.0 / 10.7 for full screen).
#define GW_TITLED     (1UL << 0)
#define GW_RESIZABLE  (1UL << 3)
#define GW_FULLSCREEN (1UL << 14)

// Smallest content, in points, that counts as a game window. 640x480, the client's floor, is
// 320x240 points under wine's Retina mode.
#define GW_MIN_W 320.0
#define GW_MIN_H 240.0

#define GW_CARRY_ENV "HXI_DYLD_INSERT_LIBRARIES"
#define GW_CARRY_SH  "/bin/sh"
static const char gw_carry_script[] =
    "export DYLD_INSERT_LIBRARIES=\"$" GW_CARRY_ENV "\"; exec \"$@\"";

static int gw_debug = 0;
static int gw_carry = 0;
static double gw_aspect_w = 0, gw_aspect_h = 0;   // 0 = no target, nothing observed

static void gw_log(const char *fmt, ...) {
    if (!gw_debug) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "gamewindow: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

/// "<W>x<H>", both whole numbers in 1...32768 and the ratio within 1:4 ... 4:1. Anything else is
/// ignored: a wrong ratio is worse than none.
static int gw_parse_aspect(const char *s, double *w, double *h) {
    if (!s || !*s) return 0;
    char *end = NULL;
    errno = 0;
    long a = strtol(s, &end, 10);
    if (errno || end == s || *end != 'x') return 0;
    const char *t = end + 1;
    errno = 0;
    long b = strtol(t, &end, 10);
    if (errno || end == t || *end != '\0') return 0;
    if (a < 1 || b < 1 || a > 32768 || b > 32768) return 0;
    if (a > 4 * b || b > 4 * a) return 0;
    *w = (double)a;
    *h = (double)b;
    return 1;
}

static BOOL gw_responds(id obj, SEL sel) {
    static SEL responds;
    if (!responds) responds = sel_registerName("respondsToSelector:");
    return ((BOOL (*)(id, SEL, SEL))objc_msgSend)(obj, responds, sel);
}

static gw_rect gw_frame(id view) {
    static SEL frame;
    if (!frame) frame = sel_registerName("frame");
#if defined(__x86_64__)
    // A 32-byte struct comes back through memory on x86_64, so this needs the _stret entry point.
    return ((gw_rect (*)(id, SEL))objc_msgSend_stret)(view, frame);
#else
    return ((gw_rect (*)(id, SEL))objc_msgSend)(view, frame);
#endif
}

/// Lock `object`'s content aspect ratio, if it is a window this is meant for.
static void gw_lock(const void *object, const char *why) {
    if (!object || gw_aspect_w <= 0 || gw_aspect_h <= 0) return;
    if (!pthread_main_np()) return;   // AppKit windows are only touched on the main thread

    static Class nswindow;
    static SEL isKind, styleMask, contentView, aspect, setAspect;
    if (!nswindow) {
        nswindow = objc_getClass("NSWindow");
        if (!nswindow) return;    // no AppKit in this process: nothing to do
        isKind = sel_registerName("isKindOfClass:");
        styleMask = sel_registerName("styleMask");
        contentView = sel_registerName("contentView");
        aspect = sel_registerName("contentAspectRatio");
        setAspect = sel_registerName("setContentAspectRatio:");
    }

    id win = (id)object;
    if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(win, isKind, nswindow)) {
        gw_log("%s: not a window, ignored", why);
        return;
    }
    if (!gw_responds(win, styleMask) || !gw_responds(win, contentView)
        || !gw_responds(win, aspect) || !gw_responds(win, setAspect)) return;

    unsigned long mask = ((unsigned long (*)(id, SEL))objc_msgSend)(win, styleMask);
    if ((mask & GW_TITLED) == 0 || (mask & GW_RESIZABLE) == 0) {
        gw_log("%s: window %p is not titled and resizable, left alone", why, (void *)win);
        return;
    }
    if (mask & GW_FULLSCREEN) {
        gw_log("%s: window %p is full screen, left alone", why, (void *)win);
        return;
    }

    id view = ((id (*)(id, SEL))objc_msgSend)(win, contentView);
    if (!view) return;
    gw_rect content = gw_frame(view);
    if (!(content.width >= GW_MIN_W && content.height >= GW_MIN_H)) {
        gw_log("%s: window %p is %.0fx%.0f points, too small to be the game, left alone",
               why, (void *)win, content.width, content.height);
        return;
    }

    gw_size current = ((gw_size (*)(id, SEL))objc_msgSend)(win, aspect);
    if (current.width == gw_aspect_w && current.height == gw_aspect_h) return;   // already locked

    gw_size want = { gw_aspect_w, gw_aspect_h };
    ((void (*)(id, SEL, gw_size))objc_msgSend)(win, setAspect, want);
    gw_log("%s: window %p (%.0fx%.0f points) now keeps %.0f:%.0f", why, (void *)win,
           content.width, content.height, gw_aspect_w, gw_aspect_h);
}

static void gw_will_resize(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                           const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_lock(object, "resize");
}

static void gw_became_key(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                          const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_lock(object, "key");
}

/// Open CoreFoundation and observe the two notifications. 1 on success.
static int gw_observe(void) {
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW | RTLD_LOCAL);
    if (!cf) { gw_log("loaded; CoreFoundation unavailable, window shape not kept"); return 0; }
    CFNotificationCenterRef (*localCenter)(void) =
        (CFNotificationCenterRef (*)(void))dlsym(cf, "CFNotificationCenterGetLocalCenter");
    void (*addObserver)(CFNotificationCenterRef, const void *, CFNotificationCallback, CFStringRef,
                        const void *, CFNotificationSuspensionBehavior) =
        (void (*)(CFNotificationCenterRef, const void *, CFNotificationCallback, CFStringRef,
                  const void *, CFNotificationSuspensionBehavior))dlsym(cf, "CFNotificationCenterAddObserver");
    CFStringRef (*makeString)(CFAllocatorRef, const char *, CFStringEncoding) =
        (CFStringRef (*)(CFAllocatorRef, const char *, CFStringEncoding))dlsym(cf, "CFStringCreateWithCString");
    if (!localCenter || !addObserver || !makeString) {
        gw_log("loaded; CoreFoundation is missing a function, window shape not kept");
        return 0;
    }
    CFNotificationCenterRef center = localCenter();
    // Kept for the life of the process: the center holds the names, and so does this.
    CFStringRef resize = makeString(NULL, "NSWindowWillStartLiveResizeNotification", kCFStringEncodingUTF8);
    CFStringRef key = makeString(NULL, "NSWindowDidBecomeKeyNotification", kCFStringEncodingUTF8);
    if (!center || !resize || !key) { gw_log("loaded; no notification center, window shape not kept"); return 0; }
    static int token;   // observer identity; only its address matters
    addObserver(center, &token, gw_will_resize, resize, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    addObserver(center, &token, gw_became_key, key, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    return 1;
}

// ---------------------------------------------------------------------------------------------
// Carrying DYLD_INSERT_LIBRARIES across the x87 sidecar (see the header)
// ---------------------------------------------------------------------------------------------

static int gw_execv(const char *path, char *const argv[]) {
    if (gw_carry && path && argv && argv[0] && argv[1] && argv[2]
        && strcmp(argv[1], "--cooperative") == 0 && argv[2][0] == '/'
        && strcmp(argv[2], GW_CARRY_SH) != 0) {
        const char *sidecar = getenv("ROSETTA_X87_PATH");
        const char *carry = getenv(GW_CARRY_ENV);
        if (sidecar && carry && *carry && strcmp(path, sidecar) == 0 && access(GW_CARRY_SH, X_OK) == 0) {
            size_t n = 0;
            while (argv[n] && n < 4096) n++;
            if (!argv[n]) {
                char *nargv[n + 5];
                nargv[0] = argv[0];
                nargv[1] = argv[1];
                nargv[2] = (char *)GW_CARRY_SH;
                nargv[3] = (char *)"-c";
                nargv[4] = (char *)gw_carry_script;
                nargv[5] = (char *)"hxi-carry";
                for (size_t i = 2; i <= n; i++) nargv[i + 4] = argv[i];   // through the NULL
                gw_log("carrying the inserted libraries through %s for %s", path, argv[2]);
                execv(path, nargv);
                gw_log("carry exec failed (%s); running the sidecar the way wine asked", strerror(errno));
            }
        }
    }
    return execv(path, argv);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *n; const void *o; } gw_i_execv = { (const void *)&gw_execv, (const void *)&execv };

__attribute__((constructor)) static void gw_init(void) {
    const char *d = getenv("FFXI_GAMEWINDOW_DEBUG");
    gw_debug = (d && *d && *d != '0');

    // The carry is only needed (and only armed) where wine will exec through the sidecar.
    const char *off = getenv("FFXI_GAMEWINDOW_CARRY");
    const char *inserted = getenv("DYLD_INSERT_LIBRARIES");
    const char *sidecar = getenv("ROSETTA_X87_PATH");
    if (!(off && *off == '0') && sidecar && *sidecar && inserted && *inserted) {
        if (setenv(GW_CARRY_ENV, inserted, 1) == 0) gw_carry = 1;
    }

    const char *want = getenv("HXI_GAME_ASPECT");
    if (!gw_parse_aspect(want, &gw_aspect_w, &gw_aspect_h)) {
        gw_aspect_w = gw_aspect_h = 0;
        if (want && *want) gw_log("loaded; HXI_GAME_ASPECT=%s is not WIDTHxHEIGHT, window shape not kept", want);
        else gw_log("loaded; no HXI_GAME_ASPECT, window shape not kept%s", gw_carry ? " (carry on)" : "");
        return;
    }

    // wineserver has no windows and never loads CoreFoundation on its own; keep it that way.
    const char *prog = getprogname();
    if (prog && strcmp(prog, "wineserver") == 0) {
        gw_log("loaded in wineserver; nothing to watch");
        return;
    }
    if (!gw_observe()) return;
    gw_log("loaded; keeping game windows at %.0f:%.0f%s", gw_aspect_w, gw_aspect_h,
           gw_carry ? " (carry on)" : "");
}
