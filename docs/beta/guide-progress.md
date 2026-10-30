# Per-character guide bookmarks and completion

Every Content guide saves its current instruction in the selected character/server record.
Switching guides, reopening the window or restarting the app restores the saved instruction.
Guide-name search results resume a bookmark; exact step results deliberately open that step.
Back, Done, Next Unfinished, city selection and achievement links all use the same save path.
Saved titles let an inserted step move the bookmark without moving the player to unrelated text;
removed instructions fall back to a bounded index. Older character JSON loads without new fields.

Done on the final route step records completion, adds a gold star to the right of the guide,
adds it to the expandable Completed category and updates the guide counter. Only after the
save succeeds does the view dismiss its own window. Closing the companion window does not
signal the launcher or game. Reopening a completed guide keeps its star and saved position;
reviewing earlier instructions does not revoke completion. Repeated final clicks do not create
duplicate completed records. A failed final save leaves the window open and displays an error.
Quest/mission completion records retain their existing keys and remain separate from guide stars.

Branching routes persist the chosen starting city. Other city branches do not count as route
steps and are skipped in either direction; shared camps keep the origin selection. This supports
the Horizon Solo Gil itinerary without turning Windurst completion into a Bastok selection.

Validation: pure production-state fixtures cover switching, intermediate/final Done, repeated
completion, JSON round-trip, legacy JSON, another character, inserted/removed steps, branching,
and a simulated save failure. Hidden compact/expanded renders check star and Completed placement.
These tests do not alter a real character file or close the user's live window.

Unified Horizon guide: a data-provided `progress_id` keeps the former Gil itinerary's stable
identity across its display-name change. A `legacy_progress_id` lets native EXP bookmarks
resume at the corresponding level band for the chosen starting city. A completed EXP-only
record does not automatically award completion of the expanded itinerary. Existing Gil
bookmarks take precedence, and the old EXP record remains intact. Header completion counts
are restricted to guides still visible in the selected server's catalogue.
