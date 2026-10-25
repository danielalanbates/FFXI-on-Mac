# Beta 3.10 build 77 (local only)

Branch `beta-b77`, from `beta-b76`. Local beta: no GitHub release.

## Window mode (Daniel, 2026-10-24: AscensionXI "isn't launching with a window border ... not centered")

AscensionXI's own launcher defaults FFXI's window mode (`[ffxi.registry] 0034`) to 2, "Borderless
windowed" (`GraphicsPage.cs`: "borderless is the usual choice"), and their profile carries it. On the
Mac that window has no title bar, cannot be moved or resized, and the game-window helper and the size
fitter leave it alone (launcher.log: "window ... is not titled and resizable, left alone"), so a
1648×928 window opened borderless on a 1440×900 screen. Every Play now sets `0034 = 1` (windowed) in
the world's profile first, for every world (`GraphicsSettings.windowedOnMac`, logged once when it
changes): PegasusXI's profile ships 3 and Olympus XI's launcher writes 2 as well. Added when a profile
has no `0034`, because the Wine prefix's registry is shared and another world's value would stay.
macOS's own full screen (green button) still works on the windowed client.

## Two new worlds

- **Olympus XI** (open beta, 2.2.x): their own client list (tag-named release) with the few files
  only they have fetched from their delta pack by Range, and their DATs as an XIPivot overlay.
- **Legendary Relaunch** (invite-only, 2.1.x): retail client, their DATs as an overlay from their
  portal. Accounts come from a GM.

Both in [`RETAIL-WORLDS.md`](RETAIL-WORLDS.md).

## Review fixes (an independent review of b72–b76, each finding checked by a second reviewer)

| finding | fix |
| --- | --- |
| **High**: LevelDown 99's 5.5 GB archive was installed from whatever a wiki page named, unchecked | pinned version, Drive file and SHA-256 (`ClientArchive.pins`), checked before every unpack; an unpinned version is reported and the client kept |
| Scythe: the signature covered the first `"release"` anywhere in the document, the fields came from the top-level one | only a top-level `"release"` is signed-checked, and the fields are read from the signed bytes and must equal the top-level object |
| MistXI/Moghouse XI followed DriftwoodXI's live list: a move to a new build would block Play and half-replace the client | the retail list is pinned by an entries digest; a copy here (or in a sibling world) means no request at all; and `RetailClient` checks every file is available before it replaces the first one |
| Vanadreams: a download list's zip name could reach outside the folder; Repair never checked client files; a fallback version could merge an old client over a new one; chunks went through the internal disk's temp folder; a bump re-downloaded all 8.4 GB | names, versions and folders validated; each zip's file list recorded and checked by Setup/Repair; the version an update was fetching is remembered; chunks stream to the drive and resume (`FileDownload`); unchanged zips are kept across versions |
| PegasusXI: a release renaming a folder only by letter case deleted the file (case-insensitive drive) | removal compares case-insensitively |
| DriftwoodXI: a stopped first Setup could be marked finished while their list was down | the client is marked unverified until it is put together; the cached list is used when theirs is down |
| DriftwoodXI: a Finder `.DS_Store` in an addon folder reinstalled it every Play | Finder files ignored when comparing an installed addon |
| `FileDownload`: a resume never checked where the server continued | `Content-Range` must continue the file, `If-Range` with the first answer's validator, `416` only when whole |
| Error types printed "The operation couldn't be completed" | `LocalizedError` |
| Vanadreams' record append crashed (Objective-C exception) on a full or unplugged drive | the throwing `FileHandle` API |

## Tests

- All 32 suites pass on the b77 app: `--selftest-graphics` 75 (window mode), `--selftest-retail-world`
  41 (pins, all-or-nothing, the overlay route, Olympus's client and delta pack), `--selftest-vanadreams`
  42, `--selftest-scythe` 21, `--selftest-pegasus` 34, `--selftest-driftwood` 37.
- Play-time passes on the real installs (MistXI, Moghouse XI, LevelDown 99, Vanadreams, Scythe,
  PegasusXI, DriftwoodXI): all `ok`; MistXI and Moghouse XI re-checked their client once against the
  pinned list (stat only), LevelDown 99's page still names the pinned 30260203_0.
- `--login-version`: 172.96.141.132 (Olympus XI) 2.2.x; 15.204.112.102 (Legendary) 2.1.x.

## Needs Daniel

1. Olympus XI: sign up at <https://olympus-games.dev/create> or **Create account**, then **Play**.
2. Legendary Relaunch: ask a GM in their Discord for a login.
