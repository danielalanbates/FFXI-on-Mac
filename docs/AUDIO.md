# Sound output: making a running game follow the Mac's setting

Status: **fixed and verified on the host side, not yet verified inside a live FFXI session.**
Written 2026-08-22.

## The bug

Change the Mac's sound output — headphones in, AirPods connect, a Bluetooth speaker appears —
while FFXI is running, and every other app moves over while the game keeps playing to the old
device. The only remedy was to quit the game and start it again.

## Why it happens

FFXI's audio goes: game → DirectSound/winmm → wine's `mmdevapi` → `winecoreaudio.drv` → a
CoreAudio **AUHAL** output unit.

`mmdevapi` has to enumerate devices and name them (that's its whole job as an API), so it creates
its output unit as `kAudioUnitSubType_HALOutput` and sets
`kAudioOutputUnitProperty_CurrentDevice` **once**, at the moment audio starts.

macOS's Sound Output control sets `kAudioHardwarePropertyDefaultOutputDevice`. That is a different
thing. An AUHAL unit that has already named a device does not care what the default becomes, and
nothing in wine is listening for the change.

Apple's own answer to this is `kAudioUnitSubType_DefaultOutput`, which follows the default device
by itself — but a unit of that subtype cannot be pointed at a named device, so mmdevapi cannot
use it.

Reproduced exactly, outside wine, with `scripts/tests/audiofollow-test.c` (pins an AUHAL unit the
way winecoreaudio does, then reports which device it is on once a second):

```
unit pinned to device 104; system default is 104
t= 1s  unit=104  system=104  FOLLOWING
t= 2s  unit=104  system=74   STUCK        <- Sound Output switched here
t= 7s  unit=104  system=74   STUCK
```

## The fix that shipped — `audio/audiofollow.c`

A ~200-line dylib inserted into the wine process with `DYLD_INSERT_LIBRARIES`. It:

1. interposes `AudioComponentInstanceNew` and remembers every `kAudioUnitType_Output` unit wine
   creates;
2. interposes `AudioOutputUnitStart` / `AudioOutputUnitStop` so it knows which are playing;
3. adds a property listener for `kAudioHardwarePropertyDefaultOutputDevice`;
4. on a change, for each tracked unit: stop → set `kAudioOutputUnitProperty_CurrentDevice` →
   start.

Verified A/B, same harness, both architectures:

```
audiofollow: listening for sound-output changes
audiofollow: tracking output unit 0
t= 1s  unit=104  system=104  FOLLOWING
audiofollow: system output changed to device 74
audiofollow: moved a unit to device 74
t= 3s  unit=74   system=74   FOLLOWING
```

**arm64: pass. x86_64 under Rosetta: pass.** x86_64 is the one that counts — wine on Apple
Silicon is an x86_64 process.

Wiring: `AudioFollow.swift` finds the dylib and refuses to name it unless the file exists *and*
carries an x86_64 slice (checked by reading the Mach-O header, not by shelling out to `lipo`,
which isn't on a Mac without developer tools). `PerfSettings.followSoundOutput` (on by default,
with a toggle in the app) adds it to `DYLD_INSERT_LIBRARIES`. If anything is missing the variable
is simply not set and the launch is byte-for-byte what it was before.

### Gotchas found on the way

- **`DYLD_INSERT_LIBRARIES` does not survive `arch(1)`.** dyld strips `DYLD_*` across an exec into
  a system binary, so `arch -x86_64 ./thing` silently loads nothing. The first x86_64 test run
  looked like a total failure for exactly this reason. Run the x86_64-only binary directly and let
  Rosetta take it. Anything that reworks the launch path has to keep exec'ing wine directly.
- A nested dylib in a notarised bundle needs `--options runtime --timestamp` of its own, the same
  as `x87sidecar-coop`. `bundle.sh` does this.
- The table is fixed-size and lock-protected, and nothing allocates on the listener thread — that
  callback runs on a CoreAudio thread while wine's audio thread is rendering.

## What is not proven yet

**Nobody has switched the output device during a live FFXI session and heard it move.** That test
needs the game running, and it could not be done in this session — the wine wrapper and the game
data live on the `x10` volume, which this shell has no Full Disk Access to (macOS returns
`Operation not permitted` for the whole volume; granting it requires quitting and reopening
Terminal, which would end the session doing the work).

So the honest position is: the mechanism is proven against the exact CoreAudio pattern
winecoreaudio uses, on the exact architecture wine runs as, and the failure mode is "does
nothing". It has not been heard working in-game.

**To finish the verification** (ten minutes, needs the game):

1. Launch a world from the app as usual.
2. `FFXI_AUDIOFOLLOW_DEBUG=1` in Setup & Diagnostics → extra environment, so the log pane carries
   the dylib's lines.
3. Get in-world with music playing, then change Sound Output in System Settings.
4. Expect `audiofollow: system output changed to device N` / `moved a unit to device N` in the
   log, and the sound to move within a second.

If it does not: check the log for `audiofollow: loaded` at all. Absent means dyld dropped the
insertion (see the `arch(1)` gotcha, or a hardened-runtime wine binary with library validation),
and the next pathway below applies.

## Pathways considered, and why they lost

| Pathway | Verdict |
| --- | --- |
| **Interpose CoreAudio in the wine process** (shipped) | Small, reversible, no wine fork, works on the prebuilt Sikarugir engine everyone downloads. |
| **Patch `winecoreaudio.drv`** — add the listener in wine itself, upstream it | The *correct* fix and worth doing upstream one day, but this project ships a prebuilt wine from Sikarugir's releases. Forking and rebuilding wine to fix an audio routing bug is out of proportion, and it would put every user on a build nobody else tests. |
| **Swap the unit subtype to `kAudioUnitSubType_DefaultOutput`** by interposing `AudioComponentFindNext` | Would follow the default for free — but mmdevapi then calls `SetProperty(CurrentDevice)` on a unit that does not accept it, and the failure lands in wine's error paths rather than ours. Rejected as fragile. |
| **A virtual loopback device** (BlackHole/aggregate) that wine is pinned to, with the real output switched underneath | Works, and is what people do by hand today — but it means shipping or requiring a kernel-adjacent audio driver install for a launcher whose whole pitch is "press four buttons". No. |
| **Restart wine's audio on device change** (kill/reopen the stream from outside) | There is no way to reach into mmdevapi from outside the process to do this, and doing it by restarting the game is the bug, not the fix. |

## If the shipped pathway turns out not to load

The fallback with the best odds is a **wine-side environment override**: `winecoreaudio` re-reads
its device list when mmdevapi re-enumerates, so a small Ashita addon or a wine service that
forces a device re-enumeration on change might get most of the way there without any injection.
It is speculative — nobody has tested it — and it is only worth exploring if the log shows the
dylib never loading.

## 2026-08-26: verified loaded inside a live client — and the bug that hid it

`audiofollow.dylib` was **not** loading in the game, silently, on every launch.
`lsof` on the live `horizon-loader.exe` showed the dylib absent even though the
launcher put it in `DYLD_INSERT_LIBRARIES`.

Cause: the game is spawned through `/bin/sh` (Detach.spawn, for the new-session
detach and the cwd). `/bin/sh` is a SIP-protected platform binary, and **dyld
strips every `DYLD_*` variable from a protected process's environment before
`main()`** — so the variable set on the shell never survived to the wine loader
it exec'd. Same class of gotcha already noted for `arch(1)`.

Fix (Detach.swift): put the `DYLD_*` assignments on the *shell command line*
(`DYLD_INSERT_LIBRARIES=... exec wine ...`) instead of in the shell's
environment. The shell exports them itself, and the unsigned wine loader — which
dyld does not restrict — inherits them. Non-DYLD vars still go through the normal
environment.

**Verified 2026-08-26:** after the fix, `lsof -p <horizon-loader pid>` lists
`/Applications/FFXI-on-Mac.app/Contents/Resources/audiofollow.dylib` mapped into
the running client on the Local (LandSandBoat) world.

## 2026-08-26: hardened-runtime signing breaks launch from the removable volume
A Developer ID + `--options runtime` build of the launcher cannot start the game
when wine lives on an external volume: the child faults with
`could not load ntdll.so: ... (file system sandbox blocked open())`, and it is
**not** fixed by answering the removable-volume prompt (the detached grandchild
is not covered by the app's TCC grant). The ad-hoc build has no such restriction.
So the **local `/Applications` build is ad-hoc** and plays fine; a notarized
release still needs this solved (candidate: a removable-volume/Documents
entitlement, or install wine to an Application Support path on the internal disk).

## 2026-10-16: not reaching an x87-accelerated client — carried since b69

Since Play runs i386 wine processes through the cooperative x87 sidecar (`ROSETTA_X87_PATH`,
docs/X87-SIDECAR.md), `audiofollow.dylib` has not been reaching the game client. Wine execs
`x87sidecar-coop --cooperative <loader> …`; that binary is signed with the hardened runtime, so
dyld strips every `DYLD_*` variable from its environment before `main()`, and the client it execs
starts without `DYLD_INSERT_LIBRARIES`. Measured with the installed Developer ID sidecar: an
unsigned child exec'd through it saw no `DYLD_INSERT_LIBRARIES` and did not load the dylib; the
same child exec'd directly did. The 2026-08-26 check above was made with an ad-hoc build (see
the note just above), whose sidecar keeps the vendored ad-hoc signature without the hardened
runtime and strips nothing; a Developer ID build (the installed one, every release) signs it with
the hardened runtime.

b69's `gamewindow.dylib` carries the list across that exec (see `window/gamewindow.c`), so with
"Keep the game window's shape" on (the default), audiofollow reaches the client again whenever
"Follow the Mac's sound output" is on. With the window setting off it does not. Details and the
test: `docs/BETA-69.md`, `scripts/tests/gamewindow-test.sh`.
