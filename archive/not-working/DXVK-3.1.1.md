# DXVK 3.1.1 — does not work on MoltenVK (2026-09-26)
DXVK 2.x/3.x require the Vulkan `geometryShader` feature. MoltenVK 1.4.2 does not expose it, so DXVK logs
"Skipping: Device does not support required feature 'geometryShader'" / "No adapters found" and the client
terminates at startup. Keep DXVK 1.10.3 (patched) with MoltenVK 1.4.2.
