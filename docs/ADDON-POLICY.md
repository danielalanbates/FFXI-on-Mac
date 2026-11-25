# Per-server addon rules

Written 2026-08-14.

On most FFXI private servers, loading an addon the server has not approved is a bannable offence.
The launcher's addon screen used to list everything installed, which on HorizonXI meant offering
Daniel a one-click route to a ban. It now filters that list per server.

## The rule the code follows

`AddonPolicy` has three states, and the important one is the third:

- `.allowlist(names, source:)` — the server publishes a list. Only what is on it is shown, and the
  screen names where the list came from.
- `.unrestricted(reason:)` — used for the local LandSandBoat world, where the only player is the
  person running the server.
- `.unknown` — **nothing is filtered, and the screen says so in warning colour.**

`.unknown` is the default for every server whose policy this project has not actually sourced. It
is tempting to fill those in from memory or by pattern-matching other servers' lists. Don't.
Presenting a guessed allowlist in the same UI that says "showing only what this server approves"
would make the launcher lie about a rule that gets accounts banned. Showing everything and saying
"this is unfiltered, go and check" is the honest failure mode.

Currently sourced:

| server | policy | source |
| --- | --- | --- |
| HorizonXI | allowlist, 5 plugins + 153 addons | <https://horizonxi.info/addons>, the list HorizonXI's own wiki points players at (checked 2026-08-14) |
| CatsEyeXI | allowlist, 40 addons + 14 plugins + 6 shipped-by-installer | <https://github.com/CatsAndBoats/catseyexi/wiki/Approved-Addons-and-Plugins> (checked 2026-08-19); Ashita section only. The six extras (`hideconsole move customcolors nolock cexidats partyfinder`) are loaded by the `scripts/default.txt` their own installer ships — filtering them would force-disable the server's defaults |
| FFEra | allowlist, 64 addons | <https://ffera.fandom.com/wiki/What_Addons_%26_Plugins_Are_Allowed>, their official wiki (checked 2026-08-19); Ashita "Allowed" section. Their "ask before using anything unlisted" is read as not-yet-allowed |
| Local server | unrestricted | it is your own world |
| Eden | unknown | rules live only in their Discord's rules channel — nothing fetchable to cite |
| Supernova, ValhallaXI, OmicronXI, Gaia XI, Tabula Rasa XI | unknown | no published list found anywhere (checked 2026-08-19) |

`horizonxi.com/players/Addons` returns 403 to anything that is not a browser, which is why the
`.info` mirror is the cited source. Re-check both before a release; names are stored verbatim as
published, including the `(author)` tags and `A / B` alternates, so re-checking is a plain diff.

## Two things that would have broken the game

**Ashita's own machinery is not an addon.** `Addons.dll` is the Lua host: nothing written in Lua
runs without it. It appears on no server's published list, because no player chooses it. An
allowlist that filtered it out — and the Apply button that switches off anything filtered — would
have silently disabled every addon in the game while the screen still looked correct.
`AddonPolicy.infrastructure` exempts it along with `Thirdparty`, `Screenshot`, `libs` and this
project's own `winefix` shim.

**Name matching has to be loose.** The published list writes `Chains (Sippius)`,
`HXUI / ConsolidatedUI`, `Don't Drop The Soap`; the disk writes `chains`, `HXUI`. `normalize()`
drops a parenthesised tag, splits `A / B` into alternates, and strips everything that is not
alphanumeric. Against this install, 32 of 105 installed items are not on HorizonXI's list — that
number is the check to re-run if the matching is ever changed, because a matching bug shows up as
that count jumping.

## A bug found on the way

`scripts/default.txt` on this install has none of the launcher's `--HORIZON_..._START--` markers.
The old code read load lines *only* between markers, so it found none and drew every addon as
disabled, and Apply then failed outright. Scanning now treats a marker-less file as entirely
managed, and the first Apply adopts it — existing `/load` lines are replaced by the two marked
blocks, while `/wait`, `/ambient` and anything else keep their place. `/load winefix` is left
exactly where it is, because the UI never offers it and must not sweep it into a block it
rewrites.

## Where addons are tested (standing rule, 2026-08-28)

Addon development and testing happen **only on the local LandSandBoat world**
(`scripts/lsb-server.sh`, 127.0.0.1). Never load an addon under test against HorizonXI or any
other hosted server — the allowlist above exists because that is a bannable offence, and an
automated test run has no way to know which addon a server tolerates.

## VanaVoice and Vanaguide (not on any allowlist)

| Addon | Wiring | Allowlist worlds | Local LSB |
| --- | --- | --- | --- |
| VanaVoice | `Narration.swift` | Refused + scrubbed | Toggle **Read cutscenes aloud** |
| Vanaguide | `Guide.swift` | Refused + scrubbed | Toggle **Quest guide (Vanaguide, local LSB only)** |

Neither is listed in shipped `addons/default.txt`. Load lines sit outside the AddonSuite markers. Details: `docs/VANAGUIDE.md`, vanaguide `docs/SERVERS.md`.

