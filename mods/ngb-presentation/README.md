# Next-Gen Football Broadcast Presentation

**MOONFROS PRESENTS** · created by **MoonFros** · for Football Life 2025 / PES 2021 (Sider 7)
**v2.0.2** — the cards are drawn *inside the game's own frame* by a D3D11 renderer DLL.

Broadcast presentation for FL25: goal cards with the real scorer, minute and
score, half-time and full-time result cards, a slim live score bug, milestone
call-outs, and per-player stats **only when they have been validated against the
scoreboard**.

The important change in 2.0: there is **no second window**. A small DLL is
loaded into the game process and draws on the game's back buffer during
`Present`. Windowed, borderless, exclusive fullscreen, focused or *not* focused —
it is the same code path, because it is the game's own frame.

| Card | What it shows | Data tier |
|---|---|---|
| **Goal** | scorer's shirt name, minute, score line, team colour, milestone badge | engine (every build) |
| **Goal, unnamed** | when a goal reaches the scoreboard without a player: `GOAL`, minute, score, `SCORER NOT AVAILABLE` — never a guessed player | engine |
| **Half time / full time** | result, final score, every scorer with minute and team | engine |
| **Score bug** | clock, score, penalty score in a shootout | engine |
| **Milestone toast** | `OPENER` / `BRACE` / `HAT-TRICK` / `N GOALS` | engine |
| **Shot / miss / save** | speed, distance, angle, xG, labelled `MEASURED` or `MODELLED` | engine + model |
| **Player stat row** | shots, on target, goals, assists, minutes | tier 2 — only after `tools/decode_probe.py` calibration *and* the coherence gate |
| **MOTM** | full-time reveal with the stat block | tier 2, same gate |

Nothing is filled with zeros. When a number is not available the card omits it
or says `PLAYER DATA UNAVAILABLE` / `SCORER NOT AVAILABLE`.

---

## Install (3 steps, no compiler)

> **Never installed a Sider mod before?** Read **`INSTALL.txt`** instead — same
> steps, plain English, with the `sider.ini` lines explained and an ordered
> "it isn't showing" list.

1. Double-click **`install.bat`** (or drag your Sider folder onto it).
   It finds Sider on any drive, copies `modules\`, `ngb-render\NGB_Render.dll`
   and (optionally) the C# fallback, backs up `sider.ini` to
   `sider.ini.ngb.bak` and adds three lines: `luajit.ext.enabled = 1`,
   `match-stats.enabled = 1`, `lua.module = "NGB_Presentation.lua"`.
2. Launch the game **however you like** — windowed, borderless or fullscreen.
3. Play. Cards appear on goals, half time, full time and shots.

Nothing is built on your machine. If you ever see the 1.x message
`error CS...`, you are running an old copy — 2.0 has no compile step at all.

**Uninstall** with `uninstall.bat`: it removes `modules\NGB_Presentation.*`,
`ngb-render\`, `content\ngb-presentation\` and this mod's line in `sider.ini`,
leaving everything else (including `sider.ini.ngb.bak`) alone.

---

## In-game keys

| key | who handles it | what it does |
|---|---|---|
| `7` | Lua module | cycle presentation style |
| `8` | Lua module | presentation on / off |
| `9` | Lua module | shot analysis on / off |
| `F8` | renderer DLL | self-test: draws a card stamped **DEMO – NOT REAL DATA** through the real path |
| `F7` | renderer DLL | renderer diagnostics strip (fps, back buffer, state age, log path) |
| `F12` | renderer DLL | kill switch: cards on / off, without restarting the game |
| `F10` / `F11` / `F12` | C# fallback only | cycle sample card / diagnostics / quit |

The DLL hotkeys work even when the game is **not focused** — that is the point
of polling `GetAsyncKeyState` inside the render hook instead of using window
messages.

---

## WHY NOTHING SHOWS — the checklist

Read the files in this order. Each line tells you which layer failed.

### 0. First, the fastest test

Press **F8** in game.

* A card stamped **DEMO – NOT REAL DATA** appears → **the renderer works**. Any
  remaining problem is data, not drawing. Go to step 3.
* Nothing appears → **run `NGB_Doctor.bat`**. It checks the folder, the three
  `sider.ini` lines, the DLL (including its architecture), the logs and the
  files the mod writes while it runs, then tells you which one is wrong. It
  writes `ngb_doctor.txt` and changes nothing. Step 1 below is the same list
  by hand, if you prefer to look yourself.
* **Live player numbers say `UNAVAILABLE`** → this is by design when the DLL is
  not loaded. The DLL is also the mod's memory reader: Sider's own
  `memory.read` dereferences an address blindly, so one stale pointer would end
  the game. There is no "just try it" fallback — see `allow_unsafe_memory_reads`
  in the ini if you insist, but the score, clock and goal cards never needed a
  memory read and keep working either way.

### 1. Is the DLL loaded?

`<Sider>\content\ngb-presentation\ngb-dll.log` (and `render.txt`)

| what you see | meaning | what to do |
|---|---|---|
| no `ngb-dll.log` at all | the Lua module never tried to load the DLL | check `sider.log` for `renderer: NO DLL at ...` or `renderer: disabled by configuration` |
| `MEMORY   none` in the F7 strip | no safe memory reader, so live player numbers are off on purpose | install `ngb-render\NGB_Render.dll`; do not set `allow_unsafe_memory_reads` |
| `renderer: NO DLL at ...` in `sider.log` | the file is not where the module looks | re-run `install.bat`; the file must be `<Sider>\ngb-render\NGB_Render.dll` |
| `ffi off - cannot LoadLibrary` | `luajit.ext.enabled` is not 1 | add it to `sider.ini`, or re-run `install.bat` |
| `LoadLibraryA failed` | wrong file / wrong architecture | the DLL must be the 64-bit `NGB_Render.dll` from this package |
| `could not create the probe window` | the hook could not be set up | the game runs normally; send me `ngb-dll.log` |
| `MH_CreateHook(Present) failed` | MinHook could not patch Present | same as above; the C# fallback still works |
| `MH_EnableHook failed` | same | same |
| `hooks installed: Present=...` | the renderer is live | if F8 still shows nothing, send `ngb-dll.log` |
| `Module (NGB_Presentation.lua) is NOT activated` in `sider.log` | start-up raised; the line above it says why | 2.0.2 fixes the `'void' is not callable` error that 2.0.0/2.0.1 always hit — reinstall and it will not appear. Otherwise send `ngb_doctor.txt` |
| `FATAL: exception 0x... inside the Present hook` | the renderer caught its own fault and disabled itself | the game keeps running; send me that line and F7's strip |

### 2. Is the module alive?

`<Sider>\content\ngb-presentation\heartbeat.txt`, rewritten every second:

| field | meaning |
|---|---|
| `ticks=0` | the module never ticked: no `display_frame` and no overlay opened. Check `sider.log` for `ctx.register` lines and `event 'display_frame' fired for the first time` |
| `tick_source=display_frame` | good — the per-frame event works on your Sider build |
| `tick_source=overlay_on` | only ticking while the Sider overlay is open: `display_frame` is not firing, so the DLL is what keeps the HUD alive |
| `state_writes_ok=0` | the module cannot write `state.json` (folder permissions?) |
| `renderer=overlay` + `renderer_detail=` | the DLL was not used; the detail says why |
| `last_error=` | the last exception the module caught |

`sider.log` lines start with `[NGB]`. The first few tell you the whole
environment: module version, Sider dir, `Lua 5.1`, `LuaJIT ...`, whether `ffi`
and `bit` exist, whether the `memory` and `match` libraries exist, and every
`ctx.register` result.

### 3. Is the data arriving?

`<Sider>\content\ngb-presentation\state.json` — look at `match.live`,
`match.home.score`, `event`, and `diag`.

| what you see | meaning |
|---|---|
| no `state.json` | the module is not writing: see step 2 |
| `"live": false` in a match | the module cannot read the scoreboard. Check `status.data.scoreboard` (should be `"sider"`) and that `match-stats.enabled = 1` is in `sider.ini` |
| `"event": null` during a goal | no goal was detected: check `status.data.scorer_hook` and `goal_telemetry_*` |
| `"player_stats": false` | the stat table is disabled or failed validation — this is the safe default, see below |

### 4. Cards appear but a number looks wrong

`diag.stats_coherent` / `status.data.stats_coherent` is `false` when the player
numbers disagree with the scoreboard. That is the guard against "0 shots, 2
goals": when it fails, the card shows `PLAYER DATA UNAVAILABLE` instead of the
numbers. The reason is in `diag.last_error` and in `sider.log`
(`stats coherence -> false (player 3/7: 0 shots but 2 goals)`).

---

## Per-player stats: why they are off by default

The per-player table layout (record base `0x7B5C0`, side stride `0x59650`,
record stride `0x2134`, …) comes from PES 2021 research, **not** from
`FL_2025.exe`. It is therefore disabled by default:

```ini
experimental_player_stats = 0
```

If you enable it, the module validates the table before showing anything:

1. the region scan must find a readable table,
2. the totals must agree with the scoreboard (`sum(goals) >= score`, `sum(shots) >= score`),
3. every player's shots must be at least his goals (own goals excluded),
4. at least 20 player records must be readable,
5. all of it is re-checked every two seconds.

Any failure ⇒ `stats_coherent = false` ⇒ cards show `PLAYER DATA UNAVAILABLE`.
There is no path that prints a number the game did not give us.

To pin the layout for FL_2025: play a match, press F9 (probe), then run
`python tools/decode_probe.py` on the dump it writes; the result goes into
`content\ngb-presentation\calibration.txt` and is picked up automatically.

---

## Requirements

* Football Life 2025 / PES 2021 with Sider 7 (`sider.exe` / `sider.dll`).
* `luajit.ext.enabled = 1` and `match-stats.enabled = 1` in `sider.ini`
  (`install.bat` adds both).
* Windows 10/11, 64-bit. The renderer needs `d3dcompiler_47.dll`, which ships
  with Windows; if it is missing the renderer logs it and stays off.
* **Not for online play.** This hooks the swapchain; any anti-cheat would treat
  it exactly like a cheat overlay.

---

## Files

```
modules\NGB_Presentation.lua      the module (events, memory reads, state.json, heartbeat)
modules\NGB_Presentation.ini      every knob, documented
ngb-render\NGB_Render.dll         the renderer (prebuilt, x64)
ngb-render\src\                  its source + MinHook
ngb-overlay\NGB_Overlay.cs        optional C# fallback (renderer = overlay)
install.bat / uninstall.bat       install / remove, with sider.ini backup
_ngb_ini.ps1                      the sider.ini editor both scripts call
tools\verify_mod.py               the offline + build + host-test suite
tools\verify_mod.lua              the simulated-Sider harness it runs
tools\test_ini.bat                add / remove / reinstall test for sider.ini
tools\decode_probe.py             stat-layout calibration
CHANGELOG.md                      the ten problems: reproduced / fixed / verified
docs\TECHNICAL.md                 how it works, offsets, event list, safety rules
README.txt                        the long-form manual (same content, plain text)
```

---

## Honest status

Everything that needs Football Life 2025 running is **UNVERIFIED** until you
run it: the event firing on your Sider build, the memory reads, exclusive
fullscreen with the DLL, and every visual. What *is* verified here is that the
Lua module loads and behaves in a sandbox that mirrors Sider's, that the
renderer builds and exports the right API, that its JSON reader survives real
and truncated input, and that its layout stays inside the screen at six
resolutions. `CHANGELOG.md` marks each of the ten problems individually.

If something does not show, send me `sider.log`, `ngb-dll.log`,
`heartbeat.txt`, `render.txt` and `state.json` — those five files name the layer
that failed.
