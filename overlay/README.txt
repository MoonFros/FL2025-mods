EA FC 27 Broadcast HUD - fc27-overlay
=====================================

Install:  copy this whole folder into your Sider folder so you get
          <Sider>\fc27-overlay\ ...  then run Start_FC27_Overlay.bat once.

Files
  FC27_Overlay.cs            the overlay source (no external libraries)
  app.manifest               DPI awareness (per-monitor v2)
  Start_FC27_Overlay.bat     compiles with Windows' own csc.exe and runs it
  Quit_FC27_Overlay.bat      stops it (same as F12)
  FC27_Overlay.exe           created by the .bat, not shipped
  FC27_Overlay.log           created at runtime, keeps the last ~512 KB

Hotkeys (global, work while the game has focus)
  F8    cycle demo card: goal -> shot -> MOTM -> off
  F9    diagnostics panel (stat region / pitch region / camera / names)
  F12   quit

The overlay is click-through and never takes focus from the game.
It only draws while the game window is in the foreground, and it follows the
game window when you alt-tab, resize it or change resolution.

Play windowed or borderless fullscreen - exclusive fullscreen cannot show
layered windows.
