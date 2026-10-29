# Beta 99 source — explicit normal logout

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.
[batesai.org](https://batesai.org) · help@batesai.org

The command helper now permits plain `/shutdown` on hosted or local worlds for an explicit
owner-requested normal logout. Arguments, chained commands and control characters remain
blocked. World, install, Wine-prefix and client-ambiguity checks are unchanged. It loads no
addon and does not send gameplay commands as part of this change.

This capability is a manual CLI action. **Do not use it as automatic test preparation while
the owner is playing.** An active-play message means leave the session running and defer
local gameplay tests and launcher/runtime installation. There is no automatic logout,
app-opening loop, install watcher or public release job.

Validation: release launcher compilation and all 53 `--selftest-addons-live` fixture checks
passed, including plain logout and rejection of logout arguments/chaining. The fixtures do
not touch a game. No hosted addon test was performed. The installed launcher remains build
96 and the standalone guide build 98; beta 99 source has not replaced either app.

Continue with the [local LSB test plan](LOCAL-LSB-TEST-PLAN.md) only after active owner play
has ended. The guide's `strict-walk-verification` source adds unassisted walking checks, but
offline contracts are not evidence of a live quest route or audible narration.
