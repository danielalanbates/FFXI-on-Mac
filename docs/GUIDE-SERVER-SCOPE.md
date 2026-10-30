# Server-scoped authored guides

Guide registration supports an optional server field. Server-Safe parses it as data, normalizes case/spacing, and restricts scoped guides to the selected world. Unknown worlds do not inherit a scoped guide. Unscoped general guides remain available.

Filtering applies to the guide list, selected detail, initial guide selection and confirmed screenshot navigation. Original guide indices are preserved, so matching and progress references remain aligned. The four Horizon solo guides declare server=HorizonXI in VanaGuide PR38. Existing server wiki data already loads from the selected server folder. Addon-side enforcement is not added by this companion change.

Validation: compiled the real GuideParser.swift against the actual guide library. All four Horizon guides load with metadata, accept HorizonXI/Horizon XI, reject CatsEyeXI/unknown world, and retain Starting out as a general guide. Full companion build and UI verification remain pending.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org
