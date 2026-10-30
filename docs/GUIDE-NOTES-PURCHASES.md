# Preserve note and purchase steps in Server-Safe

The standalone parser silently discarded N (note) and B (buy) instructions, including introductory budget advice. It now accepts both verbs and retains their notes/item tags.

Validation: compiled the real GuideParser.swift with a standalone Foundation harness. It loaded Starting out (9 steps), Solo EXP - HorizonXI (8), and Horizon Solo Gil guides for San d Oria (138), Bastok (177), and Windurst (51) from VanaGuide PR 38. Note text and buy-step item tags passed explicit checks. Matching checks are included in --selftest-parser. Full app build, layout and installed-bundle update remain pending. No game or installed app changed.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

Release verification: VanaguideCompanion release build succeeded on 2026-10-30 (60.95 seconds), with one missing cached SwiftShims module warning. The newly built binary passed all --selftest-parser checks with VANAGUIDE_ROOT explicitly pointing at the PR 38 library. Layout, character-dependent standalone presentation and installation remain pending.
