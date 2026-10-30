# Character-specific starter food in Server-Safe

The food step in Starting out now offers main-job and home-nation selectors. Preferences are optional fields in each character/world progress record, so switching characters reloads that character’s choices. Missing selections show an explicit prompt rather than inferring a job from the character’s name. Only the six starting jobs are offered in this starter panel.

Melee recommendations suggest a few Meat Jerky portions. WHM/BLM advice prioritizes budgeting for MP drinks or resting, and identifies Conquest restrictions. Nation shops: Boncort in Northern San d Oria F-8 upstairs, Griselda in Bastok Mines H-5, Ness Rugetomal in Windurst Waters North F-10. Current server stock and prices still need checking in game.

Validation: an isolated harness compiled the production StarterFood helper and exact CharacterProgress declarations. Legacy JSON without profile fields decoded; profile fields survived JSON roundtrip; 18 job/nation combinations and missing-profile behavior passed. No normal character files were read or written by that harness. The full app build and new-panel layout verification remain pending.

This depends on launcher PR 81 and VanaGuide PR 38. Earlier candidate-solo-guides contains the parser changes and static guides, not this panel. Installed apps are unchanged.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org
