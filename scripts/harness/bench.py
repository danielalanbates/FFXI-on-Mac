#!/usr/bin/env python3
"""HorizonXI-on-Mac benchmark runner.

One command per configuration variant. Applies the variant, launches the game, walks it to the
character-select screen, samples the frame rate, screenshots the window in the background and
kills the client. Every variant is measured the same way so the numbers compare.

    ./bench.py --tag baseline
    ./bench.py --tag no-argbuf --env MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0
    ./bench.py --tag dxmt --profile profiles/dxmt.json

Frame rate comes from DXVK_FPS_LOG (built into our d3d9.dll) when the pathway uses DXVK, and
otherwise from fpsvideo.py, which counts visually distinct frames in a screen recording.

Scene: character select. Heavy (~1900 draws), deterministic, needs two keypresses to reach and
no character is in the world, so killing the client afterwards is safe.
"""
import argparse, json, os, re, shutil, statistics, subprocess, sys, time

WRAP  = "/Users/daniel/Games/HorizonXI/siku.app"
SS    = f"{WRAP}/Contents/SharedSupport"
PFX   = f"{SS}/prefix10"
GAME  = f"{PFX}/drive_c/HorizonXI"
WINE  = f"{SS}/wine/bin/wine"
WORK  = "/Users/daniel/Games/hxi-workspace"
BASE  = f"{WORK}/baseline-config"
RESULTS = f"{WORK}/results"
SHOTS = f"{WORK}/shots"
FPSCSV_WIN = r"C:\HorizonXI\logs\dxvkfps.csv"
FPSCSV = f"{GAME}/logs/dxvkfps.csv"

BASE_ENV = {
    "WINEPREFIX": PFX,
    "DYLD_FALLBACK_LIBRARY_PATH": f"{WRAP}/Contents/Frameworks:/usr/lib",
    "D3DMETAL_FRAMEWORK_PATH": f"{WRAP}/Contents/Frameworks/renderer/d3dmetal/external",
    "WINEMSYNC": "1",
    "MVK_CONFIG_FAST_MATH_ENABLED": "1",
    "MVK_CONFIG_USE_COMMAND_POOLING": "1",
    "MVK_CONFIG_PREALLOCATE_DESCRIPTORS": "1",
    "MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION": "1",
    "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS": "1",
    "DXVK_CONFIG_FILE": r"C:\HorizonXI\dxvk.conf",
    "DXVK_FPS_LOG": FPSCSV_WIN,
    "WINEDEBUG": "-all",
}

HORIZON_PLUGINS = ["addons", "screenshot", "Nameplate", "PacketFlow", "sequencer", "thirdparty"]
HORIZON_ADDONS  = ["dynamic_entity_renamer", "allmaps", "chatmon", "checker", "distance",
                   "filterless", "fps", "instantah", "links", "macrofix", "nocombat",
                   "nolock", "recast", "timers", "tparty"]
REQUIRED_PLUGINS = ["addons", "PacketFlow"]


def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)


# wine's service processes do not exit when the game and wineserver are killed. Each launch
# otherwise leaks services.exe, svchost.exe, plugplay.exe, rpcss.exe, winedevice.exe and
# explorer.exe. Over a long benchmarking session that reached 800 orphaned processes and 29,100
# of the system's 30,720 file descriptors, at which point wine fails with "pipe: Too many open
# files in system" -- and, before failing outright, it makes every measurement quietly slower.
# Always sweep them.
WINE_SERVICES = ("explorer.exe", "plugplay.exe", "rpcss.exe", "svchost.exe",
                 "winedevice.exe", "services.exe")


def orphan_count():
    out = sh("ps", "-Ao", "command").stdout
    return sum(out.count(p) for p in WINE_SERVICES + ("wineserver",))


def kill_all():
    for pat in ("Ashita-cli", "horizon-loader", "pol.exe", "ffxi", "FFXi"):
        sh("pkill", "-9", "-f", pat)
    time.sleep(1)
    sh("pkill", "wineserver")
    for _ in range(25):
        if not sh("pgrep", "-f", "wineserver").stdout.strip():
            break
        time.sleep(1)
    sh("pkill", "-9", "wineserver")
    for pat in WINE_SERVICES:
        sh("pkill", "-9", "-f", pat)
    time.sleep(2)
    left = orphan_count()
    if left > 4:
        print(f"  WARNING: {left} wine helper processes still alive", flush=True)


def write_default_txt(addons_mode, extra=()):
    if addons_mode == "full":
        plugins, addons = HORIZON_PLUGINS, HORIZON_ADDONS
    elif addons_mode == "min":
        plugins, addons = REQUIRED_PLUGINS, []
    elif addons_mode == "none":
        plugins, addons = [], []
    else:
        raise SystemExit(f"unknown addons mode {addons_mode}")
    lines = ["/load winefix", ""]
    lines += [f"/load {p}" for p in plugins]
    lines += [f"/addon load {a}" for a in addons]
    lines += ["", "/wait 3", "/ambient 255 255 255"]
    lines += list(extra)
    open(f"{GAME}/scripts/default.txt", "w").write("\n".join(lines) + "\n")


def apply_registry(overrides, boot="horizonxi.ini"):
    """Write the boot profile the client will use, with graphics settings overridden.

    `boot` selects which profile: horizonxi.ini is the live server, lsb.ini the local
    LandSandBoat one. Getting this wrong sends a benchmark run at the *live* server, so it is
    an explicit argument rather than a hardcoded filename.
    """
    src = open(f"{BASE}/{boot}.orig", encoding="utf-8", errors="replace").read()
    if overrides:
        out, in_reg = [], False
        for line in src.splitlines():
            s = line.strip()
            if s.startswith("["):
                in_reg = s.lower() == "[ffxi.registry]"
            if in_reg:
                m = re.match(r"^(\d{4})(\s*=\s*)(.*)$", s)
                if m and m.group(1) in overrides:
                    out.append(f"{m.group(1)} = {overrides[m.group(1)]}")
                    continue
            out.append(line)
        src = "\n".join(out) + "\n"
    open(f"{GAME}/config/boot/{boot}", "w", encoding="utf-8").write(src)


def loader_argv(boot):
    """The bootloader command line for a boot profile, for launching without Ashita.

    Read from the profile that this run is actually using -- reading horizonxi.ini
    unconditionally pointed every --no-ashita run at the live server with the user's real
    credentials, even when the run was meant for the local server.
    """
    cmd = None
    for line in open(f"{BASE}/{boot}.orig", encoding="utf-8", errors="replace"):
        m = re.match(r"^\s*command\s*=\s*(.+?)\s*$", line)
        if m and "--server" in m.group(1):
            cmd = m.group(1).split()
    if cmd is None:
        raise SystemExit(f"could not find the loader command line in {boot}.orig")
    return [WINE, r"C:\HorizonXI\bootloader\horizon-loader.exe"] + cmd


def apply_dlls(profile):
    for name, src in profile.get("dlls", {}).items():
        for d in (GAME, f"{GAME}/bootloader"):
            dst = f"{d}/{name}"
            if src is None:
                if os.path.exists(dst):
                    os.remove(dst)
            else:
                shutil.copyfile(os.path.expanduser(src), dst)


def wine_reg(key, name, value, vtype="REG_SZ"):
    env = dict(os.environ, WINEPREFIX=PFX, WINEDEBUG="-all")
    if value is None:
        subprocess.run([WINE, "reg", "delete", key, "/v", name, "/f"], env=env, capture_output=True)
    else:
        subprocess.run([WINE, "reg", "add", key, "/v", name, "/t", vtype, "/d", value, "/f"],
                       env=env, capture_output=True)


def game_window():
    """The client's own window.

    wine puts up several windows -- including a full-width 1440x30 strip that is not the game.
    Taking the first one wider than 400 px picked that strip as soon as retina mode was
    enabled, so focus, keystrokes and screenshots all went to the wrong window and every run
    died with "the game is not frontmost". Choose by area, and require a real height.
    """
    import Quartz
    opts = (Quartz.kCGWindowListOptionOnScreenOnly |
            Quartz.kCGWindowListExcludeDesktopElements)
    wins = [w for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID)
            if (w.get("kCGWindowOwnerName") or "") == "wine"]
    # The client titles its window "FINAL FANTASY XI" (b69+: "FFXI on Mac", gamewindow.dylib).
    # Prefer that outright: during start-up wine also has a 1440x30 strip and a 500x500 helper
    # window, and picking by size alone resolves to one of those in the window between launch and
    # the game window appearing.
    named = [w for w in wins if any(t in (w.get("kCGWindowName") or "").upper()
                                    for t in ("FINAL FANTASY", "FFXI ON MAC"))]
    if named:
        return max(named, key=lambda w: w["kCGWindowBounds"]["Width"] *
                                        w["kCGWindowBounds"]["Height"])
    best = None
    for w in wins:
        b = w.get("kCGWindowBounds", {})
        if b.get("Width", 0) < 400 or b.get("Height", 0) < 200:
            continue
        if best is None or b["Width"] * b["Height"] > \
                best["kCGWindowBounds"]["Width"] * best["kCGWindowBounds"]["Height"]:
            best = w
    return best


def window_debug():
    """Every wine window, for explaining a focus failure instead of just asserting one."""
    import Quartz
    opts = (Quartz.kCGWindowListOptionOnScreenOnly |
            Quartz.kCGWindowListExcludeDesktopElements)
    out = []
    for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID):
        if (w.get("kCGWindowOwnerName") or "") == "wine":
            b = w.get("kCGWindowBounds", {})
            out.append(f"pid={w.get('kCGWindowOwnerPID')} "
                       f"{int(b.get('Width', 0))}x{int(b.get('Height', 0))} "
                       f"name={w.get('kCGWindowName')!r}")
    return "; ".join(out) or "no wine windows"


def focus_game(hide_others=False):
    """Give the game real keyboard focus. CGEventPostToPid does not work with wine, so the
    window has to actually be frontmost before any key is sent."""
    from AppKit import NSRunningApplication, NSWorkspace
    w = game_window()
    if not w:
        return False
    pid = w["kCGWindowOwnerPID"]
    ws = NSWorkspace.sharedWorkspace()
    if hide_others:
        for app in ws.runningApplications():
            if app.activationPolicy() == 0 and app.processIdentifier() != pid:
                app.hide()
        time.sleep(1.0)
    for _ in range(10):
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        if app is None:
            return False
        # A hidden application cannot be activated, and an earlier hide_others pass can hide the
        # game itself. Unhide before activating or focus silently never succeeds.
        if app.isHidden():
            app.unhide()
            time.sleep(0.3)
        app.activateWithOptions_(1 << 1)
        time.sleep(0.8)
        if ws.frontmostApplication().processIdentifier() == pid:
            return True
    return False



def game_is_frontmost():
    """True only when the game window belongs to the frontmost application."""
    w = game_window()
    if not w:
        return False
    # System Events rather than NSWorkspace. In a detached harness process NSWorkspace's
    # frontmostApplication reports whatever was frontmost when this process started -- Finder,
    # usually -- and never updates, so every 4K run aborted claiming the game was not focused
    # while it demonstrably was. System Events asks the window server each time.
    try:
        out = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to unix id of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=10).stdout.strip()
        return bool(out) and int(out) == w["kCGWindowOwnerPID"]
    except Exception:
        return False




def click_to_focus():
    """Focus the game by clicking its title bar.

    NSRunningApplication.activate is refused for this process even with Accessibility granted,
    but synthesized CGEvents work (they are what reach the frontmost app). Clicking a window
    focuses it, so a single click on the *title bar* -- never the game surface, which would
    send a click into the world -- gets focus without the activation API.
    """
    import Quartz, time as _t
    w = game_window()
    if not w:
        return False
    b = w["kCGWindowBounds"]
    # Title bar first, then the middle of the window. At 4K the window fills the screen and its
    # frame starts at x = -1, y = 30, which puts "title bar" within a pixel or two of the menu
    # bar and the desktop -- a click there lands on Finder and focus never arrives, which is
    # exactly how 4K runs kept aborting with `frontmost=Finder`. A click on the game surface is
    # safe at the point this is used: character select and standing still in the world.
    targets = [(b["X"] + b["Width"] / 2.0, b["Y"] + 12.0),
               (b["X"] + b["Width"] / 2.0, b["Y"] + b["Height"] / 2.0)]
    for x, y in targets:
        if x < 0 or y < 0:
            continue
        for ev in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
            e = Quartz.CGEventCreateMouseEvent(None, ev, (x, y), Quartz.kCGMouseButtonLeft)
            Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, 1)
            Quartz.CGEventPost(Quartz.kCGSessionEventTap, e)
            _t.sleep(0.10)
        _t.sleep(0.8)
        if game_is_frontmost():
            return True
    return game_is_frontmost()



def focus_via_system_events():
    """Focus the game with System Events.

    NSRunningApplication.activateWithOptions_ is refused for this process even with
    Accessibility granted, and clicking the title bar does not focus it either. Driving
    System Events by unix id does work, so it is the primary path; the Cocoa call stays as a
    fallback for environments where scripting is unavailable.
    """
    w = game_window()
    if not w:
        return False
    pid = w["kCGWindowOwnerPID"]
    for _ in range(4):
        sh("osascript", "-e",
           f'tell application "System Events" to set frontmost of '
           f'(first process whose unix id is {pid}) to true')
        # Activation is asynchronous: the script returns before the app is actually front, and
        # a single short sleep loses that race often enough to fail a whole run.
        for _ in range(10):
            time.sleep(0.25)
            if game_is_frontmost():
                return True
    return game_is_frontmost()


def ensure_focus(timeout=90):
    """Focus the game, retrying until it really is frontmost.

    Activation is unreliable while the client is still loading, and a detached harness process
    sometimes loses the race entirely. Retrying is fine; sending keys without focus is not --
    that is how keystrokes ended up in Finder.
    """
    import time as _t
    deadline = _t.time() + timeout
    while _t.time() < deadline:
        if game_is_frontmost():
            return True
        if focus_via_system_events():
            return True
        if click_to_focus():
            return True
        focus_game() or focus_game(hide_others=True)
        _t.sleep(2)
    return game_is_frontmost()


def press(keycode, hold=0.10, after=0.4, require_focus=True):
    """Send a key to the game.

    Keys go to whatever is frontmost, so if the game is not focused they land in Terminal or
    Finder instead. That has already renamed a folder on the Desktop and typed junk into a
    shell. Refuse to send unless the game really is frontmost.
    """
    # Establish focus rather than merely assert it: taking a screenshot or the client changing
    # scenes can drop it between calls, and a bare check then aborts a run that was fine. Keys
    # are still never sent unfocused -- that is how they ended up in Finder.
    if require_focus and not ensure_focus(timeout=60):
        try:
            from AppKit import NSWorkspace
            front = NSWorkspace.sharedWorkspace().frontmostApplication()
            front = f"{front.localizedName()} pid={front.processIdentifier()}"
        except Exception as e:
            front = f"unknown ({e})"
        raise RuntimeError("refusing to send keys: the game is not frontmost. "
                           f"frontmost={front}; wine windows: {window_debug()}")
    import Quartz
    Quartz.CGEventPost(Quartz.kCGHIDEventTap,
                       Quartz.CGEventCreateKeyboardEvent(None, keycode, True))
    time.sleep(hold)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap,
                       Quartz.CGEventCreateKeyboardEvent(None, keycode, False))
    time.sleep(after)



# Full US keyboard map, so the harness can type GM commands and chat rather than only the
# handful of keys the older code knew about.
KEYMAP = {
    'a': 0, 's': 1, 'd': 2, 'f': 3, 'h': 4, 'g': 5, 'z': 6, 'x': 7, 'c': 8, 'v': 9,
    'b': 11, 'q': 12, 'w': 13, 'e': 14, 'r': 15, 'y': 16, 't': 17, '1': 18, '2': 19,
    '3': 20, '4': 21, '6': 22, '5': 23, '=': 24, '9': 25, '7': 26, '-': 27, '8': 28,
    '0': 29, ']': 30, 'o': 31, 'u': 32, '[': 33, 'i': 34, 'p': 35, 'l': 37, 'j': 38,
    "'": 39, 'k': 40, ';': 41, '\\': 42, ',': 43, '/': 44, 'n': 45, 'm': 46, '.': 47,
    ' ': 49, '`': 50,
}
# Characters that need shift, mapped to the unshifted key they live on.
SHIFTED = {
    '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8',
    '(': '9', ')': '0', '_': '-', '+': '=', '{': '[', '}': ']', ':': ';', '"': "'",
    '<': ',', '>': '.', '?': '/', '~': '`', '|': '\\',
}


def type_text(text, per_key=0.05):
    """Type a string into the game, including characters that need shift.

    GM commands start with '!', which is shift+1 -- without shift handling the command silently
    becomes '1setweather' and nothing happens.
    """
    import Quartz
    if not ensure_focus():
        raise RuntimeError("refusing to type: the game is not frontmost")
    SHIFT = 56
    for ch in text:
        lower = ch.lower()
        shift = ch in SHIFTED or (ch.isalpha() and ch.isupper())
        key = KEYMAP.get(SHIFTED[ch]) if ch in SHIFTED else KEYMAP.get(lower)
        if key is None:
            continue
        if shift:
            Quartz.CGEventPost(Quartz.kCGHIDEventTap,
                               Quartz.CGEventCreateKeyboardEvent(None, SHIFT, True))
        down = Quartz.CGEventCreateKeyboardEvent(None, key, True)
        up = Quartz.CGEventCreateKeyboardEvent(None, key, False)
        # Stamp the actual character on the event. FFXI reads the character, not the keycode:
        # without this, digits arrive and letters are silently dropped, so "!setweather 15"
        # reaches the chat line as "15".
        Quartz.CGEventKeyboardSetUnicodeString(down, len(ch), ch)
        Quartz.CGEventKeyboardSetUnicodeString(up, len(ch), ch)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
        time.sleep(per_key)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
        if shift:
            Quartz.CGEventPost(Quartz.kCGHIDEventTap,
                               Quartz.CGEventCreateKeyboardEvent(None, SHIFT, False))
        time.sleep(per_key)


def send_command(cmd, settle=2.0):
    """Open the chat line, type a command, send it."""
    press(36, after=1.2)          # Return opens the chat input
    type_text(cmd)
    time.sleep(0.4)
    press(36, after=1.2)          # Return sends
    time.sleep(settle)


def shot(tag, n):
    w = game_window()
    os.makedirs(SHOTS, exist_ok=True)
    p = f"{SHOTS}/{tag}-{n:02d}.png"
    if w:
        sh("screencapture", "-x", "-o", "-l", str(w["kCGWindowNumber"]), p)
    else:
        sh("screencapture", "-x", "-o", "-D", "1", p)
    return p if os.path.exists(p) else None


def score(path):
    try:
        from PIL import Image
        import numpy as np
    except Exception:
        return {}
    im = Image.open(path).convert("RGB")
    im.thumbnail((640, 400))
    a = np.asarray(im).astype(np.int16)
    return dict(lit=round(float((a.max(axis=2) > 24).mean()), 4),
                colors=int(len(np.unique((a // 32).reshape(-1, 3), axis=0))))


def read_fps_csv(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="replace"):
        p = line.strip().split(",")
        if len(p) < 9 or p[0] == "epoch":
            continue
        try:
            row = dict(epoch=int(p[0]), elapsed=float(p[1]), fps=float(p[2]),
                       draws=float(p[3]), passes=float(p[4]), barriers=float(p[5]),
                       submits=float(p[6]), cschunks=float(p[7]), gpuidle=float(p[8]))
            # syncs / sync_ms are newer columns; older CSVs stop at gpuidle_us.
            row["syncs"] = float(p[9]) if len(p) > 9 else 0.0
            row["sync_ms"] = float(p[10]) if len(p) > 10 else 0.0
            row["imgsyncs"] = float(p[11]) if len(p) > 11 else 0.0
            row["imgsync_ms"] = float(p[12]) if len(p) > 12 else 0.0
            rows.append(row)
        except ValueError:
            continue
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--profile", default=None)
    ap.add_argument("--addons", default=None, choices=["full", "min", "none"])
    ap.add_argument("--env", action="append", default=[], help="KEY=VALUE, repeatable")
    ap.add_argument("--boot-wait", type=int, default=38, help="seconds before the first keypress")
    ap.add_argument("--sample", type=int, default=45, help="seconds of steady-state sampling")
    ap.add_argument("--video", action="store_true", help="also measure with the video counter")
    ap.add_argument("--heavy-draws", type=int, default=1200,
                    help="draw count that means the heavy scene has been reached")
    ap.add_argument("--enters", type=int, default=2,
                    help="Return presses after boot: 0 stops at the rules screen (light scene), 2 reaches character select (heavy)")
    ap.add_argument("--no-ashita", action="store_true",
                    help="launch the bootloader directly, with no Ashita hook")
    ap.add_argument("--boot", default="horizonxi.ini",
                    help="boot profile under config/boot (lsb.ini for the local server)")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    profile = json.load(open(args.profile)) if args.profile else {}
    if args.addons:
        profile["addons"] = args.addons
    profile.setdefault("addons", "full")
    for kv in args.env:
        k, _, v = kv.partition("=")
        profile.setdefault("env", {})[k] = v

    for d in (RESULTS, SHOTS, f"{GAME}/logs"):
        os.makedirs(d, exist_ok=True)
    kill_all()

    write_default_txt(profile["addons"], profile.get("script_extra", []))
    apply_registry(profile.get("registry", {}), args.boot)
    dxvk_conf = profile.get("dxvk_conf")
    if dxvk_conf is None:
        shutil.copyfile(f"{BASE}/dxvk.conf.orig", f"{GAME}/dxvk.conf")
    else:
        open(f"{GAME}/dxvk.conf", "w").write(dxvk_conf)
    apply_dlls(profile)
    if "renderer" in profile:
        subprocess.run([f"{WORK}/renderer.sh", profile["renderer"]], check=True)
    for k, v in profile.get("wine_reg", {}).items():
        key, name = k.rsplit("\\", 1)
        wine_reg(key, name, v)

    if os.path.exists(FPSCSV):
        os.remove(FPSCSV)

    env = dict(os.environ)
    env.update(BASE_ENV)
    env.update(profile.get("env", {}))
    for k, v in list(env.items()):
        if v in (None, ""):
            env.pop(k, None)

    if args.no_ashita:
        # Launch the bootloader directly, with no Ashita injection at all.
        # Credentials come from the user's own Ashita ini and are never written anywhere else.
        argv = loader_argv(args.boot)
    else:
        argv = [WINE, r"C:\HorizonXI\Ashita-cli.exe", args.boot]

    log = open(f"{RESULTS}/{args.tag}.wine.log", "wb")
    t0 = time.time()
    subprocess.Popen(argv, cwd=GAME, env=env, stdout=log, stderr=subprocess.STDOUT,
                     stdin=subprocess.DEVNULL, start_new_session=True)

    # --- walk to character select ------------------------------------------------------
    deadline = time.time() + args.boot_wait
    while time.time() < deadline:
        time.sleep(2)
    shots = []
    p = shot(args.tag, 0)
    if p:
        shots.append(dict(path=os.path.basename(p), t=round(time.time() - t0), stage="boot", **score(p)))

    focused = focus_game() or focus_game(hide_others=True) if args.enters else None
    print(f"  focus={focused}", flush=True)
    # Keep pressing Return until the scene actually gets heavy. The rules-of-conduct dialog
    # and the title screen each need one press, and focus does not always take on the first
    # try, so this is driven by the measured draw count rather than a fixed number of presses.
    if args.enters:
        for i in range(6):
            press(36, after=1.0)             # 36 = Return
            time.sleep(11)
            p = shot(args.tag, i + 1)
            if p:
                shots.append(dict(path=os.path.basename(p), t=round(time.time() - t0),
                                  stage=f"enter{i+1}", **score(p)))
            recent = read_fps_csv(FPSCSV)[-3:]
            if recent and min(r["draws"] for r in recent) > args.heavy_draws:
                break
            focus_game() or focus_game(hide_others=True)

    # --- sample -------------------------------------------------------------------------
    mark = len(read_fps_csv(FPSCSV))
    video = None
    if args.video:
        vp = subprocess.Popen([sys.executable, f"{WORK}/fpsvideo.py", str(min(args.sample, 20))],
                              stdout=subprocess.PIPE, text=True)
    time.sleep(args.sample)
    if args.video:
        try:
            video = json.loads(vp.communicate(timeout=60)[0])
        except Exception:
            video = dict(error="video measure failed")
    p = shot(args.tag, 9)
    if p:
        shots.append(dict(path=os.path.basename(p), t=round(time.time() - t0), stage="sample", **score(p)))

    rows = read_fps_csv(FPSCSV)[mark:]
    fps = [r["fps"] for r in rows]
    res = dict(
        tag=args.tag, profile=args.profile, addons=profile["addons"],
        env=profile.get("env", {}), registry=profile.get("registry", {}),
        renderer=profile.get("renderer"), dlls=profile.get("dlls"),
        samples=len(fps),
        fps_median=round(statistics.median(fps), 2) if fps else None,
        fps_mean=round(statistics.mean(fps), 2) if fps else None,
        fps_min=round(min(fps), 2) if fps else None,
        fps_max=round(max(fps), 2) if fps else None,
        draws=round(statistics.median([r["draws"] for r in rows]), 1) if rows else None,
        passes=round(statistics.median([r["passes"] for r in rows]), 1) if rows else None,
        barriers=round(statistics.median([r["barriers"] for r in rows]), 1) if rows else None,
        submits=round(statistics.median([r["submits"] for r in rows]), 2) if rows else None,
        cschunks=round(statistics.median([r["cschunks"] for r in rows]), 1) if rows else None,
        gpuidle_us=round(statistics.median([r["gpuidle"] for r in rows]), 0) if rows else None,
        video=video, shots=shots,
    )
    json.dump(res, open(f"{RESULTS}/{args.tag}.json", "w"), indent=1)
    if os.path.exists(FPSCSV):
        shutil.copyfile(FPSCSV, f"{RESULTS}/{args.tag}.fps.csv")
    if not args.keep:
        kill_all()

    print("RESULT " + json.dumps({k: res[k] for k in
          ("tag", "fps_median", "fps_min", "fps_max", "draws", "passes", "barriers",
           "submits", "samples", "video")}))


if __name__ == "__main__":
    main()
