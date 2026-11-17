# Technical reference

Everything the mod reads, how it derives the broadcast graphics, and how to
re‑calibrate it for a different `FL_2025.exe` / `PES2021.exe` build.

Target build: **`FL_2025.exe` v1.0** (SmokePatch Football Life 2025) and
**PES 2021 v1.7.x**. Sider **7.3.4**, LuaJIT 2.1, x64.

---

## 1. Sider module environment (why the code looks the way it does)

Sider 7.3.4 loads `modules\*.lua` with `luaL_loadbuffer`, sets a **sandbox
environment**, and then calls the returned table's `init(ctx)`. The sandbox
contains only:

```
assert table pairs ipairs string math tonumber tostring unpack error
_VERSION type io collectgarbage jit
os.time os.clock os.date
log input memory fs audio match zlib
(+ ffi and bit when luajit.ext.enabled = 1)
```

Consequences that shape the module:

| Fact | Consequence in `NGB_Presentation.lua` |
|------|--------------------------------------|
| `pcall`, `xpcall`, `require`, `select`, `next` are **absent** | no defensive `pcall` anywhere; every read returns `nil` on failure and every call site checks |
| the module must **return a table with `init`** | `local m = {} ... return m` |
| each registered callback lives in a *second* `lua_State` owned by Sider | handlers are stored as fields of `m` (`m.on_display_frame`, …) and never as local closures, so the module table can never be collected |
| `memory.read` is a raw `ffi.string` dereference | invalid addresses would crash the game; the mod reads through **`ReadProcessMemory`**, which returns 0 instead of raising an access violation |
| `ffi` only exists with `luajit.ext.enabled = 1` | the module degrades to "no live stats" and says so in `sider.log` |
| `ffi.cdef` is global to the LuaJIT state | struct/typedef names are prefixed `NGB_`, Win32 entry points are declared with `__asm__` aliases, and the guard flag is stored on the shared `ffi` table so a Sider hot‑reload cannot redefine a struct |

Declarations used (all aliased, no collisions with other modules):

```c
typedef struct NGB_MBI { void*BaseAddress; void*AllocationBase;
    uint32_t AllocationProtect; uint16_t PartitionId; uint64_t RegionSize;
    uint32_t State; uint32_t Protect; uint32_t Type; } NGB_MBI;   /* 48 bytes */

uint64_t NGB_GetTickCount64(void)   __asm__("GetTickCount64");
void    *NGB_GetCurrentProcess(void) __asm__("GetCurrentProcess");
int      NGB_ReadProcessMemory(void*, const void*, void*, size_t, size_t*)
    __asm__("ReadProcessMemory");
size_t   NGB_VirtualQuery(const void*, void*, size_t) __asm__("VirtualQuery");
int      NGB_VirtualProtect(void*, size_t, uint32_t, uint32_t*)
    __asm__("VirtualProtect");
```

---

## 2. Data sources

The 1.1.0 rewrite sorts every source into three tiers, and only tier 1 is
trusted unconditionally. The rule behind the whole design: **a number is either
read from the game or it is not shown.**

### Tier 1a. Sider's match library - `match.stats()`

`match.stats()` is Sider's own reader for the game's scoreboard. It returns a
*reused* table, so values are copied immediately. Available fields: `ptr`,
`home_score`, `away_score`, `pk_home_score`, `pk_away_score`, `period`
(1 first half, 2 second, 3 ET1, 4 ET2, 5 shootout), `clock_minutes`,
`clock_seconds`, `added_minutes`.

It only exists when `sider.ini` contains `match-stats.enabled = 1`; the module
checks the ini at `init`, reports `ENGINE OFF -> add match-stats.enabled = 1`
in the Sider overlay when the line is missing, and keeps working in
hook-only mode otherwise.

Extra fields the module reads from the returned `ptr` (verified against the
Sider source, not guessed):

| Offset | Field |
|--------|-------|
| `+0x20` | `is_paused` |
| `+0x22` | `is_clock_running` |
| `+0x38` | `SCOREBOARD_INFO2*` |
| `+0x120` / `+0x124` | home / away score |
| `+0x12C` / `+0x130` | clock minutes / seconds |
| `+0x138` / `+0x144` | injury time flag / added minutes |
| sci2 `+0x88` | `match_stage` - `0x05` live, `0x0C` kick-off, `0x10` shootout |

`m.refresh_match()` runs at 5 Hz, writes `m.eng.home/away/clock/period` and
stamps `m.eng.last_ok`. `m.data_source()` returns `"sider"` while that stamp is
younger than 4 s, else `"none"` - so the HUD can say plainly whether the engine
is talking.

### Tier 1b. Sider's goal hook - `goal_scored`

```
{ player_id, player_offset, home_or_away, player_name_on_shirt }
```

This is the only event in the whole Sider API that carries a player, and it fires
on the frame a goal is scored. `m.on_goal_scored` stores
`m.goal_hook = { side, pid, name, minute, at }` and `m.goal_from_hook()` turns it
into a `goal` event carrying `player_known = true`, the shirt name, the minute
from the scoreboard clock and the score line.

Consequences that are *by design*:

* the hook cannot report shots, assists or saves - Sider has no such event, so
  the mod never claims shots from it;
* when the hook does not fire, the card is drawn **unnamed** (`DrawGoalBare`)
  rather than attaching the goal to a guessed player.

### Tier 1c. Scoreboard fallback - `watch_scoreboard`

A 5 Hz watcher compares the scoreboard total with the last one it saw:

* score jumped and a hook arrived within the same tick → hook card (named);
* score jumped with no hook → `goal_fallback`: an unnamed card with the minute
  and the new score line, which still starts the replay window;
* score went *backwards* (a goal disallowed by VAR/replay) → the tally and the
  scorer list are re-baselined, and nothing is announced.

`watch_period` does the same for the period field: period 1 → 2 raises a
`half_time` result card, period → 5 marks the shootout, and the clock stopping at
or after 90' (120' with extra time) raises a `full_time` card.

The mod also keeps its own goal log: `m.eng.goal_log[] = { name, side, minute,
kind }`, used for the half/full-time scorer list and for per-player tallies
(brace / hat-trick), so a milestone count is a count of goals actually seen, not
an estimate.

### Tier 2. The per-player statistics table - off until it validates

Shots, shots on target, passes, ratings, assists and engine minutes live in a
per-player table in the game's private heap. **Its location is build-specific.**
The previous version trusted a fixed layout and produced `0 shots / 0 min /
id #0` for every scorer on builds where the layout had moved. 1.1.0 keeps the
reader but treats the layout as a *candidate*:

```ini
experimental_player_stats = 0   ; must be 1 before the reader is even polled
probe_enabled = 0               ; writes probe.txt with the raw evidence
```

The candidate layout (private region of `0x190000` bytes, allocator header
`{0, 0x18FFE0, 1}`):

```
record(side, idx) = region + 0x7B5C0 + side*0x59650 + idx*0x2134
stat kind k       = record + 0x08 + k*0x24,   8 x u32 (one bucket per period)
value(k)          = words[0..7] summed
```

Stat kinds used: 0 goals, 1 own goals, 3 penalty goals, 4 assists, 6 shots,
17 shots on target, 22/23 passes/completed, 55 fouls, 57/58 cards, 67 touches,
133 GK saves, 179 official rating (`word[0]` as `f32`).

`m.validate_stats()` decides whether the table is real, and is the only thing
that can switch tier 2 on:

| Check | Rule |
|-------|------|
| readable | at least 20 players give plausible values |
| ordering | per player `shots >= on_target` |
| bounds | goals / assists / passes within sane ranges |
| coverage | `Σ goals + own goals >= scoreboard goals + PK goals` |
| coverage | `Σ shots >= scoreboard goals + PK goals` |

Until it passes, `m.player_stats_ok()` is false and the HUD draws no stat cells
at all. It re-validates every 5 s until it passes, then every 30 s (a table that
stops making sense goes back off by itself).

### Tier 3. Pitch positions (used only with tier 2)

A second private region (`0xF0000` bytes, header `{0, 0xEFFE0, 1}`) holds
22 x `f32[3]` at `+0x253FC`: `(x, y, z)` in metres from the centre spot,
`0..10` home XI by formation slot, `11..21` away. Gate: 16 of 22 entries must
satisfy `|x| <= 70, |y| <= 45, -2 <= z <= 25`. Shot distance and angle are
derived from the shooter's real position, so they inherit tier 2's gating.

### Companion hand-off

`state.json` is the only interface between Lua and the HUD. The module starts
`ngb-overlay\NGB_Overlay.exe` once per session (`auto_launch_companion`),
preferring `WinExec` over FFI (instant, no console flash) and falling back to
`io.popen('start "" ...')`. The HUD resolves `state.json` relative to its own
folder (`..\content\ngb-presentation\state.json`, with fallbacks), so it keeps
working whether it sits in `ngb-overlay\`, `overlay\` or the repo root.

### `Player.bin` (`common\etc\pesdb\Player.bin`)

WESYS container: `00 01 01 "WESYS"` + `u32 compressed_size` +
`u32 uncompressed_size` + zlib payload. Decompressed records are **312 bytes**:

| Offset | Field |
|--------|-------|
| `+8` | `u32 player_id` |
| `+27` | bits: 8 wide, `+100` -> height (cm) |
| `+44` | bits: shift 6, 6 wide, `+40` -> kicking power (40-99) |
| `+49` | bits: shift 4, 6 wide, `+40` -> finishing |
| `+54` | bits: shift 2, 4 wide -> registered position code |
| `+129` | shirt number |
| `+251` | name, 60 bytes UTF-8 |

Captured once, on the `livecpk_data_ready` event for `Player.bin`, and decoded
with Sider's own `zlib.unpack`.

---

## 3. Detection logic

`display_frame` drives a throttled tick (8 ms floor):

```
every 200 ms   refresh_match(): scoreboard score, clock, period, stage, teams
every 200 ms   watch_scoreboard() + watch_period(): goals, HT, FT, shootout
every 200 ms   refresh_match reads the scoreboard through match.stats()
every 120 ms   pitch positions                      (tier 2 only)
every 350 ms   per-player stat kinds                (tier 2, validated only)
every 5 s      tier-2 validation while not yet passed, then every 30 s
every 100 ms   rewrite state.json (state_write_hz = 10)
```

Goal flow in full:

```
goal_scored hook ─┐
                  ├─> m.goal_hook / m.goal_fallback ─> event(kind="goal",
scoreboard jump ──┘                                      show_at = now + delay,
                                                         player_known = …)
                                                              │
                                     DrawGoalCard (stats) or DrawGoalBare
```

The card is held back by `goal_telemetry_delay` (1.2 s default) so it lands as the
replay starts; the delay lives on the event as `show_at` and does not shorten the
card's lifetime. Starting the mod mid-match never fires a burst: the first
scoreboard read only establishes a baseline.

Every tick writes `status.clock` and `status.data.source`, so the overlay and the
Sider overlay agree on whether the engine is talking.

---

## 4. Shot telemetry maths

Origin: the shooter's live `(x, y)`; goal centre `(±52.5, 0)`, posts at
`y = ±3.66`, crossbar `2.44 m`.

```
dist   = hypot(goal_x - x, 0 - y)
angle  = |atan2(+3.66 - y, dx) - atan2(-3.66 - y, dx)|          (radians)
xG     = clamp(1 / (1 + exp(-(-1.1 + 1.4*angle - 0.075*dist))), 0.02, 0.95)
```

Launch speed from the shooter's real kicking power `kp` and range:

```
v0 = (20.5 + (kp - 40) * 0.28) * (1 + clamp((dist - 11)/30, 0, 1) * 0.22)   [m/s]
```

Elevation is the **low‑angle ballistic solution** that reaches the chosen
goal‑face target `(target_x, target_y)`:

```
k    = g*dist² / (2 v0²)
disc = dist² - 4k(target_y + k)
tanθ = (dist - sqrt(disc)) / (2k)          (disc < 0 → raise v0 by 12 %)
apex = (v0 sinθ)² / (2g)     hang = dist / (v0 cosθ)
```

Trajectory: 16 points `(x, y, z)` in pitch metres, written to `state.json` and
drawn as a side elevation in the goal card.

The goal‑face target is deterministic per player/minute (FNV‑1a hash), so a
replay always shows the same numbers, and it is constrained by the outcome:

| outcome | target |
|---------|--------|
| goal / own goal | inside the posts, 0.15–2.25 m high |
| on target | inside the posts, 0.20–2.10 m high |
| off target | 55 % wide (3.9–6.2 m), 45 % over the bar (2.7–4.6 m) |

`state.json` → `event.shot.source` is `"measured"` when the shooter's real
position was available and `"estimated"` when a fallback origin was used.

---

## 5. Replay camera

`ReplayCam` values are found by scanning the executable's PE sections for
instruction patterns and verifying the **current float value**:

| name | pattern (invariant part) | float at | default |
|------|--------------------------|----------|---------|
| `rheight0` | `C7 45 ?? CD CC CC 3E` + `F3 41 0F 58 C0 F3 0F 11 45` | match+3 | `0.4` -> `0.34` |
| `rheight3` | `F3 0F 58 E0 F3 0F 11 46 14 C7 46 10 66 66 A6 3F` | match+12 | `1.3` -> `1.05` |
| `rzoom` | `C7 46 30 C3 F5 28 3F` | match+3 | `0.66` -> `0.62` |

Only a value that reads back as the expected constant (±0.001) is accepted, so a
wrong match is impossible. Sections are read in 4 MB chunks with a 32‑byte
overlap through `ReadProcessMemory`; the scan runs once at module init.

During a goal replay the module eases the three floats from the exact baseline
they had at startup to the preset target (1.2 s ease‑in, slow sinusoidal drift,
0.9 s ease‑out), writes at most every ~50 ms, and only when the value changed by
more than 0.0015. `context_reset`, the end of the window, or disabling the
feature restores the baseline values. Nothing is written outside goal replays.

---

## 5b. Presentation logic (spotlight, milestones, minutes, toasts)

### Spotlight cards

One model feeds every card. `player_snapshot(side, idx)` returns the player's
identity *and* his live totals in a single pass; the card renderers never read
the engine themselves. `event.kind` selects the surface:

| `event.kind` | Card |
|--------------|------|
| `goal` | spotlight + shot analysis (or spotlight only when `hud.analysis` is false) |
| `shot` | spotlight only, outcome label `ON TARGET` / `OFF TARGET` / `BLOCKED` / `SAVED` |
| `motm` | gold Man of the Match reveal |

`hud.style` (0 full, 1 compact, 2 minimal) is applied by the overlay: compact
shrinks the cards ~15 % and drops the analysis column; minimal renders a single
slim line with `G / A / S / OT`.

### Milestones

Computed from the scorer's own goal counter after the event fires:

| goals for this player | badge | tone |
|---|---|---|
| 1st of the match (and match total == 1) | `OPENER` | accent |
| 1st of the match (later in the match) | `FIRST GOAL` | accent |
| 2 | `BRACE` | accent |
| 3 | `HAT-TRICK` | gold |
| 4 | `4 GOALS` | gold |
| 5+ | `N GOALS` | gold |

A hat-trick also pushes a toast. Own goals never carry a milestone.

### Assist attribution

`detect_events` scans all 80 stat records every poll. A goal is attributed an
assist only when **exactly one** player on the scoring side has his assist
counter rise in the *same* poll. Zero or several candidates and the card simply
omits the assist - it never guesses.

### Minutes played

The engine has no per-player minutes counter, so `m.seen[pid]` records the match
minute at which each player was first observed on the pitch:

* the whole XI is checked every 2 s (`note_xi_seen`), so starters are recorded at
  `00:00` and are exact;
* an event also records its player, which is how a substitute is first seen.

`minutes = clock - first_seen`, and `minutes_exact` is true only when
`first_seen == 0`. The overlay prints `~` when it is not exact.

### Toast channel

Toasts (`hud.toast = {text, kind, seq, hold}`) are deliberately separate from
`event`, so a notification can appear while a card is on screen:
`assist`, `milestone`, `style`, `toggle`, `info`. The overlay re-arms on a new
`seq` and hides the toast when its own clock passes `hold`, so nothing sticks.

### Hotkeys

| key | config key | action |
|---|---|---|
| `7` | `hotkey_prev_style` (0x37) | cycle full -> compact -> minimal |
| `8` | `hotkey_toggle_overlay` (0x38) | presentation on / off |
| `9` | `hotkey_toggle_analysis` (0x39) | shot analysis on / off |

`F7` / `F8` / `F9` are never registered, and key `1` is untouched (Sider's
`overlay.vkey.next-module`). With `hotkeys_overlay_only = 1` the digits only act
while `now_ms() - m.overlay_seen < 1500` - i.e. while Sider's overlay is open -
so the game keeps its own 7 / 8 / 9 keys during play. Every action confirms with
a toast and is reflected in `hud.style` / `hud.master` / `hud.analysis`.

### Overlay window hotkeys

The companion itself registers only `F10` (demo), `F11` (diagnostics) and `F12`
(quit) - the presentation keys belong to the game, not to the overlay.

---

## 5c. Installer / uninstaller

`install.bat` is self-contained (no dependencies beyond Windows):

1. **Locate Sider** - `%~1` (drag & drop), `..\sider.ini`, `%HERE%\sider.ini`,
   then every drive letter against a list of common Football Life / PES install
   paths (`Football Life 2025`, `Games\...`, `FL2025`, `Sider`,
   `Program Files\...`, `SteamLibrary\steamapps\common\...`). If none match it
   asks and validates the folder (`sider.ini` required, `sider.dll` reported).
2. **Copy** `modules\NGB_Presentation.lua` + `.ini` and `ngb-overlay\`. Nothing
   else in the Sider folder is written; `ngb-overlay\install_info.txt` records
   where it was installed.
3. **Configure** `sider.ini` through `_ngb_ini.ps1` (PowerShell 5.1, present on
   every Windows 10/11): it inserts `luajit.ext.enabled = 1` (or flips a `0` to
   `1`) and `lua.module = "NGB_Presentation.lua"` next to the existing
   `lua.module` lines, writes `sider.ini.ngb.bak` first, and never rewrites the
   rest of the file. If PowerShell is blocked the installer falls back to Notepad
   + clipboard and then verifies with `findstr`.
4. **Build + start** the overlay by calling `ngb-overlay\Start_NGB_Overlay.bat`.
5. **Confirm** on screen and in `install_log.txt`.

`uninstall.bat` asks for confirmation (`choice`), stops `NGB_Overlay.exe`,
deletes only `modules\NGB_Presentation.*`, `ngb-overlay\` (verified by the
presence of `NGB_Overlay.cs`) and `content\ngb-presentation\`, then removes only
this mod's `lua.module` line from `sider.ini` (and the marker comment added with
it). `luajit.ext.enabled = 1` is intentionally left in place: it may be shared
with other modules and Sider offers no record of who enabled it.
Other mods and settings are untouched.

---

## 6. `state.json`

Written to `content\ngb-presentation\state.json` at `state_write_hz` (10 Hz),
about 2 KB, so a reader is never more than one tick behind. Schema version **3**.

```json
{
  "v": 3, "seq": 842, "ts": 918273,
  "module": "Next-Gen Broadcast", "version": "1.1.0",
  "hud": { "enabled": true, "master": true, "style": 0, "analysis": true,
           "units": "metric", "scorebug": true,
           "credit": "MOONFROS PRESENTS", "author": "MoonFros",
           "tagline": "Next-Gen Football Broadcast Presentation",
           "toast": { "text": "HAT-TRICK  |  B. SAKA", "kind": "milestone",
                      "seq": 12, "hold": 4.5 } },
  "status": {
    "ffi": true, "stats_region": false, "pitch_region": false,
    "camera": true, "player_db": true, "names": "Player.bin",
    "events": 17, "overlay_visible": true, "style": 0, "analysis": true,
    "data": { "scoreboard": "sider", "clock": "sider", "player_stats": false,
              "scorer_hook": true, "match_stats_ini": true,
              "shots": 0 }
  },
  "match": { "clock": "72:14", "period": 2, "stage": 5, "live": true,
             "score_line": "ARS 2 - 1 CHE", "pk_home": 0, "pk_away": 0,
             "home": { "name": "ARSENAL", "abbr": "ARS", "score": 2, "color": "#EF0107" },
             "away": { "name": "CHELSEA", "abbr": "CHE", "score": 1, "color": "#034694" } },
  "scorers": [ { "name": "B. SAKA", "side": "home", "minute": 12, "kind": "goal" },
               { "name": "K. HAVERTZ", "side": "home", "minute": 55, "kind": "goal" },
               { "name": "C. PALMER", "side": "away", "minute": 61, "kind": "goal" } ],
  "event": {
    "id": 17, "kind": "goal", "remaining": 0, "duration": 13, "show_at": 918000,
    "side": "home", "minute": 55, "player_known": true,
    "score_line": "ARS 2 - 1 CHE", "detail": "goal",
    "player": { "name": "B. SAKA", "shirt": 7, "pos": "RWF", "rating": 8.4,
                "minutes": 68, "minutes_exact": true },
    "team":   { "name": "ARSENAL", "abbr": "ARS", "color": "#EF0107" },
    "tally":  { "goals": 2 },
    "milestone": { "key": "brace", "label": "BRACE", "tone": "gold" },
    "score":  { "home": 2, "away": 1 },
    "stats":  { "shots": 4, "on_target": 3, "goals": 2, "assists": 1, "ga": 3 },
    "shot":   { "speed_kmh": 119.4, "speed_source": "modelled",
                "distance_m": 16.8, "distance_yd": 18.4, "distance_source": "measured",
                "angle_deg": 22.6, "xg": 0.24, "outcome": "goal", "source": "measured" }
  }
}
```

Event kinds and their guarantees:

| `event.kind` | When | Always present | Conditional |
|---|---|---|---|
| `goal` | hook or scoreboard jump | `minute`, `score_line`, `score`, `side`, `milestone`, `tally` | `player` + `stats` + `shot` only when `player_known` **and** tier 2 validated |
| `fulltime` | period change / clock stop | `result` (`half_time` / `full_time`), `score_line`, `scorers[]` | `pk` in a shootout |
| `shot` | tier 2 only | - | everything: shots, on/off target, telemetry |
| `motm` | full time, tier 2 only | `motm.score_line` | full stat block |

A `goal` event with `player_known = false` is drawn by `DrawGoalBare`: "GOAL",
the minute, the score line and "SCORER NOT AVAILABLE". That is deliberate - the
alternative is the v1.0.1 behaviour, which printed a plausible-looking player
with zeros.

`scorers[]` is the mod's own goal log and is what the half-time and full-time
cards read.

> `speed_*` is always `"modelled"` (FL25 exposes no measured ball speed);
> `distance_*` is `"measured"` only when the shooter's real pitch position was
> available. The overlay prints `~` in front of modelled numbers and says so in
> the card footer.

The HUD animates from `event.remaining`, not from wall clocks, so a 10 Hz writer
never stutters the cards. `event.remaining` stays `0` while `show_at` is in the
future, which is how a goal card is held back for the replay without the overlay
popping it early.

---

## 7. Calibrating tier 2 on a new build

`experimental_player_stats` and `probe_enabled` are the whole toolchain; there is
no manual address hunting required to *start*, and no guessing ever reaches the
screen.

1. Set both keys to `1` in `NGB_Presentation.ini`, start a match.
2. `content\ngb-presentation\probe.txt` is written on every goal and on the
   diagnostics hotkey: scoreboard values (score, clock, period, stage), a
   hexdump of the scoreboard block, and the private regions found by the
   `VirtualQuery` header scan. `sider.log` carries the same lines prefixed
   `[NGB]`.
3. The overlay's F11 diagnostics panel prints the tier-2 verdict line
   (`PLAYER DATA ok/off`, plus why it failed).
4. If the table moved, update the candidate constants in
   `NGB_Presentation.lua`: `REGION_STATS_SIZE`, `OFF.REC_BASE`, `OFF.REC_STRIDE`,
   `OFF.SIDE_STRIDE`, `KIND`. The base can also be pinned directly:
   ```ini
   stats_region_base = 0x7E0000
   pitch_region_base = 0x7B0000
   ```
5. Restart, score a goal. When validation passes, the stat row appears on goal
   cards by itself and the shot/miss/save cards start firing.

Replay camera (unrelated to tier 2): add or replace a pattern in `CAM_PATTERNS`
(literal bytes plus a `check()` that returns the float offset and the expected
default). A wrong pattern is harmless - it finds nothing and the camera is left
untouched.

---

## 8. Performance

* `ReadProcessMemory` traffic at 1080p/60 fps with a live match: ~80 reads of
  672 B per 350 ms (≈ 150 KB/s) plus 22 position floats per 120 ms.
* Region discovery is a one‑time `VirtualQuery` walk (a few ms) per match.
* The LuaJIT garbage footprint is kept low: hot loops read numbers straight out
  of a static `ffi` buffer and never build intermediate strings.
* The HUD renders only when there is something on screen and repaints a DIB
  section through `UpdateLayeredWindow` — no per‑frame bitmap allocation.

---

## 9. Branding and credits

The mod is an original **MoonFros** creation. `MOONFROS PRESENTS` and
`created by MoonFros` are carried in:

* `modules/NGB_Presentation.lua` (`m.BRAND`, `m.AUTHOR`, the in-game overlay
  text and `hud.credit` / `hud.author` in the state file),
* the `.ini` header,
* the overlay cards (`hud.credit` footer) and the toast corner mark,
* `README.txt`, `install.bat` (banner + completion message), `uninstall.bat`,
* `tools/verify_mod.py`, which fails if the branding is removed.

`tools/verify_mod.py` also asserts that the module never registers `F7` / `F8` /
`F9` and that the three digit hotkeys are present.

---

## 10. References

* Sider 7 module API — `doc/scripting.html`, `memlib`/`memory.lua`, `fslib`
* nesa24 cameras — `ReplayCam.lua` patterns (`rheight0`, `rheight3`, `rzoom`)
* PES 2021 / FL 2025 memory research — stat kinds and record stride
  (`0x7B5C0`, `0x59650`, `0x2134`), pitch block (`0x253FC`), `Player.bin`
  bit‑packed layout
