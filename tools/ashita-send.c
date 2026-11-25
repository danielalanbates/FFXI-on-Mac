/* ashita-send.exe -- hand Ashita commands to a running FFXI client, through the Thirdparty plugin.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * Licensed under the PolyForm Noncommercial License 1.0.0 with the commercial-use rider in this
 * repository's LICENSE. Commercial licences: help@batesai.org.
 *
 *     wine ashita-send.exe [--pid N] [--busy-ms N] [--wait-ms N] "/addon load clock" ...
 *     printf '/addon unload clock\n/load minimap\n' | wine ashita-send.exe
 *     wine ashita-send.exe --list
 *
 * Run it with the game's own wine, in the game's prefix, with the running wineserver's
 * WINEMSYNC/WINEESYNC: the plugin's shared memory lives in that wineserver and nowhere else.
 * The launcher does exactly that (LiveAddons.swift); scripts/tests/ashita-send-test.sh runs it
 * against a fake plugin in a throwaway prefix.
 *
 * Exit status:
 *   0  delivered: the plugin ran every command (its handled_ flag came back)
 *   1  bad input: no command, a command that is too long, has a ';' or a control character,
 *      or is one this helper never sends (below); nothing was written. Every such exit prints a
 *      line starting "ashita-send: " to stderr, so a caller can tell it from wine's own exit 1
 *      (a WINEMSYNC/WINEESYNC that disagrees with the running wineserver ends wine that way
 *      before this program runs)
 *   2  no client: no process in this wineserver has the plugin's keyboard block
 *   3  ambiguous: more than one client has it and no --pid was given; nothing was written
 *   4  busy: the block did not come free within --busy-ms (3000); nothing was written
 *   5  pending: written, but not taken within --wait-ms (5000). The plugin runs it whenever the
 *      game next reads its keyboard; it is not lost.
 *
 * The protocol is Ashita's own Thirdparty plugin, read from AshitaXI/thirdparty-src
 * (src/handlers/keyboard.cpp, 9d6d7749) and checked against the Thirdparty.dll (v4.10) that
 * HorizonXI's client ships and loads from its own default script:
 *   - the plugin creates "WindowerMMFKeyboardHandler_<its Windows pid>", 0x10488 bytes, and sets
 *     handled_ = 1;
 *   - on every keyboard read of the game (about once a frame) it does nothing while handled_ != 0;
 *     otherwise it runs commands_[0 .. num_commands_-1], then sets num_commands_ = 0 and
 *     handled_ = 1;
 *   - a type-3 entry is command text: split on ';', each part stripped of leading '/' then ' ',
 *     given one '/', and passed to ChatManager::ParseCommand -- the same path as typed input.
 * The sender's side: wait for handled_ == 1, fill the entries, set num_commands_, barrier, set
 * handled_ = 0, wait for handled_ == 1. The plugin has no lock, so senders take one of their own
 * (the named mutex "ashita-send-<pid>", held from the busy wait to the publish): the launcher's
 * Apply and a --send-ashita from Terminal can never fill the block together.
 *
 * Only type 3 is ever written. The key types (1, 2, 1000) would be input automation; they are
 * not implemented here at all.
 *
 * Never sent, whatever the caller asks:
 *   /unload thirdparty, /reload thirdparty, /unloadall -- the plugin would free itself from
 *       inside the very callback that is running the command (/unloadall is Ashita's own
 *       "unload every plugin", read from the client's Ashita.dll);
 *   /unload addons, /reload addons, /addon unloadall -- that ends every Lua addon at once;
 *   /unload or /reload with no name;
 *   /exec, /execstr, /alias, /bind and /addon exec -- they run commands or Lua this helper
 *       cannot see, so they would get round every rule above.
 *
 * Imports KERNEL32 and the C runtime only: no user32, so wine needs no desktop or explorer for it,
 * and it never touches a window, the keyboard or the game's memory. Finding the client is
 * OpenFileMappingA by name for each process wine lists; nothing of any process is read.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma pack(push, 4)
typedef struct {
    UINT32 command_;           /* 3 = command text */
    char   param1_[8];
    char   param2_[8];
    char   param3_[8];
    char   param4_[8];
    char   text_[2048];        /* NUL-terminated */
} tp_command_t;

typedef struct {
    UINT32 num_commands_;      /* the plugin does not bound it: never above 32 */
    volatile BYTE handled_;    /* 1 = taken / free, 0 = a batch is waiting */
    BYTE   pad_[3];
    tp_command_t commands_[32];
} tp_map_t;
#pragma pack(pop)

_Static_assert(sizeof(tp_command_t) == 0x824, "command_t is 0x824 bytes in Thirdparty.dll");
_Static_assert(offsetof(tp_command_t, text_) == 0x24, "text_ at +0x24");
_Static_assert(offsetof(tp_map_t, commands_) == 8, "commands_ at +8");
_Static_assert(sizeof(tp_map_t) == 0x10488, "map_t is 0x10488 bytes in Thirdparty.dll");

enum { OK_DELIVERED = 0, BAD_INPUT = 1, NO_CLIENT = 2, AMBIGUOUS = 3, BUSY = 4, PENDING = 5 };

#define TEXT_MAX    2047       /* text_ less its NUL */
#define MAX_ENTRIES 32
#define MAX_CMDS    512
#define MAX_CLIENTS 16

static void open_name(DWORD pid, char *name, size_t size)
{
    _snprintf(name, size, "WindowerMMFKeyboardHandler_%lu", (unsigned long)pid);
    name[size - 1] = 0;
}

static HANDLE open_map(DWORD pid)
{
    char name[64];
    open_name(pid, name, sizeof name);
    return OpenFileMappingA(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, name);
}

/* Every process in this wineserver whose keyboard block exists, whatever its name. */
static int find_clients(DWORD *out, int max)
{
    int n = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32 pe;
    BOOL ok;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    memset(&pe, 0, sizeof pe);
    pe.dwSize = sizeof pe;
    for (ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe)) {
        HANDLE h;
        if (pe.th32ProcessID == GetCurrentProcessId()) continue;
        h = open_map(pe.th32ProcessID);
        if (h) {
            if (n < max) out[n] = pe.th32ProcessID;
            n++;
            CloseHandle(h);
        }
    }
    CloseHandle(snap);
    return n;
}

static int wait_handled(tp_map_t *m, DWORD ms)
{
    DWORD start = GetTickCount();
    for (;;) {
        if (m->handled_) { MemoryBarrier(); return 1; }
        if (GetTickCount() - start >= ms) return 0;
        Sleep(5);
    }
}

static int lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

/* The n-th word (0-based) after the plugin's own stripping, lowercased, into out. */
static void word(const char *cmd, int n, char *out, size_t size)
{
    const char *p = cmd;
    size_t k = 0;
    while (*p == '/' || *p == ' ' || *p == '\t') p++;
    for (;;) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        if (n == 0) {
            while (*p && *p != ' ' && *p != '\t' && k + 1 < size) out[k++] = (char)lower((unsigned char)*p++);
            break;
        }
        while (*p && *p != ' ' && *p != '\t') p++;
        n--;
    }
    out[k] = 0;
}

/* A plugin name as Ashita would match it: no ".dll", no quotes. */
static void plugin_key(char *s)
{
    size_t n;
    char *r = s, *w = s;
    for (; *r; r++) if (*r != '"' && *r != '\'') *w++ = *r;
    *w = 0;
    n = strlen(s);
    if (n > 4 && !strcmp(s + n - 4, ".dll")) s[n - 4] = 0;
}

/* NULL when cmd may be sent, else why not. */
static const char *refusal(const char *cmd)
{
    char verb[32], target[64];
    const unsigned char *p;
    size_t len = strlen(cmd);

    if (len == 0) return "empty command";
    if (len > TEXT_MAX) return "longer than 2047 bytes";
    for (p = (const unsigned char *)cmd; *p; p++) {
        if (*p < 0x20 || *p == 0x7f) return "control character";
        if (*p == ';') return "';' would split it into two commands";
    }
    word(cmd, 0, verb, sizeof verb);
    if (!verb[0]) return "empty command";
    word(cmd, 1, target, sizeof target);
    plugin_key(target);
    if (!strcmp(verb, "unload") || !strcmp(verb, "reload")) {
        if (!target[0]) return "needs a plugin name";
        if (!strcmp(target, "thirdparty")) return "the plugin would free itself mid-command";
        if (!strcmp(target, "addons")) return "that ends every Lua addon";
    }
    if (!strcmp(verb, "unloadall")) return "unloads every plugin, this one among them, mid-command";
    if (!strcmp(verb, "addon") || !strcmp(verb, "addons")) {
        if (!strcmp(target, "unloadall")) return "that ends every Lua addon";
        if (!strcmp(target, "exec")) return "runs Lua this helper cannot check";
    }
    if (!strcmp(verb, "exec") || !strcmp(verb, "execstr") || !strcmp(verb, "alias") || !strcmp(verb, "bind"))
        return "runs commands this helper cannot check";
    return NULL;
}

static char *dup_trimmed(const char *s)
{
    size_t n = strlen(s);
    char *out;
    while (n && (s[n - 1] == '\r' || s[n - 1] == '\n')) n--;
    out = (char *)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, s, n);
    out[n] = 0;
    return out;
}

static int usage(void)
{
    fprintf(stderr, "ashita-send: usage: ashita-send [--pid N] [--busy-ms N] [--wait-ms N] [--list] [\"/command\" ...]\n"
                    "       with no command arguments, one command per line on stdin\n");
    return BAD_INPUT;
}

/* The block is free for this sender: held from the busy wait to the publish. NULL when wine could
 * not make the mutex; the send then goes ahead as it did before there was one. */
static HANDLE take_lock(DWORD pid, DWORD ms, int *busy)
{
    char name[64];
    HANDLE lock;
    DWORD w;
    *busy = 0;
    _snprintf(name, sizeof name, "ashita-send-%lu", (unsigned long)pid);
    name[sizeof name - 1] = 0;
    lock = CreateMutexA(NULL, FALSE, name);
    if (!lock) return NULL;
    w = WaitForSingleObject(lock, ms);
    if (w == WAIT_OBJECT_0 || w == WAIT_ABANDONED) return lock;
    CloseHandle(lock);
    *busy = 1;
    return NULL;
}

static void drop_lock(HANDLE lock)
{
    if (!lock) return;
    ReleaseMutex(lock);
    CloseHandle(lock);
}

int main(int argc, char **argv)
{
    DWORD pid = 0, busy_ms = 3000, wait_ms = 5000;
    DWORD clients[MAX_CLIENTS];
    char *cmds[MAX_CMDS];
    int ncmds = 0, list = 0, from_stdin = 1, i, k;
    int entry_of[MAX_CMDS];
    int nentries = 0;
    size_t used = 0;
    HANDLE h, lock;
    tp_map_t *m;
    MEMORY_BASIC_INFORMATION mbi;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--pid") && i + 1 < argc) pid = strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--busy-ms") && i + 1 < argc) busy_ms = strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--wait-ms") && i + 1 < argc) wait_ms = strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--list")) list = 1;
        else if (!strcmp(a, "--")) { i++; break; }
        else if (a[0] == '-' && a[1] == '-') return usage();
        else break;
    }
    if (busy_ms > 60000) busy_ms = 60000;
    if (wait_ms > 60000) wait_ms = 60000;

    for (; i < argc; i++) {
        from_stdin = 0;
        if (ncmds >= MAX_CMDS) { fprintf(stderr, "ashita-send: more than %d commands\n", MAX_CMDS); return BAD_INPUT; }
        if (!(cmds[ncmds++] = dup_trimmed(argv[i]))) return BAD_INPUT;
    }
    if (from_stdin && !list) {
        char line[4096];
        while (fgets(line, sizeof line, stdin)) {
            size_t n = strlen(line);
            if (n == sizeof line - 1 && line[n - 1] != '\n') {
                fprintf(stderr, "ashita-send: a line is longer than %d bytes\n", TEXT_MAX);
                return BAD_INPUT;
            }
            if (ncmds >= MAX_CMDS) { fprintf(stderr, "ashita-send: more than %d commands\n", MAX_CMDS); return BAD_INPUT; }
            if (!(cmds[ncmds] = dup_trimmed(line))) return BAD_INPUT;
            if (!cmds[ncmds][0]) { free(cmds[ncmds]); continue; }
            ncmds++;
        }
    }
    if (!list && ncmds == 0) return usage();

    /* Every command is checked before anything is written: all or nothing. */
    for (k = 0; k < ncmds; k++) {
        const char *why = refusal(cmds[k]);
        if (why) { fprintf(stderr, "ashita-send: refused \"%s\": %s\n", cmds[k], why); return BAD_INPUT; }
    }

    /* Pack: as many ';'-joined commands per entry as fit, at most 32 entries, one batch. */
    for (k = 0; k < ncmds; k++) {
        size_t n = strlen(cmds[k]);
        if (nentries == 0 || used + 1 + n > TEXT_MAX) {
            if (++nentries > MAX_ENTRIES) { fprintf(stderr, "ashita-send: too many commands for one batch\n"); return BAD_INPUT; }
            used = n;
        } else {
            used += 1 + n;
        }
        entry_of[k] = nentries - 1;
    }

    if (!pid) {
        int n = find_clients(clients, MAX_CLIENTS);
        if (list) {
            for (k = 0; k < n && k < MAX_CLIENTS; k++) printf("client %lu\n", (unsigned long)clients[k]);
            return n ? OK_DELIVERED : NO_CLIENT;
        }
        if (n == 0) { fprintf(stderr, "no client with the Thirdparty plugin in this wineserver\n"); return NO_CLIENT; }
        if (n > 1) {
            for (k = 0; k < n && k < MAX_CLIENTS; k++) printf("client %lu\n", (unsigned long)clients[k]);
            fprintf(stderr, "%d clients have the plugin; refusing to guess\n", n);
            return AMBIGUOUS;
        }
        pid = clients[0];
    } else if (list) {
        h = open_map(pid);
        if (!h) return NO_CLIENT;
        CloseHandle(h);
        printf("client %lu\n", (unsigned long)pid);
        return OK_DELIVERED;
    }

    h = open_map(pid);
    if (!h) { fprintf(stderr, "no keyboard block for pid %lu\n", (unsigned long)pid); return NO_CLIENT; }
    m = (tp_map_t *)MapViewOfFile(h, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
    if (!m) { CloseHandle(h); return NO_CLIENT; }
    if (!VirtualQuery(m, &mbi, sizeof mbi) || mbi.RegionSize < sizeof(tp_map_t)) {
        /* Not the layout this was written against: write nothing. */
        fprintf(stderr, "the keyboard block is smaller than expected\n");
        UnmapViewOfFile(m); CloseHandle(h);
        return NO_CLIENT;
    }

    {
        /* Another sender first (its lock), then the plugin (handled_), within busy_ms in all. */
        DWORD t0 = GetTickCount(), spent;
        int locked_out;
        lock = take_lock(pid, busy_ms, &locked_out);
        spent = GetTickCount() - t0;
        if (locked_out || !wait_handled(m, spent >= busy_ms ? 0 : busy_ms - spent)) {
            fprintf(stderr, "the plugin did not free its block within %lu ms\n", (unsigned long)busy_ms);
            drop_lock(lock); UnmapViewOfFile(m); CloseHandle(h);
            return BUSY;
        }
    }

    /* handled_ == 1: the plugin does not touch the block until it reads 0. Fill, count, publish. */
    for (k = 0; k < nentries; k++) {
        memset(&m->commands_[k], 0, sizeof m->commands_[k]);
        m->commands_[k].command_ = 3;
    }
    for (k = 0; k < ncmds; k++) {
        char *text = m->commands_[entry_of[k]].text_;
        size_t at = strlen(text), n = strlen(cmds[k]);
        if (at) text[at++] = ';';
        memcpy(text + at, cmds[k], n + 1);
    }
    m->num_commands_ = (UINT32)nentries;
    MemoryBarrier();
    m->handled_ = 0;
    MemoryBarrier();
    /* Published: the next sender now waits on handled_, not on this one. */
    drop_lock(lock);

    k = wait_handled(m, wait_ms);
    UnmapViewOfFile(m);
    CloseHandle(h);
    printf("%s %lu %d\n", k ? "delivered" : "pending", (unsigned long)pid, ncmds);
    fflush(stdout);
    return k ? OK_DELIVERED : PENDING;
}
