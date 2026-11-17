NEXT-GEN FOOTBALL BROADCAST PRESENTATION  -  overlay
MOONFROS PRESENTS  -  created by MoonFros
==========================================================

This folder is the graphics companion. Install.bat copies it next to
sider.exe as <Sider>\ngb-overlay\.

Files
  NGB_Overlay.cs            overlay source (no external libraries)
  app.manifest              DPI awareness (per-monitor v2)
  Start_NGB_Overlay.bat     compiles with Windows' own csc.exe and runs it
  Quit_NGB_Overlay.bat      stops it (same as F12)
  NGB_Overlay.exe           created by the .bat, not shipped
  NGB_Overlay.log           created at runtime, rotated at 512 KB

Overlay-only hotkeys  (the in-game presentation keys are 7 / 8 / 9)
  F10   cycle demo card   (goal -> shot with shot data -> MOTM -> off)
        demo cards carry a "DEMO - SAMPLE DATA" badge on purpose
  F11   diagnostics panel
  F12   quit

The overlay is click-through, never takes focus, only draws while the game
window is in the foreground, and follows the game window when you alt-tab,
resize it or change resolution.

Liveness
  NGB_Overlay.log           what happened: state file, target window, errors
  ..\content\ngb-presentation\overlay_alive.txt
                            rewritten every 2 s while the overlay runs; the Lua
                            module reads it and reports "OVERLAY running" (or
                            not) in the Sider overlay and in state.json

Window targeting
  First it looks for a process called FL_2025 / FL2025 / FL25 / PES2021 or
  FootballLife2025. If none is found it falls back to the window that currently
  has focus (any exe name), as long as it is at least 640x360. F11 diagnostics
  and the start-up card draw on the primary screen even when no window is found,
  so the overlay can always be seen and can always say what it is waiting for.

One instance only: a second copy logs "already running" and exits.

You only need Start_NGB_Overlay.bat once. The Lua module starts the overlay
itself every time the game starts (renderer = overlay), so the .bat is a
first-time/repair tool, not a step in your routine.

Nothing appears? The overlay writes NGB_Overlay.log next to the exe, and for the
first 30 seconds after it starts it draws a small card that says either "state
file found" or "waiting for <path>". That tells you immediately whether the exe
is running or the Lua module is not writing state.json.

Play windowed or borderless fullscreen - exclusive fullscreen cannot show
layered windows. A CPK / livecpk root cannot replace this program: livecpk swaps
asset files, and the game's scoreboard graphics are static textures that cannot
be animated from live match data.
