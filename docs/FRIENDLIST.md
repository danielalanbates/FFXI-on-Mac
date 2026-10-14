# Friend list without PlayOnline

The retail FFXI friend list is a PlayOnline Viewer feature. The client still ships the
commands — `/befriend`, `/friendlist`, `/flist`, `/blacklist`, `/blist`, `/search`,
`/sea` are all present as literal strings in `FFXiMain.dll` (around offsets 183088 and
184480) — but on a private server the PlayOnline half of that conversation does not
exist, so the feature is dead.

`addons/friendlist/friendlist.lua` reimplements it entirely client-side. **No server
changes and no private server are involved.** LandSandBoat is used here only as a local
*test bed*, never as part of the implementation.

## How it works

1. **Commands.** Ashita intercepts `/befriend` and `/friendlist` / `/flist` before they
   reach the server and blocks them. The names are identical to the originals, taken
   from the client binary, so people use the commands they already know.
2. **The handshake.** Friend requests ride on ordinary `/tell`, tagged
   (`<FLREQ>`, `<FLACK>`, `<FLNAK>`, `<FLDEL>`) with the marker stripped from the chat
   log before you see it. This preserves the mutual-consent flow of the original: you
   ask, they accept.
3. **Presence.** A tagged `<FLPING>` tell, answered by `<FLPONG>`.

The list is a plain text file per character under `addons/friendlist/data/`.

## Presence: why not /sea

`/sea` was the obvious idea and it is **wrong**. Search results travel on a separate
encrypted binary connection to the search server (`src/search/` in LandSandBoat —
blowfish + md5, `SearchPacket`) and are rendered into the client's own Search panel.
**They never appear as chat text**, so there is nothing for an addon to parse. An
earlier version of this addon scraped chat for `/sea` output; that could never have
worked.

What *does* produce chat text is a failed tell. The server answers a tell aimed at an
absent player with standard message **125** — "Your tell was not received. The recipient
is currently away." (`src/map/enums/msg_std.h:58`, sent from
`src/world/ipc_server.cpp:438`).

So presence is: ping a friend with a tagged tell and watch for that reply. The reply
means offline; no reply means the tell was delivered, which means online. A friend who
also runs the addon answers with `<FLPONG>`, which marks them online immediately.

**Caveat:** a friend *not* running this addon will see the raw tag text arrive as a
tell. Hence the deliberately slow poll (one query per 3s, full sweep every 60s).

## Commands

    /befriend <name>            Send a friend request.
    /friendlist                 Toggle the friend list window.
    /flist                      Same.
    /friendlist add <name>      Send a friend request.
    /friendlist delete <name>   Remove a friend.  (del / remove also accepted)
    /friendlist accept <name>   Accept a pending request.
    /friendlist decline <name>  Decline a pending request.
    /friendlist refresh         Poll presence now.
    /friendlist selftest        Run the built-in end-to-end test.
    /friendlist simulate <name> <REQ|ACK|NAK|DEL|PING|PONG>

## Verification status

**Verified live in the running client, 2026-08-17** — both against HorizonXI and against
the local LandSandBoat server. Screenshots: `friendlist-in-game.png`,
`friendlist-after-add-remove.png`.

- Addon loads clean and creates its per-character data file.
- `/friendlist selftest` — **11/11 PASS** inside the running game: inbound request
  creates a pending entry; accept promotes pending to friend; friend written to disk;
  friend survives reload from disk; delete removes the friend; removal persisted;
  remote delete drops the friend; decline clears the pending request; pong marks a
  friend online; an offline reply is attributed to the pinged friend; offline reply
  marks the friend offline.
- `/befriend Kiyoko` through the real command path produced
  "A friend request has been sent to Kiyoko."
- The Friend List window renders in game with friends, online markers, and a pending
  request with Accept / Decline buttons.
- `/friendlist accept` and `/friendlist delete` both changed the window and the on-disk
  file as expected.

**Verified live IN WORLD against the local LandSandBoat server** (character `Test`,
Southern San d'Oria) — screenshots `friendlist-in-world.png`,
`friendlist-live-presence.png`:

- A tagged tell round-trips through a real server: `>>Test : <FLPING>` went out and
  `Test>> <FLPING>` came back in. The handshake transport works for real, not just in
  the state machine.
- **Offline detection**: pinging an absent player produced the real server reply
  "Your tell was not received. The recipient is either offline or changing areas."
  and the friend was marked offline.
- **Online detection**: a delivered ping (no error reply) marked the friend online.
- The window showed "2 friends, 1 online" with correct per-friend markers.

Note the live wording is "either offline or changing areas", NOT the "currently away"
in the LandSandBoat source comment. The parser matches on `tell was not received`, which
covers both — but do not tighten it to the source-comment wording.

### Bug found by live testing

The first in-world run revealed that both directions of a tell carry the tag and the
original regex matched both:

    outgoing echo :  ">>Name : <FLREQ>"
    incoming tell :  "Name>><FLREQ>"

So sending a friend request made the addon read our own outgoing request as an incoming
one from the person we had just asked, creating a phantom pending entry. Fixed by
rejecting lines starting with `>>` and anchoring the incoming match to `Name>>`. This is
exactly the class of bug that only shows up in world.

### Verified with TWO real clients (the full test)

Two clients at 800x600 against local LandSandBoat, two separate accounts and characters
(`Test` on lsbtest, `Buddy` on lsbtest2), both in Southern San d'Oria and visible to each
other in game. Screenshots `friendlist-two-clients-test.png`,
`friendlist-two-clients-buddy.png`.

- `/befriend Buddy` on Test -> Buddy sees "Test would like to add you to their friend
  list. Use /friendlist accept Test or /friendlist decline Test." The tag never appears
  in either chat log.
- `/friendlist accept Test` on Buddy -> Buddy: "Test has been added to your friend
  list." Test: "Buddy has accepted your friend request." Both data files persisted
  (`test.txt` -> `friend Buddy`, `buddy.txt` -> `friend Test`).
- Presence ping/pong crossed both ways (`Test>> <FLPONG>` and `Buddy>> <FLPONG>`), and
  **both windows showed "1 friend, 1 online"** with the other player green.
- `/friendlist delete Buddy` on Test -> Test: "Buddy has been removed from your friend
  list." Buddy: "Test has removed you from their friend list." Both lists emptied.

That is the complete original feature — add, mutual consent, presence, remove — working
between two real players with no PlayOnline and no server-side support.

### Second bug found by two-client testing

Incoming tells arrive wrapped in colour/control bytes, so `"Name>><TAG>"` never matched
an anchored pattern — the request was delivered by the server but silently ignored by the
receiving addon. Fixed by stripping everything outside printable ASCII before matching.
Single-client testing could not have found this, because the self-tell path and the
outgoing echo both looked fine.

### Running two clients on 8 GB

Drop the resolution first: `[ffxi.registry]` `0001`/`0002` and `0037`/`0038` to 800x600
and `0003`/`0004` to 1024. Even then this machine sat at ~70-150 MB free with ~700 MB of
swap headroom, so close other apps first and watch `vm.swapusage`.

Each client needs its own command channel or they both eat the same file. `mousediag`
reads `cmd<FLCLIENT>.txt` and logs to `mousediag<FLCLIENT>.log`, so launching the second
client with `FLCLIENT=2` in the environment keeps them independent. Boot config for the
second account is `lsb2.ini`.

A second character was made by cloning the first in SQL. Note `chars` has a BEFORE INSERT
trigger that auto-creates the child rows (`char_equip`, `char_exp`, `char_jobs`, ...), so
insert into `chars` FIRST and only then copy `char_look` / `char_stats` / `char_skills` /
`char_jobs`. Pre-inserting the child rows makes the trigger collide with a confusing
"Duplicate entry for key PRIMARY" on a table that visibly has no such row.

## Why the NATIVE in-game menu cannot be populated (investigated 2026-08-17)

Daniel's goal was menu integration — making the game's own Friend List menu work, not an
overlay. Findings:

**The native menu renders fine on a private server.** Opening it shows "No friends
registered." rather than erroring, so the UI is intact and client-side. Only the data is
absent.

**There is no friend-list packet in the FFXI world protocol.** LandSandBoat implements the
protocol comprehensively and has `GP_CLI_COMMAND_BLACK_LIST` and
`GP_CLI_COMMAND_BLACK_EDIT` — the blacklist IS a world-protocol feature. There is no
friend equivalent. The one friend-named packet, `GP_CLI_COMMAND_FRIENDPASS` (0x01B), is
the *world pass* (inviting a friend to buy the game), unrelated to the friend list.

This is the crux: **no server can populate that menu through the game connection, because
the packet does not exist.** It is not that LandSandBoat failed to implement it. The
friend list is PlayOnline Viewer functionality delivered over PlayOnline's own channel.

**No client-side storage either.** `SquareEnix/FINAL FANTASY XI/USER/` holds macros and
per-character config; there is no friend-list file. The data is memory-only at runtime.

**Ashita offers no handle on it.** The SDK exposes IPlayer, IParty, IInventory, ITarget,
IRecast and friends — there is no menu interface and no friend structure, and no offsets
ship for one.

### What populating the native menu would actually require

Writing directly into the in-memory structure that `menu friend` reads. That is a static
reverse-engineering project against FFXiMain.dll, made harder than usual because **there
is no way to observe a populated state to diff against** — nothing can fill that menu
without PlayOnline, so the usual find-the-struct-by-comparison technique is unavailable.
It would mean disassembling the menu's draw/populate path.

Possible in principle. Not a code fix, and not a small job.

### What exists instead

The addon draws its own Friend List window. It is a genuinely working friend list — add,
mutual consent, presence, remove, all verified between two real clients — but it is an
overlay, not the native menu. Making it *look* like the native menu (FFXI frame art,
fonts, colours) is achievable and would satisfy "looks just like it"; making the built-in
menu itself light up is the reverse-engineering project above.

## 2026-08-17 — switched to Tanyrus/FFXIFriendList (server-backed)

Daniel chose to use **Tanyrus/FFXIFriendList** (GPL-3.0, Ashita v4 Lua, hosted backend
`api2.horizonfriendlist.com`) instead of our tell-based `friendlist` addon. Our addon is no
longer loaded from `scripts/default.txt` (backup `default.txt.bak-tanyrus`); the code stays
in `addons/friendlist/` for reference.

`addons/FFXIFriendList/` in this repo is upstream `main` (2026-06-12) plus three compat
patches, all needed on the Ashita 4.3 / imgui 1.9x that HorizonXI ships since 2026-08-02
(upstream issue #18 "Addon Crashing on Ashita 4.3" is open with no fix):

1. `FFXIFriendList.lua` — `imgui.BeginChild(id, size, bool)` → shim converts the boolean to
   the new `child_flags` int (was a sol "no matching function" Lua error).
2. `app/ui/FontManager.lua` — `M.get()` returns nil, so nothing pushes atlas fonts by index
   (`io.Fonts.Fonts[n]` is not valid under the new dynamic-font imgui).
3. `libs/icons.lua` — `M.GetIcon()` returns nil, so `imgui.Image/ImageButton` with the legacy
   signatures are never called; every icon falls back to text.
4. `FFXIFriendList.lua` — `jit.off()`. The remaining crash was
   `EXCEPTION_ACCESS_VIOLATION` at `Addons.dll+0xA0761A`, which disassembles to LuaJIT's
   `lj_mcode_patch` walking a NULL MCode-area chain (`mov (%esi),%esi … mov 0x4(%esi),%ecx`
   then `VirtualProtect`). It fired on the first draw after load, roughly 3 times out of 4,
   and never after `jit.off()`. Note: when the Addons plugin catches that AV it can unload
   *every* addon (and once the plugin itself), which also kills the `mousediag` command
   channel — recover with `/load addons` typed by keyboard.

Verified live 2026-08-17 with two clients (Test / Buddy) on the local LandSandBoat server,
addon loaded per client as `FFXIFriendList` and a patched copy `FFXIFriendList2` (its
config dir renamed so the two clients get separate accounts/API keys):
`/befriend Buddy` → "Friend request sent" → `/fl accept Test` on Buddy → both lists show
the other with the green online marker (`tanyrus-friendlist-test.png`,
`tanyrus-friendlist-buddy.png`) → `/fl block Test` on Buddy removed the friendship on
Test's list live (`tanyrus-friendlist-after-block.png`) → `/fl unblock`, re-request,
`/fl deny Test` all echoed correctly. Quirk seen: `/fl unblock Test` printed
"test was not blocked" although `/fl blocked` had listed Test.

Caveats: the realm list on his backend is Horizon/Eden only, so a private-server character
registers under the Horizon realm on his hosted DB. Friend removal is UI-only (right-click
context menu) — there is no `/fl remove`. `scripts/twoclient.py` launches/drives client 1
or 2 (`launch N`, `cmd N "<chat cmd>"`, `shot N file`); mousediag's cmd channel now also
evaluates lines prefixed `LUA `.

### Update, same day — proper fixes, fork + upstream PR

The blunt "disable fonts / disable icons" patches above were replaced by version-aware
fixes (probe `imgui.ImageWithBg ~= nil` → ImGui >= 1.91): BeginChild shim, new
`Image`/`ImageButton` signatures in `libs/icons.lua`, and `jit.off()`. Icons and toolbar
now render correctly on Ashita 4.3. Fonts were left untouched (PushFont is pcall'd upstream
and did not crash once the JIT was off).

- Fork (what to submit to HorizonXI for addon approval): https://github.com/danielalanbates/FFXIFriendList — branch `ashita-4.3-compat`
- Upstream PR: https://github.com/Tanyrus/FFXIFriendList/pull/19 (fixes their #18)
- `addons/FFXIFriendList/` in this repo now mirrors that branch exactly.
- Our old tell-based addon is archived at `archive/friendlist-tell-addon-2026-08-17/`
  (and `addons-archive/friendlist` in the live prefix). `FFXIFriendList2` in the live prefix
  is only the two-client test copy (older blunt patches) — delete or resync before relying on it.

## GM Tools (SQLCommit/GMTools) — 2026-08-18

Installed `addons/gmtools` (MIT, v1.0.4, built for Ashita 4.3) for the local LSB server: `/gm`
opens an ImGui browser of 184 `!` commands (Teleport/Character/Skills/Items/Status/Mobs/World/
Quests/Admin/Reload/Debug), item search by name, favorites, presets, per-job gear loadouts.
Rendered first try; but the same LuaJIT fault as FFXIFriendList (`Addons.dll+0xA0761A`,
`lj_mcode_patch`) fired on `/gm gear WAR` and unloaded it. One line fixes it — `jit.off()` after
`require 'common'` in `gmtools.lua` (patched copy in this repo). Verified after the patch:
`/gm gear WAR` gave 18 items (inventory 7→24), `!setplayerlevel 75` via chat took effect
(char_stats.mlvl=75). Requires `chars.gmlevel` (Test/Buddy = 99). LSB prints "Lost key item: ."
after each `!additem` — server-side quirk, harmless.

**Pattern worth remembering:** on this Ashita 4.3 + Wine/Rosetta stack, *any* Lua addon that gets
hot enough to JIT can hit that fault; `jit.off()` at the top of the entry file is the fix.

## Native friend list — dynamic reverse engineering, 2026-09-12

Context: HorizonXI declined friend-list addons because their team "is currently working
on getting the in-game friends list function to work." Neither upstream LandSandBoat nor
Horizon's public repos show that work, so this session measured what the native feature
actually needs. All testing on the local LSB world only.

### Proven by live packet capture

A packet logger (both directions, id + hexdump) was added to the harness addon and
`/friendlist`, `/flist`, `/befriend <name>` were issued in world with the FFXIFriendList
addon unloaded. Result: **zero packets leave the client.** Every command is refused
client-side with "You cannot use that command at this time." The gate is inside
FFXiMain.dll, before any network involvement. No server implementation alone —
LandSandBoat's or anyone's — can light this up.

### Client internals mapped (from a live in-memory dump)

FFXiMain.dll was dumped from the running process (base 0x01CA0000, size 0x00BDF000 —
the dump and `analyze.py` live in `~/Downloads/ffxi-friendlist-re/`, never committed):

- **Text-command table**: 277 entries × 0x18 bytes at VA `0x1ff3418`. Layout:
  `char name[16]; u32 pad; u16 command_id; u16 flags`.
  `/befriend` id=0x0d flags=0x5b · `/friendlist` & `/flist` id=0x3d flags=0x51 ·
  `/blacklist` id=0x3b flags=0x59 · `/search` id=0x3a flags=0x59.
- **Flags are not the gate.** Live-patching `/friendlist`/`/befriend` flags to 0x59
  (matching working `/blacklist`) changes nothing.
- **Dispatcher**: name lookup at `0x1d1fe53`, then `0x1d20020(command_id)` executes.
  `0x1d20110` translates command_id → *menu id* through a 0xe4-pair s16 table at
  `0x1fcabb0`: `/search`→0x0c, **`/friendlist`→0x0d**, `/blacklist`→0x0e,
  `/befriend`→0x83. Search (0x0c) and blacklist (0x0e) open; friend (0x0d) is refused —
  so the gate sits in the menu system's open-check for that one menu id.
- **The friend menus ship in the client**: resource names `menu friend`,
  `menu flistmai`, `menu flmes`, `menu olstat` are present in loaded memory.

### What "making it work" therefore requires

1. **Un-gate menu 0x0d** — find the availability check the menu open path performs for
   the friend menu (almost certainly a "POL friend service connected" flag that the
   private-server loaders never set) and force it true. Static follow-up in Ghidra on
   the dump: walk `0x1d20020`'s consumer to the menu-open routine, diff the 0x0c/0x0e
   paths against 0x0d.
2. **Feed the menu data** — once it opens, find the structure `flistmai` reads and
   populate it (Ashita addon/plugin writing memory, sourced from any backend: LSB DB
   via custom packets, or a hosted API as Tanyrus does).
3. **Handle add/remove/status** — hook the menu's action callbacks the same way.

This is precisely the work Horizon must be doing privately (they control loader +
client patches + server). Pathways for a future session, in order of value:

- **A (recommended):** Ghidra session on the dump, starting from the addresses above.
  The gate flag is one bool; finding it may be hours, not weeks. Test flips live via
  the harness `LUA` channel (see below).
- **B:** If the gate proves to be deep POL plumbing (polcore COM state), extend the
  loader's IPOLCoreCom emulation instead (see `LandSandBoat/xiloader` `src/polcore.h`).
- **C:** Fall back to the overlay addon (works today, archived in this repo) or
  Tanyrus's — blocked only by Horizon approval politics, not technology.

### New harness capabilities (this session)

The Mac-side harness addon gained, both guarded behind the pipe being armed:

- **Packet logger**: every world packet in/out → `/tmp/ffxi-pipe/packets.log`
  (`HH:MM:SS C2S/S2C 0xID len=N <first 96 bytes hex>`).
- **In-process Lua eval**: a `cmd.txt` line `LUA <expr>` runs inside the game's Lua
  state; result/error appended to `/tmp/ffxi-pipe/lua.out`. This is what made the
  memory reconnaissance and live patching possible — `ashita.memory.*` is fully
  reachable. Pattern quirk: `ashita.memory.find` wants **unspaced** hex ("46494E414C");
  spaced patterns silently return 0.

## CORRECTION and resolution — same day, 2026-09-12 (later)

The section above is **wrong about the gate**. "You cannot use that command at this time" was
caused by a modal *Start Seekers of Adoulin?* prompt that was open on screen; it blocks every menu
(`/blacklist` and `/search` were refused too). With the prompt dismissed, the native Friend List
opens normally and shows "No friends registered." The flags/menu-0x0d theory is retracted.

The native friend list has since been made to work, verified with two real characters on the
local LSB world: **https://github.com/danielalanbates/ffxi-native-friendlist**. The `nativefriends`
addon redirects FFXiMain's per-slot friend fetch (`0x1d87720` → PlayOnline `0x1d91350`) to entries
built from `friendsd` (a small service beside the LSB database), and redraws the open menu live.
Full internals in that repo's `docs/CLIENT_INTERNALS.md`.
