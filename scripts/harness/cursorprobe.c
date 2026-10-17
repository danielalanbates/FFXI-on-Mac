/* cursorprobe.exe -- does a d3d9.dll leave the game's own Win32 cursor alone?
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * Licensed under the PolyForm Noncommercial License 1.0.0 with the commercial-use rider in this
 * repository's LICENSE. Commercial licences: help@batesai.org.
 *
 * FFXI's Hardware Mouse (registry 0021 = 1) is a plain animated Win32 cursor: FFXiMain.dll loads
 * mousenor.ani with LoadCursorFromFileA and sets it with user32 SetCursor. It never sets a D3D
 * cursor. The vendored DXVK 1.10.3 answers IDirect3DDevice9::ShowCursor with
 * SetCursor(bShow ? m_hCursor : NULL), and m_hCursor is NULL when no D3D cursor was set, so every
 * ShowCursor erases the game's cursor (d3d8to9 forwards the game's d3d8 ShowCursor unchanged).
 * Upstream fixed it in v2.3 (b0b46fd075, PR #3562); patches/dxvk-1.10.3-horizonxi*.patch carry
 * that backport. See docs/CURSOR-DXVK.md.
 *
 * This program does what the game does, minus the game: set an .ani cursor, create a D3D9
 * device on a small window through the d3d9.dll beside this .exe, call ShowCursor(FALSE) then
 * ShowCursor(TRUE), and check that GetCursor() still returns the .ani after each. Native D3D9
 * and wine's own d3d9 leave the handle unchanged (wine dlls/d3d9/tests/device.c test_cursor,
 * "unchanged", checked against Windows).
 *
 *   stock vendor DLL (e5f1a6b9..., 2026-08-20)   FAIL, GetCursor() reads 0 after ShowCursor
 *   DLL rebuilt with the backport                 PASS
 *   wine's builtin d3d9 (WINEDLLOVERRIDES unset) exit 2: not the DLL under test
 *
 * Build (i686, like the game; not built yet -- first build is part of the b70 release step):
 *
 *     i686-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -static -s -Wl,--no-insert-timestamp \
 *         -o cursorprobe.exe scripts/harness/cursorprobe.c -ld3d9
 *
 * Run, in a throwaway prefix only -- never in prefix10 or any game prefix, and never while a game
 * client runs (count clients the way scripts/tests/ashita-send-test.sh does; never print ps args,
 * a loader's command line carries the account password):
 *
 *     D=~/Downloads/FFXI-on-Mac-build/fixture/cursorprobe; mkdir -p "$D/stock" "$D/fixed"
 *     # each folder: cursorprobe.exe, the d3d9.dll under test, and a COPY of mousenor.ani from
 *     # the FFXI folder (nothing in the game folder is run or changed)
 *     export WINEPREFIX="$D/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="d3d9=n;mscoree,mshtml="
 *     W=<wine-coop>/wine/bin/wine         # the game wine: its lib/external has MoltenVK 1.4.2
 *     (cd "$D/stock" && "$W" cursorprobe.exe mousenor.ani); echo "exit $?"
 *     (cd "$D/fixed" && "$W" cursorprobe.exe mousenor.ani); echo "exit $?"
 *     WINEPREFIX="$D/prefix" "${W:h}/wineserver" -k   # that throwaway prefix's server only
 *
 * The window needs the Mac driver (DXVK makes a Vulkan surface on it), so this cannot run with
 * winemac.drv disabled. It opens a 160x120 window for about a second without activating it.
 *
 * Exit status:
 *   0  PASS: the .ani handle survived ShowCursor(FALSE) and ShowCursor(TRUE)
 *   1  FAIL: GetCursor() changed after either call (the 1.10.3 bug)
 *   2  could not test: bad arguments, the .ani did not load, no D3D9 device, or the d3d9.dll that
 *      loaded is not the one beside this .exe (set WINEDLLOVERRIDES=d3d9=n)
 *
 * It touches nothing outside its own window and thread: no other process, no game memory, no
 * input. GetCursor() reads the cursor of this thread's input queue, which is the one the DLL's
 * SetCursor changes, since D3D9 ShowCursor runs on the caller's thread.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <string.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    /* A pointer resting on the window must not change the cursor behind the test's back:
     * DefWindowProc would set the class cursor (none here) or an arrow on the frame. */
    if (msg == WM_SETCURSOR)
        return TRUE;
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void pump(DWORD ms) {
    DWORD end = GetTickCount() + ms;
    MSG m;
    do {
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&m);
            DispatchMessageA(&m);
        }
        Sleep(10);
    } while ((LONG)(end - GetTickCount()) > 0);
}

/* Directory part of a path, in place: "C:\a\b.dll" -> "C:\a". */
static void dirname_in_place(char *path) {
    char *slash = strrchr(path, '\\');
    if (slash != NULL)
        *slash = '\0';
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: cursorprobe.exe <file.ani>\n");
        return 2;
    }

    HCURSOR ani = LoadCursorFromFileA(argv[1]);
    if (ani == NULL) {
        fprintf(stderr, "cursorprobe: LoadCursorFromFileA(%s) failed, error %lu\n",
                argv[1], (unsigned long)GetLastError());
        return 2;
    }

    WNDCLASSA wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "cursorprobe";
    wc.hCursor = NULL;
    if (!RegisterClassA(&wc)) {
        fprintf(stderr, "cursorprobe: RegisterClassA failed, error %lu\n", (unsigned long)GetLastError());
        return 2;
    }
    HWND hwnd = CreateWindowExA(0, "cursorprobe", "cursorprobe", WS_POPUP, 0, 0, 160, 120,
                                NULL, NULL, wc.hInstance, NULL);
    if (hwnd == NULL) {
        fprintf(stderr, "cursorprobe: CreateWindowExA failed, error %lu\n", (unsigned long)GetLastError());
        return 2;
    }
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    pump(200);

    SetCursor(ani);
    if (GetCursor() != ani) {
        fprintf(stderr, "cursorprobe: SetCursor did not take (GetCursor %p, want %p)\n",
                (void *)GetCursor(), (void *)ani);
        return 2;
    }

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (d3d == NULL) {
        fprintf(stderr, "cursorprobe: Direct3DCreate9 failed\n");
        return 2;
    }

    /* Prove which d3d9.dll answered: wine prefers its builtin unless told otherwise, and a run
     * against the builtin would PASS for the wrong reason. */
    char exe[MAX_PATH], dll[MAX_PATH];
    HMODULE mod = GetModuleHandleA("d3d9.dll");
    if (mod == NULL || !GetModuleFileNameA(NULL, exe, sizeof(exe)) || !GetModuleFileNameA(mod, dll, sizeof(dll))) {
        fprintf(stderr, "cursorprobe: cannot read module paths\n");
        return 2;
    }
    printf("d3d9.dll: %s\n", dll);
    dirname_in_place(exe);
    dirname_in_place(dll);
    if (lstrcmpiA(exe, dll) != 0) {
        fprintf(stderr, "cursorprobe: that is not the d3d9.dll beside cursorprobe.exe (%s); "
                        "set WINEDLLOVERRIDES=d3d9=n\n", exe);
        IDirect3D9_Release(d3d);
        return 2;
    }

    D3DPRESENT_PARAMETERS pp;
    memset(&pp, 0, sizeof(pp));
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.BackBufferWidth = 160;
    pp.BackBufferHeight = 120;
    pp.hDeviceWindow = hwnd;
    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                         D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr) || dev == NULL) {
        fprintf(stderr, "cursorprobe: CreateDevice failed, hr 0x%08lx (no Vulkan/MoltenVK?)\n",
                (unsigned long)hr);
        IDirect3D9_Release(d3d);
        return 2;
    }
    pump(200);

    /* The device may have been created with the pointer over the window; put the .ani back so
     * both checks start from the game's state. */
    SetCursor(ani);

    BOOL was = IDirect3DDevice9_ShowCursor(dev, FALSE);
    HCURSOR afterHide = GetCursor();
    printf("ShowCursor(FALSE) returned %d; GetCursor %p (ani %p)\n", was, (void *)afterHide, (void *)ani);

    was = IDirect3DDevice9_ShowCursor(dev, TRUE);
    HCURSOR afterShow = GetCursor();
    printf("ShowCursor(TRUE)  returned %d; GetCursor %p (ani %p)\n", was, (void *)afterShow, (void *)ani);

    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    DestroyWindow(hwnd);
    DestroyCursor(ani);

    if (afterHide == ani && afterShow == ani) {
        printf("PASS\n");
        return 0;
    }
    printf("FAIL: the d3d9.dll replaced the game's cursor\n");
    return 1;
}
