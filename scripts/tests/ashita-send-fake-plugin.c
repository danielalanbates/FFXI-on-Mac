/* ashita-send-fake-plugin.exe <mode> <out-file> <seconds> -- a stand-in for Ashita's Thirdparty
 * plugin, so tools/ashita-send.c can be tested under wine with no game at all.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * Licensed under the PolyForm Noncommercial License 1.0.0 with the commercial-use rider in this
 * repository's LICENSE. Commercial licences: help@batesai.org.
 *
 * It creates "WindowerMMFKeyboardHandler_<its own pid>" exactly as the plugin's keyboard handler
 * does (CreateFileMappingA, 0x10488 bytes) and then, by mode:
 *   normal  handled_ = 1, and every 16 ms (about a frame) does what the plugin's update() does:
 *           nothing while handled_ != 0, else runs commands_[0 .. num_commands_-1] and sets
 *           num_commands_ = 0, handled_ = 1. A type-3 entry is split on ';' (empty parts
 *           skipped), each part stripped of leading '/' then ' ' and given one '/'. Instead of
 *           ParseCommand, each resulting command is appended to <out-file> as "cmd <text>", and
 *           each entry's raw text as "raw <text>";
 *   busy    handled_ stays 0 (a batch the game never takes): a sender must give up as busy;
 *   stall   handled_ = 1 but never polls (a game that stopped reading its keyboard): a sender's
 *           batch stays pending;
 *   late    starts with an earlier batch waiting ("/echo earlier", handled_ = 0) and only begins
 *           polling, as normal, after 6 s: a game in the background that takes an earlier
 *           pending change when it is brought back. A sender is busy until then.
 * The first line of <out-file> is "ready <pid>" once the block exists. Exits after <seconds>.
 * Further arguments are ignored: the test passes "--server fake.invalid" so the launcher's process
 * scan files this fake under a host of its own, like a game client.
 * Kept to KERNEL32 and the C runtime, like the helper.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma pack(push, 4)
typedef struct { UINT32 command_; char param1_[8], param2_[8], param3_[8], param4_[8]; char text_[2048]; } tp_command_t;
typedef struct { UINT32 num_commands_; volatile BYTE handled_; BYTE pad_[3]; tp_command_t commands_[32]; } tp_map_t;
#pragma pack(pop)
_Static_assert(sizeof(tp_map_t) == 0x10488, "map_t is 0x10488 bytes");

static FILE *out;

static void say(const char *tag, const char *text)
{
    fprintf(out, "%s %s\n", tag, text);
    fflush(out);
}

static void run_text(const char *text)
{
    char buf[2049];
    char *part, *next;
    say("raw", text);
    strncpy(buf, text, sizeof buf - 1);
    buf[sizeof buf - 1] = 0;
    for (part = buf; part; part = next) {
        char *cmd, line[2052];
        next = strchr(part, ';');
        if (next) *next++ = 0;
        if (!*part) continue;
        cmd = part;
        while (*cmd == '/') cmd++;
        while (*cmd == ' ') cmd++;
        _snprintf(line, sizeof line, "/%s", cmd);
        line[sizeof line - 1] = 0;
        say("cmd", line);
    }
}

int main(int argc, char **argv)
{
    char name[64], ready[32];
    HANDLE h;
    tp_map_t *m;
    DWORD start, seconds;
    const char *mode;

    if (argc < 4) { fprintf(stderr, "usage: fake-plugin normal|busy|stall <out-file> <seconds>\n"); return 2; }
    mode = argv[1];
    seconds = strtoul(argv[3], NULL, 10);
    out = fopen(argv[2], "ab");   /* binary: "\n", not "\r\n" */
    if (!out) { fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }

    _snprintf(name, sizeof name, "WindowerMMFKeyboardHandler_%lu", (unsigned long)GetCurrentProcessId());
    name[sizeof name - 1] = 0;
    h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(tp_map_t), name);
    if (!h) { fprintf(stderr, "CreateFileMappingA failed %lu\n", GetLastError()); return 1; }
    m = (tp_map_t *)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!m) { fprintf(stderr, "MapViewOfFile failed %lu\n", GetLastError()); return 1; }
    m->num_commands_ = 0;
    m->handled_ = strcmp(mode, "busy") ? 1 : 0;
    if (!strcmp(mode, "late")) {
        memset(&m->commands_[0], 0, sizeof m->commands_[0]);
        m->commands_[0].command_ = 3;
        strcpy(m->commands_[0].text_, "/echo earlier");
        m->num_commands_ = 1;
        MemoryBarrier();
        m->handled_ = 0;
    }

    _snprintf(ready, sizeof ready, "%lu", (unsigned long)GetCurrentProcessId());
    ready[sizeof ready - 1] = 0;
    say("ready", ready);

    start = GetTickCount();
    while (GetTickCount() - start < seconds * 1000) {
        Sleep(16);
        if (!strcmp(mode, "late")) { if (GetTickCount() - start < 6000) continue; }
        else if (strcmp(mode, "normal")) continue;
        if (m->handled_) continue;
        MemoryBarrier();
        {
            UINT32 x, n = m->num_commands_;
            if (n > 32) { say("bad", "num_commands_ above 32"); n = 32; }
            for (x = 0; x < n; x++) {
                if (m->commands_[x].command_ == 3) {
                    m->commands_[x].text_[2047] = 0;
                    run_text(m->commands_[x].text_);
                } else {
                    char t[16];
                    _snprintf(t, sizeof t, "%lu", (unsigned long)m->commands_[x].command_);
                    t[sizeof t - 1] = 0;
                    say("type", t);
                }
            }
        }
        m->num_commands_ = 0;
        MemoryBarrier();
        m->handled_ = 1;
    }
    say("exit", mode);
    UnmapViewOfFile(m);
    CloseHandle(h);
    fclose(out);
    return 0;
}
