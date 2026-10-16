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
//     with HXI_WINDOW_TITLE, the title and Window menu item of a game window (see The title);
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
// Debug output: set FFXI_GAMEWINDOW_DEBUG=1 to get one stderr line per action, and one at the end
// of every live resize of a locked window saying whether it really kept the ratio.

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

// HXI_WINDOW_TITLE: the text (for the log) and the string the overrides hand AppKit (a CFString,
// toll-free bridged to NSString; made once, kept for the life of the process). NULL = off.
#define GW_TITLE_MAX 255
static char gw_title_text[GW_TITLE_MAX + 1];
static id gw_title = NULL;
static Class gw_title_class = Nil;   // WineWindow, once a game window of it has been seen
static IMP gw_title_orig = NULL;     // the -setTitle: WineWindow had before the override
static IMP gw_menu_orig = NULL;      // the -changeWindowsItem:title:filename: NSApp's class had

/// One line on stderr, written with a single write(2): no stdio lock is taken, because the carry
/// logs from wine's forked child, where a FILE lock held by another thread at fork() would never
/// be released.
static void gw_log(const char *fmt, ...) {
    if (!gw_debug) return;
    char line[1024];
    int n = snprintf(line, sizeof(line), "gamewindow: ");
    va_list ap;
    va_start(ap, fmt);
    int m = vsnprintf(line + n, sizeof(line) - (size_t)n - 1, fmt, ap);
    va_end(ap);
    if (m < 0) return;
    size_t len = (size_t)n + ((size_t)m < sizeof(line) - (size_t)n - 1 ? (size_t)m : sizeof(line) - (size_t)n - 2);
    line[len++] = '\n';
    ssize_t w = write(STDERR_FILENO, line, len);
    (void)w;
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

/// The class named WineWindow in `win`'s ancestry (wine's window class), or Nil.
static Class gw_wine_class(id win) {
    for (Class c = object_getClass(win); c; c = class_getSuperclass(c))
        if (strcmp(class_getName(c), "WineWindow") == 0) return c;
    return Nil;
}

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
static int gw_override(Class cls, const char *name, IMP imp, IMP *orig) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return 0;
    IMP current = method_getImplementation(m);
    if (current == imp) return 1;
    if (*orig) return 0;   // already overridden on another class: never chain to ourselves
    *orig = current;
    class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
    gw_log("title: -%s overridden on %s", name, class_getName(cls));
    return 1;
}

/// The Window menu override, on NSApp's class. AppKit is loaded (a window notification came), so
/// NSApp is read, never created.
static void gw_override_menu(void) {
    if (gw_menu_orig) return;
    id *app = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (!app || !*app) return;
    Class cls = ((Class (*)(id, SEL))objc_msgSend)(*app, sel_registerName("class"));
    if (cls) gw_override(cls, "changeWindowsItem:title:filename:", (IMP)gw_change_windows_item, &gw_menu_orig);
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
        if (!gw_override(wine, "setTitle:", (IMP)gw_set_title, &gw_title_orig)) return;
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
}

static void gw_became_main(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                           const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_retitle(object, "main");
}

// Posted when a window comes on screen (and when it is covered or uncovered): the game window is
// seen even while the app is in the background. Not per frame.
static void gw_occlusion(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                         const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    gw_retitle(object, "shown");
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
    if (!aspect && !gw_title) { gw_log("loaded; nothing kept"); return 0; }
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
    if (gw_title) {
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

    // wineserver has no windows and never loads CoreFoundation on its own; keep it that way.
    const char *prog = getprogname();
    if (prog && strcmp(prog, "wineserver") == 0) {
        gw_log("loaded in wineserver; nothing to watch");
        return;
    }
    if (!gw_observe()) return;
    char shape[64] = "";
    if (gw_aspect_w > 0) snprintf(shape, sizeof(shape), "keeping game windows at %.0f:%.0f", gw_aspect_w, gw_aspect_h);
    gw_log("loaded; %s%s%s%s%s%s", shape, shape[0] && gw_title ? ", " : "",
           gw_title ? "titled \"" : "", gw_title ? gw_title_text : "", gw_title ? "\"" : "",
           gw_carry ? " (carry on)" : "");
}
