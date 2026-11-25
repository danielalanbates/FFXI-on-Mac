# World picker by online population (build 101)

The launcher now sorts hosted worlds by **online players**, largest first. Live public counters
already fetched by `ServerFeeds` override built-in estimates; a valid live zero overrides a larger
estimate. A failed/malformed counter falls back to the dated estimate. Equal/unknown counts sort
by name. The local development server remains last. Legacy `pinned` fields remain decodable but
no longer affect sorting. Sorting never changes the selected world.

The picker and companion handoff use the same order. Existing saved hosts, data paths, selected
world and account separation survive the merge; newly catalogued Phoenix is inserted once.
There is no extra popup, warning banner or fabricated player number. The existing selected-world
population line continues to show only a successfully fetched public count.

## Offline estimates

| World | Online estimate | Source / observation date |
| --- | ---: | --- |
| HorizonXI | 1,496 | `https://api.horizonxi.com/api/v1/misc/status`, October 28, 2026 |
| Phoenix XI | 1,110 | `https://phoenix-xi.com/` rendered homepage, October 28, 2026 |
| CatsEyeXI | 657 | `https://catseyexi.com/` rendered “Online Now”, October 28, 2026 |
| DriftwoodXI | 42 | `https://xi.driftwoodgaming.com/api/players`, October 28, 2026 |
| Vanadreams | 21 | October 24 survey, `https://vanadreams.org/api/public/vanadreams/status` (survey also recorded 22 at another observation) |
| Olympus XI | 2 | `https://olympus-games.dev/api/status`, October 28, 2026 |
| PegasusXI | 0 | `https://pegasusxi.com/api/status`, October 28, 2026 |
| MistXI | 0 | `https://api.mistxi.com/status.php`, October 28, 2026 |
| Other offered hosted worlds | unknown | Old Discord/community/weekly-account rankings removed; no comparable online estimate established. |

These are snapshots, not peak population, unique human players or promises of present activity.
A snapshot zero and unknown both sort with zero fallback weight. Public live counters can vary
by time zone, maintenance and a world's boxing rules. Phoenix currently has only the snapshot;
its public API route has not been re-established in this change. Recheck snapshots with releases.
CatsEye and Vanadreams HTTP requests returned 403 in command-line research; CatsEye's rendered
homepage supplied the observed count. No challenge was bypassed.

The parser rejects booleans, fractions, negative counts, counts over one million, missing keys and
HTML/error responses. This prevents malformed status data from outranking worlds or appearing as
negative online players. The server menu reuses the existing refresh cadence; no new polling,
app-launch loop or hosted game request is introduced.
