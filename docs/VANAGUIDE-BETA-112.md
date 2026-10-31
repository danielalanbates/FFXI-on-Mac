# VanaGuide beta 112

- VanaGuide (Beta) replaces the ALPHA name in the app and launcher.
- Server reference articles live in Content: general notes in Start Here, job articles in
  Jobs, mission articles in Missions, other walkthroughs in Quests. Search opens those same
  articles directly. The separate Server tab is removed; server selection remains.
- Done records a per-character, per-guide step title in optional Codable bookmark data.
  Returning with Back shows its star. Whole-guide undo clears the final step star and leaves
  earlier steps intact. Older profiles remain readable. Identical titles within a guide share
  a marker; unique authored step IDs would improve that in a later schema revision.
- Gear NM/drop sources and monster pages display sourced NM cards. Standard LSB records are
  a fallback, not a claim of server-specific verification. Horizon Tom Tit Tat has an authored
  camp override. Missing rules/timers are not guessed.

Validation: release build, parser/progress/profile checks, offline Lua suite, compact/expanded
layout renders including Fruit Punches, static bundle manifest and code signature checks.
No hosted gameplay/addon testing. Windows download is the existing Ashita addon, not SwiftUI
GUI parity. Public packages belong in the vanaguide repository as a prerelease.
