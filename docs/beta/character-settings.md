# Character settings

The Settings tab manages characters for the server selected in the header. The Character
picker also has Manage Characters to open this page. Select a row to rename it, choose
Use Character to make it active, or remove it from the list. Add Character selects the
new profile. Server selection is not overridden by the launcher timer while Settings is open.

Renaming carries quest records, guide bookmarks, completion stars and food choices to the
new name. Case-only changes are supported. Duplicate names and filename collisions are
rejected before saving, including unreadable files that must not be overwritten. Renaming
the active character updates the remembered selection without resetting the current step.

Removal is reversible: the original JSON is saved atomically in the local `removed` folder
before the active file is removed. Removed records do not appear in the character picker.
Adding the same name on the same server restores its progress; the same name on another
server is independent. Removing the active profile selects another remaining character,
or leaves the picker at None yet. Settings never changes a character on the game server.

Developer checks run only when `VANAGUIDE_TEST_DIRECTORY` names an explicit fixture root.
They create and remove a UUID subdirectory there, never using the real character directory.
Tests cover add, full-progress rename, case-only rename, collisions, per-server removal,
restoration, repeated remove/restore, invalid names and unreadable existing files. Hidden
layout checks cover the Settings page at compact and expanded sizes using synthetic names.
Real character files and removed archives must never be committed or included in a release.

Support-job and BLU content in this beta: Support Jobs is one guide with a Route selector
for Selbina/Mhaura and ten steps per town. Legacy town-specific progress keeps its instruction
and unlock completion. Authored quest_solutions.lua overlays provide completion answers in
Job Unlocks without replacing generated quest data. BLU includes all ten relevant divination
choices, item clue solutions, collection conditions, the pool route and final acceptance.
The source wiki's planned-content banner does not establish current Horizon BLU availability.

Completion toggle: when a guide is completed, the final step's primary button reads Completed
instead of Done, and the Guide completed screen provides a Completed toggle button. Clicking
Completed on either view marks the guide incomplete, removes its completion star and Completed
section entry, and restores Done while preserving the saved step position.

The final-step Completed button and the completion screen's Completed button can mark the
guide incomplete again. This removes its star/list entry and restores Done while preserving
its current instruction and observed quest records.
