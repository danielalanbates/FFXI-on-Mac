// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation

/// A shared reference, not a claim that Horizon's custom rules apply on another world.
/// Keep the source route and its citations intact; progress stays separate per world.
enum ClassicSoloGuide {
    static func addingReference(to guides: [Guide]) -> [Guide] {
        guard let source = guides.first(where: { $0.name == "Solo Guide - HorizonXI" }),
              !guides.contains(where: { $0.progressID == "Solo Guide - Classic FFXI" }) else { return guides }
        var reference = source
        reference.name = "Solo Guide - Classic FFXI"
        reference.desc = "Solo EXP and gil routes for all three starting cities, with quest detours and optional NMs. "
            + "Adapted from the cited Horizon reference; check your server's mob levels, drops, quest rewards and market prices. "
            + "Not yet verified on Phoenix."
        reference.levels = "1-75 reference"
        reference.server = nil
        reference.excludedServers = ["HorizonXI"]
        reference.progressID = "Solo Guide - Classic FFXI"
        reference.legacyProgressID = nil
        reference.legacyStartingLocation = nil
        reference.preservesLegacyCompletion = false
        return guides + [reference]
    }
}
