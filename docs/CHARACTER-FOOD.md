# Character-specific starter food in Server-Safe

The food step in Starting out now offers main-job and home-nation selectors. Preferences are optional fields in each character/world progress record, so switching characters reloads that character’s choices. Missing selections show an explicit prompt rather than inferring a job from the character’s name. Only the six starting jobs are offered in this starter panel.

Melee recommendations suggest a few Meat Jerky portions. WHM/BLM advice prioritizes budgeting for MP drinks or resting, and identifies Conquest restrictions. Nation shops: Boncort in Northern San d Oria F-8 upstairs, Griselda in Bastok Mines H-5, Ness Rugetomal in Windurst Waters North F-10. Current server stock and prices still need checking in game.

Validation: an isolated harness compiled the production StarterFood helper and exact CharacterProgress declarations. Legacy JSON without profile fields decoded; profile fields survived JSON roundtrip; 18 job/nation combinations and missing-profile behavior passed. No normal character files were read or written by that harness. The full app build and new-panel layout verification remain pending.

This depends on launcher PR 81 and VanaGuide PR 38. Earlier candidate-solo-guides contains the parser changes and static guides, not this panel. Installed apps are unchanged.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

## Current-binary verification

Correction: the first parser/layout runs and candidate-solo-guides used an older binary under arm64-apple-macosx/release. Those runs do not verify the new source. The authoritative build path reported by swift build --show-bin-path is now launcher-build/out/Products/Release. Do not reuse hard-coded historical output paths.

The current release binary passed 142 parser checks against the explicit PR 38 guide root, plus all hidden layout scenarios including melee/caster food profiles at 620x460 and 1000x720. The compact caster image was visually inspected: profile selectors, shop/stock advice and bottom controls are readable. Profile field compatibility and roundtrip checks also passed. This evidence supersedes prior candidate claims.
