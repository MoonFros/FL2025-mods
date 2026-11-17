================================================================================
  NEXT-GEN FOOTBALL BROADCAST PRESENTATION
  MOONFROS PRESENTS
  Created by MoonFros
  For Football Life 2025 / PES 2021  -  Sider 7  -  version 2.0.1
================================================================================

A broadcast presentation layer for Football Life 2025: goal cards with the real
scorer and minute, half-time and full-time score cards, a slim live score bug,
shot analysis and milestone call-outs.

2.0 changed HOW it is drawn. There is no second window any more. A small DLL
(ngb-render\NGB_Render.dll) is loaded into the game process by the module and
draws the cards inside the game's own frame, during Present. That is why it now
works in windowed, borderless AND exclusive fullscreen, and why it keeps working
when the game is NOT focused - which is how you play:

    "I play windowed and deliberately click the desktop so the game is not
     focused, because the game runs faster unfocused."

    That case is now the normal case. Nothing in the renderer looks at which
    window has focus.

Everything on screen still comes from the game: Sider's match library, the goal
hook, and the scoreboard. Nothing is guessed, and nothing is filled with zeros.

2.0 fixes the ten reported problems (see CHANGELOG.md for the individual
verdicts): the focus rule, the wrong-window fallback, the guessed exe names, the
unverified event names, the Sider version assumptions, the circular tests, the
unproven stat offsets ("0 shots, 2 goals"), the FFI/Win32 risk, the uninstall
script bug, and the fact that a separate window cannot draw over exclusive
fullscreen.

WHAT IS STILL UNVERIFIED: anything that needs Football Life running. The event
names, the memory reads, exclusive fullscreen with the DLL and every visual are
marked UNVERIFIED in CHANGELOG.md until you have run them. Section 8 tells you
which file to read when something does not show.


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
  * Windows 10 or 11, 64-bit. Nothing to download and nothing to compile: the
    renderer ships as a prebuilt x64 DLL (ngb-render\NGB_Render.dll).
  * Any display mode: windowed, borderless or exclusive fullscreen. The cards
    are drawn inside the game's own frame, so all three work. (The optional C#
    fallback still cannot draw over exclusive fullscreen - that is the Windows
    limitation the DLL exists to remove.)


--------------------------------------------------------------------------------
 3. INSTALL  (extract, run install.bat, play)
--------------------------------------------------------------------------------

  1. Extract this folder anywhere (it does not matter where).

  2. Double-click  install.bat

     It finds your Sider folder automatically (all drives are checked). If it
     cannot, drag the Sider folder - the one with sider.exe and sider.ini - onto
     the black window and press Enter.  install.bat then:

        - copies modules\NGB_Presentation.lua and .ini into <Sider>\modules\
        - copies ngb-render\ into <Sider>\ngb-render\   (the renderer DLL)
        - copies ngb-overlay\ into <Sider>\ngb-overlay\ (optional fallback)
        - adds these three lines to sider.ini, next to your other lua.modules,
          after writing a backup (sider.ini.ngb.bak):

              luajit.ext.enabled = 1
              match-stats.enabled = 1
              lua.module = "NGB_Presentation.lua"

        - checks that the renderer landed, then shows where every log is.

     Nothing is compiled. If you see the old "error CS..." message you are
     running a 1.x copy of this folder.

     No other file in your Sider folder is modified. If another mod already set
     luajit.ext.enabled = 1, nothing is added twice; if it was set to 0 it is
     changed to 1 (live stats need it).

  3. Start the game. That's it.

  Manual install (if you ever need it): copy modules\, ngb-render\ (and, only
  if you want the fallback, ngb-overlay\) into your Sider folder and add the
  three lines above to sider.ini. Nothing has to be started by hand: the module
  loads ngb-render\NGB_Render.dll into the game itself at startup.


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

RENDERER (handled by NGB_Render.dll, works even when the game is not focused):

  F8    SELF-TEST: draws a card stamped "DEMO - NOT REAL DATA" through the real
        render path. If this appears, the renderer works and the problem is
        data, not drawing. This is the single most useful key in the mod.
  F7    diagnostics strip: back buffer size, state file age, frames drawn,
        kill-switch state, fault count, log path
  F12   kill switch: cards ON / OFF without restarting the game
        (the same switch as dll_enabled = 0 in the ini, applied at runtime)

C# FALLBACK WINDOW (only if renderer = overlay):

  F10   cycle a demo card    F11   diagnostics panel    F12   quit


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

  RENDERER

  renderer                 dll (default) / overlay (C# fallback) / none
  dll_enabled              1 = cards on, 0 = the DLL is never even hooked.
                           The same switch as F12 at runtime.
  dll_selftest_hotkey      default 0x77 = F8, draws the DEMO card
  dll_diag_hotkey          default 0x76 = F7, diagnostics strip
  dll_kill_hotkey          default 0x7B = F12, cards on / off
  state_write_hz           how often state.json is published (1-30, default 10)
  experimental_player_stats  0 = per-player numbers off (see section 6)

  allow_unsafe_memory_reads  0 (default) = memory is read only through the
                           renderer DLL, which cannot crash the game.
                           1 = also allow Sider's raw memory library when the
                           DLL is not in use. That library dereferences
                           addresses directly, so one wrong address is a
                           crashed game. Do not set this to 1 unless you have
                           a reason to: without the DLL, live player numbers
                           are simply switched off, and the score, clock and
                           goal cards still work.


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
  * The C# fallback window cannot appear over exclusive fullscreen (Windows
    limitation). The default renderer - the DLL - can, because it draws inside
    the game's own frame.
  * The replay camera is moved by patching the game's own replay camera
    constants during goal replays. If a future build moves them, the mod detects
    it and leaves the camera alone instead of guessing.


--------------------------------------------------------------------------------
 8. TROUBLESHOOTING
--------------------------------------------------------------------------------

  WHY NOTHING SHOWS  (check in this order)

    0. PRESS F8 FIRST.
       A card stamped "DEMO - NOT REAL DATA" appears
            -> the renderer works. The problem is data, not drawing. Go to 3.
       Nothing appears
            -> the renderer is not running. Go to 1.

    1. Is the DLL loaded?
       <Sider>\content\ngb-presentation\ngb-dll.log   (and render.txt)

         no ngb-dll.log at all ......... the module never tried to load the DLL.
                                         Read sider.log for the [NGB] line
                                         "renderer: NO DLL at ..." or
                                         "renderer: disabled by configuration".
         "NO DLL at ..." ............... wrong folder. Re-run install.bat; the
                                         file belongs in <Sider>\ngb-render\.
         "ffi off" ..................... add luajit.ext.enabled = 1 to sider.ini.
         "LoadLibraryA failed" ......... wrong/32-bit file, or blocked by AV.
         "hooks installed: Present=..." the renderer is live. If F8 still shows
                                         nothing, send me this file.
         "FATAL: exception 0x... " ..... the renderer caught its own fault and
                                         switched itself off. The game keeps
                                         running. Send me that line.

    2. Is the module alive?
       <Sider>\content\ngb-presentation\heartbeat.txt is rewritten every second.

         ticks=0 ....................... the module never ticked: display_frame
                                         is not firing AND the Sider overlay was
                                         never opened. sider.log will show each
                                         ctx.register line and "event 'x' fired
                                         for the first time" when one works.
         tick_source=display_frame ..... good, the per-frame event works.
         tick_source=overlay_on ........ only ticks while the Sider overlay is
                                         open; the DLL still renders, but goals
                                         are then detected from the scoreboard
                                         watcher alone.
         state_writes_ok=0 ............. state.json cannot be written (folder
                                         permissions, or the game is on a
                                         read-only drive).
         renderer=overlay .............. the DLL was not used; renderer_detail
                                         says why.
         last_error=................... the last exception the module caught.

       sider.log lines that start with [NGB] describe the whole environment on
       the first run: module version, Sider folder, Lua version, LuaJIT, whether
       ffi/bit exist, whether the memory and match libraries exist, and every
       ctx.register result.

    3. Is the data arriving?
       <Sider>\content\ngb-presentation\state.json - check "match.live",
       "match.home.score", "event" and "diag".

         no state.json ................. the module is not writing. See 2.
         "live": false during a match .. the scoreboard is not being read. Check
                                         status.data.scoreboard (want "sider")
                                         and that match-stats.enabled = 1 is in
                                         sider.ini.
         "event": null during a goal ... no goal was detected. Check
                                         status.data.scorer_hook.
         player numbers all "UNAVAILABLE"  the memory backend is off. Look for
                                         "MEMORY" in the F7 strip (Sider overlay):
                                           dll .................. normal
                                           none ................. no DLL, so no
                                                                   safe reader
                                           SIDER RAW ............ you set
                                                                   allow_unsafe_memory_reads
                                                                   = 1; the game
                                                                   can crash

    4. Numbers look wrong
       diag.stats_coherent / status.data.stats_coherent is false when the player
       numbers disagree with the scoreboard - that is the guard against
       "0 shots, 2 goals". The card then shows PLAYER DATA UNAVAILABLE instead of
       the numbers, and sider.log holds the reason, e.g.
           stats coherence -> false  (player 3/7: 0 shots but 2 goals)

  The C# fallback (renderer = overlay) has its own files:
  <Sider>\ngb-overlay\NGB_Overlay.log and overlay_alive.txt.

  Nothing shows when the game is NOT focused
    That is the case this version was rebuilt for. If it still happens:
      - check ngb-dll.log for "hooks installed" (if the hook is not in, the
        fallback window was used, and the fallback only draws on a window it can
        identify);
      - press F8 while the game is unfocused. The self-test card is drawn from
        the same Present call as everything else, so if F8 works the renderer is
        fine and the cards are simply not being fed data (step 3).

  Cards flicker or vanish during alt-tab / resolution changes
    That is a ResizeBuffers cycle. The renderer releases its size-dependent
    objects before the buffers change and rebuilds on the next frame; a one
    frame gap is expected, a permanent blank is not - report it with the log.

  The game crashes on start
    Remove ngb-render\NGB_Render.dll and start again. If the game is fine
    without it, send me ngb-dll.log (it is written before anything is hooked).
    Nothing else in the mod can crash the game: the Lua module runs inside
    Sider's pcall.

--------------------------------------------------------------------------------
 9. FILES INSTALLED
--------------------------------------------------------------------------------

  <Sider>\modules\NGB_Presentation.lua          the module
  <Sider>\modules\NGB_Presentation.ini          its settings
  <Sider>\ngb-render\NGB_Render.dll             the renderer (prebuilt, x64)
  <Sider>\ngb-overlay\                          optional C# fallback
  <Sider>\content\ngb-presentation\state.json   runtime state (rewritten 10x/s)
  <Sider>\content\ngb-presentation\heartbeat.txt  module alive, 1/s
  <Sider>\content\ngb-presentation\render.txt     renderer alive, 1/s
  <Sider>\content\ngb-presentation\ngb-dll.log    renderer log
  <Sider>\content\ngb-presentation\calibration.txt  only after calibration
  sider.ini                                     three added lines (+ .ngb.bak)


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

  2.0.1  Memory reads go through the DLL. Sider's memory library reads an
         address by dereferencing it, so a single stale pointer could end the
         game; ReadProcessMemory cannot. Without the DLL, live player numbers
         are switched off instead of guessed.
  2.0.0  The renderer moved inside the game.
         - New: ngb-render\NGB_Render.dll hooks IDXGISwapChain::Present and
           draws the cards on the game's own back buffer. Windowed, borderless
           and exclusive fullscreen; focused or not. No second window, no
           loader to compile - the module loads the DLL into the game.
         - Safety: hardware SEH around the hook; on any fault it logs the
           exception, disables itself and lets the game run. F12 kill switch,
           dll_enabled = 0 installs no hooks at all. The DLL writes only its own
           log and render.txt.
         - Fixed: the overlay no longer requires the game to be the foreground
           window (this was the reason nothing showed in windowed+unfocused
           play).
         - Fixed: the window is found from the PID/exe the game itself writes
           into state.json (or from the process holding sider.dll), never from
           "whatever has focus", and never from a list of guessed names.
         - Fixed: per-player stats can no longer print "0 shots, 2 goals" - a
           coherence check compares them with the scoreboard every two seconds
           and the card says PLAYER DATA UNAVAILABLE instead. The feature is
           still off by default until your build's table is calibrated.
         - Fixed: uninstall.bat now edits sider.ini correctly (the PowerShell
           else that made it fail is gone; tools\test_ini.bat proves it).
         - New: heartbeat.txt, render.txt, a diag/game block in state.json,
           F7 diagnostics and F8 self-test. Never a silent failure.
         - New: verify_mod.py rebuilds the DLL and runs host tests for the JSON
           reader (against a real state.json) and the card layout (six
           resolutions). The offline suite is no longer circular.
         - Removed: WinExec/Auto-launch of a companion process, ReadProcessMemory,
           VirtualQuery, VirtualProtect, __asm__ FFI aliases, GetTickCount64.

  1.3.1  The overlay actually compiles again.
         - 1.1.0 - 1.3.0 put [STAThread] on the version constant instead of on
           Main, so csc refused the file: no exe was ever produced and every
           fix since 1.1.0 was invisible for that reason alone
         - install.bat now stops with INSTALL INCOMPLETE and the compiler
           messages instead of announcing success
         - Start_NGB_Overlay.bat warns loudly when it falls back to an older
           exe (and prints when that exe was built)
         - the Sider overlay reports "OVERLAY STALE <version>" when the exe is
           older than the module, which is the other way this can look broken

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
