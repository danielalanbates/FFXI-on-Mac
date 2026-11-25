# One Horizon solo guide

`Solo Guide - HorizonXI` is the single Horizon route for leveling and earning gil. It retains
the three starting-city branches, shared 1–75 coverage, quest detours and optional NM camps.
Every leveling step stores separate `EXP` and `GIL` tags and renders them as labelled bullet
points. Extra travel/safety instructions remain in the step note. Goal text remains searchable.
The old EXP/Gil guide registrations and active EXP generator were removed/archived.

Native progress uses the data-provided `progress_id`, retaining the old Gil bookmark and
completion star despite the renamed guide. An EXP-only bookmark maps by its level band and
chosen starting city; it does not automatically complete the extra quests/NM itinerary.
An existing Gil bookmark takes precedence. Source metadata parsing matches whole field names,
so `progress_id` cannot accidentally read `legacy_progress_id`.

Validation: Lua source checks for one menu registration, goal fields, aliases and full city
routes; native parser, objective search and bookmark migration fixtures; hidden compact and
expanded bullet-layout renders; and a signed package with a complete static-data manifest.
Local beta 107 is installed through the existing one-shot companion replacement workflow.

Completion UI follow-up: beta 108 keeps the app window open and shows a completed-guide
screen on final Done, with stars and Review buttons. Existing completion/bookmark data is
retained. This supersedes earlier wording about dismissing the whole companion window.
