# Beta 101 — Phoenix catalog and population ordering

- Phoenix XI appears as **Mac support pending**, not a verified/playable server. **Server Info**
  opens its official getting-started page. Its custom auth, Mac client route and tool approval
  remain outstanding ([PHOENIX.md](PHOENIX.md)).
- Worlds sort by existing live public online counters, then comparable dated online snapshots,
  with alphabetical ties/unknowns and the local world last. Legacy pins and mixed Discord/monthly
  membership estimates no longer determine the order ([SERVER-POPULATION.md](SERVER-POPULATION.md)).
- Existing edited hosts and data paths are retained during migration. A refresh changes order,
  not selection. No new polling, updater prompt or client launch is introduced.
- Malformed population payloads (including booleans/fractions/negative counts) are rejected.

## Verification on Apple Silicon, October 28, 2026

| Check | Result |
| --- | --- |
| Native release launcher compile | Passed |
| Native release companion compile | Passed |
| `--selftest-server-catalog` | 19/19 passed; pure synthetic metadata, no network/game |
| `--selftest-primary-action` | 94/94 passed |
| `--selftest-news` | 40/40 passed |
| `--selftest-addon-policy` | All checks passed |
| Public counter research | Horizon 1,496; Phoenix homepage 1,110; CatsEye homepage 657; Driftwood 42; Pegasus/Mist 0; Olympus 2 |
| `git diff --check` | Passed |

No hosted game or addon testing was performed. No Phoenix login, download or authentication
success is claimed. Existing Swift concurrency/deprecation warnings remain; builds passed.

A signed build-101 candidate is staged outside /Applications for later review. The installed
playable launcher remains build 96 and its executable SHA-256 remains
`e56b77d6ba5b0439352ced11f7abc4c6aae96e4071e417539a07008230f7b072`.
The standalone artifact-job-menu companion remains installed at build 100. No public binary
release was published; this work is a source PR stacked on the artifact-menu beta branch.

## Separate local beta issue still open

The earlier strict local guide walk did not reach Gulemont. It failed without teleporting,
skipping or forcing completion; therefore actual quest-acceptance/narration acceptance remains
unverified. See the guide repository's strict-walk PR. That failed local run is not a passing
end-to-end beta result and is unrelated to the population/catalog checks above.
