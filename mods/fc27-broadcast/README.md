# EA FC 27 HyperMotion Broadcast — PES 2021 / Football Life 2025

`FL2025-mods` → [`mods/fc27-broadcast`](../..) · v1.0.0 · 145 offline checks passing

A Sider Lua mod for **PES 2021 / SmokePatch Football Life 2025 (`FL_2025.exe` v1.0)**
that brings three EA FC style broadcast moments to your match, plus a transparent
click‑through HUD that draws them over the game:

| # | Feature | What appears on screen |
|---|---------|------------------------|
| 1 | **HyperMotion goal replay** | A custom replay camera sweep during goal replays + a broadcast goal card with live shot telemetry: speed, distance, angle, elevation, apex, hang time, xG, goal‑face placement and a 3D shot trajectory diagram |
| 2 | **Goal / miss player popup** | Every goal **and every shot** (on target, off target, blocked) pops the shooter's match totals: **shots, shots on target, goals, assists, G/A** |
| 3 | **Post‑match Man of the Match** | When the match ends, during the MOTM animation: match rating, goals, assists, G/A, shots, on target, passes, pass %, tackles, dribbles, touches, saves, peak shot speed and total xG |

Everything is **pure EA FC 27 HyperMotion styling**: volt‑green accents, obsidian
glass panels, condensed uppercase typography, animated sweeps — in **imperial
units** (mph / yd / ft) by default, with a one‑click metric toggle.

Designed at 1080p and **fully resolution independent**: 720p, 1080p, 1440p, 4K and
ultrawide all scale from the same layout. Tested geometry at **720p first**.

---

## Contents

```
mods/fc27-broadcast/
├─ Install.bat                    one-click installer (does steps 1-3 for you)
├─ modules/                       -> copy into <Sider>\modules\
│  ├─ FC27_Broadcast.lua          the Sider Lua module (the "brain")
│  └─ FC27_Broadcast.ini          all settings, hotkeys, units, tuning
├─ fc27-overlay/                  -> copy into <Sider>\fc27-overlay\
│  ├─ FC27_Overlay.cs             the transparent broadcast HUD (C# source)
│  ├─ app.manifest                DPI awareness manifest
│  ├─ Start_FC27_Overlay.bat      one-click build + launch (Windows' own csc.exe)
│  ├─ Quit_FC27_Overlay.bat       stops the HUD (same as F12)
│  └─ README.txt                  short hotkey card
├─ preview/FC27_HUD_Preview.html  interactive preview of all cards (any browser)
├─ docs/TECHNICAL.md              memory layout, detection logic, calibration
└─ tools/verify_mod.py            offline test-suite
```

Runtime output (`content\fc27-broadcast\state.json`) is created inside your
Sider folder on first run — it is not part of this folder.

---

## Requirements

* **Sider 7.3.4** (the version you have) — `sider.dll` + `sider.exe`
* **`luajit.ext.enabled = 1`** in `sider.ini` — *required*. The mod reads live match
  memory, and Sider only exposes `ffi` + the `memory` library when LuaJIT
  extensions are on. (Your `nesalib.lua` needs this too.)
* **Windows 10 / 11 x64** — nothing else. The HUD compiles itself with the C#
  compiler that ships with .NET Framework 4.x (already installed on every
  supported Windows).
* Play **windowed or borderless fullscreen**. Exclusive fullscreen cannot show any
  overlay (this is a Windows limitation, not a mod bug).

---

## Installation — 4 steps, ~1 minute

Everything you need is in `mods/fc27-broadcast/`. You copy **two folders** and
add **two lines**.

### Fastest way: run `Install.bat`

Double‑click **`Install.bat`** (or drag your Sider folder onto it). It copies
both folders, shows you the two `sider.ini` lines (already on your clipboard),
then builds and starts the HUD. That's it — start the game.

The manual steps below are exactly what it does, if you prefer to do it by hand
or the script cannot find your Sider folder.

### 1. Copy the two folders into your Sider folder

```
mods\fc27-broadcast\modules\        ->  <your Sider folder>\modules\
mods\fc27-broadcast\fc27-overlay\   ->  <your Sider folder>\fc27-overlay\
```

(`fc27-overlay` is a new folder; just drop it next to `sider.exe`.)

### 2. Enable the module in `sider.ini`

Add these two lines anywhere among the other `lua.*` lines:

```ini
luajit.ext.enabled = 1
lua.module = "FC27_Broadcast.lua"
```

`luajit.ext.enabled = 1` is **required** — without it Sider does not expose
`ffi`/`memory` and the mod cannot read the match. (If you already run
`nesalib.lua`, you already have it.)

### 3. Build the HUD once

Double‑click:

```
<your Sider folder>\fc27-overlay\Start_FC27_Overlay.bat
```

It compiles `FC27_Overlay.exe` with the C# compiler Windows already ships
(2 seconds, no downloads) and starts it. From then on the module **launches the
HUD automatically** with the game (`auto_launch_companion = 1`).

### 4. Play

Start the game in **borderless or windowed** fullscreen. Goal → shot → MOTM
cards appear automatically. Press **F8** on the desktop any time to cycle a demo
card, **F9** for diagnostics, **F12** to quit the HUD.

> Want to see the cards before installing anything? Open
> `preview/FC27_HUD_Preview.html` in any browser.

> **Where does the mod look for the HUD?** `fc27-overlay\FC27_Overlay.exe`,
> `..\fc27-overlay\FC27_Overlay.exe` or `overlay\FC27_Overlay.exe` relative to
> the Sider folder — any of them works.

---

## Hotkeys

| Key | Where | Action |
|-----|-------|--------|
| **F8** | HUD (global) | Cycle a demo card (goal → shot → MOTM → off) so you can check the HUD without playing |
| **F9** | HUD (global) | Toggle the diagnostics panel (shows whether the stat region, pitch region, camera patch and Player.bin were found) |
| **F12** | HUD (global) | Quit the HUD |
| **F8** | Sider overlay | Fire the demo event inside the game overlay |
| **F9** | Sider overlay | Re‑show the last card |
| **F7** | Sider overlay | Cycle replay camera preset (HyperMotion → Broadcast → vanilla) |

All Lua hotkeys are re‑mappable in `FC27_Broadcast.ini`.

---

## Configuration (`modules/FC27_Broadcast.ini`)

| Key | Default | Meaning |
|-----|---------|---------|
| `units` | `imperial` | `imperial` = mph / yd / ft, `metric` = km/h / m |
| `companion_hud_enabled` | `1` | Write `state.json` for the HUD |
| `auto_launch_companion` | `1` | Start the HUD automatically with the game |
| `replay_camera_enabled` | `1` | Patch the replay camera values |
| `replay_camera_preset` | `1` | `1` HyperMotion low sweep, `2` elevated broadcast, `3` leave the game camera alone |
| `replay_height_cam0` / `cam3` / `zoom` | `0.28` / `0.95` / `0.56` | Fine tuning of preset 1 |
| `goal_telemetry_duration` | `16.0` | Seconds the goal card stays up |
| `goal_telemetry_delay` | `1.2` | Delay before the goal card appears (lets the celebration play, lands as the replay starts) |
| `shot_popup_duration` | `6.5` | Seconds a shot/miss popup stays up |
| `motm_card_enabled` | `1` | Show the post‑match MOTM card |
| `motm_card_duration` | `22.0` | Seconds the MOTM card stays up |
| `shot_popup_enabled` | `1` | Show the shot / miss popup at all |
| `stats_poll_ms` | `350` | How often per‑player stats are sampled (min 100) |
| `position_poll_ms` | `120` | How often the 22 player positions are sampled (min 60) |
| `replay_window_max` | `16.0` | Upper bound of the goal‑replay camera window |
| `state_write_hz` | `10` | How often `state.json` is rewritten |
| `show_scorebug` | `0` | Slim EA FC score bug in the top‑left corner |
| `show_position` | `1` | Show the registered position (RWF, CB, …) next to the player name |
| `theme` | `eafc` | Card theme name written to `state.json` |
| `stats_region_base` | `0` | Pin the stat region instead of scanning (`0` = auto) |
| `pitch_region_base` | `0` | Pin the pitch region instead of scanning (`0` = auto) |
| `hotkey_cycle_replay_cam` | `VK_F7` | Replay camera preset hotkey |
| `hotkey_demo_preview` | `VK_F8` | Demo event hotkey |
| `hotkey_reshow_card` | `VK_F9` | Re‑show the last card hotkey |
| `debug_log` | `0` | Verbose `sider.log` output (region addresses, goal payloads) |

---

## How it works (short version)

The Lua module reads **live match state that the engine already keeps in memory**:

* `ctx.mis` → team names, abbreviations, kit colours, squad lists, starting XI
* `match.stats()` → score, clock, period, paused/running, `match_stage`
* The per‑player **stat block** in a private heap region (goals, own goals,
  assists, shots, shots on target, passes, tackles, dribbles, touches, saves and
  the engine's own match rating) — this is *exactly* the data the game's own
  post‑match screens display
* 22 live player `(x, y, z)` positions, used for the shot geometry
* `common\etc\pesdb\Player.bin` (WESYS + zlib, 312‑byte records) → real names,
  shirt numbers, positions, height, kicking power and finishing

From that it derives the broadcast layer:

* **Shot telemetry is computed, not read from a hidden table.** Distance and the
  angle subtended by the posts come from the shooter's real position; xG uses a
  logistic model of distance and angle; launch speed comes from the shooter's
  real *kicking power* attribute scaled by range; elevation, apex and hang time
  come from a ballistic solve that actually reaches the recorded goal‑face
  target. If the aim point / speed has to be modelled (e.g. a shot taken before
  the module saw the player's position), the state file marks
  `"source": "estimated"` instead of `"measured"`.
* **Goals and misses** are detected from the stat block rising: `kind 0` goals,
  `kind 1` own goals, `kind 6` shots, `kind 17` shots on target, `kind 4`
  assists. Because it watches the *shooter's own counters*, the popup is correct
  on misses too — no fragile "last player who touched the ball" logic.
* **MOTM** is selected from every player who actually played (touches/passes > 0)
  with a composite score built from the engine rating + goals, assists, shots,
  on target, pass %, tackles, saves and a winner bonus.

`modules/FC27_Broadcast.lua` writes everything into
`content\fc27-broadcast\state.json`; `FC27_Overlay.exe` reads it at ~20 Hz and
paints the cards with per‑pixel alpha. If the HUD is not running, the mod still
works and shows a compact text version in the Sider overlay (toggle it with
whatever key/chord you normally use for the Sider overlay).

Full technical details, memory offsets and how to re‑calibrate for a future
executable: **[docs/TECHNICAL.md](docs/TECHNICAL.md)**.

---

## Troubleshooting

**Nothing appears at all**
* Is `lua.module = "FC27_Broadcast.lua"` in `sider.ini`?
* Open `sider.log` and search for `[FC27]`. You should see the banner with
  `v1.0.0`, then `state file: <path>`, then `ready`.

**`WARNING: LuaJIT FFI is off`** in `sider.log`
* Add `luajit.ext.enabled = 1` to `sider.ini`. Without it Sider does not even load
  its `memory` library, so live stats cannot work.

**"stat region not found" in the diagnostics panel (F9)**
* The scan runs at kick‑off, up to three times. Wait until a match starts.
* If it still fails, set `debug_log = 1`, start a match, and look for
  `[FC27] stats region @ 0x...` in `sider.log`.
* Referee of last resort: paste an address into `stats_region_base` /
  `pitch_region_base` in the INI. See `docs/TECHNICAL.md`.

**Player names show as `PLAYER 11`**
* `Player.bin` had not been loaded yet when the first popup fired (it loads at
  startup, so this only happens in the first seconds after launching).
* Or your build stores `Player.bin` elsewhere; check `debug_log = 1` output.

**The HUD is invisible but the game runs**
* Use **borderless / windowed**. Exclusive fullscreen blocks all layered windows.
* The game window must be the foreground window when the overlay starts; it
  re‑attaches automatically within a second.
* Press **F12** then re‑run `Start_FC27_Overlay.bat`.

**HUD text looks blurry**
* The HUD is DPI aware. If you run Windows at 125 %/150 % scaling, the overlay
  matches the game's client area in physical pixels, so it stays sharp; make
  sure the game itself is not being bitmap‑scaled by Windows.

**The replay camera did not change**
* `replay_camera_preset = 3` disables it. Check `sider.log` for
  `[FC27] replay camera ready (3/3 values, preset 1)`.
* If the pattern scan reports `0/3`, your `FL_2025.exe` build moved the replay
  camera constants. The mod leaves the camera untouched instead of guessing —
  see `docs/TECHNICAL.md` for how to add a pattern.

**MOTM card appears on the wrong screen / too early**
* The card shows 2.6 s after full time or after the post‑match flow file loads.
  Raise `motm_card_duration` or set `motm_card_enabled = 0` if you prefer the
  game's own presentation.

---

## Verifying the build

```bash
python3 mods/fc27-broadcast/tools/verify_mod.py   # static + functional checks
pip install lupa && python3 mods/fc27-broadcast/tools/verify_mod.py   # + simulation
```

The functional part rebuilds a miniature `FL_2025.exe` memory image (team struct,
scoreboard, 22 pitch positions, 80 stat records, a WESYS `Player.bin`) and drives
the real module through baseline → shot → goal → own goal → MOTM → `state.json`,
so the whole detection pipeline is exercised without the game. It also validates
the JSON schema the HUD consumes, the C# structure, and the HTML preview.

---

## Uninstall

1. Remove `lua.module = "FC27_Broadcast.lua"` from `sider.ini`.
2. Delete `modules\FC27_Broadcast.lua`, `modules\FC27_Broadcast.ini` and the
   `fc27-overlay` folder.
3. Delete `content\fc27-broadcast` (only holds `state.json`).

Nothing is written to your save files, EDIT data or game install.

---

## Notes & limitations (please read)

* **Replay camera**: the mod patches the game's own replay camera constants
  (`rheight0`, `rheight3`, `rzoom`) during goal replays and restores the exact
  baseline values afterwards, so normal replays and `camera.lua` are untouched.
  If the values cannot be located with certainty, nothing is patched.
* **Shot speed / apex / hang time** are physically consistent derivations, not
  engine telemetry — PES 2021 does not expose a "shot speed" number. Distance,
  angle, goal/miss outcome, shots, goals, assists and ratings are real match data.
* **720p**: geometry is scaled from a 1080p master (×0.667 at 720p). All cards
  fit inside the safe area; at 720p the goal card is 826 × 200 px.
* The HUD is **click‑through** — it can never steal input from the game.

---

## Credits

* **Sider** by nesa24 / juce — module API, overlay pipeline
* **nesalib / ReplayCam** by nesa24 — replay camera pattern research
* **PES 2021 match memory research** (stat kinds, region signatures, Player.bin
  layout) — the `supercontinental-draft` collector documentation
* Everything in this repo: EA FC 27 HyperMotion broadcast design, Lua module,
  C# HUD, preview and test harness
