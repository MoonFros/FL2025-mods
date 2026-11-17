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
  F10   cycle demo card   (goal -> shot -> MOTM -> off)
  F11   diagnostics panel
  F12   quit

The overlay is click-through, never takes focus, only draws while the game
window is in the foreground, and follows the game window when you alt-tab,
resize it or change resolution.

Play windowed or borderless fullscreen - exclusive fullscreen cannot show
layered windows.
