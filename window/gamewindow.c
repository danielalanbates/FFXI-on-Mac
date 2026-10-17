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
// Wine's Mac driver does not get in the way (athei/wine cx-26-patched, dlls/winemac.drv): WineWindow
// resizes through AppKit's own tracking ([super sendEvent:]; its sendEvent: override only handles
// title-bar drags), its setFrame overrides call super, and constrainFrameRect:toScreen: is about
// screens. AppKit applies the ratio *before* calling the delegate's windowWillResize:toSize: and
// uses what the delegate returns (measured on macOS 27 through NSWindow's
// _frame:resizedFromEdge:withDelta:withEvent:, scripts/tests/gamewindow-test.m). WineWindow is its
// own delegate and returns that size unchanged unless the game's window procedure handles
// WM_SIZING and returns TRUE (query_resize_size); DefWindowProc does not handle WM_SIZING.
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
//     and the only things ever changed are the content aspect ratio of a qualifying window and,
//     with HXI_WINDOW_TITLE, the title and Window menu item of a game window (see The title). The
//     not-responding check (below) adds four overrides that each call the one they replaced, a
//     key monitor that passes every key on, and its question; it never changes or drops a request;
//   * full-screen windows are left alone;
//   * no allocation on the notification path; the carry builds its argv on the stack.
//
// The title
// ---------
// Ashita sets the game window's title to the character's name at login (SetWindowText), and
// wine's Mac driver copies every Windows title to the Cocoa window (macdrv_set_cocoa_window_title:
// [window setTitle:], then [NSApp changeWindowsItem:title:filename:] for the Window menu). With
// HXI_WINDOW_TITLE set ("FFXI on Mac"), the first time a game window of wine's (class WineWindow,
// titled, resizable, at least 320x240 points) becomes key or main or comes on screen, this:
//   * overrides -setTitle: once on WineWindow, so a game window's title is always HXI_WINDOW_TITLE
//     and every other window of that class (a message box is not resizable) keeps its own;
//   * overrides -changeWindowsItem:title:filename: once on NSApp's class, the same way, so the
//     Window menu says the same as the title bar;
//   * sets the title, and the Window menu item if the window has one, at once.
// Both overrides call the implementation they replaced. Only windows whose class is or descends
// from WineWindow are touched (never AppKit's own panels). The Windows side is not changed:
// GetWindowText still returns what the game set.
//
// Not responding
// --------------
// A game that hangs with its window up cannot be closed from that window: wine only queues the
// request for the game's own thread, and a hung thread never reads it (athei/wine cx-26-patched,
// dlls/winemac.drv). The red button: WineWindow is its own delegate, and windowShouldClose: posts
// WINDOW_CLOSE_REQUESTED to the window's queue and answers NO (cocoa_window.m:3202-3208); the
// game's thread turns it into WM_SYSCOMMAND/SC_CLOSE (window.c macdrv_window_close_requested).
// Quit (Cmd-Option-Q, cocoa_app.m:367-368; the app menu; the Dock): applicationShouldTerminate:
// posts APP_QUIT_REQUESTED to every queue and answers NSTerminateLater (cocoa_app.m:2655-2696).
// Plain Cmd-Q is no quit at all: wine sends it to the game as Alt-Q (keyboard.c:102, kVK_Command
// is VK_LMENU). AppKit's own thread stays fine, so macOS never calls the game "not responding".
//
// So, from the first game window of wine's on (class WineWindow, titled, resizable, at least
// 320x240 points), this watches each close, each quit and each plain Cmd-Q on a game window the
// way Windows judges a hung window: the request goes to wine unchanged, then, if in the next
// FFXI_GAMEWINDOW_HANG seconds (default 5: Windows' own HungAppTimeout) the game window's thread
// took nothing from its wine event queue (-[WineEventQueue getEventMatchingMask:], which only that
// thread calls and which the request itself wakes) and the game asked for no frame
// (-[CAMetalLayer nextDrawable]: MoltenVK 1.4.2 asks once per frame it presents,
// MVKPresentableSwapchainImage::getCAMetalDrawable; wine's WineMetalLayer goes through super), it
// asks, on AppKit's main thread: "The game isn't responding." Force Quit (Return) / Wait (Escape).
// Force Quit is SIGKILL, as Force Quit in the Apple menu: the launcher sees the game exit and
// wine's own shutdown ends the rest. Wait changes nothing. The question goes away by itself if the
// game reads its input or draws while it is up. It is kept one level above every other visible
// window of the app: wine puts a topmost game window at NSFloatingWindowLevel and, while the
// displays are captured, above the screen shield (cocoa_window.m minimumLevelForActive:).
// That the question happened, and what the player chose, always go to stderr (the game's log),
// debug or not; the Force Quit line is the last thing the process writes.
//
// Nothing is judged unless the player asked to close or quit: normal play, zone loads, a minimized
// or covered window and a locked screen never are. A live game, even one idle in GetMessage or
// throttled behind a locked screen, takes the request within a frame or two. Only two counters
// are touched on the game's own threads. FFXI_GAMEWINDOW_HANG=0 turns this off, 1...600 sets the
// seconds; it runs wherever HXI_GAME_ASPECT or HXI_WINDOW_TITLE has the dylib watching anyway.
// FFXI_GAMEWINDOW_HANG_ANSWER=force|wait answers the question without showing it (tests; only
// with FFXI_GAMEWINDOW_DEBUG=1).
//
// Debug output: set FFXI_GAMEWINDOW_DEBUG=1 to get one stderr line per action, and one at the end
// of every live resize of a locked window saying whether it really kept the ratio. With it, a gap
// of a second or more between frames, or between the game window thread's reads of its input,
// is logged when it ends ("gap: ..."): how to measure what a zone load really costs.

#include <CoreFoundation/CoreFoundation.h>   // types only: CoreFoundation is not linked (see above)
#include <dlfcn.h>
#include <errno.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// What @autoreleasepool compiles to (libobjc exports both; no public header declares them).
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

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

// HXI_WINDOW_TITLE: the text (for the log) and the string the overrides hand AppKit (a CFString,
// toll-free bridged to NSString; made once, kept for the life of the process). NULL = off.
#define GW_TITLE_MAX 255
static char gw_title_text[GW_TITLE_MAX + 1];
static id gw_title = NULL;
static Class gw_title_class = Nil;   // WineWindow, once a game window of it has been seen
static IMP gw_title_orig = NULL;     // the -setTitle: WineWindow had before the override
static IMP gw_menu_orig = NULL;      // the -changeWindowsItem:title:filename: NSApp's class had

// Not responding (see the header). 0 seconds = off.
#define GW_HANG_DEFAULT 5             // Windows' HungAppTimeout
#define GW_HANG_MAX     600
#define GW_ANSWER_FORCE 1
#define GW_ANSWER_WAIT  2
#define GW_ANSWER_BACK  3             // the game came back while the question was up
static int gw_hang_secs = 0;
static int gw_hang_answer = 0;        // FFXI_GAMEWINDOW_HANG_ANSWER (tests): 0 = really ask
// Written on the game's own threads, atomics only.
static _Atomic(unsigned long) gw_frames;        // -[CAMetalLayer nextDrawable] calls, this process
static _Atomic(unsigned long) gw_polls;         // reads of gw_watch_queue by its own thread
static _Atomic(uintptr_t) gw_watch_queue;       // the WineEventQueue a request went to; compared only
static _Atomic(uintptr_t) gw_game_queue;        // the last game window's queue (Quit is judged by it)
static _Atomic(uint64_t) gw_last_frame, gw_last_poll;   // FFXI_GAMEWINDOW_DEBUG gap lines, ns uptime
// Main thread only.
static int gw_hang_state = 0;         // 0 = not tried, 1 = watching, -1 = not wine's (never retried)
static int gw_hang_pending = 0;       // a request is being judged, or the question is up
static int gw_alert_up = 0;
static id gw_alert_panel = NULL;      // the question's window while it is up
static unsigned long gw_polls_at, gw_frames_at;
static const char *gw_hang_why = "";  // "close", "quit", "cmd-q"
static IMP gw_poll_orig, gw_close_orig, gw_quit_orig, gw_drawable_orig;
static id gw_s_message, gw_s_force, gw_s_wait, gw_s_escape, gw_s_q;   // CFStrings, kept for good
// CoreFoundation's run loop (resolved in gw_observe: CoreFoundation is not linked).
static struct {
    CFRunLoopRef (*main)(void);
    CFAbsoluteTime (*now)(void);
    CFRunLoopTimerRef (*timer)(CFAllocatorRef, CFAbsoluteTime, CFTimeInterval, CFOptionFlags, CFIndex,
                               CFRunLoopTimerCallBack, CFRunLoopTimerContext *);
    void (*add)(CFRunLoopRef, CFRunLoopTimerRef, CFStringRef);
    void (*invalidate)(CFRunLoopTimerRef);
    void (*release)(CFTypeRef);
    CFStringRef (*string)(CFAllocatorRef, const char *, CFStringEncoding);
    CFStringRef common, modal;
} gw_cf;

/// One line on stderr, written with a single write(2): no stdio lock is taken, because the carry
/// logs from wine's forked child, where a FILE lock held by another thread at fork() would never
/// be released (and the gap lines come from DXVK's and wine's threads).
static void gw_vwrite(const char *fmt, va_list ap) {
    char line[1024];
    int n = snprintf(line, sizeof(line), "gamewindow: ");
    int m = vsnprintf(line + n, sizeof(line) - (size_t)n - 1, fmt, ap);
    if (m < 0) return;
    size_t len = (size_t)n + ((size_t)m < sizeof(line) - (size_t)n - 1 ? (size_t)m : sizeof(line) - (size_t)n - 2);
    line[len++] = '\n';
    ssize_t w = write(STDERR_FILENO, line, len);
    (void)w;
}

static void gw_log(const char *fmt, ...) {
    if (!gw_debug) return;
    va_list ap;
    va_start(ap, fmt);
    gw_vwrite(fmt, ap);
    va_end(ap);
}

/// The same, debug or not: that the game stopped responding, and what the player chose, belong in
/// the game's log (the client's stderr) every time.
static void gw_note(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    gw_vwrite(fmt, ap);
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

/// FFXI_GAMEWINDOW_DEBUG only: after a live resize, say whether the window really kept the ratio.
/// AppKit applies contentAspectRatio *before* the delegate's windowWillResize:toSize: and takes
/// whatever the delegate returns (measured on macOS 27, scripts/tests/gamewindow-test.m); wine's
/// delegate returns AppKit's size unless the game's window procedure handles WM_SIZING and returns
/// TRUE (winemac.drv query_resize_size). A window that ends a drag out of proportion therefore
/// means the game overrode the size. Read-only.
static void gw_report(const void *object) {
    if (!object || gw_aspect_w <= 0 || gw_aspect_h <= 0 || !pthread_main_np()) return;
    Class nswindow = objc_getClass("NSWindow");
    if (!nswindow) return;
    SEL isKind = sel_registerName("isKindOfClass:"), contentView = sel_registerName("contentView");
    SEL aspect = sel_registerName("contentAspectRatio");
    id win = (id)object;
    if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(win, isKind, nswindow)) return;
    if (!gw_responds(win, contentView) || !gw_responds(win, aspect)) return;
    gw_size current = ((gw_size (*)(id, SEL))objc_msgSend)(win, aspect);
    if (current.width != gw_aspect_w || current.height != gw_aspect_h) return;   // not a locked window
    id view = ((id (*)(id, SEL))objc_msgSend)(win, contentView);
    if (!view) return;
    gw_rect c = gw_frame(view);
    if (!(c.width > 0 && c.height > 0)) return;
    // Within one point either way of the ratio: what AppKit's whole-point rounding allows.
    double off = c.width * gw_aspect_h - c.height * gw_aspect_w;
    if (off < 0) off = -off;
    gw_log("resize ended: window %p is %.0fx%.0f points, %s %.0f:%.0f", (void *)win, c.width, c.height,
           off <= gw_aspect_w + gw_aspect_h ? "in proportion with" : "OUT OF PROPORTION with (the game overrode the size)",
           gw_aspect_w, gw_aspect_h);
}

// ---------------------------------------------------------------------------------------------
// The title (see the header)
// ---------------------------------------------------------------------------------------------

/// The class named `name` in `obj`'s ancestry (a KVO subclass included), or Nil.
static Class gw_class_named(id obj, const char *name) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c))
        if (strcmp(class_getName(c), name) == 0) return c;
    return Nil;
}

/// The class named WineWindow in `win`'s ancestry (wine's window class), or Nil.
static Class gw_wine_class(id win) { return gw_class_named(win, "WineWindow"); }

/// A window shaped like the game's: titled, resizable, content at least 320x240 points. Read-only.
static int gw_game_shaped(id win) {
    SEL styleMask = sel_registerName("styleMask"), contentView = sel_registerName("contentView");
    if (!gw_responds(win, styleMask) || !gw_responds(win, contentView)) return 0;
    unsigned long mask = ((unsigned long (*)(id, SEL))objc_msgSend)(win, styleMask);
    if ((mask & GW_TITLED) == 0 || (mask & GW_RESIZABLE) == 0) return 0;
    id view = ((id (*)(id, SEL))objc_msgSend)(win, contentView);
    if (!view) return 0;
    gw_rect c = gw_frame(view);
    return c.width >= GW_MIN_W && c.height >= GW_MIN_H;
}

/// A game window whose title is HXI_WINDOW_TITLE: of the overridden WineWindow class (subclasses
/// included) and game-shaped. Main thread only.
static int gw_titled_game(id win) {
    if (!win || !gw_title || !gw_title_class || !pthread_main_np()) return 0;
    if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(win, sel_registerName("isKindOfClass:"), gw_title_class))
        return 0;
    return gw_game_shaped(win);
}

/// WineWindow's -setTitle: from the first sighting on: a game window gets HXI_WINDOW_TITLE, any
/// other window the title it was given.
static void gw_set_title(id self, SEL cmd, id title) {
    if (gw_titled_game(self)) {
        if (title != gw_title) gw_log("title: window %p asked for another title; it stays \"%s\"",
                                      (void *)self, gw_title_text);
        title = gw_title;
    }
    ((void (*)(id, SEL, id))gw_title_orig)(self, cmd, title);
}

/// NSApp's -changeWindowsItem:title:filename:, the same way: wine calls it with the Windows title
/// right after setTitle:, for the Window menu.
static void gw_change_windows_item(id self, SEL cmd, id win, id title, BOOL filename) {
    if (gw_titled_game(win)) title = gw_title;
    ((void (*)(id, SEL, id, id, BOOL))gw_menu_orig)(self, cmd, win, title, filename);
}

/// Replace `sel` on `cls` with `imp`, keeping the implementation it had (its own or inherited) in
/// `*orig`, which is set before the swap so no call can find it empty. Once: never over itself.
static int gw_override(Class cls, const char *name, IMP imp, IMP *orig, const char *why) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return 0;
    IMP current = method_getImplementation(m);
    if (current == imp) return 1;
    if (*orig) return 0;   // already overridden on another class: never chain to ourselves
    *orig = current;
    class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
    gw_log("%s: -%s overridden on %s", why, name, class_getName(cls));
    return 1;
}

/// The Window menu override, on NSApp's class. AppKit is loaded (a window notification came), so
/// NSApp is read, never created.
static void gw_override_menu(void) {
    if (gw_menu_orig) return;
    id *app = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (!app || !*app) return;
    Class cls = ((Class (*)(id, SEL))objc_msgSend)(*app, sel_registerName("class"));
    if (cls) gw_override(cls, "changeWindowsItem:title:filename:", (IMP)gw_change_windows_item, &gw_menu_orig, "title");
}

/// The Window menu item of `win`, if it has one, says HXI_WINDOW_TITLE. Never adds one.
static void gw_retitle_menu_item(id win) {
    id *app = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (!app || !*app) return;
    SEL windowsMenu = sel_registerName("windowsMenu"), count = sel_registerName("numberOfItems");
    SEL itemAt = sel_registerName("itemAtIndex:"), target = sel_registerName("target");
    SEL title = sel_registerName("title"), equal = sel_registerName("isEqualToString:");
    SEL change = sel_registerName("changeWindowsItem:title:filename:");
    if (!gw_responds(*app, windowsMenu) || !gw_responds(*app, change)) return;
    id menu = ((id (*)(id, SEL))objc_msgSend)(*app, windowsMenu);
    if (!menu || !gw_responds(menu, count) || !gw_responds(menu, itemAt)) return;
    long n = ((long (*)(id, SEL))objc_msgSend)(menu, count);
    for (long i = 0; i < n; i++) {
        id item = ((id (*)(id, SEL, long))objc_msgSend)(menu, itemAt, i);
        if (!item || !gw_responds(item, target) || !gw_responds(item, title)) continue;
        if (((id (*)(id, SEL))objc_msgSend)(item, target) != win) continue;
        id t = ((id (*)(id, SEL))objc_msgSend)(item, title);
        if (t && gw_responds(t, equal) && ((BOOL (*)(id, SEL, id))objc_msgSend)(t, equal, gw_title)) return;
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(*app, change, win, gw_title, NO);
        gw_log("title: Window menu item of window %p now reads \"%s\"", (void *)win, gw_title_text);
        return;
    }
}

/// A window became key or main, or came on screen. The first game window of WineWindow seen
/// installs the overrides; every game window's title and menu item are set to HXI_WINDOW_TITLE.
static void gw_retitle(const void *object, const char *why) {
    if (!object || !gw_title || !pthread_main_np()) return;
    Class nswindow = objc_getClass("NSWindow");
    if (!nswindow) return;
    id win = (id)object;
    if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(win, sel_registerName("isKindOfClass:"), nswindow)) return;
    if (!gw_title_class) {
        Class wine = gw_wine_class(win);
        if (!wine || !gw_game_shaped(win)) return;
        if (!gw_override(wine, "setTitle:", (IMP)gw_set_title, &gw_title_orig, "title")) return;
        gw_title_class = wine;
    }
    gw_override_menu();
    if (!gw_titled_game(win)) return;
    SEL title = sel_registerName("title"), equal = sel_registerName("isEqualToString:");
    id current = gw_responds(win, title) ? ((id (*)(id, SEL))objc_msgSend)(win, title) : NULL;
    if (!current || !gw_responds(current, equal)
        || !((BOOL (*)(id, SEL, id))objc_msgSend)(current, equal, gw_title)) {
        ((void (*)(id, SEL, id))objc_msgSend)(win, sel_registerName("setTitle:"), gw_title);
        gw_log("%s: window %p now reads \"%s\"", why, (void *)win, gw_title_text);
    }
    gw_retitle_menu_item(win);
}

// ---------------------------------------------------------------------------------------------
// Not responding (see the header)
// ---------------------------------------------------------------------------------------------

static uint64_t gw_uptime_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/// FFXI_GAMEWINDOW_DEBUG only: a gap of a second or more, logged when it ends. Any thread.
static void gw_gap(_Atomic(uint64_t) *last, const char *what) {
    uint64_t now = gw_uptime_ns(), before = atomic_exchange_explicit(last, now, memory_order_relaxed);
    if (before && now - before >= 1000000000ULL)
        gw_log("gap: %s for %.1f s", what, (double)(now - before) / 1e9);
}

/// -[CAMetalLayer nextDrawable], on DXVK's threads: MoltenVK 1.4.2 asks once per frame it presents
/// (MVKImage.mm getCAMetalDrawable, after each acquire released the last one). Counted on the way
/// in, so a call CoreAnimation holds up (no drawable free: a covered window, a locked screen) still
/// counts as the game trying to draw.
static id gw_next_drawable(id self, SEL cmd) {
    atomic_fetch_add_explicit(&gw_frames, 1, memory_order_relaxed);
    if (gw_debug) gw_gap(&gw_last_frame, "no frame");
    return ((id (*)(id, SEL))gw_drawable_orig)(self, cmd);
}

/// -[WineEventQueue getEventMatchingMask:] (macdrv_event_mask is uint64_t): only the thread that
/// owns the queue calls it (macdrv_copy_event_from_queue from its message loop; OnMainThread's
/// wait), never AppKit's. Counted on the way out, so the call that takes a request posted after
/// the counters were read always counts.
static id gw_get_event(id self, SEL cmd, uint64_t mask) {
    id event = ((id (*)(id, SEL, uint64_t))gw_poll_orig)(self, cmd, mask);
    uintptr_t me = (uintptr_t)self;
    if (me == atomic_load_explicit(&gw_watch_queue, memory_order_acquire))
        atomic_fetch_add_explicit(&gw_polls, 1, memory_order_release);
    if (gw_debug && me == atomic_load_explicit(&gw_game_queue, memory_order_relaxed))
        gw_gap(&gw_last_poll, "the game window's input not read");
    return event;
}

/// The wine event queue a window of wine's posts to (WineWindow's `queue`), as a number: it is
/// only ever compared, never messaged. 0 if there is none.
static uintptr_t gw_queue_of(id win) {
    SEL queue = sel_registerName("queue");
    if (!win || !gw_responds(win, queue)) return 0;
    return (uintptr_t)((id (*)(id, SEL))objc_msgSend)(win, queue);
}

static void gw_timer_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    ((void (*)(void))info)();
}

/// A timer on the main run loop that also fires while AppKit waits in NSModalPanelRunLoopMode (a
/// quit answered NSTerminateLater; the question itself). `every` 0 = once: the run loop keeps a
/// one-shot timer until it fires. A repeating one is the caller's to invalidate and release.
static CFRunLoopTimerRef gw_timer(double after, double every, void (*fn)(void)) {
    CFRunLoopTimerContext ctx = { 0, (void *)fn, NULL, NULL, NULL };
    CFRunLoopTimerRef t = gw_cf.timer(NULL, gw_cf.now() + after, every, 0, 0, gw_timer_fired, &ctx);
    if (!t) return NULL;
    CFRunLoopRef loop = gw_cf.main();
    gw_cf.add(loop, t, gw_cf.common);
    if (gw_cf.modal) gw_cf.add(loop, t, gw_cf.modal);
    return t;
}

/// Before wine posts a request to `queue`: read the counters, so that taking the request counts.
/// 0 (watch nothing) while another request is being judged, or without a queue.
static int gw_hang_watch(uintptr_t queue) {
    if (!queue || gw_hang_pending) return 0;
    atomic_store_explicit(&gw_watch_queue, queue, memory_order_release);
    gw_polls_at = atomic_load_explicit(&gw_polls, memory_order_acquire);
    gw_frames_at = atomic_load_explicit(&gw_frames, memory_order_acquire);
    return 1;
}

static int gw_hang_alive(void) {
    return atomic_load_explicit(&gw_polls, memory_order_acquire) != gw_polls_at
        || atomic_load_explicit(&gw_frames, memory_order_acquire) != gw_frames_at;
}

static void gw_hang_check(void);

/// After wine posted the request: judge it in gw_hang_secs seconds.
static void gw_hang_schedule(const char *why) {
    CFRunLoopTimerRef t = gw_timer(gw_hang_secs, 0, gw_hang_check);
    if (!t) return;
    gw_cf.release(t);
    gw_hang_pending = 1;
    gw_hang_why = why;
    gw_log("%s: watching the game for %d s", why, gw_hang_secs);
}

#define GW_MODAL_LEVEL 8   // NSModalPanelWindowLevel (kCGModalPanelWindowLevel)

/// Keep the question above every other window of the app, and never below
/// NSModalPanelWindowLevel. Wine raises a game window to NSFloatingWindowLevel when it is topmost,
/// and above the screen shield while the displays are captured (cocoa_window.m
/// minimumLevelForActive:; adjustWindowLevels runs again whenever the app becomes active), where
/// an alert's own level would sit under it. Returns the level.
static long gw_raise(id app, id panel) {
    SEL level = sel_registerName("level"), setLevel = sel_registerName("setLevel:");
    SEL windows = sel_registerName("windows"), count = sel_registerName("count");
    SEL at = sel_registerName("objectAtIndex:"), visible = sel_registerName("isVisible");
    if (!panel || !gw_responds(panel, level) || !gw_responds(panel, setLevel)) return 0;
    long mine = ((long (*)(id, SEL))objc_msgSend)(panel, level);
    long top = mine > GW_MODAL_LEVEL ? mine : GW_MODAL_LEVEL;
    id list = gw_responds(app, windows) ? ((id (*)(id, SEL))objc_msgSend)(app, windows) : NULL;
    unsigned long n = list ? ((unsigned long (*)(id, SEL))objc_msgSend)(list, count) : 0;
    for (unsigned long i = 0; i < n; i++) {
        id w = ((id (*)(id, SEL, unsigned long))objc_msgSend)(list, at, i);
        if (!w || w == panel || !((BOOL (*)(id, SEL))objc_msgSend)(w, visible)) continue;
        long l = ((long (*)(id, SEL))objc_msgSend)(w, level);
        if (l >= top) top = l + 1;
    }
    if (top != mine) ((void (*)(id, SEL, long))objc_msgSend)(panel, setLevel, top);
    return top;
}

/// Every 0.25 s while the question is up: withdraw it once the game reads its input or draws;
/// until then keep it on top (wine may have raised a window since).
static void gw_hang_recheck(void) {
    if (!gw_alert_up) return;
    id *app = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (!app || !*app) return;
    if (gw_hang_alive()) ((void (*)(id, SEL))objc_msgSend)(*app, sel_registerName("abortModal"));
    else gw_raise(*app, gw_alert_panel);
}

static void gw_force_quit(void) {
    gw_note("%s: Force Quit chosen; ending the game (pid %d) now", gw_hang_why, (int)getpid());
    kill(getpid(), SIGKILL);
    _exit(137);
}

/// The question, on the main thread: an app-modal NSAlert, "Force Quit" first (Return, destructive)
/// and "Wait" (Escape). One line and two buttons: nothing else is the player's to decide.
static void gw_hang_ask(void) {
    gw_note("%s: the game has drawn nothing and read none of its input for %d s; asking",
            gw_hang_why, gw_hang_secs);
    id *app = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    Class cls = objc_getClass("NSAlert");
    if (!app || !*app || !cls) return;
    void *pool = objc_autoreleasePoolPush();
    SEL add = sel_registerName("addButtonWithTitle:");
    id alert = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("alloc")), sel_registerName("init"));
    if (!alert) { objc_autoreleasePoolPop(pool); return; }
    ((void (*)(id, SEL, id))objc_msgSend)(alert, sel_registerName("setMessageText:"), gw_s_message);
    id force = ((id (*)(id, SEL, id))objc_msgSend)(alert, add, gw_s_force);
    id waitButton = ((id (*)(id, SEL, id))objc_msgSend)(alert, add, gw_s_wait);
    if (waitButton) ((void (*)(id, SEL, id))objc_msgSend)(waitButton, sel_registerName("setKeyEquivalent:"), gw_s_escape);
    SEL destructive = sel_registerName("setHasDestructiveAction:");   // macOS 11+
    if (force && gw_responds(force, destructive)) ((void (*)(id, SEL, BOOL))objc_msgSend)(force, destructive, YES);
    SEL window = sel_registerName("window");
    id panel = gw_responds(alert, window) ? ((id (*)(id, SEL))objc_msgSend)(alert, window) : NULL;
    long level = gw_raise(*app, panel);
    int answer = gw_hang_answer;
    if (answer) {
        gw_log("%s: answered by FFXI_GAMEWINDOW_HANG_ANSWER (%s), nothing shown (window level %ld)",
               gw_hang_why, answer == GW_ANSWER_FORCE ? "force" : "wait", level);
    } else {
        // -activate is macOS 14's; -activateIgnoringOtherApps: before it.
        SEL activate = sel_registerName("activate"), activateOld = sel_registerName("activateIgnoringOtherApps:");
        if (gw_responds(*app, activate)) ((void (*)(id, SEL))objc_msgSend)(*app, activate);
        else if (gw_responds(*app, activateOld)) ((void (*)(id, SEL, BOOL))objc_msgSend)(*app, activateOld, YES);
        CFRunLoopTimerRef watch = gw_timer(0.25, 0.25, gw_hang_recheck);
        gw_alert_panel = panel;
        gw_alert_up = 1;
        long r = ((long (*)(id, SEL))objc_msgSend)(alert, sel_registerName("runModal"));
        gw_alert_up = 0;
        gw_alert_panel = NULL;
        if (watch) { gw_cf.invalidate(watch); gw_cf.release(watch); }
        // NSAlertFirstButtonReturn 1000; NSModalResponseAbort -1001 (abortModal: the game came back)
        answer = r == 1000 ? GW_ANSWER_FORCE : r == -1001 ? GW_ANSWER_BACK : GW_ANSWER_WAIT;
    }
    ((void (*)(id, SEL))objc_msgSend)(alert, sel_registerName("release"));
    objc_autoreleasePoolPop(pool);
    if (answer == GW_ANSWER_FORCE) gw_force_quit();
    if (answer == GW_ANSWER_BACK) gw_note("%s: the game came back; question withdrawn", gw_hang_why);
    else gw_note("%s: Wait chosen; the game keeps running", gw_hang_why);
}

/// gw_hang_secs after a request: left to the game if it read its input or drew, else asked.
static void gw_hang_check(void) {
    if (!gw_hang_pending || gw_alert_up) return;
    if (gw_hang_alive())
        gw_log("%s: the game read its input or drew within %d s; left to the game", gw_hang_why, gw_hang_secs);
    else
        gw_hang_ask();
    gw_hang_pending = 0;
}

/// WineWindow's -windowShouldClose: (the red button: WineWindow is its own delegate). Wine's own,
/// which queues the close for the game's thread and answers NO, with the watch around it.
static BOOL gw_should_close(id self, SEL cmd, id sender) {
    int watching = pthread_main_np() && gw_game_shaped(self) && gw_hang_watch(gw_queue_of(self));
    BOOL ok = ((BOOL (*)(id, SEL, id))gw_close_orig)(self, cmd, sender);
    if (watching) gw_hang_schedule("close");
    return ok;
}

/// WineApplicationController's -applicationShouldTerminate: (Cmd-Option-Q, the app menu, the
/// Dock's Quit, log out). Wine's own, which posts the quit to every thread's queue and answers
/// NSTerminateLater while the game decides; watched on the game window's queue.
static unsigned long gw_should_terminate(id self, SEL cmd, id sender) {
    int watching = pthread_main_np() && gw_hang_watch(atomic_load_explicit(&gw_game_queue, memory_order_relaxed));
    unsigned long reply = ((unsigned long (*)(id, SEL, id))gw_quit_orig)(self, cmd, sender);
    if (watching && reply == 2 /* NSTerminateLater */) gw_hang_schedule("quit");
    return reply;
}

#define GW_EVENT_KEY_DOWN 10                                                  // NSEventTypeKeyDown
#define GW_MODIFIERS ((1UL << 17) | (1UL << 18) | (1UL << 19) | (1UL << 20))  // shift control option command
#define GW_COMMAND   (1UL << 20)

/// A key-down on its way to a window (local monitor: before wine sees it). Plain Cmd-Q on a game
/// window is watched like a quit; the event always goes on unchanged (to the game, as Alt-Q).
static id gw_key_seen(id event) {
    if (!event || gw_hang_state <= 0 || gw_hang_pending || !pthread_main_np()) return event;
    if (((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type")) != GW_EVENT_KEY_DOWN) return event;
    unsigned long mods = ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags"));
    if ((mods & GW_MODIFIERS) != GW_COMMAND) return event;
    if (((BOOL (*)(id, SEL))objc_msgSend)(event, sel_registerName("isARepeat"))) return event;
    id chars = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("charactersIgnoringModifiers"));
    SEL compare = sel_registerName("caseInsensitiveCompare:");
    if (!chars || !gw_responds(chars, compare)
        || ((long (*)(id, SEL, id))objc_msgSend)(chars, compare, gw_s_q) != 0) return event;
    id win = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("window"));
    if (!win || !gw_wine_class(win) || !gw_game_shaped(win)) return event;
    if (gw_hang_watch(gw_queue_of(win))) gw_hang_schedule("cmd-q");
    return event;
}

static id (^const gw_key_monitor)(id) = ^id (id event) { return gw_key_seen(event); };

/// Once, at the first game window of wine's: the request hooks and the two counters. Without wine's
/// event queue nothing is installed: a live game that draws nothing (at a message box, say) would
/// look hung by frames alone.
static int gw_hang_install(id win) {
    if (gw_hang_state) return gw_hang_state > 0;
    gw_hang_state = -1;
    Class wine = gw_wine_class(win), queue = objc_getClass("WineEventQueue");
    if (!wine || !queue || !gw_queue_of(win)) {
        gw_log("hang: no wine event queue behind this window; not watching");
        return 0;
    }
    gw_s_message = (id)gw_cf.string(NULL, "The game isn\xe2\x80\x99t responding.", kCFStringEncodingUTF8);
    gw_s_force = (id)gw_cf.string(NULL, "Force Quit", kCFStringEncodingUTF8);
    gw_s_wait = (id)gw_cf.string(NULL, "Wait", kCFStringEncodingUTF8);
    gw_s_escape = (id)gw_cf.string(NULL, "\033", kCFStringEncodingUTF8);
    gw_s_q = (id)gw_cf.string(NULL, "q", kCFStringEncodingUTF8);
    if (!gw_s_message || !gw_s_force || !gw_s_wait || !gw_s_escape || !gw_s_q) return 0;
    if (!gw_override(queue, "getEventMatchingMask:", (IMP)gw_get_event, &gw_poll_orig, "hang")
        || !gw_override(wine, "windowShouldClose:", (IMP)gw_should_close, &gw_close_orig, "hang")) return 0;
    Class layer = objc_getClass("CAMetalLayer");
    if (!layer || !gw_override(layer, "nextDrawable", (IMP)gw_next_drawable, &gw_drawable_orig, "hang"))
        gw_log("hang: no CAMetalLayer; judging by input reads alone");
    id *app = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    SEL delegateSel = sel_registerName("delegate");
    id delegate = app && *app && gw_responds(*app, delegateSel) ? ((id (*)(id, SEL))objc_msgSend)(*app, delegateSel) : NULL;
    Class controller = delegate ? gw_class_named(delegate, "WineApplicationController") : Nil;
    if (!controller || !gw_override(controller, "applicationShouldTerminate:", (IMP)gw_should_terminate,
                                    &gw_quit_orig, "hang"))
        gw_log("hang: no WineApplicationController; Quit is not watched");
    Class nsevent = objc_getClass("NSEvent");
    SEL monitor = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
    if (nsevent && class_getClassMethod(nsevent, monitor))
        ((id (*)(id, SEL, unsigned long long, id (^)(id)))objc_msgSend)((id)nsevent, monitor,
                                                                       1ULL << GW_EVENT_KEY_DOWN, gw_key_monitor);
    gw_hang_state = 1;
    gw_log("hang: watching the game's close and quit requests; asks after %d s", gw_hang_secs);
    return 1;
}

/// A window became key or main, or came on screen. A game window of wine's installs the check
/// (once) and becomes the one a Quit is judged by.
static void gw_hang_sight(const void *object) {
    if (!object || gw_hang_secs <= 0 || gw_hang_state < 0 || !pthread_main_np()) return;
    Class nswindow = objc_getClass("NSWindow");
    if (!nswindow) return;
    id win = (id)object;
    if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(win, sel_registerName("isKindOfClass:"), nswindow)) return;
    if (!gw_wine_class(win) || !gw_game_shaped(win) || !gw_hang_install(win)) return;
    uintptr_t q = gw_queue_of(win);
    if (q && q != atomic_load_explicit(&gw_game_queue, memory_order_relaxed)) {
        atomic_store_explicit(&gw_game_queue, q, memory_order_relaxed);
        gw_log("hang: game window %p reads its input from wine queue %p", (void *)win, (void *)q);
    }
}

/// FFXI_GAMEWINDOW_HANG: unset or empty = 5 s; 0 = off; 1...600 = that many seconds; anything else
/// is ignored (5 s): the check only ever asks, so the shipped default beats a guess.
static int gw_parse_hang(const char *s) {
    if (!s || !*s) return GW_HANG_DEFAULT;
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || end == s || *end != '\0' || v < 0 || v > GW_HANG_MAX) {
        gw_log("FFXI_GAMEWINDOW_HANG=%s is not 0...%d seconds; using %d", s, GW_HANG_MAX, GW_HANG_DEFAULT);
        return GW_HANG_DEFAULT;
    }
    return (int)v;
}

/// CoreFoundation's run-loop timer functions, for the check. 1 when all are there.
static int gw_resolve_cf(void *cf) {
    gw_cf.main = (CFRunLoopRef (*)(void))dlsym(cf, "CFRunLoopGetMain");
    gw_cf.now = (CFAbsoluteTime (*)(void))dlsym(cf, "CFAbsoluteTimeGetCurrent");
    gw_cf.timer = (CFRunLoopTimerRef (*)(CFAllocatorRef, CFAbsoluteTime, CFTimeInterval, CFOptionFlags, CFIndex,
                                         CFRunLoopTimerCallBack, CFRunLoopTimerContext *))dlsym(cf, "CFRunLoopTimerCreate");
    gw_cf.add = (void (*)(CFRunLoopRef, CFRunLoopTimerRef, CFStringRef))dlsym(cf, "CFRunLoopAddTimer");
    gw_cf.invalidate = (void (*)(CFRunLoopTimerRef))dlsym(cf, "CFRunLoopTimerInvalidate");
    gw_cf.release = (void (*)(CFTypeRef))dlsym(cf, "CFRelease");
    gw_cf.string = (CFStringRef (*)(CFAllocatorRef, const char *, CFStringEncoding))dlsym(cf, "CFStringCreateWithCString");
    const CFStringRef *common = (const CFStringRef *)dlsym(cf, "kCFRunLoopCommonModes");
    if (!gw_cf.main || !gw_cf.now || !gw_cf.timer || !gw_cf.add || !gw_cf.invalidate || !gw_cf.release
        || !gw_cf.string || !common || !*common) return 0;
    gw_cf.common = *common;
    // AppKit's NSModalPanelRunLoopMode, by value (AppKit is never linked or loaded here).
    gw_cf.modal = gw_cf.string(NULL, "NSModalPanelRunLoopMode", kCFStringEncodingUTF8);
    return 1;
}

static void gw_will_resize(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                           const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_lock(object, "resize");
}

static void gw_did_end_resize(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                              const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_report(object);
}

static void gw_became_key(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                          const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_lock(object, "key");
    gw_retitle(object, "key");
    gw_hang_sight(object);
}

static void gw_became_main(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                           const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_retitle(object, "main");
    gw_hang_sight(object);
}

// Posted when a window comes on screen (and when it is covered or uncovered): the game window is
// seen even while the app is in the background. Not per frame.
static void gw_occlusion(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                         const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_retitle(object, "shown");
    gw_hang_sight(object);
}

/// Open CoreFoundation and observe the notifications the ratio and the title need. 1 on success.
static int gw_observe(void) {
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW | RTLD_LOCAL);
    if (!cf) { gw_log("loaded; CoreFoundation unavailable, nothing kept"); return 0; }
    CFNotificationCenterRef (*localCenter)(void) =
        (CFNotificationCenterRef (*)(void))dlsym(cf, "CFNotificationCenterGetLocalCenter");
    void (*addObserver)(CFNotificationCenterRef, const void *, CFNotificationCallback, CFStringRef,
                        const void *, CFNotificationSuspensionBehavior) =
        (void (*)(CFNotificationCenterRef, const void *, CFNotificationCallback, CFStringRef,
                  const void *, CFNotificationSuspensionBehavior))dlsym(cf, "CFNotificationCenterAddObserver");
    CFStringRef (*makeString)(CFAllocatorRef, const char *, CFStringEncoding) =
        (CFStringRef (*)(CFAllocatorRef, const char *, CFStringEncoding))dlsym(cf, "CFStringCreateWithCString");
    if (!localCenter || !addObserver || !makeString) {
        gw_log("loaded; CoreFoundation is missing a function, nothing kept");
        return 0;
    }
    CFNotificationCenterRef center = localCenter();
    if (gw_title_text[0]) {
        // Not valid UTF-8: no title rather than a wrong one.
        gw_title = (id)makeString(NULL, gw_title_text, kCFStringEncodingUTF8);
        if (!gw_title) gw_log("HXI_WINDOW_TITLE is not UTF-8, title left to the game");
    }
    int aspect = gw_aspect_w > 0 && gw_aspect_h > 0;
    if (gw_hang_secs > 0 && !gw_resolve_cf(cf)) {
        gw_log("CoreFoundation is missing a run loop function; hang check off");
        gw_hang_secs = 0;
    }
    if (!aspect && !gw_title && gw_hang_secs <= 0) { gw_log("loaded; nothing kept"); return 0; }
    // Kept for the life of the process: the center holds the names, and so does this.
    CFStringRef key = makeString(NULL, "NSWindowDidBecomeKeyNotification", kCFStringEncodingUTF8);
    if (!center || !key) { gw_log("loaded; no notification center, nothing kept"); gw_title = NULL; return 0; }
    static int token;   // observer identity; only its address matters
    const CFNotificationSuspensionBehavior now = CFNotificationSuspensionBehaviorDeliverImmediately;
    addObserver(center, &token, gw_became_key, key, NULL, now);
    if (aspect) {
        CFStringRef resize = makeString(NULL, "NSWindowWillStartLiveResizeNotification", kCFStringEncodingUTF8);
        if (resize) addObserver(center, &token, gw_will_resize, resize, NULL, now);
        if (gw_debug) {
            CFStringRef ended = makeString(NULL, "NSWindowDidEndLiveResizeNotification", kCFStringEncodingUTF8);
            if (ended) addObserver(center, &token, gw_did_end_resize, ended, NULL, now);
        }
    }
    if (gw_title || gw_hang_secs > 0) {
        CFStringRef becameMain = makeString(NULL, "NSWindowDidBecomeMainNotification", kCFStringEncodingUTF8);
        CFStringRef shown = makeString(NULL, "NSWindowDidChangeOcclusionStateNotification", kCFStringEncodingUTF8);
        if (becameMain) addObserver(center, &token, gw_became_main, becameMain, NULL, now);
        if (shown) addObserver(center, &token, gw_occlusion, shown, NULL, now);
    }
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
        if (want && *want) gw_log("HXI_GAME_ASPECT=%s is not WIDTHxHEIGHT, window shape not kept", want);
    }
    // The game window's title: 1...255 bytes, else none.
    const char *title = getenv("HXI_WINDOW_TITLE");
    if (title && *title) {
        if (strlen(title) <= GW_TITLE_MAX) memcpy(gw_title_text, title, strlen(title) + 1);
        else gw_log("HXI_WINDOW_TITLE is longer than %d bytes, title left to the game", GW_TITLE_MAX);
    }
    if (gw_aspect_w <= 0 && !gw_title_text[0]) {
        gw_log("loaded; no HXI_GAME_ASPECT or HXI_WINDOW_TITLE, nothing kept%s", gw_carry ? " (carry on)" : "");
        return;
    }
    // Not responding: wherever the dylib watches windows anyway (see the header).
    gw_hang_secs = gw_parse_hang(getenv("FFXI_GAMEWINDOW_HANG"));
    const char *answer = getenv("FFXI_GAMEWINDOW_HANG_ANSWER");
    if (gw_debug && answer && strcmp(answer, "force") == 0) gw_hang_answer = GW_ANSWER_FORCE;
    if (gw_debug && answer && strcmp(answer, "wait") == 0) gw_hang_answer = GW_ANSWER_WAIT;

    // wineserver has no windows and never loads CoreFoundation on its own; keep it that way.
    const char *prog = getprogname();
    if (prog && strcmp(prog, "wineserver") == 0) {
        gw_log("loaded in wineserver; nothing to watch");
        return;
    }
    if (!gw_observe()) return;
    char shape[64] = "", hang[48];
    if (gw_aspect_w > 0) snprintf(shape, sizeof(shape), "keeping game windows at %.0f:%.0f", gw_aspect_w, gw_aspect_h);
    if (gw_hang_secs > 0) snprintf(hang, sizeof(hang), "hang check after %d s", gw_hang_secs);
    else snprintf(hang, sizeof(hang), "hang check off");
    gw_log("loaded; %s%s%s%s%s%s%s%s", shape, shape[0] && gw_title ? ", " : "",
           gw_title ? "titled \"" : "", gw_title ? gw_title_text : "", gw_title ? "\"" : "",
           shape[0] || gw_title ? ", " : "", hang, gw_carry ? " (carry on)" : "");
}
