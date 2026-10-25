# Beta 3.10 build 78 (local only)

Branch `beta-b78`, from `beta-b77`. Local beta: no GitHub release.

## A population line on every world's page (Daniel, 2026-10-24)

"can we put the estimated populations in the news feed of each server page? ... if there's no such
data for a server, maybe it can pull the active discord numbers or other population based numbers
instead."

The line above each world's news (`ContentView.populationLine`) showed only for the eight worlds
whose servers publish a players-online counter (HorizonXI, CatsEyeXI, Eden, Vanadreams, DriftwoodXI,
PegasusXI, MistXI, Olympus XI). Every other world now shows its **Discord's** live numbers instead,
from Discord's public invite API (`discord.com/api/v9/invites/<code>?with_counts=true`, no account):
"36 online in their Discord · 120 members", with a different dot and a tooltip saying these are
people online in the Discord, not in the game. A server's own counter always wins; a world with
neither (OmicronXI) shows no line, never a made-up 0.

Checked 2026-10-24, every built-in hosted world's invite answered (e.g. Scythe 36/120, LevelDown 363/
1,391, Legendary 131/416, AscensionXI 24/67). Fetched for the selected world only, at most every ten
minutes per world; a failed fetch removes the number.

## Files

| file | what |
| --- | --- |
| `ServerFeeds.swift` | `DiscordCount`, `inviteCode`, `parseInvite`, `wantsDiscord`, `refreshDiscord(for:)` |
| `App.swift` | `populationLine` falls back to the Discord line; refreshed on launch, world change and the two-minute tick |
| `NewsSelfTest.swift` | invite codes, the API answer, which worlds fall back, the wording |

## Tests

- All 32 suites pass on the b78 app (`--selftest-news` 40). The updater suite failed two probe-timing
  checks once when run at `nice -n 20` beside a running game; it passed three runs out of three at
  normal priority.
