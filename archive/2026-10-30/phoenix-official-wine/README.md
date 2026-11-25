# Failed Phoenix official-launcher prototype

Archived investigation, **not a working or supported launch route**. WebView2 installed,
but its frontend crashed under the existing Wine10, CrossOver/Wine11 and native arm64
Wine11.20 runtime. Chromium compatibility flags did not resolve the failure. Do not expose
this helper as playable support or use its lock/process tests as evidence of gameplay.

The patch records the rejected launcher integration; the shell helper and offline tests are
preserved for future investigation. The active implementation is the native browser sign-in
probe described in docs/PHOENIX-NATIVE-SIGNIN.md. No login credentials, crash dumps or installed
runtime trees are part of this archive.
