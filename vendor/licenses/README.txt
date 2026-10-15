Third-party notices for FFXI on Mac

FFXI on Mac is Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
Its own licence is in LICENSE (PolyForm Noncommercial 1.0.0 + commercial rider).

The app bundles the third-party components below. Each keeps its own licence; the
full texts are the other files in this folder.

d3d8to9 v1.15.1 (https://github.com/crosire/d3d8to9)
  Ships as: d3d8to9.dll (unmodified)
  Licence:  BSD 3-Clause, Copyright (C) 2015 Patrick Mours -> d3d8to9-BSD-3-Clause.txt

DXVK 1.10.3 (https://github.com/doitsujin/dxvk)
  Ships as: dxvk-1.10.3-x32-d3d9-horizonxi.dll
  MODIFIED: built with this project's patch (patches/dxvk-1.10.3-horizonxi-fencewait.patch);
            it is not the original DXVK release.
  Licence:  zlib/libpng, Copyright (c) 2017-2021 Philip Rebohle, (c) 2019-2021 Joshua Ashton
            -> DXVK-zlib.txt

MoltenVK 1.4.2 (https://github.com/KhronosGroup/MoltenVK)
  Ships as: libMoltenVK-1.4.2.dylib (unmodified release binary, re-signed)
  Licence:  Apache License 2.0 -> MoltenVK-Apache-2.0.txt
  Contains, statically linked: SPIRV-Cross and SPIRV-Tools (Khronos, Apache License 2.0, same
            text) and cereal (https://github.com/USCiLab/cereal, BSD 3-Clause, Copyright (c)
            2013-2022 Randolph Voorhies, Shane Grant) -> cereal-BSD-3-Clause.txt

x87sidecar (https://github.com/athei/x87sidecar)
  Ships as: x87sidecar-coop, x87sidecar_entitled
  MODIFIED: x87sidecar_entitled adds an attach-by-pid mode (patches/x87sidecar-attach-pid.patch);
            x87sidecar-coop carries a changed Rosetta pattern for macOS 27.
  Licence:  MIT, Copyright (c) 2025 Lifeisawful -> x87sidecar-MIT.txt

The bundled Vanaguide and VanaVoice addons are Bates LLC's own; their licences are in
their folders (Resources/Vanaguide/LICENSE, Resources/vanavoice/LICENSE).
