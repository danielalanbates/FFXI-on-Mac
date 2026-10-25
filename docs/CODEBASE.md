# Which emulator each world runs, and why the list is shorter

**Rule: the launcher offers LandSandBoat worlds only** (Daniel's qualification, restated
2026-08-21 after the round-trip below). LSB is the one FFXI emulator still in development, so it
is the only lineage that keeps receiving content and fixes; a world on a dead fork is frozen at
whatever its team can write alone.

**Population does not override the rule.** It is worth being explicit about this, because the
numbers are lopsided and the temptation to make an exception is real: Eden had 835 players online
and 9,889 Discord members (2,642 online) when checked — the second-largest community on this list —
and is still cut. "Alive" and "on a maintained emulator" are different questions, and the second
one is the qualification.

The first version of this cut removed every non-LandSandBoat world, reasoning that only LSB
receives upstream development. The emulator part is true. The inference — that a world on another
codebase is therefore deprecated — is not, and checking the servers themselves said so:

| World | Players online | Discord members / online | Verdict |
|---|---|---|---|
| Eden | **835** (their own `/api/v1/misc/active`) | 9,889 / 2,642 | very much alive |
| FFEra | not published | 1,204 / 313 | alive |
| ValhallaXI | not published | 1,362 / 271 | alive |
| Tabula Rasa XI | — | no invite; `TabulaRasaXI/TabulaRasa` last pushed 2024-05-21, domain parked | **dead — withheld** |

For comparison at the same moment: HorizonXI 2,517 online, CatsEyeXI ~3,894 in Discord.

So the cut worlds are **not deprecated servers** — three of the four are busy. They are cut for the
codebase, which is the stated qualification, and the distinction matters if this is ever revisited:
Eden going quiet would be news; Eden being DarkStar-lineage is the reason it is not listed. The
news banner still names the codebase for the worlds that *are* listed, since "can pull from a
living upstream" is the whole point of the rule.

LandSandBoat is the only FFXI server emulator still in development. Everything else in the family
tree is frozen:

    DarkStar (deprecated 2020-04-25)
      -> Project Topaz -> renamed LandSandBoat        <- alive, actively released
      -> AirSkyBoat (fork, May 2022, 75-cap module)   <- archived Feb 2025, no reason given
      -> various private forks                        <- frozen wherever they forked

HorizonXI itself is the cautionary tale: it ran on AirSkyBoat, ASB was archived in February 2025,
and Horizon spent nearly a year re-basing onto LandSandBoat, completed 30 January 2026. A world on
a dead fork gets no new content and no upstream fixes.

## How each world was classified

Not by asking around — none of these servers publish their codebase. By probing the login server:

Modern LandSandBoat speaks **JSON over TLS on port 54231** (`src/login/auth_session.cpp`), and
answers a stale version tuple with a verbatim `Your xiloader is too old.` payload. DarkStar-lineage
login servers predate TLS entirely and never complete a handshake. `scripts/login-probe.py` re-runs
the whole test in about ten seconds.

| World | Port 54231 | TLS | Reply | Verdict |
|---|---|---|---|---|
| HorizonXI | open | yes | `{"error_message":"Your xiloader is too old…'2.0.x'…"}` | **LandSandBoat** |
| CatsEyeXI | open | yes | same LSB payload (and their fork is public: `CatsAndBoats/catseyexi`, forked from `LandSandBoat/server`) | **LandSandBoat** |
| Supernova | open | yes | same LSB payload | **LandSandBoat** |
| OmicronXI | open | yes | LSB payload, demanding xiloader `2.1.x` | **LandSandBoat** |
| Gaia XI | open | yes | `0x02` — binary result code from an older LSB login | **LandSandBoat** (older login build) |
| Vanadreams (added 2026-10-24) | open | yes | `This server requires version 2.2.x` (LSB JSON) | **LandSandBoat** |
| DriftwoodXI (added 2026-10-24) | open | yes (TLS 1.3) | `Your xiloader is too old. Please update to version '2.1.x'` (LSB JSON); their bundle's loader is LSB xiloader 2.1.2 | **LandSandBoat** |
| PegasusXI (added 2026-10-24) | open | yes (TLS 1.3) | `Your xiloader is too old. Please update to version '2.1.x'` (LSB JSON); their client ships stock LandSandBoat xiloader 2.1.1.0 | **LandSandBoat** |
| MistXI (added 2026-10-24) | open | yes (TLS 1.3) | `Your xiloader is too old. Please update to version '2.1.x'` (LSB JSON) | **LandSandBoat** |
| Moghouse XI (added 2026-10-24) | open | yes (TLS 1.3) | `Unsupported xiloader version 0.0.0. This server requires version 2.2.x.` (LSB JSON) | **LandSandBoat** |
| AscensionXI (added 2026-10-24) | open | yes (TLS 1.3) | `{"error_message":"Your xiloader is too old.\nPlease update to version '2.1.x'…"}`; their loader's own notice: "Based on LandSandBoat xiloader v2.1.2" | **LandSandBoat** |
| Local server | n/a | n/a | it is LSB, built by `scripts/lsb-server.sh` | **LandSandBoat** |
| Eden | open | **no** (handshake times out) | — | DarkStar lineage — *cut*. Corroborated twice over: their community wiki says Eden forked from DarkStar, and the loader in their own client identifies itself as `DarkStar Boot Loader (c) 2015 DarkStar Team` from `github.com/EdenServer/xiloader` |
| FFEra | open | **no** (EOF during handshake) | — | DarkStar lineage — *cut* |
| ValhallaXI | open | **no** (EOF during handshake) | — | DarkStar lineage — *cut* |
| Tabula Rasa XI | no host published | — | — | server stopped (parked domain, repo last pushed 2024-05-21) — *cut* |

Neither FFEra nor ValhallaXI is installed here, so their shipped loaders could not be inspected the
way Eden's was; for those two the protocol probe is the whole of the evidence. It is a strong
signal — TLS on 54231 is an LSB-era addition — but a second one would be better if either world is
ever reconsidered: install it and read the strings in its `xiloader.exe`.

## What "retired" means in the code

`Server.builtins` — what the picker shows — is
`all.filter { !$0.retired && $0.codebase == .landSandBoat }`. Two independent axes: `codebase` is
what the login probe measured, `retired` means the server has actually stopped (Tabula Rasa XI
alone). `Server.retiredWorlds` is everything the picker withholds for either reason. Nothing was
deleted: the retired entries keep their install pathways, boot profiles, client-version sources and
signup routes, because that was all real work and none of it is wrong — those worlds simply do not
meet the LSB bar.

`ServerStore.merge` drops retired worlds by name from a `servers.json` written by an older build,
so an existing install cleans itself up on first launch. It only drops entries this project
shipped; a server the user added by hand is never touched.

**To bring a world back**, change its `codebase:` to `.landSandBoat` — that is the entire change.
Do it only on evidence: re-run `scripts/login-probe.py` and check the reply, because a server that
re-bases onto LSB (as Horizon did) will start answering the JSON.

## Caveats worth keeping honest

- The probe proves the *login server* is LSB. A world could in principle run an LSB login in front
  of something else; nothing observed suggests that, but it is not disproved.
- Gaia XI's `0x02` is an LSB result code, not the JSON payload — it is on an older LSB login than
  the other four. LSB-family, but not the same vintage.
- "LandSandBoat" here means the lineage, not that a world tracks upstream closely. Every one of
  these is a fork with its own content; the point of the cut is that the fork can still *pull* from
  a living upstream, as Horizon now does.
