================================================================================
  NEXT-GEN FOOTBALL BROADCAST PRESENTATION
  MOONFROS PRESENTS
  Created by MoonFros
  For Football Life 2025 / PES 2021  -  Sider 7  -  version 1.3.0
================================================================================

A broadcast presentation layer for Football Life 2025: goal cards with the real
scorer and minute, half-time and full-time score cards, a slim live score bug
and milestone call-outs, drawn over the game by a transparent click-through
overlay.

Everything on screen comes from Sider's own match library and goal hook, which
read the game directly. Nothing is guessed, and nothing is filled with zeros.

1.3.0 fixes the two things that made the mod look broken: the overlay could not
find the game window unless the process was called exactly FL_2025 / PES2021
(now it falls back to the focused window, and F11 always draws), and one goal
could produce two cards because the scoreboard updates seconds after Sider's
hook (goals are now counted, not timed). There is also a heartbeat file, so the
mod can tell you whether the overlay is running at all.

1.2.0 added the calibration toolchain (section 6) and labelled the F10 demo
cards as sample data, so you can watch every animation on your own PC.

1.1.0 was a rewrite of the data layer: the previous version tried to find the
per-player statistics table by scanning memory with guessed offsets, which
produced the famous "0 shots, 0 minutes, id #0" cards on builds where those
offsets were wrong. That is gone. See section 6 for exactly what is measured,
what is modelled and what is switched off until it is calibrated.


--------------------------------------------------------------------------------
 1. WHAT YOU GET  (and what needs calibrating)
--------------------------------------------------------------------------------

WORKS OUT OF THE BOX - scoreboard data, correct on every build
  * GOAL card: the scorer's name as the game prints it on the shirt, the
    minute from the match clock, the running score, the team colour, a
    milestone badge (OPENER / BRACE / HAT-TRICK / 4 GOALS / N GOALS...) and the
    entrance animation.
  * Unnamed goal card: if a goal reaches the scoreboard without the hook firing
    you still get a clean card with the minute and the score - never a fake
    player.
  * HALF TIME and FULL TIME cards: result, score line and every goal of the
    match with its scorer and minute.
  * LIVE SCORE BUG: clock, score and (in a shootout) the penalty score.
  * MILESTONE toasts, three presentation styles, 720p to 4K scaling.

NEEDS CALIBRATION - the per-player table (see section 6)
  * shots / shots on target / passes / rating per player
  * miss, save and blocked-shot reaction cards
  * shot analysis: trajectory, distance, angle, speed, xG
  * assists, per-player minutes, Man of the Match
  These need the game's per-player statistics table. Its location depends on
  your exact FL_2025.exe build, so it ships switched off (it would otherwise
  print zeros). The probe tool in section 6 collects what is needed to pin it
  down; once it validates, all of it switches on by itself.

NO IMAGE ASSETS: every card, pitch diagram, badge and animation is drawn
procedurally by the overlay, so the package stays tiny and stays sharp at 720p,
900p, 1080p, 1440p and 4K. Nothing is stretched from a bitmap.


--------------------------------------------------------------------------------
 2. REQUIREMENTS
--------------------------------------------------------------------------------

  * Football Life 2025 (FL_2025.exe) or PES 2021, with Sider 7
  * luajit.ext.enabled = 1 in sider.ini  -  install.bat adds it for you.
    (Without it Sider hides its memory library and the per-player extras.)
  * match-stats.enabled = 1 in sider.ini  -  install.bat adds this too.
    Sider's match library is what reports the live score and clock; without the
    line the mod can only see goals from its hook, with no score and no minute.
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
        - adds these three lines to sider.ini, next to your other lua.modules,
          after writing a backup (sider.ini.ngb.bak):

              luajit.ext.enabled = 1
              match-stats.enabled = 1
              lua.module = "NGB_Presentation.lua"

        - compiles and starts the overlay, then shows a confirmation.

     No other file in your Sider folder is modified. If another mod already set
     luajit.ext.enabled = 1, nothing is added twice; if it was set to 0 it is
     changed to 1 (live stats need it).

  3. Start the game. That's it.

  Manual install (if you ever need it): copy the two folders into your Sider
  folder, add the three lines above to sider.ini, then run
  ngb-overlay\Start_NGB_Overlay.bat once.

  The .bat is only a launcher: it compiles NGB_Overlay.exe the first time and
  starts it. After that the Lua module starts the overlay itself whenever the
  game starts (auto_launch_companion = 1), so you never need the .bat again.


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
 6. WHERE THE NUMBERS COME FROM  (please read)
--------------------------------------------------------------------------------

TIER 1 - always on, correct on every build
  Sider's match library (match-stats.enabled = 1) reports the score, the clock,
  the period, the added minutes and the penalty score. Sider's goal hook fires
  the moment a goal is scored and hands over the scorer's name, his id and which
  team scored. Both are read out of the game by Sider itself, so they cannot be
  "slightly off": either the line is in sider.ini and the numbers arrive, or the
  mod says so in the Sider overlay (press the overlay key) and in sider.log.

  Everything in section 1 under "works out of the box" is this tier: goal cards
  with the real scorer and minute, the score line, half time, full time, the
  score bug, milestone counts (the mod counts the goals it saw, so a brace and a
  hat-trick are real counts).

TIER 2 - the per-player statistics table, off until calibrated
  Shots, shots on target, passes, ratings, assists and the engine's minutes live
  in a per-player table inside the game's memory. Its location is specific to
  the exact FL_2025.exe build. The previous version guessed it, which is where
  the "0 shots, 0 min, id #0" cards came from. This version does not guess:

    * experimental_player_stats = 0 by default.
    * When you set it to 1, the mod reads its candidate table and validates it
      against the scoreboard: 22 readable players, shots >= shots on target, and
      a goal total that covers the score. Only a table that passes is used.
    * probe_enabled = 1 writes content\ngb-presentation\probe.txt with the
      scoreboard values, a hexdump of the scoreboard block and a map of the
      game's memory regions.

  CALIBRATION IN ONE FILE (recommended)
    1. In NGB_Presentation.ini set:
           experimental_player_stats = 1
           probe_enabled             = 1
           probe_dump_region         = 1
    2. Play until a goal is scored, then quit the game.
       content\ngb-presentation\ now holds probe_region.bin (the private region,
       up to 4 MB) and probe_region.txt (its address, the score, the layout).
    3. Run the decoder on those two files:
           python tools\decode_probe.py probe_region.bin --write "C:\path\content\ngb-presentation"
       It searches the dump for the record grid whose goal counts reproduce the
       scoreboard and writes calibration.txt. The mod reads that file at start.
    4. Start the game. Goal cards now carry the stat row, and miss/save cards
       and shot telemetry switch on by themselves once validation passes.
    No Python? Send probe_region.bin and probe_region.txt and the decoder runs
    on the other side; the answer is a six line calibration.txt.

  The layout can also be pinned by hand in the ini (stat_rec_base,
  stat_side_stride, stat_rec_stride, stat_kind_stride, stat_kind_offset,
  stat_buckets) - the six numbers the decoder prints.

TIER 3 - modelled, never presented as measured
  Shot speed, apex, hang time, elevation and xG are computed from real distance,
  real angle and the shooter's real kicking-power attribute. They appear with a
  "~" prefix and "MODELLED" in the card footer. Football Life exposes no measured
  ball speed, so no measured ball speed is claimed.

Any statistic the game does not provide is omitted or marked. Nothing is random,
and nothing is filled with zeros to look complete.


--------------------------------------------------------------------------------
 7. LIMITATIONS
--------------------------------------------------------------------------------

  * Per-player numbers (section 6, tier 2) need calibration on your build. Until
    then the goal cards show the scorer, minute and score and no stat row at all.
  * No miss / save / blocked-shot cards without tier 2: without the shots
    counter there is nothing to detect them from. They appear once the table is
    calibrated.
  * No player portraits: FL25 does not expose face textures to Lua. The overlay
    uses the game's own close-up and keeps its card low and wide instead.
  * Video quality: an overlay can draw over the game, it cannot re-render the
    game. Broadcast-style replays with new camera work need the game's replay
    system, not a CPK.
  * A CPK root (livecpk) cannot do any of this: livecpk swaps asset files -
    textures, models, .bin data. The game's scoreboards are static textures and
    cannot be animated from live data. Every animated live graphic in this mod
    comes from the overlay process, which is why it exists.
  * Exclusive fullscreen cannot show overlays. Use borderless or windowed.
  * The replay camera is moved by patching the game's own replay camera
    constants during goal replays. If a future build moves them, the mod detects
    it and leaves the camera alone instead of guessing.


--------------------------------------------------------------------------------
 8. TROUBLESHOOTING
--------------------------------------------------------------------------------

  Nothing appears in the game  (check in this order)
    1. Is the companion running? Open the Sider overlay (its key while playing).
       One line reads either
           OVERLAY   running 1.3.0   (cards draw over the game)
       or
           OVERLAY   NOT RUNNING  ->  run ngb-overlay\Start_NGB_Overlay.bat
       The same answer is in content\ngb-presentation\overlay_alive.txt: the
       companion rewrites it every two seconds.
    2. Press F11 in game. The diagnostics panel now draws even when no game
       window is recognised, and its first two lines are
           target       :  game process FL_2025.exe   (or "focused window of ...")
           drawn on     :  1920x1080 game              (or "primary screen")
       If it says "no window found", the overlay is alive but could not see the
       game - the panel still tells you so instead of staying invisible.
    3. Read <Sider>\ngb-overlay\NGB_Overlay.log. It logs the target window, the
       state file it watches, and whether the file exists.
    4. Borderless or windowed only. In exclusive fullscreen a layered window is
       not composited and nothing can appear.
    5. Windows 7/8 compat mode, or an antivirus blocking a new exe, also stops
       the window from showing; the log records the start-up line either way.

  Cards appear but the score and clock are 0
    - match-stats.enabled = 1 is missing from sider.ini. The mod says so in the
      Sider overlay ("ENGINE OFF -> add match-stats.enabled = 1") and in
      sider.log. Add the line, restart the game.

  A goal shows the team but no player name
    - The goal hook did not fire for that goal (the scoreboard reported it
      instead). The card is deliberately unnamed rather than guessing.
    - If it happens for every goal, check that luajit.ext.enabled = 1 is in
      sider.ini and that you are on Sider 7.3 or newer.

  Shots / assists / ratings show nothing
    - That is tier 2 (section 6): the per-player table is not calibrated for
      your exe build. Follow "calibration in one file" in section 6: set the
      three keys, play until a goal, then run tools\decode_probe.py on
      probe_region.bin. Until the table validates, the cards stay clean instead
      of printing zeros.

  "WARNING: LuaJIT FFI is off" in sider.log
    - Add luajit.ext.enabled = 1 to sider.ini (install.bat does this).

  Player names show as "PLAYER 11"
    - Only affects the tier-2 paths. Player.bin had not loaded yet (first
      seconds after launch) or your build keeps it elsewhere - see debug_log.

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

  1.3.0  Made visible and de-duplicated.
         - the overlay finds the game window by name OR falls back to the
           focused window, so a differently named exe no longer means a blank
           screen
         - F11 diagnostics and the start-up card draw even with no window found
           (primary screen fallback) and show the target and the state age
         - heartbeat file overlay_alive.txt: the mod can report whether the
           companion is running, in the Sider overlay and in state.json
         - one goal can no longer produce two cards: the hook is authoritative
           and the scoreboard is matched against it by count, with a short grace
           window (goal_fallback_delay_ms) for a slow hook
         - full time is detected from the clock actually stopping instead of an
           unverified "clock is running" byte
         - single instance: a second copy exits instead of stacking cards
         - a state file that stops updating is dropped, so no frozen score bug
           is left behind after the game closes

  1.2.0  Calibration toolchain.
         - probe_dump_region writes the private stats region byte for byte
         - tools/decode_probe.py finds the record grid that reproduces the
           scoreboard and writes calibration.txt (delete it to reset)
         - the per player layout can be pinned from calibration.txt or the ini,
           so a rebuild needs no source edit
         - the in-game shot card now draws the animated shot-data panel whenever
           an event carries telemetry
         - F10 demo cards carry a DEMO - SAMPLE DATA badge, so the animations
           can be previewed without a match and never pass for live data

  1.1.0  Data layer rewritten around Sider's own match library and goal hook.
         - goals, scorer name, minute, score, half time, full time and the score
           bug now work on any build, with no memory offsets involved
         - installer adds match-stats.enabled = 1 as well
         - the per-player scan is off by default and only publishes numbers
           after it validates against the scoreboard, so the "0 shots / id #0"
           cards are gone
         - probe.txt for calibrating the per-player table on a new exe build
         - the overlay draws a startup card and writes overlay_log.txt, so a
           missing state file is visible instead of a blank screen
         - score bug on by default (instant proof that the overlay is alive)

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
