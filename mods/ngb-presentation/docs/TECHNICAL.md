# Technical reference

Everything the mod reads, how it derives the broadcast graphics, how the
renderer hooks the game, and how to re-calibrate it for a different
`FL_2025.exe` / `PES2021.exe` build.

Target: **`FL_2025.exe`** (Football Life 2025) and **PES 2021 v1.7.x**,
Sider 7.x, LuaJIT 2.1, x64, Direct3D 11.

> 2.0 note: this document describes the current architecture. The 1.x version
> claimed Sider 7.3.4 and a Win32/`ReadProcessMemory` based module; both are gone.
> Section 1 says exactly what replaced them and why.

---

## 1. Sider module environment (why the code looks the way it does)

Sider 7 loads `modules\*.lua` with `luaL_loadbuffer`, runs it in a **sandbox
environment**, and calls the returned table's `init(ctx)`. The sandbox contains:

```
assert table pairs ipairs string math tonumber tostring unpack error
_VERSION type io collectgarbage jit
os.time os.clock os.date
log input memory fs audio match zlib
(+ ffi and bit when luajit.ext.enabled = 1)
```

Everything below was verified by reading Sider's `sider.cpp` and `soft/fs.lua`,
and by running the module inside a sandbox with the same restrictions (see
`tools/verify_mod.lua`).

| Fact | Consequence in `NGB_Presentation.lua` |
|------|--------------------------------------|
| `pcall`, `xpcall`, `require`, `select`, `next`, `load`, `loadstring`, `print`, `setmetatable`, `rawset/getmetatable`, `coroutine`, `debug`, `package` are **absent** | no defensive `pcall` anywhere; every read returns `nil` on failure and every call site checks. There is no `require`, so the module is one file. |
| `os` is only `{time, clock, date}` — **no `os.rename`** | `state.json` cannot be renamed atomically. The module writes `state.json.tmp` and then copies it over `state.json` in one `io.open`+`write`, and the DLL tolerates a truncated file (it is tested: see `tests/json_test.c`). |
| the module must **return a table with `init`** | `local m = {} ... return m` |
| handlers live in a *second* `lua_State` owned by Sider | handlers are fields of `m` (`m.on_display_frame`, …) and are looked up through `m.handler_for`, so the table cannot be collected and registration is table-driven |
| Sider calls each handler through `lua_pcall` and only logs `lua ERROR from module_X:` | a bug in this module cannot crash the game; it prints one line and that handler call is skipped |
| `memory.read(addr, n)` is an **in-process** read (`ffi.string`-like) | no `ReadProcessMemory`, no `VirtualQuery`, no `__asm__` aliases any more. An invalid address is now an access violation, so **every** read is bounds-checked against a region map first (`m.build_regions` / `m.in_region`) |
| `ffi` only exists with `luajit.ext.enabled = 1` | the module degrades to "no live stats" and logs why (`memory lib = false  <-- READS DISABLED`) |
| `ffi.cdef` is global to the LuaJIT state | the only declarations are six Win32 loader/identity calls, declared once behind `ffi.NGB_loader_cdefs` (idempotent across Sider hot-reloads) |

The complete FFI surface, in 2.0:

```c
void *LoadLibraryA(const char *name);
int   FreeLibrary(void *handle);
void *GetProcAddress(void *handle, const char *name);
unsigned int SetErrorMode(unsigned int mode);
unsigned int GetCurrentProcessId(void);
unsigned int GetModuleFileNameA(void *mod, char *buf, unsigned int size);
void *GetCurrentProcess(void);
```

Nothing else. The old `NGB_ReadProcessMemory` / `NGB_VirtualQuery` /
`NGB_VirtualProtect` / `NGB_WinExec` / `NGB_GetTickCount64` aliases are gone,
and `verify_mod.py` fails the build if any of them comes back.

### 1.1 Timing without `GetTickCount64`

`now_ms()` is `os.time() * 1000 + floor((os.clock() % 1) * 1000)`, clamped
monotonic (`if now < last then now = last`). It is accurate enough for card
timing (the card durations are seconds) and it cannot fail.

### 1.2 Float codecs without `ffi.cast`

`f32` (decode) and `f32_bytes` (encode) are pure Lua IEEE-754. They were checked
bit-for-bit against `struct.pack('<f')` for 18 representative values (including
denormals, ±0, 1e-40 and 3.4e38) under LuaJIT 2.1: **0 mismatches**.

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

### Renderer hand-off

`state.json` is the only interface between the module and whatever draws the
cards. In 2.0 the module does **not** start a process any more (the 1.x
`auto_launch_companion` / `WinExec` / `io.popen` path is gone): it loads
`ngb-render\NGB_Render.dll` into its own process with `LoadLibraryA` and calls
`NGB_Start(state_file, log_file, dir, enabled, hotkeys...)`. Section 9b covers
the DLL. If the DLL is missing or refuses to start, the module logs the exact
reason and falls back to `ngb-overlay\NGB_Overlay.exe` (`renderer = overlay`),
which resolves `state.json` relative to its own folder with the same fallbacks
as before.

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

`install.bat` is self-contained (no dependencies beyond Windows, **no
compiler**):

1. **Locate Sider** - `%~1` (drag & drop), `..\sider.ini`, `%HERE%\sider.ini`,
   then every drive letter against a list of common Football Life / PES install
   paths. If none match it asks and validates the folder (`sider.ini` required,
   `sider.dll` reported).
2. **Copy** `modules\NGB_Presentation.lua` + `.ini` and
   `ngb-render\NGB_Render.dll`. The DLL ships prebuilt (x64, 325 KB); nothing is
   compiled on the user's machine. The C# overlay is copied too, but only as an
   optional fallback, and it is not required for anything.
3. **Configure** `sider.ini` through `_ngb_ini.ps1` (PowerShell 5.1, present on
   every Windows 10/11): it inserts `luajit.ext.enabled = 1` (or flips a `0` to
   `1`), `match-stats.enabled = 1` and `lua.module = "NGB_Presentation.lua"` next
   to the existing `lua.module` lines, writes `sider.ini.ngb.bak` **once**
   (never overwriting an existing backup), and never rewrites the rest of the
   file. If PowerShell is blocked the installer falls back to Notepad + clipboard
   and then verifies with `findstr`.
4. **Verify** that the renderer DLL landed and say where every log file is.
5. **Confirm** in `install_log.txt`.

`uninstall.bat` asks for confirmation (`choice`), stops `NGB_Overlay.exe` if the
fallback was running, deletes only `modules\NGB_Presentation.*`,
`ngb-render\` (verified by the presence of `NGB_Render.dll`), `ngb-overlay\`
(verified by `NGB_Overlay.cs`) and `content\ngb-presentation\`, then removes
only this mod's `lua.module` line from `sider.ini` (and the marker comment added
with it). `luajit.ext.enabled` / `match-stats.enabled` are intentionally left in
place: they may be shared with other modules.
`tools\test_ini.bat` runs the whole add → add-again → remove → re-add cycle
against sample `sider.ini` files if you want to see it for yourself.

---

## 6. `state.json`

Written to `content\ngb-presentation\state.json` at `state_write_hz` (10 Hz),
about 2 KB, so a reader is never more than one tick behind. Schema version **4**.

Publishing is `state.json.tmp` first, then the same bytes over `state.json` in a
single `io.open`+`write`. (`os.rename` does not exist in Sider's sandbox, so a
true atomic replace is impossible from Lua; the reader is written to tolerate a
truncated file instead — `tests/json_test.c` sweeps every truncation offset.)

```json
{
  "v": 4, "seq": 842, "ts": 918273,
  "module": "Next-Gen Broadcast", "version": "2.0.0",
  "game": { "pid": 12345, "exe": "FL_2025.exe", "exe_path": "D:\\FL2025\\FL_2025.exe",
            "pid_source": "ffi", "hwnd": "0x00120A3C", "backbuffer": "2560x1440",
            "renderer_fps": "0", "renderer_frames": "18231", "renderer_enabled": "1" },
  "diag": { "schema": 4, "module": "2.0.0", "lua": "Lua 5.1",
            "luajit": "LuaJIT 2.1.0-beta3", "ffi": true, "mem_lib": true,
            "match_lib": true, "renderer": "dll", "renderer_detail": "...NGB_Render.dll",
            "started_at": 1200, "ticks": 18231, "tick_source": "display_frame",
            "state_writes": 1823, "state_writes_ok": 1823, "state_writes_failed": 0,
            "last_error": "",
            "events": { "display_frame": { "fired": 18231, "first": 812 },
                        "goal_scored": { "fired": 1, "first": 152300 } } },
  "hud": { "enabled": true, "master": true, "style": 0, "analysis": true,
           "units": "metric", "scorebug": true,
           "credit": "MOONFROS PRESENTS", "author": "MoonFros",
           "tagline": "Next-Gen Football Broadcast Presentation",
           "toast": { "text": "HAT-TRICK  |  B. SAKA", "kind": "milestone",
                      "seq": 12, "hold": 4.5 } },
  "status": {
    "stats_coherent": false,
    "ffi": true, "stats_region": false, "pitch_region": false,
    "camera": true, "player_db": true, "names": "Player.bin",
    "events": 17, "overlay_visible": true, "style": 0, "analysis": true,
    "data": { "scoreboard": "sider", "clock": "sider", "player_stats": false,
              "scorer_hook": true, "match_stats_ini": true, "goals": 3,
              "player_stats_ok": false, "overlay_alive": true,
              "overlay_version": "1.3.0" }
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

The layout is data, not code: `NGB_Presentation.lua` keeps the compiled defaults
in `OFF` and `m.apply_layout()` can replace six of them at start-up.

| ini / calibration.txt key | `OFF` field | default |
|---|---|---|
| `stat_rec_base` | `REC_BASE` | `0x7B5C0` |
| `stat_side_stride` | `REC_SIDE` | `0x59650` |
| `stat_rec_stride` | `REC_IDX` | `0x2134` |
| `stat_kind_stride` | `KIND_STRIDE` | `0x24` |
| `stat_kind_offset` | `KIND_OFFSET` | `0x08` |
| `stat_buckets` | `BUCKETS` | `8` |

Precedence: defaults → `content\ngb-presentation\calibration.txt` →
`NGB_Presentation.ini`. Deleting `calibration.txt` resets to the defaults.
A value that is not a number, negative, or out of range is ignored, and a layout
is only *displayed* after `m.validate_stats()` reproduces the scoreboard with it
(§2, tier 2), so a bad calibration cannot put false numbers on screen.

### The one-file workflow

```
experimental_player_stats = 1
probe_enabled             = 1
probe_dump_region         = 1
```

On the first goal (and on the diagnostics hotkey) the module writes:

| file | contents |
|---|---|
| `probe.txt` | scoreboard values, hexdump of `SCOREBOARD_INFO`, the region map from `VirtualQuery`, the layout in force (`LAYOUT`), and per-slot decoded rows (`PLAYERS`) |
| `probe_region.bin` | the located private stats region, byte for byte (≤ 4 MB, once per session, 16 KB `ReadProcessMemory` chunks) |
| `probe_region.txt` | `region_base`, size, score, layout |

`tools/decode_probe.py` then searches that dump:

```
python3 tools/decode_probe.py probe_region.bin [--write <content dir>] [--selftest]
```

How the search works — no heuristics that can invent a number:

1. `G[o] = Σ u32(o..o+28)` is computed once for every 4-byte offset: the goal
   kind is eight period buckets, so a candidate goal field is a sliding sum.
2. For each candidate `(rec_stride, side_stride)`, every aligned offset whose
   40-record sum equals the home score **and** whose second block of 40 equals
   the away score is collected (vectorised with numpy).
3. Candidates must still look like a football match: per side ≥ 12 players with
   a rating inside `[3.0, 10.0]`, ≥ 12 slots with passes or touches, per-player
   `shots ≤ 60`, `on_target ≤ shots`, `goals ≤ 12`.
4. Survivors are ranked by how many slots carry a rating, which is what
   separates the true base from the same grid shifted by a record or two.

`--selftest` builds a synthetic region (allocator header, 40 records per side,
eight buckets, float ratings), runs the same search and asserts three things:
the default layout is recovered, a region moved by `0x8000` is recovered at the
new base, and a wrong score produces no candidate at all. It runs inside the
offline check suite, so the decoder is exercised on every verification run.

### If the table is not in that region

`probe.txt` carries the `VirtualQuery` map with the first 64 bytes of every
committed region ≥ 64 KB. A different build may put the per-player table in a
region with a different size/header; the `PLAYERS` block then shows all zeros.
In that case the dump and the map are the evidence needed to add the new
signature to `scan_regions()`.

### Replay camera (unrelated to tier 2)

Add or replace a pattern in `CAM_PATTERNS` (literal bytes plus a `check()` that
returns the float offset and the expected default). A wrong pattern is harmless:
it finds nothing and the camera is left untouched.

---

## 7b. The renderer: targeting, liveness, de-duplication

### Who draws what

| renderer | mechanism | when it is used |
|---|---|---|
| `dll` (default) | `ngb-render\NGB_Render.dll`, loaded **into the game process** by the module with `LoadLibraryA`, draws in `IDXGISwapChain::Present` | always, unless it fails to load |
| `overlay` | the C# layered click-through window | `renderer = overlay`, or automatically if the DLL is missing / refuses to start |
| `none` | nothing is drawn; the Sider overlay text still works | `renderer = none` |

`renderer = dll` is the default because a second window structurally cannot draw
over an exclusive-fullscreen swapchain, and because window finding (whose
window? is it focused? is it minimised?) disappears entirely when you draw inside
the game's own frame.

### Window targeting (C# fallback only)

The 1.x overlay tried a list of guessed exe names, then fell back to "the
focused window of any other process, ≥ 640×360". Both were wrong: the guess
failed on a renamed exe, and the fallback could attach the overlay to a browser.
Targeting now uses facts the game itself published in `state.json`:

| Order | Rule |
|---|---|
| 1 | the PID in `state.json` (`game.pid`, read inside the game with `GetCurrentProcessId`) |
| 2 | the exe name in `state.json` (`game.exe`, from `GetModuleFileNameA`) |
| 3 | a process that has `sider.dll` loaded |
| 4 | the previously resolved window, if it still exists and is visible |

If none produce a window, the overlay attaches to **nothing**. Diagnostics can
still draw on the primary screen, so it can always be read.

### Does the overlay draw when the game is not focused?

Yes. The 1.x rule "the game must be the foreground window" is deleted. The only
conditions are `IsWindowVisible` and `!IsIconic`, and the layout comes from the
game window's client rect.

### Liveness

Three separate heartbeat files, because a freeze has three different causes:

| file | writer | period | proves |
|---|---|---|---|
| `content\ngb-presentation\state.json` | Lua module | 10 Hz | the module is reading the game and publishing it |
| `content\ngb-presentation\heartbeat.txt` | Lua module | 1 Hz | the module is *ticking* (`ticks_from=` names the event), and how many state writes succeeded |
| `content\ngb-presentation\render.txt` | DLL | 1 Hz | the renderer is inside a frame (`frames=`), the real `backbuffer=`, the `hwnd=`, and whether the kill switch is on |

The DLL decides freshness from the **write time of `state.json`**, not from when
it last read it: if the module stops writing, the cards disappear instead of
freezing the last score line on screen.

### De-duplication

Unchanged and still the authority chain: the `goal_scored` hook first (counts
into `unconfirmed[side]`), the scoreboard watcher second (a jump already covered
by a hook count is the board catching up, not a second goal), the delayed
fallback last (`goal_fallback_delay_ms`). Own goals are re-attributed to the
conceding side. A VAR-disallowed goal simply never reaches the scoreboard, so it
produces no card.

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

## 9b. The renderer DLL (`ngb-render/`)

### Why a DLL and not a window

A layered, click-through window can never appear over an **exclusive fullscreen**
swapchain: when the game owns the display, anything drawn by DWM is simply not
composited. A second window also has to answer "which window is the game, where
is it, is it focused, is it minimised" — three questions that produced problems
1–3 in the first place. Drawing inside the game's own `Present` removes all four
issues at once: the cards are part of the frame the GPU submits, so windowed,
borderless, exclusive fullscreen, focused and unfocused are the same case.

### How it is loaded

The module calls `LoadLibraryA("<sider>\ngb-render\NGB_Render.dll")` and then
`NGB_Start(config)`. There is **no loader for the user to compile**, no
`dinput8.dll` proxy, no injection: the DLL is loaded by the game process, into
the game process, by a module that is already running inside it. If
`luajit.ext.enabled = 0` the module cannot call `LoadLibraryA`, and it says so.

Config block (semicolon separated, copied immediately):

```
state_file=<sider>\content\ngb-presentation\state.json
log_file=<...>\ngb-dll.log
dir=<...>\
enabled=1
hotkey_selftest=0x77      (F8)
hotkey_diag=0x76          (F7)
hotkey_kill=0x7B          (F12)
```

### Hooking (MinHook)

`IDXGISwapChain::Present` and `IDXGISwapChain::ResizeBuffers` are patched with
**MinHook** (BSD-2, vendored under `ngb-render/minhook/`):

| step | detail |
|---|---|
| 1 | `MH_Initialize()` |
| 2 | create a **private, never-shown** window (`WS_EX_TOOLWINDOW \| WS_EX_NOACTIVATE`) and a dummy `D3D11CreateDeviceAndSwapChain` on it. This is the version-independent way to obtain the swapchain vtable without assuming `d3d11.dll` is already loaded, and it never touches anybody else's window. |
| 3 | `MH_CreateHook(vtbl[8], present_hook)` — `IDXGISwapChain::Present` |
| 4 | `MH_CreateHook(vtbl[13], resize_hook)` — `IDXGISwapChain::ResizeBuffers` |
| 5 | `MH_EnableHook(MH_ALL_HOOKS)`, then destroy the probe window |

`resize_hook` releases every size-dependent object (`RenderTargetView`, shader
resource views, cached text) **before** calling the original, then rebuilds on
the next `Present`. Skipping this is the classic cause of a black screen after
alt-tab or a resolution change.

### Drawing

* Device and swapchain are the game's own (`swapchain->GetDevice`); nothing here
  can change the presentation mode.
* Every frame: capture the game's render target, depth-stencil view, shaders,
  input layout, vertex/index/constant buffers, blend/raster/depth state,
  sampler, viewport and topology; set ours; draw; restore all of it.
* Quads: one vertex buffer (6 vertices per quad, written with
  `MAP_WRITE_DISCARD`), one constant buffer carrying screen size + colour, one
  pixel shader that multiplies the sampled texture's red channel by the colour.
  Solid fills sample a 1×1 white texture, so there is exactly one shader pair.
* Text: GDI renders the string white-on-black into a DIB, which is uploaded as
  a texture and used as an alpha mask (anti-aliased, tinted by the colour).
  Cached per (string, px, weight) with LRU eviction, 384 entries max. This gives
  real typography without shipping a font file and without a DirectWrite
  dependency.
* Shaders are compiled at runtime from `d3dcompiler_47.dll` (present on Windows
  8.1+, and shipped with the game). If it is missing the renderer logs
  `d3dcompiler_47.dll not available` and stays off.
* No hard-coded resolution: the layout unit is `h / 1080` from the **real back
  buffer**, clamped to 0.45–3.0. `tests/card_test.c` asserts that no draw call
  leaves the screen at 1280×720, 1920×1080, 2560×1440, 3440×1440, 3840×2160 and
  1024×768, and that type scales with height.

### Data

`state.json` only, read on a worker thread every 100 ms
(`CreateThread`, `CRITICAL_SECTION`). Present only ever touches the snapshot, so
file IO never blocks the render thread. Freshness comes from the **file's write
time**: `age >= 3000 ms` means "no data", and nothing is drawn. The DLL never
reads game memory, so a wrong offset cannot make it crash.

### Safety

| risk | mitigation |
|---|---|
| a fault inside our code | the whole Present body is inside hardware SEH (`__try/__except`, emitted as a real scope table by clang/MSVC). On an exception: log the code, set `g_dead`, return `Present` untouched. The game never sees it. |
| re-entrancy (our draw triggering Present) | `s_in_present` guard; the nested call goes straight to the original |
| a bad state file | bounded reader, no allocation of parsed values, truncation-safe (tested) |
| a stuck renderer | `F12` kill switch, and `dll_enabled = 0` skips hook installation entirely |
| logs growing forever | capped at 8 MB, then truncated with a marker |
| the module disappearing | cards vanish after 3 s of no new state (by design, not a freeze) |
| touching game data | the DLL opens exactly one file for writing (`render.txt`) and one log file. It never writes a save, EDIT data or a game file. |

`NGB_GetState()` returns
`version=...;hooks=1;enabled=1;faults=0;frames=...;backbuffer=2560x1440;state_age_ms=...;state_seq=...;dead=0;log=...`
and is folded into `state.json`'s `diag` block, the F7 strip and the diagnostics
panel.

### Building

```bat
rem no Visual Studio needed:
ngb-render\build.sh            (zig cc -target x86_64-windows-gnu -fms-extensions)

rem or, with MSVC:
cl /LD /O2 /EHsc- /GS- src\*.c minhook\src\*.c minhook\src\hde\hde64.c ^
   /I minhook\include /I src /link d3d11.lib dxgi.lib gdi32.lib user32.lib ole32.lib
```

`-fms-extensions` is what makes `__try/__except` available to clang; without it
the SEH protection silently disappears, so `verify_mod.py` checks for it in both
the source and the build command.

---

## 10. References

* Sider 7 module API — `doc/scripting.html`, `memlib`/`memory.lua`, `fslib`
* nesa24 cameras — `ReplayCam.lua` patterns (`rheight0`, `rheight3`, `rzoom`)
* PES 2021 / FL 2025 memory research — stat kinds and record stride
  (`0x7B5C0`, `0x59650`, `0x2134`), pitch block (`0x253FC`), `Player.bin`
  bit‑packed layout
