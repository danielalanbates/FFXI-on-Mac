// Stand-in for wine's Mac driver: makes windows the way winemac.drv does (an NSPanel subclass,
// titled and resizable), never shows them, posts the notifications AppKit posts around a live
// resize, and checks what gamewindow.dylib did to them.
//
//   gamewindow-test lock   expects game-sized windows locked to HXI_GAME_ASPECT
//   gamewindow-test none   expects nothing locked (no or invalid HXI_GAME_ASPECT)
//
// Nothing is ever ordered front and the app may never activate (activation policy Prohibited),
// so it is safe to run while somebody is using the Mac. Build/run: scripts/tests/gamewindow-test.sh
#import <AppKit/AppKit.h>
#include <mach-o/dyld.h>
#include <string.h>

static int failures = 0;

static void check(const char *what, BOOL ok) {
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) failures++;
}

static BOOL dylib_loaded(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "gamewindow.dylib")) return YES;
    }
    return NO;
}

// winemac.drv's windows are NSPanels (WineWindow : NSPanel).
@interface FakeWineWindow : NSPanel
@end
@implementation FakeWineWindow
@end

static NSWindow *make(Class cls, NSWindowStyleMask mask, CGFloat w, CGFloat h) {
    NSWindow *win = [[cls alloc] initWithContentRect:NSMakeRect(100, 100, w, h)
                                           styleMask:mask
                                             backing:NSBackingStoreBuffered
                                               defer:YES];
    win.releasedWhenClosed = NO;
    return win;
}

static void post(NSString *name, id object) {
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:object];
}

static BOOL same(NSSize a, NSSize b) { return a.width == b.width && a.height == b.height; }

static int *delivered_ptr;
static void probe_callback(CFNotificationCenterRef c, void *observer, CFNotificationName name,
                           const void *object, CFDictionaryRef info) {
    (void)c; (void)observer; (void)name; (void)object; (void)info;
    if (delivered_ptr) (*delivered_ptr)++;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL expectLock = argc > 1 && strcmp(argv[1], "lock") == 0;
        double W = 0, H = 0;
        const char *env = getenv("HXI_GAME_ASPECT");
        if (expectLock && (!env || sscanf(env, "%lfx%lf", &W, &H) != 2)) {
            printf("FAIL  lock mode needs HXI_GAME_ASPECT=WxH\n");
            return 2;
        }
        NSSize target = NSMakeSize(W, H);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        check("gamewindow.dylib is loaded in this process", dylib_loaded());
        // What the dylib relies on: a post through NSNotificationCenter.defaultCenter (AppKit's
        // way) reaches an observer on CoreFoundation's local center (the dylib's way). They need
        // not be the same object, so identity is only reported.
        static int delivered = 0;
        static int probeToken;
        delivered_ptr = &delivered;
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), &probeToken, probe_callback,
                                        CFSTR("GameWindowTestProbe"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        post(@"GameWindowTestProbe", nil);
        printf("info  NSNotificationCenter.defaultCenter %s CFNotificationCenterGetLocalCenter()\n",
               (__bridge void *)[NSNotificationCenter defaultCenter] == (void *)CFNotificationCenterGetLocalCenter()
                   ? "is" : "is not the same object as");
        check("a post through NSNotificationCenter.defaultCenter reaches a CoreFoundation local-center observer",
              delivered == 1);

        const NSWindowStyleMask gameMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                         | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

        // The game window, before a live resize.
        NSWindow *game = make([FakeWineWindow class], gameMask, 960, 540);
        NSSize before = game.contentAspectRatio;
        NSRect frameBefore = game.frame;
        post(NSWindowWillStartLiveResizeNotification, game);
        if (expectLock) {
            check("a live resize locks the game window (NSPanel, titled|resizable) to HXI_GAME_ASPECT",
                  same(game.contentAspectRatio, target));
        } else {
            check("without a valid HXI_GAME_ASPECT the game window is left alone",
                  same(game.contentAspectRatio, before));
        }
        check("locking does not move or resize the window", NSEqualRects(game.frame, frameBefore));
        check("the window was never shown", !game.isVisible);

        // Becoming key locks too (so the very first drag is already in proportion).
        NSWindow *keyed = make([NSWindow class], gameMask, 1280, 720);
        NSSize keyedBefore = keyed.contentAspectRatio;
        post(NSWindowDidBecomeKeyNotification, keyed);
        check(expectLock ? "becoming key locks a plain NSWindow as well"
                         : "becoming key leaves it alone without HXI_GAME_ASPECT",
              same(keyed.contentAspectRatio, expectLock ? target : keyedBefore));

        // Exactly the client's 640x480 floor under Retina mode: 320x240 points.
        NSWindow *floorWin = make([FakeWineWindow class], gameMask, 320, 240);
        NSSize floorBefore = floorWin.contentAspectRatio;
        post(NSWindowWillStartLiveResizeNotification, floorWin);
        check("a 320x240-point window (640x480 game) counts",
              same(floorWin.contentAspectRatio, expectLock ? target : floorBefore));

        // Windows that must never be touched.
        NSWindow *fixed = make([FakeWineWindow class], NSWindowStyleMaskTitled | NSWindowStyleMaskClosable, 960, 540);
        NSSize fixedBefore = fixed.contentAspectRatio;
        post(NSWindowWillStartLiveResizeNotification, fixed);
        post(NSWindowDidBecomeKeyNotification, fixed);
        check("a window that is not resizable is left alone", same(fixed.contentAspectRatio, fixedBefore));

        NSWindow *bare = make([FakeWineWindow class], NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable, 960, 540);
        NSSize bareBefore = bare.contentAspectRatio;
        post(NSWindowWillStartLiveResizeNotification, bare);
        check("a borderless window is left alone", same(bare.contentAspectRatio, bareBefore));

        NSWindow *tiny = make([FakeWineWindow class], gameMask, 200, 150);
        NSSize tinyBefore = tiny.contentAspectRatio;
        post(NSWindowWillStartLiveResizeNotification, tiny);
        check("a window under 320x240 points is left alone", same(tiny.contentAspectRatio, tinyBefore));

        // Off the main thread: never touched (AppKit windows are main-thread only).
        NSWindow *bg = make([FakeWineWindow class], gameMask, 960, 540);
        NSSize bgBefore = bg.contentAspectRatio;
        NSThread *t = [[NSThread alloc] initWithBlock:^{
            post(NSWindowWillStartLiveResizeNotification, bg);
        }];
        [t start];
        while (!t.isFinished) [NSThread sleepForTimeInterval:0.01];
        check("a notification posted off the main thread changes nothing", same(bg.contentAspectRatio, bgBefore));

        // Not windows at all: must not crash.
        post(NSWindowWillStartLiveResizeNotification, @"not a window");
        post(NSWindowDidBecomeKeyNotification, @42);
        post(NSWindowWillStartLiveResizeNotification, nil);
        check("a non-window object or no object with those names is ignored (no crash)", YES);

        // A window that already had a different ratio is put on the game's.
        NSWindow *other = make([FakeWineWindow class], gameMask, 960, 720);
        other.contentAspectRatio = NSMakeSize(4, 3);
        post(NSWindowWillStartLiveResizeNotification, other);
        check(expectLock ? "a window with another ratio is put on the game's"
                         : "a window's own ratio is kept without HXI_GAME_ASPECT",
              same(other.contentAspectRatio, expectLock ? target : NSMakeSize(4, 3)));

        for (NSWindow *w in @[game, keyed, floorWin, fixed, bare, tiny, bg, other]) [w close];
        printf("%s: %d failure(s)\n", failures ? "FAILED" : "ok", failures);
    }
    return failures ? 1 : 0;
}
