# Vanagear

**Gear swapping for Final Fantasy XI that you set up from your in-game macros.**
No Lua profile to write, no `Sets.Precast = {...}` tables to hand-maintain.

Every other swapper for Ashita — LuAshitacast, Ashitacast, kupocast, miniswap —
asks you to author a profile file outside the game. That is why most players end
up copying somebody else's 900-line job file and editing it blind. Vanagear
turns it around: **you wear the gear, and a macro saves it.** The addon writes
its own profile and never asks you to open it.

```
Wear your TP set.        /vgear save tp
Wear your Sturmwind set. /vgear save ws.sturmwind over tp
Done. Swing away — it swaps on its own.
```

---

The command is **`/vgear`**, with `/vanagear` and `/gs` as aliases. (Not `/vg` —
that belongs to [Vanaguide](https://github.com/danielalanbates/vanaguide), and
two addons answering the same slash command means whichever loaded last wins
while the other silently stops responding.)

## Install

Ashita v4 only.

1. Copy the `vanagear` folder into `<Ashita>\addons\` so you have
   `<Ashita>\addons\vanagear\vanagear.lua`.
2. Add `/addon load vanagear` to `<Ashita>\scripts\default.txt`, or type it once.

> **Check your server's rules first.** Most private servers publish an addon
> allowlist and loading something that is not on it is a bannable offence.
> Vanagear is new and is on nobody's list yet. Ask before you load it.

Profiles are written to `<Ashita>\config\addons\vanagear\<Character>_<JOB>.lua`,
one per character per main job. They are the addon's business, not yours.

## The five minutes that set it up

Equip what you want to idle in, then, from a macro or the chat bar:

| Macro line | What it does |
| --- | --- |
| `/vgear save idle` | what you wear when nothing is happening |
| `/vgear save tp` | what you wear while engaged |
| `/vgear save ws over tp` | your generic weaponskill set — `over tp` stores only the slots that differ |
| `/vgear save ws.sturmwind over ws` | one weaponskill's exceptions |
| `/vgear save precast over idle` | fast cast |
| `/vgear save midcast.cure iv over idle` | one spell's gear |

That is the whole workflow. Wear it, name it, forget it.

## What fires when

Vanagear watches your outgoing actions and picks sets **generic first,
specific last**, merging as it goes — so a specific set only has to name the
slots it actually changes.

Any of these names can carry a `:token` suffix — see **Conditions** below.

| you do | sets applied, in order |
| --- | --- |
| standing around | `idle` |
| resting | `idle` → `resting` |
| engaged | `idle` → `tp` |
| casting Fire IV | ... → `precast` → `precast.elemental magic` → `precast.fire iv`, then the same three under `midcast` |
| Sturmwind | ... → `ws` → `ws.great axe` → `ws.sturmwind` |
| Berserk | ... → `ja` → `ja.berserk` |
| ranged attack | ... → `preshot`, then `midshot` |
| using an item | ... → `item` → `item.<name>` |

Anything you never save is simply skipped. Save nothing but `idle` and that is
all that ever happens.

`/vgear why` prints exactly which sets were considered and which ones matched for
the last thing you did. It is the answer to "why am I wearing that".

## The panel

`/vgear hud` opens a window that does everything the macros do, for the parts
macros are bad at: seeing every set at once, checking a set against what you
still own, and fixing one slot without retyping its name.

- **Set list** on the left, with a filter box, and a name field that saves what
  you are wearing as a new set.
- **Selected set** on the right, one row per slot. Each row is coloured by
  whether that item is still in your bags — green if you have it, green with
  *(on fallback)* if the first choice is gone, **red** if nothing in the list is
  findable, grey for slots the set leaves alone.
- **`worn`** on any row writes what you currently have in that slot into the
  set. **`x`** clears the row. That is the whole editing story, with no typing.
- **Equip / Overwrite from worn / Duplicate / Delete** across the top.
- **Modes** as buttons — one click per build, the active one bracketed.
- **Switches** for `auto`, `precast`, `equipset`, `debug`, and a grid of the 16
  slot locks.
- **Why** shows the sets considered and matched for the last thing you did.

The window remembers whether it was open. Everything it does is also a macro
command, so you never have to open it.

## Conditions

A set name can carry any number of `:token` suffixes, and it only applies while
every one of those tokens is true. That is the same mechanism modes use, so
there is nothing new to learn:

```
/vgear save tp:hp25            what to wear once you drop below 25% HP
/vgear save idle:moving        movement gear, worn only while you are moving
/vgear save ws:tp3000          the weaponskill set for a full TP bar
/vgear save tp:sub-nin         a WAR/NIN set, ignored on WAR/WAR
/vgear save midcast.stone:acc  one spell, one mode
/vgear save ws.rampage:acc:tp3000
```

`/vgear tokens` lists what is true this second — that is the discoverability
story, and the panel has the same list under **Conditions**, with a `*` beside
every conditional set showing whether it could fire right now.

Tokens available: any mode value you create, plus `hp25 hp50 hp75`,
`mp25 mp50 mp75` (at or below), `tp1000 tp2000 tp3000` (at or above), `moving`,
and `sub-<job>`. Turn the automatic ones off with `/vgear conditions off`.

When several conditional sets match, the one that demanded the most wins the
slots it names, and the shallower ones still contribute theirs. Resolution walks
the sets you actually saved rather than enumerating combinations, so having
forty conditions live at once costs nothing.

## Modes

Modes are how one job carries an accuracy build, a defensive build and a normal
build without three copies of everything.

```
/vgear mode offense acc        creates the group if it is new, and switches to it
/vgear save tp:acc             the accuracy version of the TP set
/vgear cycle offense           bind this to a macro and flip builds mid-fight
/vgear modes                   what exists, and what is on
```

With `offense = acc` active, every lookup tries `<set>:acc` before `<set>`, all
the way down the chain, so `ws.sturmwind:acc` beats `ws.sturmwind` beats `ws`.
Modes stack: with two groups on, `tp:acc:dt` wins over `tp:acc`.

## Every command

```
capture   /vgear save <set> [over <base>]        /vgear naked
edit      /vgear set <set> <slot> <item>         /vgear add <set> <slot> <fallback item>
          /vgear clear <set> [slot]
manage    /vgear list [filter]   /vgear show <set>   /vgear copy <a> <b>
          /vgear rename <a> <b>  /vgear del <set>
use       /vgear equip <set>     /vgear refresh      /vgear why
modes     /vgear mode <group> <value>   /vgear cycle <group>   /vgear modes
locks     /vgear lock <slot>     /vgear unlock <slot>          /vgear locks
conds     /vgear tokens       (what is true right now)
panel     /vgear hud [on|off]    (aliases: /vgear gui, /vgear panel)
switches  /vgear auto|precast|equipset|conditions|debug [on|off]   /vgear status
```

Slot names: `main sub range ammo head body hands legs feet neck waist ear1 ear2
ring1 ring2 back`, plus the obvious aliases (`cape`, `belt`, `shield`, `boots`,
`gloves`, ...).

Useful details:

- **`/vgear add`** gives a slot a fallback list: `/vgear add ws.sturmwind head Optical
  Hat` after a `set` makes it "Optical Hat, or the first one of these I still
  own". Sets survive losing gear.
- **`/vgear lock main`** freezes a slot. Nothing Vanagear does will ever swap it —
  the standard fix for a weapon you do not want touched mid-TP.
- **`remove`** as an item name empties the slot.
- **`/vgear equip <set>`** is the manual escape hatch, for macro lines you want to
  drive yourself. It holds off the automatic base set for three seconds; if you
  want it to stick indefinitely, that is what `/vgear auto off` is for.

## The switches, and why you might want them off

| switch | default | what turning it off does |
| --- | --- | --- |
| `auto` | on | stops all automatic swapping. Only `/vgear equip` works. |
| `precast` | on | stops Vanagear holding your action packet. Gear still swaps, but a beat late, so fast cast and weaponskill gear will not count. Slower, and the safest possible mode. |
| `equipset` | on | sends one swap packet per slot instead of a single batched one. Slower and noisier; try it if a server dislikes the batched form. |
| `conditions` | on | stops deriving hp/mp/tp/movement/sub-job tokens. Sets named after them stop applying; your own modes keep working. |
| `debug` | off | prints every decision to the log. |

## How it swaps

- **Precast** works by blocking your outgoing action packet, queueing the equip
  packets, and re-sending the action behind them in the same frame. The server
  therefore processes the swap before the action. This is the same mechanism
  every swapper uses; `/vgear precast off` opts out of it.
- **Midcast** lands on the following frame, and the base tick is held off for
  the length of the cast so it cannot overwrite midcast gear mid-spell.
- **Aftercast is not decoded at all.** Instead the base set is re-asserted on a
  half-second tick, and nothing is sent unless a slot genuinely differs. That
  makes the whole thing self-healing: it recovers from zoning, death, a manual
  swap, or a missed packet without any special case for each.
- Swaps are batched into a single equipset packet when more than one slot
  changes.
- Items are matched by name across inventory and all wardrobes, and checked
  against your job, level, race, and the slot. **A failed check only demotes a
  candidate, never eliminates it** — if every candidate fails, the first one you
  actually own is equipped anyway. A wrong bitmask must never be able to leave
  you standing there naked.

## Testing

`tests/run.lua` runs the entire addon against a fake Ashita — inventory,
resources, packets and all — with no game and no Windows:

```
luajit tests/run.lua      #  97 assertions against hand-built fixtures
luajit tests/corpus.lua   #  85 assertions against the real game data
```

`tests/corpus.lua` is the one that matters. `tools/fetch_corpus.py` pulls
LandSandBoat's published SQL — the same tables the server runs — and generates
a fixture of **15,522 equippable items, 928 spells, 200 weaponskills and 623 job
abilities**. The suite then drives the engine over all of it: every spell's
precast and midcast chain, every weaponskill, every ability, a full simulated
play session on all 21 jobs, and 2,000 randomly generated sets checked against
invariants (never two items in one slot, never one item in two slots, never a
locked slot, never a malformed packet, never an item in a slot it cannot go in).

It has already paid for itself: the slot mask used to be advisory, and the
random sweep showed that meant equipping items into slots the server would just
reject. It is a hard gate now, while job, level and race stay advisory.

It covers the rule chain, set merging, item resolution (duplicates,
fallbacks, level and job gates), packet layout for both `0x50` and `0x51`,
slot locks, the precast block-and-resend order, and every macro command. The
panel is exercised only far enough to prove it cannot crash the addon when
ImGui is absent — what it looks like on screen is unverified.

### What has been verified in the game

Run 2026-08-23 against a local LandSandBoat server, Ashita v4 under Wine on
macOS. Verified, with the evidence in `docs/`:

- The addon loads, and writes its profile to
  `config/addons/vanagear/<Character>_<JOB>.lua`.
- `/vgear save idle` captured the four equipped pieces by their real item names.
- `/vgear naked` stripped every slot, and the base tick put the whole `idle` set
  back on five seconds later, unprompted — the equip packets are accepted by the
  server and the self-healing tick does what it is supposed to.
- The panel draws, resolves each slot against the bags, and colours them.
  ![the panel in game](docs/img/panel-in-game.png)
- The panel responds to a real mouse: clicking **Copy** created a new set on
  disk, and clicking a set in the list selected it.
  ![selecting a set with the mouse](docs/img/panel-set-selected-by-mouse.png)

Still unverified in game: precast/midcast interception on a real cast,
weaponskill and ability sets, modes, and the fallback/red-item paths. Those are
next, and `docs/PATHWAYS.md` has the run written out.

## Licence

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
PolyForm Noncommercial 1.0.0 — free for players — with a 10% revenue royalty
for commercial use. See [LICENSE](LICENSE).

<https://batesai.org> · help@batesai.org

Unofficial fan project. FINAL FANTASY XI is a trademark of Square Enix
Holdings Co., Ltd. Not affiliated with or endorsed by Square Enix or any
server operator.
