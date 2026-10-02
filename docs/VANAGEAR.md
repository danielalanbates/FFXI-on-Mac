# Vanagear

Vendored copy of <https://github.com/danielalanbates/vanagear>, this project's
own addon. Written 2026-08-23.

## What it is

A gear swapper for Ashita v4 that is configured entirely from in-game macros.
Every other swapper — LuAshitacast, Ashitacast, kupocast, miniswap — needs a Lua
profile authored outside the game, which is why most players run a stranger's
job file they cannot read. Vanagear captures what you are wearing instead:

```
/vg save idle
/vg save tp over idle
/vg save ws.sturmwind over tp
```

and owns the profile file itself. Full command reference and the design notes
are in `addons/vanagear/` and in the upstream repo.

## Status here: shipped, not enabled, not verified

Three separate facts, and all three matter.

**It is not on any server's addon allowlist.** It is new, and nobody has
published a list that mentions it. `docs/ADDON-POLICY.md` is the rule this
project follows: loading an unlisted addon is a bannable offence on most private
servers. So the launcher does not offer it, `scripts/default.txt` does not load
it, and nothing in the install path enables it. It sits in `addons/` for people
who are running the local LandSandBoat world, where the only player is the
person running the server.

**It has never been run in game.** Not once, on any server. Its 85 assertions
are head-less — `luajit tests/run.lua` in the upstream repo runs the whole addon
against a fake Ashita on macOS. That covers the rule chain, item resolution,
packet layout and every macro command, and it covers none of the things only a
real client can tell you. The verification run, step by step, is written down in
the upstream `docs/PATHWAYS.md`.

**`/Applications/FFXI-on-Mac.app` is untouched by this branch.** Addons live in
the game prefix, not in the app bundle, so nothing here changes the playable
build.

## The one risky mechanism

Precast works by blocking the outgoing `0x1A` action packet, queueing the equip
packets, and re-sending the action behind them in the same frame. If that is
wrong, the symptom is an action that never goes off rather than wrong gear.
`/vg precast off` skips the block entirely and everything else still works. That
is the first thing to try if anything looks strange, and the first thing to
verify in game.
