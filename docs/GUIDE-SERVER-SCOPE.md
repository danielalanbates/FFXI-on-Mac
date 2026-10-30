# Server-scoped authored guides

Guide registration supports an optional server field. Server-Safe parses it as data, normalizes case/spacing, and restricts scoped guides to the selected world. Unknown worlds do not inherit a scoped guide. Unscoped general guides remain available.

Filtering applies to the guide list, selected detail, initial guide selection and confirmed screenshot navigation. Original guide indices are preserved, so matching and progress references remain aligned. The four Horizon solo guides declare server=HorizonXI in VanaGuide PR38. Existing server wiki data already loads from the selected server folder. Addon-side enforcement is not added by this companion change.

Validation: compiled the real GuideParser.swift against the actual guide library. All four Horizon guides load with metadata, accept HorizonXI/Horizon XI, reject CatsEyeXI/unknown world, and retain Starting out as a general guide. Full companion build and UI verification remain pending.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

Release verification: clean snapshot build succeeded in33.29s. Current binary passed147 parser checks and hidden layouts. Signed candidate-alpha-scoped bundled the latest scoped guides and BST/BLM camp notes; its packaged binary passed the same parser suite using its own bundled root. Installed standalone transactionally, previous archived, reopened once in background. Launcher/game were not signalled. Installed launcher and its embedded guide remain unchanged while the hosted session runs.

Beta build104: incremented bundle version because keeping standalone at103 tied the older embedded helper, which wins ties. Build104 lets the installed launcher’s existing newest-compatible-copy rule select the updated standalone. No public release is implied.
