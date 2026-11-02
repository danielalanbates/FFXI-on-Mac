# Phoenix guide selection and shared solo reference — beta 123

## Behavior

The companion's 30-second refresh repeatedly selected the world in the launcher's session.json.
A manual Phoenix XI selection therefore reverted to a stale HorizonXI session after leaving
Settings. The companion now consumes each changed launcher world once and persists the last
observed value. A manual world remains selected across timer ticks and companion restarts.
An actual later change to the launcher's world is still followed. On migration, an existing
saved companion world wins over an old, previously unobserved session. A brand-new companion
with no world adopts the launcher world. Missing session data does not clear either selection.
World changes also clear the old zone before restoring the newly selected character's zone.

Phoenix XI is included in the offline fallback server list. The launcher-supplied list remains
authoritative when available.

Solo Guide - Classic FFXI is a shared manual reference derived from the existing sourced
Horizon route. It retains the three starting-city branches, separate EXP and gil goals,
quest detours, optional NMs and source links. It is available outside Horizon; Horizon retains
its original entry without a duplicate. Starting out, Support Jobs, Job Unlocks and the
quest/mission references remain available as before. No expansion availability is inferred.

The shared route is explicitly a reference: Horizon mob levels, drops, quest rewards and
market prices have not been verified on Phoenix. Its progress ID has no Horizon legacy
aliases; character records remain separated by world. Future work can replace individual
steps with researched server-specific overrides without weakening the general server filter.
Do not simply expose every Horizon-only guide to every world.

## Workspace and dependencies

Base project: Google Drive Code/HorizonXI-on-Mac and its workspace handoff. The handoff says
the recovered Downloads workspaces supersede the stale Drive checkout. This fix uses a clean
Downloads worktree from e98263f, leaving unrelated party-guide drafts untouched.

Before changes, official GitHub release metadata was rechecked: athei/wine-build
arm64-11.20-5 (2026-10-30), KhronosGroup/MoltenVK v1.4.2 (2026-07-24). The earlier same-day
Software Update audit reported no updates. No Wine, Rosetta, game data, graphics policy or
runtime dependency is changed by this companion fix.

## Validation and delivery

Run the companion parser suite with VANAGUIDE_ROOT pointing at the existing static addon
data and VANAGUIDE_TEST_DIRECTORY pointing at private Downloads fixtures. Tests cover stale
session polling, restart persistence, actual launcher world transitions, first-run selection,
shared reference visibility, distinct progress keys, all three 30-step branches and gil search.
Run hidden layout checks and strict/deep code-signature verification on the packaged beta.
These checks do not start a client or test an addon on a hosted server.

Install only the standalone /Applications/VanaGuide Server-Safe.app. The current launcher's
companion resolver selects the newest compatible standalone or embedded build, so beta 123
supersedes embedded beta 122 without replacing the running playable launcher. Archive the
previous standalone under Downloads before replacement. Do not change the embedded helper
or playable launcher while the hosted game is active. Reopen the companion once in the
background with Phoenix XI selected. Public release binaries/tags remain unchanged; this is
a local beta and source PR, not verified gameplay or a stable public release.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org
