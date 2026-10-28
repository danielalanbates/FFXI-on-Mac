# VanaGuide Server-Safe

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
[batesai.org](https://batesai.org) · help@batesai.org

The standalone guide now has optional local screenshot matching. The product name describes
its separation from the game; **it does not establish approval by any server**. Use screenshot
mode only where the server permits screenshot tools. This feature does not install an addon,
read client memory, read packets, contact a game server, or send game input.

| Mode | Operation |
| --- | --- |
| Manual guide | Choose a guide and use Back / Done / Next. No Screen Recording permission required. |
| Screenshot mode | Explicitly choose an FFXI window, specify its chat rectangle, then Start. Captures once immediately and every 10 seconds while enabled. |
| Recognition | Apple Vision OCR runs locally on the cropped image. Two consecutive samples with the same match open the guide section: an exact quest/mission title, or else (b83) a dialogue line whose speaker is a recorded quest giver (`Gulemont : …`). |
| Stop | Stop is always visible while capture runs. Closing the guide window or a capture error stops reading. A closed, minimized, replaced or renamed game window requires a fresh selection. |
| Progress | OCR never completes quests, advances checkpoints, changes achievement progress or supplies live player coordinates. The player confirms steps manually. |

## Usage

1. Open **VanaGuide Server-Safe**. Screenshot mode starts off on every launch.
2. Open **Screen Reading…**, then **Find Game Window**. macOS may ask for Screen Recording
   permission for this app. No permission prompt runs at startup.
3. Choose the game window. The list contains visible FFXI-titled game windows, plus (b83) Wine
   windows of a process running an FFXI loader, since private servers title the window with the
   character's name, not displays or
   arbitrary desktop windows. An FFXI title must also belong to a known Wine/game process;
   browser/wiki and terminal titles are excluded, as is the launcher window.
4. Set Left, Top, Width and Height as percentages from the game window's top-left corner. The
   default is the full-width bottom 35%, suitable for a conventional chat log. Custom chat layouts
   need a matching rectangle. Values must fit entirely within the selected window.
5. Press **Start Reading** where the server permits screenshot tools.
6. Leave quest/mission titles visible for two samples (normally 10–20 seconds). The guide opens a
   matching authored route if one is linked by its quest/mission tag, otherwise the database
   reference section. Use **Stop** when finished.

Only the selected window is captured, independently of other desktop windows. Images and OCR
text exist in memory for processing; this code never writes images/transcripts to disk, logs
chat, or sends capture content to an AI/API. RetroAchievements remains a separate read-only
progress snapshot feature. No AI service or token spend is required for screenshot matching.

## Coverage and conservative behavior

- The existing companion could parse only literal `steps = [[...]]` guides. Most addon coverage
  comes from `generated.lua`, which constructs guides while Lua runs. The companion now reads
  the literal bundled `data/quests.lua` and `data/missions.lua` with its non-executing Lua data
  parser, and creates quest-log reference sections. Recorded zones/coordinates/NPCs are preserved.
- Reference sections are labelled as reference targets. They are not presented as complete
  authored walkthroughs, and they do not claim prerequisite-safe ordering or complete routing.
- Titles normalize case, punctuation and diacritics. Matching uses whole words, not fuzzy item
  or dialogue guesses. Speaker matching (b83) needs the whole speaker name before the colon to
  equal a recorded quest giver; the newest such line wins, and a giver of several quests opens
  the first with "(NPC offers N)" in the title. Single-word titles require a `Quest:` or `Mission:` label. Multiple
  titles, duplicate titles across logs, and overlapping sequel titles are refused as ambiguous.
- An already-opened match does not repeatedly reset the guide while its line remains in chat.
  A manually advanced checkpoint in the same route is preserved. Stop/Start resets the matching
  session, permitting a deliberate new selection.
- Dialogue rarely contains the quest's exact title, so speaker matching does most of the work.
  NPCs with no recorded quest, or quests with no recorded giver, do not trigger. Show the relevant quest/mission log title or select the section manually. Low OCR
  confidence, a cropped title, non-English text or small type can prevent matching.
- Screenshot mode requires macOS 14 or later; the manual companion remains available on macOS 13.
  ScreenCaptureKit supplies a window-only image and Vision performs OCR on a utility task. Captures
  do not overlap if OCR takes longer than the 10-second interval.

## Files and validation

| Source | Purpose |
| --- | --- |
| `QuestCatalogue.swift` | Literal database reader, reference sections, exact-title matcher, match debounce. |
| `ScreenGuideCapture.swift` | Explicit window selection, bounded percentage crop, one-window capture and local OCR lifecycle. |
| `ScreenshotSelfTest.swift` | Offline fixtures for quest/mission parsing, title ambiguity, checkpoints and crop validation. |
| `main.swift` | Manual guide and screenshot controls. |

Run `VanaguideCompanion --selftest-parser` to include the new offline fixtures. Set
`VANAGUIDE_ROOT` to an explicit local addon source to check real library/catalogue coverage too;
without it, tests never discover or hydrate Google Drive files. The self-test
does not request Screen Recording permission, enumerate game windows, capture screens, launch
the game, send input, or connect to hosted servers. Live capture and in-game recognition still
need a beta check on the owner's **local LSB server**, using a synthetic test account/chat log.
Do not call offline fixtures evidence of a live character walkthrough or a server approval.

Apple API references: [window-only content filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)),
[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit),
[Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest).

## Getting Started and the local progress record (b84)

Server-Safe cannot ask a server what a character has done, so it keeps its own record.

| Item | Detail |
| --- | --- |
| Where | `~/Library/Application Support/VanaGuide Server-Safe/characters/<world>-<character>.json` |
| Contents | Catalogue key → `current`/`completed`, date last seen, source (`quest log` or `done`) |
| Written by | Getting Started log reads; Done on a guide step (accept steps → current, others → completed) |
| Rules | Completed is never downgraded by a later read; nothing is ever deleted automatically |
| Not stored | Images, OCR text, chat |

The **Getting Started** guide opens first for a character with nothing recorded:
Main Menu (−) → Quests → home nation → Current Quests, then Completed Quests, optional other
areas, then Missions. On those steps the whole game window is read (log pages are mid-screen),
every exact title on a page is recorded under the visible heading (Current/Completed) or the
step's list, a truncated `…` title matches a unique stem, and a title found in several areas is
settled by the area heading on the page. Guide steps then show Completed/Current, and
**Next Unfinished** skips completed ones.

Not yet verified against a real in-game log page (no capture of one exists yet); the menu key
is the default PC layout.

## Names and design (b86)

| Item | Standard |
|---|---|
| Products | VanaGuide (in-game addon), VanaGuide Server-Safe (separate app), VanaVoice, FFXI on Mac |
| Internal identifiers | Unchanged: addon folder/name `Vanaguide`, executable `VanaguideCompanion` |
| Buttons | Title case: Screen Reading…, Find Game Window, Start Reading, Stop, Load, Back, Done, Next Unfinished |
| Guide names | Title case in Server-Safe (display only; the addon keys saved progress by its own names) |
| Palette | The launcher's: night-blue gradient, crystal accent, gold headings, jade = completed, ember = attention (`Theme.swift`) |
| Window | Fixed 620 × 460; Screen Reading settings live in a popover |
