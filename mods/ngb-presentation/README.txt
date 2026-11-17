================================================================================
  NEXT-GEN FOOTBALL BROADCAST PRESENTATION
  MOONFROS PRESENTS
  Created by MoonFros
  For Football Life 2025 / PES 2021  -  Sider 7  -  version 1.0.1
================================================================================

A broadcast presentation layer for Football Life 2025: live player spotlights,
animated goal analysis, milestone call-outs and a full-time Man of the Match
reveal, drawn over the game by a transparent click-through overlay.

Reads only data the game already keeps in memory - it never invents a number.


--------------------------------------------------------------------------------
 1. WHAT YOU GET
--------------------------------------------------------------------------------

GOAL PRESENTATION
  * Player spotlight: name, shirt number, team, position, minutes played,
    goals, assists, shots, shots on target.
  * Shot analysis: original shot position, trajectory from that position to the
    goal, goal location, distance, angle, modelled speed and xG.
  * Milestone badge on the card: OPENER / FIRST GOAL / BRACE / HAT-TRICK /
    4 GOALS / N GOALS.
  * Assist credit as a separate toast when the game records one.

SHOT / REACTION PRESENTATION
  * Every shot that is not a goal (on target, off target, blocked, saved) pops
    the shooter's live match totals, sized to sit low and wide so it never
    covers the player's face in the reaction cam.

LIVE PERFORMANCE TRACKER
  * One player-statistics model feeds every card, so the numbers are identical
    everywhere and update the moment the game records an event.

MAN OF THE MATCH REVEAL
  * Full-time card with a gold treatment, rating ring, and goals, assists,
    shots, on target, passes, pass %, touches and minutes.

MILESTONES
  * Brace, hat-trick and bigger hauls get a badge on the card and a short toast;
    assists get their own toast sign-off.

Three presentation styles (full / compact / minimal) so you can dial the amount
of graphics up or down without touching a file.

NO IMAGE ASSETS: every card, pitch diagram, badge and animation is drawn
procedurally by the overlay, so the package stays tiny and stays sharp at 720p,
900p, 1080p, 1440p and 4K. Nothing is stretched from a bitmap.


--------------------------------------------------------------------------------
 2. REQUIREMENTS
--------------------------------------------------------------------------------

  * Football Life 2025 (FL_2025.exe) or PES 2021, with Sider 7
  * luajit.ext.enabled = 1 in sider.ini  -  install.bat adds it for you.
    (Without it Sider hides its memory library and live stats are impossible.)
  * Windows 10 or 11, 64-bit. Nothing else to download: the overlay is compiled
    on your PC by the C# compiler that ships with .NET Framework 4.x.
  * Play WINDOWED or BORDERLESS fullscreen. Exclusive fullscreen cannot show any
    overlay - that is a Windows limitation, not a mod bug.


--------------------------------------------------------------------------------
 3. INSTALL  (extract, run install.bat, play)
--------------------------------------------------------------------------------

  1. Extract this folder anywhere (it does not matter where).

  2. Double-click  install.bat

     It finds your Sider folder automatically (all drives are checked). If it
     cannot, drag the Sider folder - the one with sider.exe and sider.ini - onto
     the black window and press Enter.  install.bat then:

        - copies modules\NGB_Presentation.lua and .ini into <Sider>\modules\
        - copies ngb-overlay\ into <Sider>\ngb-overlay\
        - adds these two lines to sider.ini, next to your other lua.modules,
          after writing a backup (sider.ini.ngb.bak):

              luajit.ext.enabled = 1
              lua.module = "NGB_Presentation.lua"

        - compiles and starts the overlay, then shows a confirmation.

     No other file in your Sider folder is modified. If another mod already set
     luajit.ext.enabled = 1, nothing is added twice; if it was set to 0 it is
     changed to 1 (live stats need it).

  3. Start the game. That's it.

  Manual install (if you ever need it): copy the two folders into your Sider
  folder, add the two lines above to sider.ini, then run
  ngb-overlay\Start_NGB_Overlay.bat once.


--------------------------------------------------------------------------------
 4. HOTKEYS
--------------------------------------------------------------------------------

IN GAME (handled by the Lua module):

  [7]   previous / alternative presentation option
        cycles  FULL  ->  COMPACT  ->  MINIMAL
  [8]   main presentation overlay ON / OFF
  [9]   shot analysis / trajectory ON / OFF

  These are configurable in modules\NGB_Presentation.ini and are deliberately
  NOT F7 / F8 / F9. Key [1] is left completely alone: it belongs to Sider
  (overlay control) and this mod never registers, blocks or remaps it.

  By default (hotkeys_overlay_only = 1) the digits only act while the Sider
  overlay is open, so they can never clash with the game's own 7 / 8 / 9 keys.
  Set hotkeys_overlay_only = 0 if you want them during open play.

  Every action shows a short confirmation toast, and the in-game overlay text
  always states the current state:
        PRESENTATION ON   STYLE FULL   ANALYSIS ON

OVERLAY WINDOW (only when you want to check it):

  F10   cycle a demo card (goal -> shot -> MOTM -> off)
  F11   diagnostics panel (regions, style, units, state file)
  F12   quit the overlay


--------------------------------------------------------------------------------
 5. CONFIGURATION
--------------------------------------------------------------------------------

  modules\NGB_Presentation.ini  -  edit with the game closed.

  units                    metric (km/h, m) or imperial (mph, yd, ft)
  presentation_enabled     master switch
  presentation_style       0 full, 1 compact, 2 minimal
  shot_analysis_enabled    show the trajectory diagram in the goal card
  goal_telemetry_duration  seconds the goal card stays up
  goal_telemetry_delay     delay so the card lands as the replay starts
  shot_popup_duration      seconds a shot card stays up
  motm_card_duration       seconds the Man of the Match card stays up
  milestone_toast_enabled  brace / hat-trick / assist toasts
  replay_camera_enabled    subtle replay camera move on goals
  replay_camera_preset     1 subtle, 2 higher, 3 leave the camera alone
  show_scorebug            optional slim score line (off by default)
  stats_poll_ms            how often player stats are sampled
  position_poll_ms         how often player positions are sampled
  hotkey_*                 the three in-game keys
  debug_log                extra detail in sider.log


--------------------------------------------------------------------------------
 6. WHAT IS REAL DATA AND WHAT IS CALCULATED  (please read)
--------------------------------------------------------------------------------

REAL, read from the game:
  * player names, shirt numbers, registered position, height, kicking power
    (from Player.bin)
  * teams, abbreviations, kit colours, score, clock, period, match stage
  * goals, own goals, assists, shots, shots on target, passes, pass %, tackles,
    dribbles, touches, saves, interceptions, clearances, cards, the engine's own
    match rating
  * the 22 live player positions on the pitch
  * the shot's starting position, therefore the real shot distance and the real
    angle the goal subtends from that position

CALCULATED from that real data - and labelled as modelled in the interface:
  * shot speed ("~" prefix in the card, "SPEED MODELLED" in the card footer):
    derived from the shooter's real kicking-power attribute and the real
    distance. Football Life does not expose a measured ball speed, so this is an
    estimate, never presented as a measurement.
  * apex height, hang time and the elevation angle: ballistic solution that
    actually reaches the recorded goal-face target.
  * xG: a logistic model of real distance and real angle.
  * minutes played: the game keeps no per-player minutes counter, so the mod
    records the match minute at which each player was first seen on the pitch.
    Starters are exact; a substitute's figure is marked with "~".

Anything the game does not provide is either omitted or clearly marked. No
statistic is random and nothing is presented as a measurement when it is not.


--------------------------------------------------------------------------------
 7. LIMITATIONS
--------------------------------------------------------------------------------

  * No player portraits: FL25 does not expose face textures to Lua. The mod uses
    the game's own close-up and keeps its card low and wide instead.
  * Shot trajectory is drawn from the shooter's real position to the recorded
    goal-face target, not from raw ball physics every frame. Where the shooter's
    position was not available the card says the origin is estimated.
  * The replay camera is moved by gently patching the game's own replay camera
    constants during goal replays; exact baseline values are restored afterwards.
    If a future game build moves those constants, the mod detects it and leaves
    the camera untouched instead of guessing.
  * Player close-up detection is not exposed, so the shot/reaction card is timed
    from the shot event itself (a few seconds), which is when broadcasters show
    the reaction.
  * Exclusive fullscreen cannot show overlays.


--------------------------------------------------------------------------------
 8. TROUBLESHOOTING
--------------------------------------------------------------------------------

  Nothing appears at all
    - Is lua.module = "NGB_Presentation.lua" in sider.ini?
    - Open sider.log and search for "[NGB]". You should see the banner, then
      "state file: ...", then "ready".

  "WARNING: LuaJIT FFI is off" in sider.log
    - Add luajit.ext.enabled = 1 to sider.ini (install.bat does this).

  "stat region not found" in the F11 diagnostics
    - The scan runs up to three times at kick-off; wait for a match.
    - Set debug_log = 1 and look for "[NGB] stats region @ 0x..." in sider.log.
    - Worst case, paste the address into stats_region_base in the .ini.

  Player names show as "PLAYER 11"
    - Player.bin had not loaded yet (only in the first seconds after launch),
      or your build keeps it somewhere else - check debug_log output.

  Overlay invisible while the game runs
    - Use borderless / windowed.
    - The game window must be the foreground window; the overlay re-attaches
      within a second. Press F12, then run ngb-overlay\Start_NGB_Overlay.bat.

  Keys 7 / 8 / 9 do nothing
    - Open the Sider overlay first (hotkeys_overlay_only = 1 is the default), or
      set hotkeys_overlay_only = 0.

  Keys 7 / 8 / 9 also trigger game tactics
    - That is the game reading the same keys. Keep hotkeys_overlay_only = 1, or
      change hotkey_* in the .ini to keys you do not use.

  The overlay build fails with error CS.... (compiler messages in the window)
    - The build is plain C# for .NET Framework 4.x and compiles with no
      downloads. If you see errors, copy the text of the window and send it on;
      meanwhile ngb-overlay\NGB_Overlay.exe from an earlier build still starts.
    - "csc.exe not found" means .NET Framework 4.x is missing: install
      .NET Framework 4.8 from Windows Update and run Start_NGB_Overlay.bat.


--------------------------------------------------------------------------------
 9. FILES INSTALLED
--------------------------------------------------------------------------------

  <Sider>\modules\NGB_Presentation.lua          the module
  <Sider>\modules\NGB_Presentation.ini          its settings
  <Sider>\ngb-overlay\                          overlay source + build scripts
  <Sider>\ngb-overlay\NGB_Overlay.exe           compiled on your PC
  <Sider>\content\ngb-presentation\state.json   runtime state (created at play)
  sider.ini                                     two added lines (+ .ngb.bak)


--------------------------------------------------------------------------------
10. UNINSTALL
--------------------------------------------------------------------------------

  Run uninstall.bat from this folder and confirm. It removes exactly the files
  listed above and this mod's lua.module line in sider.ini (the .ngb.bak backup
  from install is left next to it), and never deletes other mods or settings.

  One deliberate exception:  luajit.ext.enabled = 1  is left switched on,
  because other mods may use it too and Sider has no way to tell who turned it
  on. It costs nothing when unused.


--------------------------------------------------------------------------------
11. CHANGES
--------------------------------------------------------------------------------

  1.0.1  First build compiled on Windows:
         - fixed  NGB_Overlay.cs: TextRenderingHint needed
                  using System.Drawing.Text
         - fixed  NGB_Overlay.cs: the shirt number drew a Color where a
                  Brush was expected (player spotlight card)
         - removed two unused EA-flavoured colour aliases from the overlay
         - corrected leftover naming in the module header and comments;
                  the default team colour is now the MoonFros accent #D8F26B
  1.0.0  First release.


--------------------------------------------------------------------------------
12. CREDITS
--------------------------------------------------------------------------------

  Concept, Lua module, overlay, installer and design: MoonFros
  Built for Football Life 2025 / PES 2021 on Sider 7.

  MOONFROS PRESENTS  -  Next-Gen Football Broadcast Presentation
================================================================================
