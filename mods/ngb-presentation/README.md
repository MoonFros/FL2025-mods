# Next-Gen Football Broadcast Presentation

**MOONFROS PRESENTS** · created by **MoonFros** · for Football Life 2025 / PES 2021 (Sider 7)

A broadcast presentation layer for FL25: live player spotlights, animated goal
analysis, milestone call-outs and a full-time Man of the Match reveal, drawn over
the game by a transparent click-through overlay.

| Card | What it shows |
|---|---|
| **Goal** | player spotlight (name, number, position, minutes, G/A/shots/SOT) + shot analysis: origin, trajectory on a mini pitch, goal location, distance, angle, modelled speed, xG, milestone badge, assist credit |
| **Shot / reaction** | the same spotlight for every non-goal shot, sized low and wide so it never covers the player's face |
| **Milestone toast** | `OPENER` / `FIRST GOAL` / `BRACE` / `HAT-TRICK` / `4 GOALS` / `N GOALS`, plus assist sign-off |
| **MOTM** | gold full-time reveal: rating ring, goals, assists, shots, on target, passes, pass %, touches, minutes |
| **Style switch** | `full` → `compact` → `minimal`, live, with the in-game `[7]` key |

Everything numeric comes from the game's own match memory. Shot speed, apex,
hang time and xG are **modelled** from real distance/angle/attributes and are
labelled as such in the interface (`~` prefix, "SPEED MODELLED" in the footer).
See [README.txt](README.txt) §6 for the exact measured-vs-calculated breakdown.

---

## Install (3 steps)

1. Double-click **`install.bat`** (or drag your Sider folder onto it).
   It finds Sider on any drive, copies `modules\` and `ngb-overlay\`, adds two
   lines to `sider.ini` after writing `sider.ini.ngb.bak`, then builds and starts
   the overlay.
2. Launch the game in **borderless or windowed** mode.
3. Play. Cards appear on goals, shots, milestones and at full time.

Uninstall with **`uninstall.bat`** — it removes only this mod's files and its
`sider.ini` line.

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
