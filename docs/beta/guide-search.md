# Guide search and local beta updates

The header search replaces the window-reading control. Typing offers separate results
for monster families, named monsters (including NMs), available guides and matching steps,
gear, skills, and selected-server wiki guides. Picking a step opens its exact route/index;
picking a family opens the monster database; picking a monster opens its detail page.
Return opens the first suggestion, Escape dismisses suggestions, and × clears the query.
Search is local and does not open a browser, access the game, or mark any step completed.

Search respects guide server metadata and server-specific monster-family data. Standard
monster data is labelled as reference because private servers can change it. Rapid server
switches invalidate previous-server results while the new data loads. The public UI no
longer exposes window-reading controls or asks the user to enable recording. Existing
internal reader/replay fixtures remain available for offline development.

The combined Horizon Solo Gil guide has three Starting location options: Windurst,
San d'Oria and Bastok. They jump to each city's section without changing home nation or
quest-completion records. Each step labels its starting-city route.

User preference: install each completed VanaGuide change into the Applications companion
and reopen it once in the background. Preserve the launcher and any running game. Keep
public binary releases on the existing stable-release cadence, independently of local beta
updates. Archive the previous companion and verify the replacement's signature before launch.

Validation includes offline source assertions, production parser/search fixtures, and hidden
layout renders at compact and expanded sizes. These checks do not claim live game acceptance.
