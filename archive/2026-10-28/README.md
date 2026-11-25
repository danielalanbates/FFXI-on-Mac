# Retired detached-spawn implementation

The pre-beta82 `Detach.spawn` implementation at `87a5a02` removed its temporary script as
soon as osascript returned a background PID. The background shell had not necessarily opened
that script yet. A PID could be reported even though the updater probe never ran; the updater
self-test caught missing arguments and PATH output on October 27.

Beta82 makes the child remove its own script after opening it, creates the file owner-only,
quotes both the shell and AppleScript layers, and refuses a failed working-directory change.
It preserves the tested AppleScript ancestry rather than repeating the direct-posix_spawn
external-drive failure recorded in `docs/LAUNCH-DEATH.md`.

The old implementation is preserved in Git:
`git show 87a5a02:app/Sources/HorizonXILauncher/Detach.swift`.
Do not restore the parent-side deletion or world-readable launch scripts.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org
