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

### 2.1 `ctx.mis` — `MATCH_INFO_STRUCT`

| Offset | Field |
|--------|-------|
| `+0x138` | home `TEAM_INFO_STRUCT` |
| `+0x7C8` | away `TEAM_INFO_STRUCT` (stride `0x690`) |
| team `+0x04` | `team_name[0x46]` (UTF‑8, NUL padded) |
| team `+0x4A` | `team_abbr[4]` |
| team `+0x5D8` | `SHIRTCOLOR_STRUCT players[2]` → `index, ?, color1[3], color2[3]` (kit colour) |
| team `+0x150` | `u32 squad_id[40]` — roster order, **the stat record index** |
| `+0x1078` / `+0x12D0` | `u8 xi_slot[11]` — squad index of the 11 players on the pitch |

The XI list is used to map a squad index (which is what the stat block is keyed
by) to a pitch position slot (`0..10` home, `11..21` away).

### 2.2 `match.stats()` — `SCOREBOARD_INFO`

`match.stats()` returns a *reused* table; values must be copied immediately.
Fields: `ptr`, `home_score`, `away_score`, `pk_home_score`, `pk_away_score`,
`period` (1 first half, 2 second, 3 ET1, 4 ET2, 5 shootout), `clock_minutes`,
`clock_seconds`, `added_minutes`.

Extra fields read from `ptr`:

| Offset | Field |
|--------|-------|
| `+0x20` | `is_paused` |
| `+0x22` | `is_clock_running` |
| `+0x38` | `SCOREBOARD_INFO2*` |
| `+0x120` / `+0x124` | home / away score |
| `+0x12C` / `+0x130` | clock minutes / seconds |
| `+0x144` | added minutes |
| sci2 `+0x88` | `match_stage` — `0x05` live, `0x0C` kick‑off, `0x10` shootout |

### 2.3 Per‑player stat block (private heap region `0x190000`)

The engine keeps a dedicated private region of exactly `0x190000` bytes whose
first 12 bytes are the allocator header `{ 0, 0x18FFE0, 1 }` (`u32` ×3). It is
found with `VirtualQuery` + header comparison (`m.scan_regions`).

```
record(side, idx) = region + 0x7B5C0 + side*0x59650 + idx*0x2134
stat kind k       = record + 0x08 + k*0x24,   8 × u32 (one bucket per period)
value(k)          = words[0..7] summed
```

Stat kinds used (the full table has ~0xB0 entries):

| kind | meaning | kind | meaning |
|------|---------|------|---------|
| 0 | goals | 49 | tackles |
| 1 | own goals | 50 | tackles won |
| 2 | free‑kick goals | 54 | clearances |
| 3 | penalty goals | 55 | fouls |
| 4 | **assists** | 56 | offsides |
| 6 | **shots** | 57 | yellow cards |
| 12 | shots (engine "success") | 58 | red cards |
| 17 | **shots on target** | 63 | corners |
| 21 | penalty shots | 65 / 66 | dribbles / completed |
| 22 / 23 | passes / completed | 67 | touches |
| 133 | GK saves | 78 | interceptions |
| **179** | **official match rating** — `word[0]` as IEEE‑754 `f32` (4.0–9.5) | 86 | blocks |

Two more values in the same region: the match‑time counter at `+0x7B518` and the
possession pair at `+0x181A10` / `+0x181A14`.

> The engine's own ratings (`kind 179`) are used when they read back inside
> `[1.0, 10.0]`; otherwise the module computes a composite rating from goals,
> assists, shot accuracy, pass %, tackles, dribbles, saves and touches.

### 2.4 Pitch positions (private heap region `0xF0000`)

A second private region of `0xF0000` bytes with header `{ 0, 0xEFFE0, 1 }`.
At `region + 0x253FC` there are **22 × `f32[3]`** = `(x, y, z)` in metres from
the centre spot (`x ∈ [-52.5, 52.5]`, `y ∈ [-34, 34]`), entries `0..10` = home
XI by formation slot, `11..21` = away XI by formation slot.

Sanity gate: at least 16 of the 22 entries must satisfy
`|x| ≤ 70, |y| ≤ 45, -2 ≤ z ≤ 25`, otherwise the block is treated as
"not ready" and the telemetry falls back to an estimated origin.

Attack direction: the home keeper's `x` (`|x| ≥ 25`). `x < 0` ⇒ home attacks the
`+52.5` goal.

### 2.5 Companion hand-off

`state.json` is the only interface between Lua and the HUD. The module starts
`ngb-overlay\NGB_Overlay.exe` once per session (`auto_launch_companion`),
preferring `WinExec` over FFI (instant, no console flash) and falling back to
`io.popen('start "" …')`. The HUD resolves `state.json` relative to its own
folder (`..\content\ngb-presentation\state.json`, with fallbacks), so it keeps
working whether it sits in `ngb-overlay\`, `overlay\` or the repo root.

### 2.6 `Player.bin` (`common\etc\pesdb\Player.bin`)

WESYS container: `00 01 01 "WESYS"` + `u32 compressed_size` + `u32`
`uncompressed_size` + zlib payload. Decompressed records are **312 bytes**:

| Offset | Field |
|--------|-------|
| `+8` | `u32 player_id` |
| `+27` | bits: 8 wide, `+100` → height (cm) |
| `+44` | bits: shift 6, 6 wide, `+40` → kicking power (40–99) |
| `+49` | bits: shift 4, 6 wide, `+40` → finishing |
| `+54` | bits: shift 2, 4 wide → registered position code (0 GK, 1 CB, 2 LB, 3 RB, 4 DMF, 5 CMF, 6 LMF, 7 RMF, 8 AMF, 9 LWF, 10 RWF, 11 SS, 12 CF) — *best effort, ~78 % exact* |
| `+129` | shirt number |
| `+251` | name, 60 bytes UTF‑8 |

Captured once, on the `livecpk_data_ready` event for `Player.bin`, and decoded
with Sider's own `zlib.unpack`.

---

## 3. Detection logic

`display_frame` drives a throttled tick:

```
every 200 ms   refresh match info (score, clock, stage) + team names / XI
every 6000 ms  (until found, max 3 tries) region discovery
every ~120 ms  read the 22 pitch positions
every ~350 ms  read 18 stat kinds for all 40 players of both sides
every ~100 ms  rewrite state.json
```

Each stat poll reads one contiguous `0x288`‑byte window per player (kinds 0–17)
with a single `ReadProcessMemory`, then compares `goals / own goals / assists /
shots / shots on target` with the previous snapshot. Priority per poll:
**goal > own goal > shot**. The first successful poll only establishes a
baseline (so starting the mod mid‑match never fires a burst of fake events).

* goal (`kind 0` ↑) → goal event, `outcome = "goal"`, also starts the replay
  camera window. The card itself is held back by `goal_telemetry_delay`
  (default 1.2 s) so it lands as the replay starts; the delay is stored on the
  event as `show_at` and does not shorten the card's lifetime.
* own goal (`kind 1` ↑) → goal event, `outcome = "own_goal"`, aimed at the
  scorer's *own* net.
* shot (`kind 6` ↑, no goal) → shot event; `outcome = "on_target"` when
  `kind 17` rose in the same poll, else `"off_target"`.

The `goal_scored` Sider event is used as a fallback when the stat region has not
been located yet (name comes from the payload's `player_name_on_shirt`).

Post‑match: the MOTM card is armed by either
`livecpk_data_ready` → `MatchSetupRematch.json`, or the clock stopping at/after
90′ (120′ when `period ≥ 3`, i.e. extra time) with `is_clock_running == 0`;
the card appears 2.6 s later.

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

Written to `content\ngb-presentation\state.json` at `state_write_hz` (10 Hz).
Small (~1.5 KB) so a reader can never be more than one frame behind.

```json
{
  "v": 2, "seq": 842, "ts": 918273,
  "module": "Next-Gen Broadcast", "version": "1.0.1",
  "hud": { "enabled": true, "master": true, "style": 0, "analysis": true,
           "units": "metric", "scorebug": false,
           "credit": "MOONFROS PRESENTS", "author": "MoonFros",
           "tagline": "Next-Gen Football Broadcast Presentation",
           "toast": { "text": "HAT-TRICK  |  B. SAKA", "kind": "milestone",
                      "seq": 12, "hold": 4.5 } },
  "status": { "ffi": true, "stats_region": true, "pitch_region": true,
              "camera": true, "player_db": true, "names": "Player.bin",
              "events": 17, "overlay_visible": true,
              "style": 0, "analysis": true },
  "match": { "clock": "72:14", "period": 2, "stage": 5, "live": true,
             "home": { "name": "ARSENAL", "abbr": "ARS", "score": 2, "color": "#EF0107" },
             "away": { "name": "CHELSEA", "abbr": "CHE", "score": 1, "color": "#034694" } },
  "event": {
    "id": 17, "kind": "goal", "remaining": 12.4, "duration": 13, "side": "home",
    "player": { "name": "B. SAKA", "shirt": 7, "pos": "RWF", "rating": 8.4,
                "minutes": 68, "minutes_exact": true },
    "team":   { "name": "ARSENAL", "abbr": "ARS", "color": "#EF0107" },
    "stats":  { "shots": 4, "on_target": 3, "goals": 3, "assists": 1, "ga": 4 },
    "milestone": { "key": "hat_trick", "label": "HAT-TRICK", "tone": "gold" },
    "assist":    { "name": "M. ODEGAARD", "shirt": 8 },
    "shot":   { "speed_kmh": 119.4, "speed_mph": 74.2, "speed_source": "modelled",
                "distance_m": 16.8, "distance_yd": 18.4, "distance_source": "measured",
                "angle_deg": 22.6, "elevation_deg": 8.4, "apex_m": 1.9, "apex_ft": 6.2,
                "hang_s": 0.92, "xg": 0.24, "outcome": "goal", "body": "right_foot",
                "source": "measured", "target_x": 1.2, "target_y": 1.4,
                "origin_x": 36.0, "origin_y": 9.0,
                "traj": [[36.0, 9.0, 0.0], "..."] }
  }
}
```

`event.kind` is `"goal"`, `"shot"` or `"motm"`; the block is absent when nothing
is on screen. `event.remaining` is `0` while a goal card is held back by
`goal_telemetry_delay`, so the overlay does not pop the card early. MOTM events
add `event.motm = { score_line, stats: {…} }` with passes, pass %, tackles,
dribbles, touches, saves, interceptions, peak_mph and xg.

> `speed_*` is always `"modelled"` (FL25 exposes no measured ball speed) while
> `distance_*` is `"measured"` whenever the shooter's real position was
> available. The overlay prints `~` in front of modelled numbers and states it in
> the card footer - nothing modelled is ever presented as measured.

`event.kind` is `"goal"`, `"shot"` or `"motm"`; `event` is absent when nothing is
on screen. MOTM events add `event.motm = { score_line, stats: {…} }` with passes,
pass %, tackles, dribbles, touches, saves, interceptions, peak_mph and xg.

The HUD animates from `event.remaining`, not from wall clocks, so a 10 Hz writer
never stutters the cards.

---

## 7. Re‑calibration guide

If a future game build moves things, `debug_log = 1` tells you exactly what was
found. Order of attack:

1. **Stats / pitch regions** — pinned with 12‑byte headers. If the scan fails,
   the header changed. Find the new header/offset with a memory scanner, update
   `REGION_STATS_SIZE`, `OFF.REC_BASE`, `OFF.PITCH_BLOCK` in
   `NGB_Presentation.lua`. You can also pin the base addresses directly:
   ```ini
   stats_region_base = 0x7E0000
   pitch_region_base = 0x7B0000
   ```
2. **Stat kinds** — if shots no longer rise, the `KIND` table changed; the
   engine exposes ~0xB0 kinds and the mapping is in the table at the top of the
   file.
3. **Replay camera** — add/replace a pattern in `CAM_PATTERNS` (literal bytes +
   `check()` returning the float offset relative to the match start + the
   expected default). The scan validates the value, so a wrong pattern is
   harmless: it simply finds nothing.
4. **Player.bin** — if names stop resolving, verify the WESYS magic and the
   312‑byte record size; the field offsets live in the `P.*` constants.

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
