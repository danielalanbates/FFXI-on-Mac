# Beta 100 — Artifact Armor by job

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.
[batesai.org](https://batesai.org) · help@batesai.org

Gear → Artifact Armor now opens a separate job menu, alphabetized by full job name. Each row
shows its abbreviation and piece count. Selecting a job opens only that job's artifact armor;
Jobs returns to the menu, and a piece's Back action returns to its job's list. Other gear
categories keep their existing job filter. Artifact selection does not inherit a different
job or stale search from another category.

The menu is derived from the selected server's loaded gear data, and omits jobs with no
artifact pieces in that data. The standard snapshot currently contains 105 pieces across
20 jobs. No new gear or server-specific availability was invented for this UI change.

Validation: companion release compilation, all 120 parser/catalogue/job-menu checks and
all hidden compact/expanded/shrink checks passed. The layout check now renders populated
Artifact Armor menus and a Warrior list from an explicitly supplied local data source.
Both compact previews were visually inspected. No game input, screen capture, audio or
hosted-server addon test was used. Installed launcher/runtime and the playing session are
outside this change; only the standalone guide may be refreshed in the background.

Build commands and evidence remain under Downloads. Source publication does not authorize
a public binary release or close the live local gameplay/performance gates.
