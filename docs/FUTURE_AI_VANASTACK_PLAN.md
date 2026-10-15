# FUTURE_AI_VANASTACK_PLAN — HorizonXI / VanaVoice / Vanaguide

**Author:** FFXI agent exploration pass  
**Date:** 2026-09-17 (PT)  
**Machine target:** Daniel Bates Mac `a2ec4a3d-2cdc-4ac8-b04a-84dde1993a37`  
**Source of truth for this write-up:** public GitHub mirrors (`danielalanbates/HorizonXI-on-Mac`, `danielalanbates/vanaguide`) + `Narration.swift` / `Addons.swift` / `LocalServer.swift` / `RELEASE-WHEN-STABLE.md`.  
**Gap:** VanaVoice source tree (`github.com/danielalanbates/vanavoice`) and live iCloud trees were **not** readable this pass (repo 404/private; Mac `machineId` Shell/Read did not route from this executor). Re-confirm live iCloud vs mirror deltas on next Mac-connected pass.

**Hard constraints (standing):**
- Do not use Mac GUI; do not launch games; do not connect to hosted FFXI servers.
- Do not break/replace `/Applications/HorizonXI.app` or `/Applications/VanaVoice.app` — keep playable.
- Addon testing **only** on local LandSandBoat (`127.0.0.1`). Never load under-test addons on HorizonXI / CatsEyeXI / FFEra.
- Keep product names **VanaVoice** and **Vanaguide**.

---

## 1. Current inventory

### 1.1 Paths (expected on Mac)

| Role | Preferred (iCloud live) | GitHub / mirror |
| --- | --- | --- |
| Launcher tree | `…/CloudDocs/Code/HorizonXI-on-Mac` | `github.com/danielalanbates/HorizonXI-on-Mac` (+ `…/Code/GitHub/HorizonXI-on-Mac`) |
| VanaVoice | `…/CloudDocs/Code/VanaVoice` | Expected `danielalanbates/vanavoice` (**private / not fetchable this pass**) |
| Vanaguide | `…/CloudDocs/Code/Vanaguide` | `github.com/danielalanbates/vanaguide` |
| Zygor reference | `…/CloudDocs/Code/Zygor Replacement` | Interaction model also mirrored by CompletionRoute / `openroute` (WoW) — cited by Vanaguide README |
| LSB docs | `…/Code/Game_Server_Horizon_FFXI`, `…/Code/Game_Servers` | Launcher: `scripts/lsb-server.sh`, `LocalServer.swift` |
| Playable apps | `/Applications/HorizonXI.app`, `/Applications/VanaVoice.app` | Bundle via `app/bundle.sh`; weekly GitHub `.app` cadence |

### 1.2 HorizonXI-on-Mac — addon integration

| Piece | Path / mechanism | Notes |
| --- | --- | --- |
| Managed script blocks | `addons/default.txt` markers `--HORIZON_PLUGINS_*--` / `--HORIZON_ADDONS_*--` | `AddonSuite` (`Addons.swift`) rewrites only between markers |
| Shipped / recommended loads | `addons/default.txt` | Plugins: Addons, Deeps, Minimap, Nameplate, PacketFlow, Sequencer, Thirdparty (+ winefix outside UI). Addons: mousediag, friendlist, allmaps, chains, chatmon, … (no vanavoice/vanaguide in **shipped** default) |
| Repo addons tree | `addons/{FFXIFriendList,fpslog,gmtools,lslog,mousediag}`, `addons/lsb2.ini.example` | Friendlist is large Ashita addon; gmtools is LSB/GM-only |
| Policy gate | `AddonPolicy.swift`, `docs/ADDON-POLICY.md` | Allowlist servers hide/forbid unlisted; local LSB = unrestricted |
| Narration wiring | `Narration.swift` | Copies `/Applications/VanaVoice.app/Contents/Resources/vanavoice` → `addons/vanavoice`, appends `/addon load vanavoice` **outside** AddonSuite markers; launches menu-bar app; **blocked on allowlist worlds** |
| Local LSB | `LocalServer.swift` + `scripts/lsb-server.sh` | Client → `127.0.0.1`; root default `~/Games/lsb` |
| Local-world extras | `LocalWorldAddons` in `Addons.swift` | Can fetch SQLCommit/GMTools for LSB only |
| cmdpipe / mouse / signatures | HorizonXI-on-Mac patches + docs (cited by Vanaguide `DRIVING_THE_CLIENT.md`) | Command/chat wire for bot harness; Ashita pointer fix for packet inject |

**Does the launcher already load VanaVoice / Vanaguide?**  
- **VanaVoice:** Yes, *when* narration enabled **and** policy allows **and** `/Applications/VanaVoice.app` present — via `Narration.prepare` (not via the HORIZON_ADDONS block). On HorizonXI/CatsEyeXI allowlists it is **explicitly removed**, not offered.  
- **Vanaguide:** **No** first-class launcher wiring found in public mirror (no `Vanaguide.swift` twin of `Narration.swift`; not in `addons/default.txt`). Install is manual (`vanaguide/tools/install.sh`) / LSB-only policy.

### 1.3 VanaVoice status (from launcher docs + Vanaguide harness notes)

| Area | Status | Evidence |
| --- | --- | --- |
| Product shape | Separate menu-bar app + Ashita Lua addon | `Narration.swift`: OCR needs Screen Recording; TTS stays up when launcher closed; IPC dir `/tmp/vanavoice` |
| Bundle id | `org.batesai.vanavoice` | `Narration.launchNarrator` |
| Addon install | Copied from app Resources each launch | Avoids stale addon vs new app |
| Text capture | Chat / dialogue sink (not DAT packets) | `DRIVING_THE_CLIENT.md`: NPC words come from client DATs once event opens; VanaVoice reads chat; event-block silences narrator |
| Dedup need | Open | Same doc: 0x032 retransmit → triplicate lines; dedupe on `(speaker, text, second)` |
| Hosted servers | **Forbidden** by design | Not on allowlists; Balloon cited as approved dialogue path on HorizonXI |
| Generic narrator for *all* cutscene/NPC text | **Partial / goal** | Works when event+chat path fires; menus/cutscene edge cases still open (`/vg pick` untested beyond option 0) |

### 1.4 Vanaguide status (public repo, v0.2.0)

| Area | Works | Stubbed / open |
| --- | --- | --- |
| Guide viewer + auto-complete | `core/progress.lua`, `conditions.lua` | Generated quests often need fame/prereqs |
| Server truth | Packet `0x056` quest/mission log (`core/story.lua`) | Mid-quest mostly KI; MSG tags proposed |
| Arrow + distance | `ui/arrow.lua` (ImGui foreground; DXVK-safe) | Yaw calibration may need `/vg arrow flip` |
| Travel routing | Dijkstra `routing/zonegraph.lua` + learned zone lines | Seed graph incomplete; dump-learned not shipped |
| Guide library | 506 quests / 459 missions generated + hand guides | Content still thin vs Zygor; GPL adapters external |
| Guided bot run | `tools/guided_run.sh` on **LSB only** | Teleports; no walk automation (deliberate) |
| Mouse UI | Commands `/vg load N` etc. | ImGui click broken on Mac port (`MOUSE.md`) |
| Hosted servers | Documented ban risk | Launcher must not offer on allowlist worlds |

### 1.5 Zygor Replacement — interaction model (reference)

Vanaguide explicitly positions itself as “Zygor for Vana’diel,” modeled on the author’s WoW **CompletionRoute** (`openroute`) pattern:

| Zygor-like capability | How Vanaguide talks to the world |
| --- | --- |
| Step list + auto-tick | Reads **server-sent** quest/mission state (packet `0x056`), not memory hacks for completion |
| Waypoint arrow | Client-side draw only (ImGui lines); bearing from player pos/yaw vs step coords |
| Travel graph | Zone graph + airship/ferry edges; learns zone lines from play |
| No botting | **No** movement, targeting, casting, or arbitrary packet spam for play; harness injects talk/advance **only on LSB** with documented packet facts |
| External guide corpora | Prefer runtime adapter to player-installed licensed data (same CompletionRoute ↔ Zygor/WoW-Pro shape) |

Live Mac folder `Code/Zygor Replacement` should be treated as the offline reference dump for UX/step language — re-open on next Mac-connected pass.

### 1.6 LSB / private local testing (no secrets)

| Item | Value (non-secret) | Secret location (gitignore) |
| --- | --- | --- |
| Client connect | `127.0.0.1` | — |
| Default root | `~/Games/lsb` (`LSB_ROOT`) | — |
| Processes | `xi_connect`, `xi_search`, `xi_world`, `xi_map` (+ Homebrew mariadb) | Logs under `$LSB_ROOT/run/` |
| DB name / user | `xidb` / `xiuser` | Password file **`$LSB_ROOT/.dbpass`** (chmod 600); written into LSB SQL settings at setup |
| Game accounts | Created on first login to local world | Launcher account store: `~/Library/Application Support/HorizonXI-on-Mac/accounts.json` (mode 600); boot profiles `config/boot/*.ini|*.xml` (**gitignored**) |
| Control script | `scripts/lsb-server.sh` `{status,setup,start,stop}` | Do not commit `.dbpass`, boot profiles, or `accounts.json` |

**Is LSB runnable locally?** Yes, by design: launcher “Local server (LandSandBoat)” → setup/build (~12 GB) → Play starts server + client to loopback. This pass did **not** execute setup/start (no games / no Mac shell).

### 1.7 RELEASE-WHEN-STABLE + weekly `.app` cadence

From `RELEASE-WHEN-STABLE.md` (standing directive 2026-08-17, cadence clarified 2026-08-22):

- Ship official GitHub release only when **definitively stable** (cold boots, mouse, wine reaper, max settings FPS, real play sessions).
- **Local** `/Applications/…app` must stay playable always; rebuild/reinstall as fixes land; never replace while running.
- **Public** `.app`: at most ~**once a week**, and only if stable — cadence is a ceiling, not an obligation.
- Fold diagnostic fixes out of `mousediag` before shipping.

### 1.8 `.gitignore` personal-info coverage

| Repo | Coverage | Gaps / tighten |
| --- | --- | --- |
| HorizonXI-on-Mac | Ignores `config/boot/*`, harness shots/results, `archive/app-builds/`, logs | Confirm live tree also ignores `accounts.json`, Keychain leftovers, `~/Games/lsb/.dbpass` (outside repo — OK). Consider explicit ignore for any accidental `.dbpass` / `accounts.json` copies under repo |
| vanaguide | Ignores `marks.txt`, settings/config, `Vanaguide/data/nav/`, logs | Good for character names; keep `results/` intentional or move large PNGs out of default clone if needed |
| VanaVoice | **Not inspected** (repo private) | On next pass: ensure OCR dumps, voice cache, `/tmp` copies, API keys, Screen Recording artifacts are ignored |

---

## 2. Architecture pathways

```
┌─────────────────────┐     prepare()      ┌──────────────────────┐
│ HorizonXI-on-Mac    │ ─────────────────► │ VanaVoice.app        │
│ Narration.swift     │  copy addon +      │ menu bar + TTS       │
│ AddonPolicy gate    │  /addon load line  │ reads /tmp/vanavoice │
└─────────┬───────────┘                    └──────────▲───────────┘
          │ Ashita scripts/default.txt                │ chat/dialogue
          ▼                                           │ lines from Lua
┌─────────────────────┐                    ┌──────────┴───────────┐
│ Ashita + game       │ ── packets 0x056 ► │ vanavoice.lua addon  │
│ (Wine / DXVK)       │ ── chat events ──► │ (+ optional OCR)     │
└─────────┬───────────┘                    └──────────────────────┘
          │
          │  (LSB only / unrestricted policy)
          ▼
┌─────────────────────┐     arrow/UI       ┌──────────────────────┐
│ vanaguide.lua       │ ◄────────────────► │ ImGui arrow/window   │
│ story/progress/     │                    │ routing/zonegraph    │
│ guide format        │                    └──────────────────────┘
└─────────┬───────────┘
          │ tools/guided_run.sh + cmdpipe (LSB bot)
          ▼
┌─────────────────────┐
│ LandSandBoat @      │
│ 127.0.0.1 + GM cmds │
└─────────────────────┘
```

**Pathway A — Generic narrator:** deepen Ashita chat/event capture → robust dedupe → optional Balloon-compatible mode for allowlist servers; keep OCR as fallback requiring Screen Recording only in VanaVoice.app.  
**Pathway B — Sequential quest guide:** expand hand + generated guides; tighten KI/MSG conditions; keep arrow; optional world-space marker experiment under DXVK.  
**Pathway C — Launcher wiring:** mirror `Narration.swift` as `Guide.swift` for Vanaguide (LSB/unrestricted only); never install on allowlist worlds.  
**Pathway D — Bot LSB testing:** `guided_run.sh` + `cmdpipe`; human-gated; no auto-loop that owns the Mac; no hosted targets.

---

## 3. Risks

| Risk | Mitigation |
| --- | --- |
| **Hosted-server ban** | Policy gate already in launcher; never enable VanaVoice/Vanaguide on HorizonXI/CatsEyeXI/FFEra; bot harness LSB-only |
| **`.app` playability** | Never overwrite `/Applications/*.app` while processes live; archive prior builds; local rebuild ≠ GitHub release |
| **Weekly GitHub cadence** | Do not cut releases mid-experiment; fold mousediag fixes first; verify cold-boot checklist |
| **Allowlist drift** | Re-diff horizonxi.info / CatsEye / FFEra lists before any release that touches addons UI |
| **Packet inject / automation optics** | Keep inject harness out of shipping addons; document “no automation” for approval asks |
| **Secrets leak** | `.dbpass`, boot profiles, `accounts.json` never committed; audit VanaVoice `.gitignore` |

---

## 4. Recommended names

Keep **VanaVoice** (narrator) and **Vanaguide** (quest guide). Do not rename for marketing in this phase — launcher, bundle ids, and docs already use them.

---

## 5. Next 5 implementation tasks (ordered)

1. **Mac-connected inventory delta** — With `ListMachines` + `machineId` Shell, confirm iCloud trees vs GitHub; open private VanaVoice tree; audit Zygor Replacement folder; verify `/Applications/VanaVoice.app` Resources layout and whether Vanaguide is already installed into any game `addons/`.
2. **VanaVoice generic narrator v1** — In vanavoice.lua: de-dupe `(speaker,text,second)`; cover NPC/cutscene chat sinks; document OCR vs packet/chat modes; add offline fixture tests; **no** allowlist-server enablement.
3. **Vanaguide sequential quest MVP** — One hand-authored multi-step starter guide with POS/NPC/KI conditions; verify arrow advance without `!completequest` crutches; expand MSG/KI condition tags.
4. **Launcher `Guide` wiring (LSB-only)** — **Done in source (2026-09-17 PT).** `Guide.swift` + toggle + Runner hook; refuse/scrub on allowlist. Apply to live iCloud tree / open PR next.
5. **LSB bot harness hardening** — Wrap `guided_run.sh` as a **manual**, single-guide, timeout-bounded job: requires explicit start, writes `results/`, never targets hosted IPs, never loops unattended overnight, never launches if playable `.app` session detected.

---

---

## Progress (2026-09-17 PT, Guide wiring pass)

| Item | Status |
| --- | --- |
| `Guide.swift` (LSB / unrestricted only) | **Done** in source — mirrors `Narration.swift` safety model |
| Pref + UI toggle | **Done** — `PerfSettings.enableVanaguide`, Setup & Diagnostics |
| `Runner.launch` calls `Guide.prepare` | **Done** |
| Docs | **Done** — `docs/VANAGUIDE.md`; ADDON-POLICY note; this Progress block |
| `.gitignore` secrets | **Done** — `accounts.json` / `.dbpass` on HorizonXI-on-Mac + Vanaguide |
| Live iCloud tree apply | **Blocked this executor** — Mac `machineId` Shell not routed; apply clone branch / patch on Mac |
| `/Applications/*.app` | Untouched (source-only) |
| VanaVoice `.gitignore` audit | Still open (private repo) |
| Push / PR | Prefer parent: commit ready on branch; no force-push |

**Enable on LSB:** Local server world → toggle Quest guide → Play. Source: `Code/Vanaguide/Vanaguide` or `Downloads/Vanaguide`.

## 6. How bot testing should work (LSB only)

| Rule | Detail |
| --- | --- |
| Target | Only LandSandBoat via launcher local world / `127.0.0.1` |
| Entry | Human or agent starts **one** `tools/guided_run.sh <guide>` (or successor); no cron / no while-true |
| Side effects | Use GM helpers (`!where`, `!checkquest`, …) only on local GM chars; prefer packet path that matches player Enter |
| Observation | Screenshots + `RESULTS.md` under `vanaguide/results/`; read `~/Games/lsb/run/xi_map.log` |
| Mac ownership | No GUI takeover; no auto-relaunch loops; abort if `pgrep` shows active player session in HorizonXI/VanaVoice you did not start for the test |
| Hosted servers | Hard fail if world ≠ local / host ≠ loopback |
| Playable apps | Do not replace `/Applications/*.app` as part of a test; use existing playable builds |

---

## 7. Top gaps (this pass)

1. **No live Mac filesystem confirmation** (machineId routing unavailable to this executor).  
2. **VanaVoice source not readable** (private/404) — TTS engine, OCR, event-flag details inferred only.  
3. **Vanaguide not launcher-wired** yet.  
4. **Zygor Replacement folder** unread on disk.  
5. **`.gitignore` for VanaVoice** unverified.

---

*End of plan. Pointers: VanaVoice/docs and Vanaguide/docs should link here.*
