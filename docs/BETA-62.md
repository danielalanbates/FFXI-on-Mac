# Beta 3.9 build 62 (local only)

Branch `beta-b62`, on top of `beta-b61` (cb6e9f0). Local beta: no GitHub release, nothing pushed.

Two features: the news panel comes back, with HorizonXI's real posts in it, and the launcher
takes back a game it started itself before it was relaunched.

## A. News panel

Daniel: "where did the news feed go?" b59 (b3b6a83) removed the left-panel banner as dead,
because `ServerFeeds`' header said (2026-08-14) that no FFXI server publishes a feed a launcher
can read. For HorizonXI that was wrong.

### What HorizonXI publishes (checked 2026-10-15)

- `GET https://api.horizonxi.com/api/v1/news` → `200 application/json`, `Cache-Control: public,
  max-age=300`, a JSON array of the newest 30 posts:
  `{slug, title, date (ISO 8601 UTC), author, excerpt, html, readingTime, printReadingTime,
  printDate, category, categoryLabel}`.
- Categories in the live 30: `server-notices` "Server Notice", `patch-notes` "Patch Notes",
  `known-issues` "Known Issue", `announcements` "Announcement". The site's bundle also knows
  `launcher-notices` and `discord-notices`.
- It is what horizonxi.com's own news page reads: the site's bundle builds every API call as
  `` `${"https://api.horizonxi.com"}/api/v1/${path}` `` and the news query's path is `news`.
- Posts are relayed from Discord: two titles start `@everyone` with no space
  ("@everyoneApologies for the late notice…"), and a stripped Discord timestamp leaves `()`
  ("…at the normal time tomorrow ()", "…finish before: .").
- `html` is simple: `h3`, `ul`/`li` (nested), `p`, `em`, `strong`; empty for most notices.
- Per-post page: the site routes `/news/$slug` and declares `https://horizonxi.com/news/<slug>`
  as each post's `mainEntityOfPage` (JSON-LD), so that is the link. The page is client-rendered
  from the same list, falling back to `/news/<slug>.json`.
- 2026-08-14 tried `/rss.xml`, `/feed`, `/api/news` and obvious unversioned API paths, never
  `/api/v1/news`. The other worlds still publish nothing readable (unchanged).

### What the launcher does

- `Server.newsURL` / `newsPageURL` (per world, curated like `loader`: always the app's values,
  never servers.json's). Only HorizonXI has them. A world without a feed shows no panel and no
  text.
- `News`: parse (newest first by date, one post per slug, `nil` for anything that is not the
  feed: an error page, an object, garbage), clean-up of Discord tokens (`@everyone`, `@here`,
  `<@id>`, `<@&id>`, `<#id>`, `<t:…>`, custom emoji, the `()` a timestamp leaves, a dangling
  `: .`), chip labels (the feed's own; an unlabelled id made readable), dates, the post URL.
- `NewsHTML`: a post's HTML as heading / paragraph / list-item blocks with emphasis and
  http(s) links, nothing else. Script, style, iframe/object/embed/svg/media are dropped with
  their contents, images dropped, comments skipped, entities decoded. No WebKit and no
  `NSAttributedString(html:)` (which would need the main thread and loads resources): showing a
  post loads nothing. Parsed off the main actor, with the fetch.
- `ServerFeeds.news`: at start the cached copy (Application Support/HorizonXI-on-Mac/news/
  `api.horizonxi.com-api-v1-news.json`, the last good payload, one file per feed address),
  then one GET (10 s timeout) in the background; again every 15 minutes while the window is
  visible, and when it comes back into view if the last ask was over 15 minutes ago. A failed
  fetch keeps what is shown; a good one replaces it and the cache. Never on the main thread.
- The ServerFeeds header records all of the above and why 2026-08-14 missed it.

### Exactly what the left panel shows

Under the title (`HORIZONXI`), the `FINAL FANTASY XI ON APPLE SILICON` line, the launcher's own
update line when there is one, and "N online": a rounded dark panel (500 pt wide at most, like
the account card), one row per post, newest first, thin dividers. Each row:

- top line: the category chip, capitals, tinted by kind (PATCH NOTES gold, SERVER NOTICE crystal,
  KNOWN ISSUE ember, ANNOUNCEMENT muted), and on the right the date: "Today", "Yesterday",
  "N days ago" (under a week), else "Oct 5" ("Dec 31, 2025" in another year), on this Mac's
  calendar; the full date is the tooltip;
- the title, cleaned, two lines at most;
- patch notes only: the post's own sentences without its section headings, two lines at most.
  (The feed's `excerpt` runs a heading into the first item, "Battlefields An issue where…"; it is
  used only for a post with no body.)

The panel is at most 360 pt (five to eight rows, depending on how many are patch notes) and
scrolls through all 30; in a small window it gives way down to 120 pt rather than push the
cards below it out. Hovering a row tints it; a click opens a sheet: chip, date and author, the
title (serif), the post's blocks (gold serif section headings, bullet lists, nested lists
indented with ◦), and at the bottom `horizonxi.com` (the post's page) and Done. A notice with no
body is its chip, date and title.

No label, no placeholder, no built-in blurbs: no feed, nothing fetched and nothing cached, or an
empty feed, is no panel at all.

The live feed at 2026-10-15 13:45 PDT, as `--news-preview` prints it (rows' summaries cut here):

    SERVER NOTICE | Server is up, enjoy the weekend | 6 days ago
    PATCH NOTES | Patch Notes for October 9, 2026 | 6 days ago
        An issue where the orbs in "Pulling the Plug" would sometimes chase players should be resolved. The Light Elemental…
    SERVER NOTICE | Apologies for the late notice - We will be doing maintenance at the normal time tomorrow | Oct 8
    SERVER NOTICE | Server is back up! | Oct 5
    PATCH NOTES | Patch Notes for October 5, 2026 | Oct 5
        Players should now be able to do shady deals with Ropchop to leave Ghelsba Outpost battlefields early. …
    SERVER NOTICE | Will be doing a quick server maint to address some issues | Oct 4
    PATCH NOTES | Closing Remarks on EXP Changes | Oct 2
    …  (30 rows down to KNOWN ISSUE | We are aware of current connection issues… | Sep 12)

An offscreen render of the row and sheet views over that feed (SwiftUI `ImageRenderer`, a
temporary flag not in the app; no window, not a screenshot of the launcher):
`~/Downloads/FFXI-on-Mac-build/fixture/news/render-panel-rows.png` and `render-sheet.png`.

## B. Adopting our own leftover sessions

Live on 2026-10-15: the launcher was relaunched (to install a build) while the loader it had
started kept running, detached, as designed. The new launcher's sessions were empty, so the scan
filed that client under "elsewhere": a greyed "Running…", "Already running from another
launcher.", and no Stop on the button or in the RUNNING list. Nothing on screen could end it.
After the loader was killed, wine's `services/explorer/winedevice/plugplay/svchost/rpcss` lived
on with no wineserver. And "elsewhere" refreshed only on the 15 s tick while the window was
visible, so it stayed stale.

### What is now "ours" (`Leftovers.adoptable`)

A client elsewhere (a loader whose world can be read, in no session of this run) is adopted when
all of these hold:

- no other launcher process is alive (`SingleInstance.otherLauncherAlive`: any app with this
  bundle id or executable, or a live lock holder that is not this process);
- every process of its group runs this launcher's wine (`LiveClients.Client.ownWine`, from
  `OwnWine`: wine-coop at any known location, the remembered wrapper's own wine, or the x87
  sidecar);
- it runs in the selected install's prefix: a process of its group carries that `WINEPREFIX`
  (the x87 sidecar: wine rewrites its own processes' argv/env, the sidecar's `ps -E` is
  readable; only `WINEPREFIX` is extracted, since that command line holds `--pass`); or, with no
  readable environment (x87 off), every wineserver of this launcher's wine serves that prefix
  and at least one runs (a wine client is served by its own prefix's wineserver).

Anything else stays "Running…" without Stop: another wine (CrossOver, Whisky, XIV on Mac,
CatsEyeXI's own launcher), another prefix, or a launcher process that is still alive.

`Runner.adopt` makes it a session of its world (the world's idle session, else a further one):
running, not "Starting…", its process group held as having shown the loader. From there it is
the same as a session this run launched: the big button is **Stop** (enabled; "Play Another"
on a world that allows two, with the Stop in the RUNNING list), the RUNNING entry has Stop, the
exit watcher (5 s `ps`) brings Play back when it ends, and Stop SIGTERMs the group's wine
processes (loader, sidecar), SIGKILLs what ignores it after 8 s, and with nothing else left
takes that prefix's wineserver down (`wineserver -k` / `-w`), exactly as for any session.
Nothing is written or signalled by adopting. launcher.log gets one line.

### wine's own programs with no wineserver (`Leftovers.serverless`)

With no wineserver of this launcher's wine running at all, and the selected prefix's server
socket (`/tmp/.wine-<uid>/server-<st_dev hex>-<st_ino hex>/socket`; read live as
`server-1000016-d7c73b` for this prefix) not possibly live (it is absent, or no wineserver of any
wine runs), wine's own programs (`LiveClients.wineSystemPrograms`, `C:\windows\…`) of this
launcher's wine whose parent is launchd are leftovers. They are ended quietly: a second scan
under the launch lock (so no launch here or in another launcher can be starting a server),
SIGTERM, SIGKILL after 3 s for any still the same process, one line in launcher.log. Never
another wine install's programs (`Snapshot.ownSystemPrograms` only), never while a launch or job
of this launcher runs, never while another launcher is alive.

### When it looks

`Sessions.refreshElsewhere` does all of this. It runs at start, again right after the remembered
install is known (before any `--play` is handled, so a forwarded Play sees the game as this
window's), on the 15 s tick while visible, when the window comes into view, **when the app
becomes active**, **right after Stop** (button and RUNNING list), and **whenever a session
starts, stops or exits**. The prefix's drive is touched (realpath, stat) only when there is a
candidate to decide on.

### On Daniel's Mac, read-only (`--leftovers-report`, during this build)

Daniel's b61 launcher (pid 33176) was open and his game running:

    prefix: …/FFXI on Mac/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10
    another launcher alive: true
    this wine's wineservers: ["33416 -> …/prefix10"]
    client pid 33436 group 33401 host play.horizonxi.com own wine true prefix …/prefix10
    client pid 33438 group 33401 host play.horizonxi.com own wine true prefix …/prefix10
    would adopt (with no other launcher alive): ["group 33401 play.horizonxi.com pids [33436, 33438]"]
    adopts now: nothing (another launcher is alive)
    this wine's own programs: [33423, 33425, 33427, 33429, 33432, 33434, 33452]; would end: []

So with this build installed in place of that launcher, that game would be adopted with a Stop;
nothing would be ended while its wineserver runs.

## Also

- Self-tests never rotate the real launcher.log: `Runner.logFile` goes to `$TMPDIR` for any
  `--selftest-*`, as it already did for `--fix` (the leftovers test drives a Runner).
- New read-only commands: `--news-preview [feed.json]` (the panel as text; one GET without a
  file), `--leftovers-report` (what would be adopted and ended now). Both exempt from
  SingleInstance; neither writes anything.

## Tests (2026-10-15, M1 8 GB, macOS 27.0, release build of the final tree)

- `--selftest-news` (new): 33/33. On a trimmed capture of the live feed (`NewsFixture`, 10 of 30
  posts) and synthetic payloads: count, newest first (also from the reversed array), chips,
  `@everyone` and `()` stripped in every title, every Discord token kind, `before: .`, row
  summary vs feed excerpt, Today/Yesterday/N days/short date/year, local vs UTC date in the
  sheet, post URL (and refusal of `../x`, `a/b`, http, no template), HorizonXI's feed and no
  other world's, servers.json cannot override the feed, heading/list blocks of a real patch
  note (5 headings, 13 items), nested list levels (1 + 14), entities, script/style/img/comment
  dropped, emphasis and only http(s) links kept, unclosed markup, not-the-feed payloads → nil,
  `[]` → no posts, duplicate slug, cache round trip, junk never cached, damaged cache, and with
  the fetch swapped: failed with no cache → no panel, empty → no panel, good → shown, failed
  after good → kept, second trigger inside the interval → no GET, next start offline → cached
  posts at once, worlds without a feed never fetched.
- `--selftest-leftovers` (new): 23/23. Synthetic `ps` shaped like the live client: own orphan
  adopted (sidecar env, and server-only evidence); another launcher alive, another wine, a group
  partly another wine, another prefix, ambiguous/unreadable/no servers, this run's own group or
  starting host, CatsEyeXI's own launcher → not adopted; after `adopt`: running, not starting,
  in `live`, in `playingGroups`, not elsewhere, not adopted twice, button Stop (enabled), a
  stranger's client → Running…, disabled, its reason; Stop/watcher see exactly the group, then
  nothing once it ends; a running session is never re-pointed; serverless: flagged with no own
  wineserver, stale socket with no server at all, nothing with our server alive, never another
  install's, nothing when the socket may be live under a foreign server, parent not launchd left
  alone; `WINEPREFIX` with spaces read from a `ps -E` line; socket folder name.
- The other 19 suites: all pass (`--selftest-primary-action` 77/77, `--selftest-install-location
  ~/Downloads/FFXI-on-Mac-build/fixture` 107/107, `--selftest-setup-progress` 27/27,
  `--selftest-retroachievements` 47/47, `HXI_FIXTURE_DIR=… --selftest-boot-profile` 43/43, the
  rest "all checks passed": addon-policy, addon-source, addon-installer, addon-profile,
  addon-scrub, addon-install, cursor-fix, guide-disabled, narration-disabled, multiworld,
  updater, perf, ui-text, single-instance).
- `scripts/tests/setup-scripts-test.sh` with `HXI_LAUNCHER_BIN`: 98 ok, 2 failed, 2 skipped (no
  aria2 archive, no game-Wine tarball). Both failures are part 21, the same two as b61: `--fix`
  refused Repair, "a game is running in this prefix (play.horizonxi.com: pid 33436,33438)" —
  Daniel's live game, left alone.
- `--check`: HorizonXI ok, Local server ok, Gaia XI ok; CatsEyeXI, Supernova, OmicronXI BAD
  (their client folders, as before); exit 1 as in b60/b61.
- `--next-action HorizonXI`: `play | Play |`, exit 0 (it does not look at running clients).
- `--news-preview` against the live feed: 30 rows, as above. `--leftovers-report`: as above.

## Not tested (rules for this build: no GUI, no game, no wine on the real install)

- **The window.** Nothing here was seen in the running launcher: the panel's place under the
  title, its height against the account card and the error strip, the scroll, hover, the sheet
  opening and its link. Only offscreen renders of the row and sheet views exist.
- **A real adoption**: a b62 launcher started under a game the previous launcher left, the Stop
  button ending it (loader, sidecar, wineserver), the watcher bringing Play back. The decision
  was checked read-only on the live client; the actions are the ones every session already uses.
- **The serverless cleanup on real orphans.** Never run against processes (the live Mac had a
  wineserver, so the report flagged nothing).
- The 15-minute refresh and the occlusion trigger; the fetch's behaviour offline (the code path
  is the self-test's failed fetch).
- Intermediate commits were not built one by one; the final tree was.

## Risks

- A client of this launcher's wine in the selected prefix that **no launcher** started (a
  hand-run `Play HorizonXI.command`, the harness, `twoclient.py`) is adopted too, when no other
  launcher is alive: it gets a Stop, and its exit writes the window size into the boot profile
  like any session. Before, it sat in "elsewhere".
- With x87 off (no sidecar in the group), the prefix is inferred from this wine's wineservers;
  if one of them cannot have its environment read, nothing is adopted (stays Running…).
- `otherLauncherAlive` counts any app with this bundle id, a launch about to hand over and exit
  included, and a stale lock pid reused by an unrelated process: adoption then waits a refresh,
  or (stale pid) until that process ends.
- The serverless rule is global, not per prefix: with this wine's wineserver serving any prefix
  (an installer prefix, say), orphans of another prefix are left until it stops. And a hand-run
  script of this wine starting a server in the one second between the scans could lose its
  `services.exe` (the launch lock does not cover scripts).
- The news panel depends on HorizonXI keeping `/api/v1/news` and its field names; a change reads
  as "not the feed" and the cached copy stays up, unchanging, until it works again.
- The row summary joins the post's items into one line; long posts are cut at two lines.
- The sheet's link opens the browser (the only thing that leaves the launcher); the post's page
  is client-rendered and finds only posts still in the newest 30 (else its `.json` fallback).
