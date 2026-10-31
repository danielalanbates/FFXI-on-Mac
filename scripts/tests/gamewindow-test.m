// Stand-in for wine's Mac driver: makes windows the way winemac.drv does (an NSPanel subclass,
// titled and resizable), never shows them, posts the notifications AppKit posts around a live
// resize, and checks what gamewindow.dylib did to them.
//
//   gamewindow-test lock   expects game-sized windows locked to HXI_GAME_ASPECT
//   gamewindow-test none   expects nothing locked (no or invalid HXI_GAME_ASPECT)
//   gamewindow-test title <key|main|shown> <expect|none>
//                          wine's window title path (WineWindow, WineApplication, the Window menu):
//                          with `expect`, a game window first seen through that notification and
//                          every later title wine gives it read HXI_WINDOW_TITLE, other windows
//                          keep theirs; with `none`, nothing changes at all
//   gamewindow-test hang <close|quit|cmdq|cmdqopt> <polls|wakes|frames|stops|hung|dialog|raised>
//                          not responding (FFXI_GAMEWINDOW_HANG): wine's event queue, window,
//                          application controller and Metal layer under wine's class names, a
//                          stand-in for the game's thread (`model`) and one request; the shell
//                          judges from the exit status and the log (a Force Quit is SIGKILL)
//
// Nothing is ever ordered front and the app may never activate (activation policy Prohibited),
// so it is safe to run while somebody is using the Mac. Build/run: scripts/tests/gamewindow-test.sh
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdatomic.h>
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

// winemac.drv's windows are NSPanels (WineWindow : NSPanel), and each is its own delegate:
// windowWillResize:toSize: returns AppKit's size unless the game's window procedure handles
// WM_SIZING (query_resize_size). `forced` stands in for a game that does, with its own size.
@interface FakeWineWindow : NSPanel <NSWindowDelegate>
@property NSSize forced;   // content size the "game" answers WM_SIZING with; zero = not handled
@end
@implementation FakeWineWindow
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
    (void)sender;
    if (self.forced.width <= 0) return frameSize;
    return [self frameRectForContentRect:NSMakeRect(0, 0, self.forced.width, self.forced.height)].size;
}
@end

// The size AppKit's live-resize tracking computes for one drag of the right edge (private, guarded:
// returns NO when this macOS does not have it). Pure computation on a window that is never shown.
static BOOL drag_right_edge(NSWindow *w, CGFloat dx, NSSize *content) {
    SEL s = NSSelectorFromString(@"_frame:resizedFromEdge:withDelta:withEvent:");
    if (![w respondsToSelector:s]) return NO;
#if defined(__x86_64__)
    // A 32-byte struct comes back through memory on x86_64: the _stret entry point.
    NSRect r = ((NSRect (*)(id, SEL, NSRect, unsigned long, NSSize, id))objc_msgSend_stret)(
        w, s, w.frame, 4 /* right edge, as measured on macOS 27 */, NSMakeSize(dx, 0), nil);
#else
    NSRect r = ((NSRect (*)(id, SEL, NSRect, unsigned long, NSSize, id))objc_msgSend)(
        w, s, w.frame, 4 /* right edge, as measured on macOS 27 */, NSMakeSize(dx, 0), nil);
#endif
    *content = [w contentRectForFrameRect:r].size;
    return YES;
}

static BOOL in_ratio(NSSize c, NSSize ratio) {
    double off = c.width * ratio.height - c.height * ratio.width;
    return fabs(off) <= ratio.width + ratio.height;   // within one point either way
}

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

// KVO on a window's title (AppKit and accessibility observe windows this way): the window's
// class is then a runtime subclass of WineWindow, which must still get the game's title.
@interface TitleWatcher : NSObject
@property int changes;
@end
@implementation TitleWatcher
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context {
    (void)keyPath; (void)object; (void)change; (void)context;
    self.changes++;
}
@end

static BOOL titled(NSWindow *w, NSString *t) { return [w.title isEqualToString:t]; }

/// The Window menu item of `w`, or nil.
static NSString *menu_title(NSWindow *w) {
    for (NSMenuItem *item in NSApp.windowsMenu.itemArray)
        if (item.target == w) return item.title;
    return nil;
}

/// wine's title path, as winemac.drv runs it (cocoa_window.m, macdrv_set_cocoa_window_title):
/// [window setTitle:], then, for a window that is ordered in (here: has a Window menu item),
/// [NSApp changeWindowsItem:title:filename:NO].
static void wine_set_title(NSWindow *w, NSString *t) {
    [w setTitle:t];
    if (menu_title(w)) [NSApp changeWindowsItem:w title:t filename:NO];
}

/// What wine does when it orders a window in (cocoa_window.m): [NSApp addWindowsItem:self
/// title:[self title] filename:NO]. The window itself is never ordered in here.
static void wine_order_in(NSWindow *w) {
    [NSApp addWindowsItem:w title:w.title filename:NO];
}

static int title_main(const char *first, BOOL expect) {
    NSString *want = expect ? [NSString stringWithUTF8String:getenv("HXI_WINDOW_TITLE") ?: ""] : nil;
    if (expect && want.length == 0) { printf("FAIL  expect mode needs HXI_WINDOW_TITLE\n"); return 2; }
    NSString *firstName = strcmp(first, "main") == 0 ? NSWindowDidBecomeMainNotification
                        : strcmp(first, "shown") == 0 ? NSWindowDidChangeOcclusionStateNotification
                        : NSWindowDidBecomeKeyNotification;
    double W = 0, H = 0;
    const char *aspectEnv = getenv("HXI_GAME_ASPECT");
    BOOL aspect = aspectEnv && sscanf(aspectEnv, "%lfx%lf", &W, &H) == 2;

    // wine's classes, made at run time under wine's names: WineApplication : NSApplication (it
    // does not implement changeWindowsItem:title:filename:) and WineWindow : NSPanel.
    Class wineApp = objc_allocateClassPair([NSApplication class], "WineApplication", 0);
    objc_registerClassPair(wineApp);
    Class wineWindow = objc_allocateClassPair([NSPanel class], "WineWindow", 0);
    objc_registerClassPair(wineWindow);
    [wineApp sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    check("NSApp is a WineApplication", [NSApp class] == wineApp);
    check("gamewindow.dylib is loaded in this process", dylib_loaded());
    // The Window menu, as wine builds it (cocoa_app.m transformProcessToForeground). Never shown.
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [mainMenu addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = windowMenu;
    NSApp.mainMenu = mainMenu;
    NSApp.windowsMenu = windowMenu;

    SEL setTitle = @selector(setTitle:), change = @selector(changeWindowsItem:title:filename:);
    IMP wineBefore = class_getMethodImplementation(wineWindow, setTitle);
    IMP windowBefore = class_getMethodImplementation([NSWindow class], setTitle);
    IMP panelBefore = class_getMethodImplementation([NSPanel class], setTitle);
    IMP appBefore = class_getMethodImplementation(wineApp, change);
    IMP nsappBefore = class_getMethodImplementation([NSApplication class], change);

    const NSWindowStyleMask gameMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                     | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    // The game window as wine makes it: titled from the Windows title, added to the Window menu
    // when ordered in (never ordered in here).
    NSWindow *game = make(wineWindow, gameMask, 960, 540);
    wine_set_title(game, @"FINAL FANTASY XI");
    wine_order_in(game);
    // Windows that must keep their own titles: a message box (wine's too, not resizable), a
    // titled resizable window that is not wine's, and a resizable wine window under 320x240 points.
    NSWindow *dialog = make(wineWindow, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable, 400, 300);
    wine_set_title(dialog, @"Error");
    wine_order_in(dialog);
    NSWindow *plain = make([NSWindow class], gameMask, 960, 540);
    wine_set_title(plain, @"Launcher");
    wine_order_in(plain);
    NSWindow *small = make(wineWindow, gameMask, 200, 150);
    wine_set_title(small, @"Small");
    wine_order_in(small);
    // A game window already observed by KVO before anything is overridden: its class is a KVO
    // subclass made from WineWindow as it was, and must still get the title once the override is in.
    NSWindow *early = make(wineWindow, gameMask, 800, 600);
    wine_set_title(early, @"Early");
    TitleWatcher *earlyWatcher = [TitleWatcher new];
    [early addObserver:earlyWatcher forKeyPath:@"title" options:0 context:NULL];
    check("before any window notification nothing is overridden or retitled",
          titled(game, @"FINAL FANTASY XI") && [menu_title(game) isEqualToString:@"FINAL FANTASY XI"]
          && class_getMethodImplementation(wineWindow, setTitle) == wineBefore
          && class_getMethodImplementation(wineApp, change) == appBefore);

    post(firstName, dialog);
    post(firstName, plain);
    post(firstName, small);
    post(firstName, @"not a window");
    post(firstName, nil);
    check("a message box, a window that is not wine's, a small window and non-windows install nothing",
          class_getMethodImplementation(wineWindow, setTitle) == wineBefore
          && class_getMethodImplementation(wineApp, change) == appBefore
          && titled(dialog, @"Error") && titled(plain, @"Launcher") && titled(small, @"Small"));

    // First sighting of the game window, after the game already titled it.
    NSSize ratioBefore = game.contentAspectRatio;
    post(firstName, game);
    if (expect) {
        check("first sighting: the game window's title is HXI_WINDOW_TITLE at once", titled(game, want));
        check("first sighting: its Window menu item says the same",
              [menu_title(game) isEqualToString:want]);
        check("-setTitle: is overridden on WineWindow only (NSPanel, NSWindow untouched)",
              class_getMethodImplementation(wineWindow, setTitle) != wineBefore
              && class_getMethodImplementation([NSWindow class], setTitle) == windowBefore
              && class_getMethodImplementation([NSPanel class], setTitle) == panelBefore);
        check("-changeWindowsItem:title:filename: is overridden on WineApplication only",
              class_getMethodImplementation(wineApp, change) != appBefore
              && class_getMethodImplementation([NSApplication class], change) == nsappBefore);
    } else {
        check("without HXI_WINDOW_TITLE the game window keeps the game's title",
              titled(game, @"FINAL FANTASY XI") && [menu_title(game) isEqualToString:@"FINAL FANTASY XI"]);
        check("without HXI_WINDOW_TITLE nothing is overridden",
              class_getMethodImplementation(wineWindow, setTitle) == wineBefore
              && class_getMethodImplementation(wineApp, change) == appBefore);
    }
    // The ratio is still only the key notification's business.
    BOOL lockedNow = aspect && strcmp(first, "key") == 0;
    check(lockedNow ? "becoming key still locks the ratio alongside the title"
                    : "this notification does not touch the ratio",
          same(game.contentAspectRatio, lockedNow ? NSMakeSize(W, H) : ratioBefore));

    // Ashita at login: SetWindowText(character name), which wine copies to the title and the menu.
    wine_set_title(game, @"Murn");
    check(expect ? "the character's name at login becomes HXI_WINDOW_TITLE (title and Window menu)"
                 : "without HXI_WINDOW_TITLE the character's name shows (title and Window menu)",
          titled(game, expect ? want : @"Murn") && [menu_title(game) isEqualToString:expect ? want : @"Murn"]);
    wine_set_title(game, @"Other");
    check(expect ? "any later title becomes HXI_WINDOW_TITLE too" : "any later title shows as given",
          titled(game, expect ? want : @"Other") && [menu_title(game) isEqualToString:expect ? want : @"Other"]);

    // Observed by KVO: the window's class is now a runtime subclass of WineWindow.
    TitleWatcher *watcher = [TitleWatcher new];
    [game addObserver:watcher forKeyPath:@"title" options:0 context:NULL];
    wine_set_title(game, @"Watched");
    check(expect ? "a window observed by KVO still gets HXI_WINDOW_TITLE (and KVO still fires)"
                 : "a window observed by KVO gets its title as given",
          titled(game, expect ? want : @"Watched") && watcher.changes > 0);
    [game removeObserver:watcher forKeyPath:@"title"];
    wine_set_title(early, @"Murn");
    check(expect ? "a window observed by KVO before the override gets HXI_WINDOW_TITLE too (and KVO still fires)"
                 : "a window observed by KVO before anything gets its title as given",
          titled(early, expect ? want : @"Murn") && earlyWatcher.changes > 0);
    [early removeObserver:earlyWatcher forKeyPath:@"title"];

    // The Window menu still works: exactly one item for the game window, still aimed at it with
    // AppKit's action, so choosing it brings the window forward.
    NSInteger gameItems = 0;
    BOOL aimed = YES;
    for (NSMenuItem *item in windowMenu.itemArray) {
        if (item.target != game) continue;
        gameItems++;
        aimed = aimed && item.action == @selector(makeKeyAndOrderFront:);
    }
    check("the game window keeps one Window menu item, aimed at it with makeKeyAndOrderFront:",
          gameItems == 1 && aimed);

    // A second game window, made after the override: its first title is already the game's, and
    // so is the Window menu item wine gives it when it is ordered in.
    NSWindow *second = make(wineWindow, gameMask, 1280, 720);
    wine_set_title(second, @"Second");
    check(expect ? "a later game window reads HXI_WINDOW_TITLE from its first title"
                 : "a later game window keeps its title",
          titled(second, expect ? want : @"Second"));
    // Not ordered in yet: sightings must not give it a Window menu item.
    NSInteger items = windowMenu.numberOfItems;
    post(NSWindowDidBecomeKeyNotification, game);
    post(NSWindowDidBecomeMainNotification, game);
    post(NSWindowDidChangeOcclusionStateNotification, second);
    check("notifications never add a Window menu item", windowMenu.numberOfItems == items && menu_title(second) == nil);
    wine_order_in(second);
    check(expect ? "its Window menu item reads HXI_WINDOW_TITLE when it is ordered in"
                 : "its Window menu item reads its own title when it is ordered in",
          [menu_title(second) isEqualToString:expect ? want : @"Second"]);

    // The others still pass through untouched, title and Window menu.
    wine_set_title(dialog, @"Error 2");
    wine_set_title(plain, @"Launcher 2");
    wine_set_title(small, @"Small 2");
    check("a message box keeps its own title (title and Window menu)",
          titled(dialog, @"Error 2") && [menu_title(dialog) isEqualToString:@"Error 2"]);
    check("a titled resizable window that is not wine's keeps its own title",
          titled(plain, @"Launcher 2") && [menu_title(plain) isEqualToString:@"Launcher 2"]);
    check("a resizable wine window under 320x240 points keeps its own title", titled(small, @"Small 2"));
    wine_set_title(dialog, @"");
    check("an empty title for a message box stays empty", titled(dialog, @""));

    check("no window was ever shown",
          !game.isVisible && !dialog.isVisible && !plain.isVisible && !small.isVisible && !second.isVisible
          && !early.isVisible);
    for (NSWindow *w in @[game, dialog, plain, small, second, early]) [w close];
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "ok", failures);
    return failures ? 1 : 0;
}

// --- Not responding ------------------------------------------------------------------------------
// wine's classes as the dylib relies on them (athei/wine cx-26-patched, dlls/winemac.drv); the
// runtime subclasses made in hang_main carry wine's names.

// WineEventQueue (cocoa_event.m): -getEventMatchingMask:, called only by the thread that owns the
// queue. -post stands in for postEvent:, which writes the queue's pipe and so wakes that thread.
@interface HangQueue : NSObject {
@public
    dispatch_semaphore_t wake;
    _Atomic int polls, posted;
}
- (id)getEventMatchingMask:(uint64_t)mask;
- (void)post;
@end
@implementation HangQueue
- (instancetype)init {
    if ((self = [super init])) wake = dispatch_semaphore_create(0);
    return self;
}
- (id)getEventMatchingMask:(uint64_t)mask { (void)mask; atomic_fetch_add(&polls, 1); return nil; }
- (void)post { atomic_fetch_add(&posted, 1); dispatch_semaphore_signal(wake); }
@end

// WineWindow (cocoa_window.m): an NSPanel that is its own delegate (:1049) with its thread's queue
// (:1053); -windowShouldClose: posts the close there and answers NO (:3202-3208).
@interface HangWindow : NSPanel <NSWindowDelegate>
@property (strong) HangQueue *queue;
@property int closeRequests;
@end
@implementation HangWindow
- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    self.closeRequests++;
    [self.queue post];
    return NO;
}
@end

// WineApplicationController (cocoa_app.m:2655-2696): the quit goes to every queue, and AppKit is
// told NSTerminateLater while the Windows side decides.
@interface HangController : NSObject <NSApplicationDelegate>
@property (strong) HangQueue *queue;
@property int quitRequests;
@end
@implementation HangController
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    self.quitRequests++;
    [self.queue post];
    return NSTerminateLater;
}
@end

// WineMetalLayer (d3dmetal_objc.m:38-71): -nextDrawable ends in CAMetalLayer's, through super.
@interface HangLayer : CAMetalLayer
@end
@implementation HangLayer
- (id<CAMetalDrawable>)nextDrawable { return [super nextDrawable]; }
@end

// A window wine raised (a topmost game window at NSFloatingWindowLevel, or one above the screen
// shield while the displays are captured): it only says it is on screen at level 1000, so the
// question's level can be checked without showing anything.
@interface RaisedWindow : NSWindow
@end
@implementation RaisedWindow
- (BOOL)isVisible { return YES; }
- (NSWindowLevel)level { return 1000; }
- (BOOL)reallyVisible { return [super isVisible]; }
@end

static _Atomic int model_stop;

/// One request to a stand-in game whose thread does `model`: polls = reads its queue every 33 ms
/// (playing); wakes = blocked until something is posted, then reads it (idle in GetMessage);
/// frames = draws at 30 fps and reads nothing; stops = reads and draws, then stops just before the
/// request; hung = nothing at all; dialog = hung, and the close is a message box's; raised = hung,
/// beside a window at level 1000.
static int hang_main(const char *path, const char *model) {
    BOOL quit = strcmp(path, "quit") == 0, cmdq = strncmp(path, "cmdq", 4) == 0;
    BOOL option = strcmp(path, "cmdqopt") == 0, dialog = strcmp(model, "dialog") == 0;
    BOOL raised = strcmp(model, "raised") == 0;
    BOOL silent = strcmp(model, "hung") == 0 || strcmp(model, "stops") == 0 || dialog || raised;
    const char *h = getenv("FFXI_GAMEWINDOW_HANG");
    BOOL off = h && strcmp(h, "0") == 0;
    double T = off ? 1 : (h && atoi(h) > 0 ? atoi(h) : 5);

    Class wq = objc_allocateClassPair([HangQueue class], "WineEventQueue", 0);
    objc_registerClassPair(wq);
    Class ww = objc_allocateClassPair([HangWindow class], "WineWindow", 0);
    objc_registerClassPair(ww);
    Class wc = objc_allocateClassPair([HangController class], "WineApplicationController", 0);
    objc_registerClassPair(wc);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    check("gamewindow.dylib is loaded in this process", dylib_loaded());

    HangQueue *q = [wq new];
    HangController *controller = [wc new];
    controller.queue = q;
    NSApp.delegate = controller;
    const NSWindowStyleMask gameMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                     | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    // Not deferred for Cmd-Q, so the key event can name the window. Never shown either way.
    HangWindow *game = [[ww alloc] initWithContentRect:NSMakeRect(100, 100, 960, 540) styleMask:gameMask
                                               backing:NSBackingStoreBuffered defer:!cmdq];
    HangWindow *box = [[ww alloc] initWithContentRect:NSMakeRect(100, 100, 400, 300)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered defer:YES];
    for (HangWindow *w in @[game, box]) { w.releasedWhenClosed = NO; w.queue = q; w.delegate = w; }
    RaisedWindow *top = nil;
    if (raised) {
        top = [[RaisedWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
        top.releasedWhenClosed = NO;
    }

    SEL shouldClose = @selector(windowShouldClose:), getEvent = @selector(getEventMatchingMask:);
    IMP closeBefore = class_getMethodImplementation(ww, shouldClose);
    IMP pollBefore = class_getMethodImplementation(wq, getEvent);
    post(NSWindowDidBecomeKeyNotification, box);
    check("a message box (not resizable) installs nothing", class_getMethodImplementation(ww, shouldClose) == closeBefore);
    // In a pool of its own, as one pass of wine's run loop: what the dylib sets up there (the
    // Cmd-Q key monitor) must outlive the pool.
    @autoreleasepool { post(NSWindowDidBecomeKeyNotification, game); }
    BOOL installed = class_getMethodImplementation(ww, shouldClose) != closeBefore
                  && class_getMethodImplementation(wq, getEvent) != pollBefore;
    check(off ? "FFXI_GAMEWINDOW_HANG=0: nothing is overridden"
              : "the game window's first sighting overrides -windowShouldClose: and -getEventMatchingMask:",
          off ? !installed : installed);

    // The game's thread.
    HangLayer *layer = [HangLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    layer.drawableSize = CGSizeMake(16, 16);
    BOOL reads = strcmp(model, "polls") == 0 || strcmp(model, "stops") == 0;
    BOOL draws = strcmp(model, "frames") == 0 || strcmp(model, "stops") == 0;
    BOOL waits = strcmp(model, "wakes") == 0;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        while (!atomic_load(&model_stop)) {
            @autoreleasepool {
                if (waits) {
                    if (dispatch_semaphore_wait(q->wake, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0)
                        (void)[q getEventMatchingMask:~0ULL];
                    continue;
                }
                if (reads) (void)[q getEventMatchingMask:~0ULL];
                if (draws) (void)[layer nextDrawable];
                usleep(33000);
            }
        }
    }];
    if (reads || draws || waits) [thread start];
    [NSThread sleepForTimeInterval:0.3];
    if (strcmp(model, "stops") == 0) {
        atomic_store(&model_stop, 1);
        while (!thread.isFinished) [NSThread sleepForTimeInterval:0.01];
    }

    // The request, the way AppKit makes it, then the run loop for longer than the threshold: in
    // NSModalPanelRunLoopMode for a quit (where AppKit waits after NSTerminateLater).
    NSRunLoopMode mode = quit ? NSModalPanelRunLoopMode : NSDefaultRunLoopMode;
    [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:mode];   // so an idle mode still waits
    HangWindow *target = dialog ? box : game;
    void (^request)(void) = ^{
        if (quit) {
            // What -[NSApplication terminate:] asks first (the app menu's Quit, the Dock's Quit).
            NSApplicationTerminateReply r = [controller applicationShouldTerminate:NSApp];
            check("wine's -applicationShouldTerminate: still runs and answers NSTerminateLater", r == NSTerminateLater);
        } else if (cmdq) {
            NSEventModifierFlags flags = NSEventModifierFlagCommand | (option ? NSEventModifierFlagOption : 0);
            NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                                          timestamp:0 windowNumber:game.windowNumber context:nil
                                         characters:@"q" charactersIgnoringModifiers:@"q" isARepeat:NO keyCode:12];
            [NSApp postEvent:ev atStart:YES];
            NSEvent *got = [NSApp nextEventMatchingMask:NSEventMaskKeyDown
                                              untilDate:[NSDate dateWithTimeIntervalSinceNow:1]
                                                 inMode:NSDefaultRunLoopMode dequeue:YES];
            check("the key event comes through unchanged",
                  got.type == NSEventTypeKeyDown && got.modifierFlags == ev.modifierFlags
                  && [got.charactersIgnoringModifiers isEqualToString:@"q"]);
            if (got) [NSApp sendEvent:got];
            [q post];   // what wine's keyDown: does with it next (cocoa_window.m:2917-2928)
        } else {
            // What the red button's performClose: asks the delegate (WineWindow is its own).
            (void)[target.delegate windowShouldClose:target];
        }
    };
    void (^spin)(double) = ^(double secs) {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:secs];
        while ([until timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:mode beforeDate:until];
    };
    request();
    spin(T + 1.5);
    check("the request went to wine's own handler and the game's queue once",
          atomic_load(&q->posted) == 1
          && (quit ? controller.quitRequests == 1 : cmdq ? YES : target.closeRequests == 1));
    if (silent && !dialog && !option && !off) {
        // Still here: Wait was the answer. The next request is judged afresh (two questions).
        request();
        spin(T + 1.5);
        check("a request after Wait is watched again", atomic_load(&q->posted) == 2);
    }
    atomic_store(&model_stop, 1);
    while (thread.executing) [NSThread sleepForTimeInterval:0.01];
    check("no window was ever shown", !game.isVisible && !box.isVisible && (!top || !top.reallyVisible));
    [top close];
    [game close];
    [box close];
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "ok", failures);
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 3 && strcmp(argv[1], "title") == 0)
            return title_main(argv[2], strcmp(argv[3], "expect") == 0);
        if (argc > 3 && strcmp(argv[1], "hang") == 0)
            return hang_main(argv[2], argv[3]);
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

        // What a drag does with the lock: AppKit's own resize computation (the one its live-resize
        // tracking runs per mouse event), on wine-shaped windows that are their own delegate and
        // are never shown. A right-edge drag of +300 points without the lock only widens; with it
        // the height follows. And when the "game" answers WM_SIZING with its own size, that size
        // wins: AppKit applies the ratio before asking the delegate, not after.
        FakeWineWindow *dragged = (FakeWineWindow *)make([FakeWineWindow class], gameMask, 960, 540);
        dragged.delegate = dragged;
        post(NSWindowDidBecomeKeyNotification, dragged);
        FakeWineWindow *control = (FakeWineWindow *)make([FakeWineWindow class], gameMask, 960, 540);
        control.delegate = control;
        NSSize c1, c0;
        if (drag_right_edge(dragged, 300, &c1) && drag_right_edge(control, 300, &c0)) {
            printf("info  right-edge drag +300: locked window -> %.0fx%.0f, unlocked -> %.0fx%.0f points\n",
                   c1.width, c1.height, c0.width, c0.height);
            check("an unlocked window's drag changes only the width (the squeeze this prevents)",
                  c0.width > 960 && c0.height == 540);
            if (expectLock) {
                check("a locked window's drag keeps HXI_GAME_ASPECT, the height following the width",
                      c1.width > 960 && c1.height > 540 && in_ratio(c1, target));
                dragged.forced = NSMakeSize(1000, 400);
                NSSize cf;
                drag_right_edge(dragged, 300, &cf);
                check("a game that answers WM_SIZING with its own size overrides the ratio (why the log reports it)",
                      cf.width == 1000 && cf.height == 400);
                dragged.forced = NSZeroSize;
            } else {
                check("without a valid HXI_GAME_ASPECT a drag is as free as before", same(c1, c0));
            }
        } else {
            printf("info  AppKit's drag computation is not available on this macOS; drag checks skipped\n");
        }
        // FFXI_GAMEWINDOW_DEBUG reports the end of a live resize (the shell checks the lines):
        // one in proportion, then one the "game" forced out of it. Never moves or shows anything.
        post(NSWindowDidEndLiveResizeNotification, dragged);
        [dragged setContentSize:NSMakeSize(1000, 400)];
        post(NSWindowDidEndLiveResizeNotification, dragged);
        check("the dragged windows were never shown", !dragged.isVisible && !control.isVisible);

        for (NSWindow *w in @[game, keyed, floorWin, fixed, bare, tiny, bg, other, dragged, control]) [w close];
        printf("%s: %d failure(s)\n", failures ? "FAILED" : "ok", failures);
    }
    return failures ? 1 : 0;
}
