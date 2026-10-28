# Beta 83 — Server-Safe ready for private servers (2026-10-28)

Installed locally, signed with Developer ID: `/Applications/FFXI-on-Mac.app` 3.10 (83) with its nested
Server-Safe, plus `/Applications/VanaGuide Server-Safe.app` (83). b82 is archived in
`~/Downloads/FFXI-on-Mac-build/archive-apps/`. No public release.

| Change | Why |
|---|---|
| Opens a quest from its giver's dialogue line (`Gulemont : …`) | FFXI rarely prints quest titles; exact-title-only matching almost never fired |
| Wine windows whose process runs an FFXI loader are selectable | Private servers title the window with the character name, which the title filter rejected |
| Capture follows the window by ID + PID, not title | A title change mid-session stopped reading |
| One failed OCR sample is skipped; 3 in a row stop | Vision failed once on the Neural Engine in testing, then succeeded |

Verified: launcher and companion self-tests pass; strict deep signatures pass. Apple OCR on a
real local-LSB screenshot reads chat lines. **Not verified:** a live Server-Safe session against a
running game. Owner beta test pending (2026-10-28).

Test path: launcher → world → Play; launcher → **Open Vanaguide Server-Safe** → Screenshot
settings → Find Game Window (grant Screen Recording once) → pick the game → set the chat
rectangle over the chat log → Start → talk to a quest giver (e.g. Gulemont, Port San d'Oria).
The matching section opens after two samples (10–20 s).

Copyright © 2026 Bates LLC. All rights reserved. [batesai.org](https://batesai.org) · help@batesai.org
