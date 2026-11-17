# Next-Gen Football Broadcast Presentation

**MOONFROS PRESENTS** · created by **MoonFros** · for Football Life 2025 / PES 2021 (Sider 7)
**v1.3.0** — engine-truth data layer, one-file calibration, and an overlay that can prove it is running.

A broadcast presentation layer for FL25: goal cards with the real scorer, minute
and score, half-time and full-time result cards, a slim live score bug and
milestone call-outs, drawn over the game by a transparent click-through overlay.

| Card | What it shows | Data tier |
|---|---|---|
| **Goal** | scorer's shirt name, minute, score line, team colour, milestone badge, entrance animation | engine (every build) |
| **Goal, unnamed** | when a goal reaches the scoreboard without the hook: `GOAL`, minute, score, "SCORER NOT AVAILABLE" — never a guessed player | engine |
| **Half time / full time** | result, final score, every scorer with minute and team | engine |
| **Score bug** | clock, score, penalty score in a shootout | engine |
| **Milestone toast** | `OPENER` / `BRACE` / `HAT-TRICK` / `N GOALS`, counted from goals actually seen | engine |
| **Player stat row** | shots, on target, goals, assists, minutes, rating | tier 2, after calibration (`tools/decode_probe.py`) |
| **Shot / miss / save** | shot data, miss and save cards, telemetry | tier 2, after calibration |
| **MOTM** | gold full-time reveal with the full stat block | tier 2, after calibration |

Nothing is filled with zeros. When a number is not available the card either
omits it or says so — see [README.txt](README.txt) §6 for the exact
measured / calibrated / modelled breakdown.

---

## Install (3 steps)

1. Double-click **`install.bat`** (or drag your Sider folder onto it).
   It finds Sider on any drive, copies `modules\` and `ngb-overlay\`, adds three
   lines to `sider.ini` after writing `sider.ini.ngb.bak`
   (`luajit.ext.enabled`, `match-stats.enabled`, `lua.module`), then builds and
   starts the overlay.
2. Launch the game in **borderless or windowed** mode.
3. Play. You get a goal card on the first goal, and the score bug immediately.

You never need `Start_NGB_Overlay.bat` again after the first install: the Lua
module launches the overlay itself at game start.

**Nothing on screen?** In order: the Sider overlay says `OVERLAY running` or
`OVERLAY NOT RUNNING`; `content\ngb-presentation\overlay_alive.txt` is rewritten
every 2 s by the companion; **F11** draws diagnostics even when no game window is
recognised (target + state age); `<Sider>\ngb-overlay\NGB_Overlay.log` records the
target window and the state file. Borderless/windowed only.

Press **F10** at any time to preview the animated goal, shot-data and MOTM cards.
They carry a `DEMO · SAMPLE DATA` badge — the live overlay only ever shows
numbers read from the game.

## Unlocking the per-player numbers

1. `NGB_Presentation.ini`: `experimental_player_stats = 1`, `probe_enabled = 1`,
   `probe_dump_region = 1`.
2. Play until a goal, quit. `content\ngb-presentation\` now has
   `probe_region.bin` + `probe_region.txt`.
3. `python tools/decode_probe.py probe_region.bin --write "<...>\content\ngb-presentation"`
4. Start the game: stat rows, shot data, miss and save cards switch on once the
   layout validates against the scoreboard.

`tools/decode_probe.py --selftest` proves the decoder on synthetic data — it is
part of the offline check suite.

Uninstall with **`uninstall.bat`** — it removes only this mod's files and its own
`sider.ini` lines.

## Hotkeys

| Key | Where | Action |
|---|---|---|
| **7** | in game | previous / alternative presentation option (full → compact → minimal) |
| **8** | in game | main presentation overlay on / off |
| **9** | in game | shot analysis / trajectory on / off |
| **F10** | overlay window | demo card |
| **F11** | overlay window | diagnostics panel |
| **F12** | overlay window | quit the overlay |

`F7` / `F8` / `F9` are never registered; key `1` is left to Sider. The digits only
act while the Sider overlay is open (`hotkeys_overlay_only = 1`), so they cannot
clash with the game's own keys. All three are remappable in the `.ini`.

## Folder layout

```
mods/ngb-presentation/
├─ install.bat / uninstall.bat / _ngb_ini.ps1   installer (safe sider.ini editing)
├─ README.txt                  full user documentation (install, config, limits)
├─ modules/NGB_Presentation.lua + .ini          the Sider module
├─ ngb-overlay/                C# overlay source, manifest, build scripts
├─ docs/TECHNICAL.md           offsets, detection, milestones, installer internals
├─ preview/NGB_Preview.html    interactive preview of every card (any browser)
└─ tools/verify_mod.py         offline test-suite
```

## Verify

```bash
python3 mods/ngb-presentation/tools/verify_mod.py
```

Static checks (Lua/INI/C#/HTML/installer/branding), a `Player.bin` fixture, and a
functional run that drives the real module through a simulated match:
baseline → shot → goal → assist → brace → hat-trick → own goal → MOTM → the
`7` / `8` / `9` controls → `state.json`.

## Status

| | |
|---|---|
| Tested offline | Lua logic, stat detection, telemetry maths, milestones, MOTM selection, hotkey handling, state schema, C# parse, installer scripts (static) |
| Not tested in game | the memory offsets on your exact `FL_2025.exe` build, the C# build on your machine, the visual result |
| Not possible | player portraits, per-player real minutes, measured ball speed — see README.txt §6 and §7 |

## Credits

Concept, Lua module, C# overlay, installer, design: **MoonFros**.
Sider by nesa24/juce; replay-camera pattern research by nesa24 (nesalib);
PES 2021 match-memory research (stat kinds, region signatures, `Player.bin`).
