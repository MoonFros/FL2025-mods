# CHANGELOG — Next-Gen Broadcast Presentation 2.0

This release is the "make it actually work in the real game" pass. It is not a
feature release: every item below is one of the ten problems that were reported
after the 1.x testing, plus the changes that were needed to fix them.

**How to read the status column**

| status | meaning |
| --- | --- |
| **FIXED — verified** | reproduced here, fixed, and checked by an automated test that runs in this repository |
| **FIXED — UNVERIFIED in game** | the code is changed and the reasoning is sound, but it can only be *proven* on your machine with FL_2025.exe. It is never claimed as working. |
| **UNVERIFIED** | not reproduced or not changed; treat as still broken until proven |

You will notice that many rows say "UNVERIFIED in game". That is deliberate. No
test in this repository can start Football Life, so anything that depends on the
game process is marked honestly instead of being called a success.

---

## 1. Focus bug — overlay drew nothing while the game was unfocused

**Reproduced.** `ComputeGameRect()` in `ngb-overlay/NGB_Overlay.cs` required the
foreground window to belong to the game's PID. In your setup (windowed, desktop
clicked on purpose) that is *never* true, so the overlay hid itself.

**Fixed.** That rule is deleted. The overlay now draws whenever the game window
is visible and not minimised (`IsIconic` / `IsWindowVisible` only). Cards are
laid out from the window's *client rect*, so an unfocused window in the
background is still a valid surface.

**Verified.** `verify_mod.py` regression checks: `cs: ComputeGameRect does not
look at the foreground window`, `cs: overlay hides only when minimised /
invisible`, and `cs: GetForegroundWindow is declared but never called`. Plus a
structural test that the C# code no longer contains the rule at all.
**In game: UNVERIFIED** — needs your windowed-unfocused session.

---

## 2. Wrong-window fallback — the overlay could attach to a browser or the desktop

**Reproduced.** `ProbeGameWindow()` fell back to "the focused window of any
other process that is at least 640×360", so with focus on a chat window the
overlay happily drew its cards over it.

**Fixed.** That fallback is gone. Attachment now happens in this order, and
every step is information *the game itself wrote down*:

1. the PID in `state.json` (written from inside the game with
   `GetCurrentProcessId`),
2. the exe name in `state.json` (read with `GetModuleFileNameA`),
3. a process that has `sider.dll` loaded (only the game loads it),
4. the previous window, if it still exists and is visible.

If none of those produce a window the overlay attaches to nothing: it keeps its
diagnostics panel (which can sit on the primary screen) and logs
`target: no game window yet`. Drawing on an unrelated window is worse than
drawing nothing.

**Verified.** Checks `cs: no 'focused window of another process' fallback`,
`cs: attaches by pid from state.json`, `cs: falls back to the sider.dll
process`, plus the Lua-side `state: game block` tests (pid/exe/hwnd/backbuffer
are published, empty when unknown).
**In game: UNVERIFIED.**

---

## 3. Guessed process names — `KNOWN_GAMES`

**Reproduced.** The overlay carried a list of guessed exe names
(`FL_2025`, `FL2025`, `FL25`, `PES2021`, …). Any name the list did not contain
meant "no game window".

**Fixed.** The list is deleted. `state.json` now carries a `game` block:

```json
"game": { "pid": 12345, "exe": "FL_2025.exe", "exe_path": "D:\\...\\FL_2025.exe",
          "pid_source": "ffi", "hwnd": "0x00120A3C", "backbuffer": "2560x1440",
          "renderer_fps": "", "renderer_frames": "", "renderer_enabled": "" }
```

`pid`/`exe` come from inside the game. `hwnd`/`backbuffer` come from the
renderer DLL (the only component that sees the swapchain); they are empty
strings until the DLL is running, never guesses.

**Verified.** Lua functional run asserts the block exists; the DLL's JSON test
asserts `game.pid` and `game.exe` are readable from a real `state.json`.
**In game: UNVERIFIED** (the values themselves can only be seen on your PC).

---

## 4. Unverified Sider event names

**Reproduced and resolved by reading the Sider source, not by guessing.** The
event names were checked against `sider.cpp` (Sider 7.4 tree):
`display_frame`, `overlay_on`, `key_down`, `set_teams`, `set_match_settings`,
`goal_scored`, `context_reset`, `livecpk_data_ready` are all real. Sider has no
per-frame event *other* than `display_frame`, and `overlay_on` only fires while
the Sider overlay is open.

**Fixed, in three parts:**

* `ctx.register` is a `void` C function — it cannot report success. So the
  module logs every registration and then *proves* each one by counting the
  first time the handler actually runs:
  `[NGB] event 'display_frame' fired for the first time (after 812 ms)`.
  If `display_frame` never fires you will see it in `heartbeat.txt`
  (`ticks_from=` empty) and in the diagnostics panel.
* Goals no longer depend on the `goal_scored` hook. The primary sources are
  `match.stats()` changes and scoreboard memory diffs; `goal_scored` is an
  *optional accelerator*. A goal that the hook misses is still caught, after
  `goal_fallback_delay_ms`, by the scoreboard watcher.
* The DLL renderer does not need Sider events at all: it draws inside the
  game's Present call, so even if every Lua event failed the renderer still
  runs (it would show the last state, and the diagnostics strip would say the
  state file is stale).

**Verified.** Checks `lua: verified event list has >= 7 events`,
`lua: every registered event has a handler`, `lua: first-fire tracking per
event`, `dll: hooks Present + ResizeBuffers`. The "does `display_frame` fire on
your Sider build" question is answered by the log line above —
**UNVERIFIED until you send `sider.log`.**

---

## 5. Sider version assumptions (7.3.4, "SiderAddons", sandbox claims)

**Addressed.** The header no longer claims a version. The module reads
`ctx.sider_dir` instead of assuming a folder, loads its ini relative to it,
writes its state under `content\ngb-presentation`, and logs the actual runtime
it got (`Lua 5.1`, `LuaJIT 2.1 ...`, `luajit.ext.enabled`, `bit`, the `memory`
library, the `match` library) on the first line of every session.

The sandbox claims were checked against Sider's `soft/fs.lua` and `sider.cpp`:
`load`, `loadstring`, `require`, `select`, `next`, `pcall`, `xpcall`, `print`,
`setmetatable` and `os.rename` are indeed absent; `fs.find_files` /
`fs.make_dirs` and the `memory`, `match`, `log` libraries are present. Two
consequences are baked in: the module never calls `pcall`/`require`, and
`state.json` cannot be renamed atomically (see item 4 of the table below).

**Verified.** `lua: no pcall()/require()/... in module` checks; the Lua
functional run executes against a sandbox that mirrors the real one (no
`pcall`, no `setmetatable`, an `_ENV` that errors on accidental globals).
**Sider version on your machine: UNVERIFIED** — it is printed in `sider.log`.

---

## 6. Circular tests

**Reproduced.** `verify_mod.py` tested the module against its own simulated
Sider and simulated memory, so it could not detect a wrong event name, a wrong
offset or a wrong sandbox assumption. The README admitted the visuals were
never seen in game.

**Fixed (as far as it can be fixed here):**

* The offline suite stays, and it got *stricter*, not looser: a real Lua lexer
  replaced the regex that used to mangle comments, the Lua module is executed,
  the DLL is rebuilt from source, and the DLL's JSON reader and card geometry
  are compiled and run as host tests.
* The suite now carries explicit regression checks for problems 1–3 and 9, so
  they cannot silently come back.
* A second, *separate* verification path exists that does not share the
  simulator: the DLL reads the real `state.json` the module wrote during the
  harness run (37 checks, including a truncation sweep), and the card layout is
  checked at six resolutions.
* The in-game self-test (F8) draws a card stamped **DEMO – NOT REAL DATA**
  through the real render path, which is what separates "renderer broken" from
  "data missing".

**Still true:** none of this proves the mod works in Football Life. That is what
your acceptance run is for. **UNVERIFIED in game.**

---

## 7. Per-player stat offsets unproven → "0 shots, 2 goals"

**Reproduced, and the specific symptom you reported is now impossible.**
`experimental_player_stats` stays **0 by default**. When it is enabled the
module does not trust the table until it agrees with the scoreboard, and it
keeps re-checking every two seconds:

* per player: `shots >= goals` (own goals excluded — an own goal is not a shot
  by that player),
* totals: `sum(goals) >= scoreboard`, `sum(shots) >= scoreboard`,
* at least 20 readable player records.

Any failure sets `stats_coherent = false`, which makes the HUD show
`PLAYER DATA UNAVAILABLE` instead of numbers. There is no code path left that
can print "0 shots / 2 goals": the value is either validated or absent.

**Fixed the circular gate too:** `player_stats_ok()` used to require the
coherence result *and* vice versa, so the first goal of a match was swallowed
while coherence was still `nil`. The base predicate is now separate
(`stats_base_ok`), and the first call performs the check.

**Verified.** Functional checks `stats coherence -> true`, `own goal: detected`,
`own goal: aimed at own net`, `no '0 shots / 2 goals' card` (card test), plus
the module's own `check_coherence` unit coverage in the harness. **Whether the
FL_2025 offsets are the same as PES 2021's: UNVERIFIED** — that is exactly why
the feature is off by default and why the coherence gate exists.

---

## 8. FFI risk (`__asm__` aliases, Win32 calls)

**Reproduced.** The module used `ffi.cdef` with `__asm__` aliases for
`ReadProcessMemory`, `VirtualQuery`, `VirtualProtect`, `WinExec`,
`GetTickCount64`. Any mismatch is a hard error at load time, i.e. the whole
module dies.

**Fixed.** All of it is gone. What remains:

* reads and writes go through Sider's own `memory` library (an in-process
  memcpy), with every address checked against a region map built *before* the
  read;
* `ffi.cdef` is used only for `LoadLibraryA` / `FreeLibrary` /
  `GetProcAddress` / `SetErrorMode` / `GetCurrentProcessId` /
  `GetModuleFileNameA`, it is idempotent (`ffi.NGB_loader_cdefs`), and it is
  only attempted when `ffi` exists;
* if FFI is off the module still registers, still reads the scoreboard from
  `match.stats()`, still writes `state.json` and still logs why the rest is
  unavailable;
* `now_ms()` no longer calls `GetTickCount64` (it uses `os.time` + `os.clock`
  with a monotonic clamp).

**Verified.** Checks `lua: no ReadProcessMemory`, `no VirtualQuery`,
`no VirtualProtect`, `no WinExec`, `no __asm__ aliases in code`,
`lua: uses Sider memory lib`, `lua: bounds map before every read`,
`lua: guarded ffi cdef (idempotent)`; and the pure-Lua float codecs were
compared bit-for-bit against `struct.pack('<f')` (18 values, 0 mismatches).
**Under your Sider's LuaJIT: UNVERIFIED** — but the failure mode is now a log
line, not a dead module.

---

## 9. `_ngb_ini.ps1` remove-mode `else` broke `uninstall.bat`

**Reproduced.** In remove mode the script had

```powershell
if ($changed) { Write-Host "  sider.ini : module entry removed" }
Write-Host "  sider.ini : match-stats.enabled left as it is (...)"
else { Write-Host "  sider.ini : nothing to remove" }
```

An `else` after a bare statement is a parse error. PowerShell refuses to run the
*whole* file, exits non-zero, and `uninstall.bat` then reports that it could not
edit `sider.ini` — while having already deleted the files.

**Fixed.** Proper braces; the message is now inside the `if/else`. Also: the
backup is created only if it does not exist yet, so a second install/uninstall
cannot overwrite the pristine `sider.ini` with an already-modified one.

**Verified.** Structural checks (`ini editor: braces balance`,
`ini editor: no dangling else (problem 9)`, `ini editor: never overwrites the
first backup`) **and** a behaviour test you can run yourself:
`tools\test_ini.bat` runs add → add again → remove → re-add on sample
`sider.ini` files and checks every line, including a CRLF+BOM file and an
uninstall of something that was never installed.
**The .ps1 has not been executed here (no PowerShell on this machine): the
structural gate passes, the behaviour test is provided — run
`tools\test_ini.bat` on Windows to confirm, or send me the output.**

---

## 10. A separate click-through window cannot draw over exclusive fullscreen

**Reproduced (by design).** The 1.x renderer was a layered topmost window. It
cannot appear over an exclusive-fullscreen swapchain, it depends on window
finding (problems 1–3), and its scaling was unproven.

**Fixed by inverting the architecture.** The default renderer is now
`ngb-render\NGB_Render.dll`:

* loaded into the **game process** by the Lua module (`LoadLibraryA`), no second
  window, no loader for you to compile;
* hooks `IDXGISwapChain::Present` and `ResizeBuffers` (MinHook, vtbl slots 8 and
  13 found through a private probe window and a dummy device — never on
  somebody else's window);
* draws on the game's own back buffer, so windowed / borderless / fullscreen and
  focused / unfocused are all the same case;
* every size comes from the real back buffer; `ResizeBuffers` releases the
  size-dependent objects *before* the buffers change, so alt-tab and
  resolution changes do not leave a black screen or a stretched card;
* the game's D3D state is captured and restored around the frame;
* safety: hardware SEH (`__try/__except`) around the hook body — on any fault it
  logs the exception code, marks itself dead and returns Present untouched. The
  kill switch (F12) and `dll_enabled = 0` fully disable drawing. The DLL writes
  only `ngb-dll.log` and `render.txt`; it never writes a save, EDIT data or a
  game file;
* the C# overlay remains as an optional fallback (`renderer = overlay` in the
  ini), for anyone who wants it or whose GPU driver rejects the hook.

**Verified here:** the DLL builds from source (`zig cc`, x64), the shipped
binary is x64 with the expected exports, the JSON reader passes 37 checks
against a real `state.json` (plus a truncation sweep), and the card layout
passes 83 geometry checks at 720p, 1080p, 1440p, 3440×1440, 4K and 4:3 — no
draw call leaves the screen at any of them.
**In game: UNVERIFIED.** Exclusive fullscreen in particular cannot be tested
without your GPU and your game; if the hook is rejected, `ngb-dll.log` says so
and the C# overlay remains available.

---

## 11. "The HUD kills the game" — a wrong address was an access violation

**Symptom.** Rare but fatal: the game disappears with no error dialog, usually a
few minutes into a match, sometimes when a match ends or a player is focused.
Windows logs `0xc0000005` against `FL_2025.exe`.

**Root cause.** 2.0.0 replaced the 1.x Win32 calls with Sider's `memory`
library, on the assumption that it was the safer option. It is the opposite.
Sider's `memory.lua` implements `memory.read` as:

```lua
function m.read(addr, len)
    local p = ffi.cast('char*', addr)
    return ffi.string(p, len)        -- raw dereference, no page check
end
```

`ffi.string` on an unmapped address is an access violation — not a Lua error.
Sider calls handlers through `lua_pcall`, but `pcall` only catches *Lua* errors;
it cannot catch a segfault. And the module cannot `pcall` the read itself: the
sandbox does not give modules `pcall` at all (§1 of TECHNICAL.md).

The region map (`m.build_regions`) narrowed the window but could never close it:

* regions were guessed — the image was assumed to span `base .. base+0x20000000`,
  and a `±1 GiB` band was anchored on a Sider allocation. Neither is a real map;
* a region can be freed between the check and the read (a match ending, a
  stadium unloading, an allocation moving), and `m.load` had no second guard;
* the scoreboard/stat pointers come from the *game*, so after a match they are
  exactly the dangling pointers this design was supposed to handle.

**Fix (2.0.1).** All memory access goes through the renderer DLL:

```c
__declspec(dllexport) unsigned int NGB_Read(unsigned long long addr, void *buf, unsigned int len)
{
    SIZE_T got = 0;
    if (!buf || len == 0 || len > (1u << 20) || addr < 0x10000ULL) return 0;
    if (!ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)addr, buf, len, &got))
        return (unsigned int)got;
    return (unsigned int)got;
}
```

`ReadProcessMemory` on your own process is the documented way to read an address
that may not be mapped: it returns `FALSE` and a partial byte count instead of
raising. `NGB_Query` (a `VirtualQuery` wrapper) replaces the guessed bands with
the real committed/readable region list, and `NGB_Write` does the same for the
replay-camera writes.

Consequences, all deliberate:

* **No DLL, no reads.** `renderer = overlay` or a DLL that failed to load means
  no safe reader, so live player data is switched off and the HUD says
  `memory reads: OFF (no safe backend)`. Score and clock still come from
  `match.stats()`; goal cards still work.
* **The unsafe reader is opt-in and loud.** `allow_unsafe_memory_reads = 1`
  restores 2.0.0's behaviour and logs a `WARNING:` line naming the crash risk.
* **Reads and writes are capped** at 1 MiB / 1 MiB, addresses below `0x10000`
  are refused outright, and every failure returns "no data" rather than raising.

**Verified here:**

* `func: mem: load fails closed without a backend`, `… read_big …`, `… read_u32 …`
  — with the backend set to `none`, all three return `nil`/`false` instead of
  touching a pointer (tools/verify_mod.py);
* `dll: memory helpers use ReadProcessMemory / VirtualQuery` — the shipped C
  really uses the non-faulting calls, and `dll: read length is capped`;
* `dll: prebuilt DLL exports the safe memory API` — `NGB_Read`, `NGB_Write`,
  `NGB_Query` are present in the shipped binary;
* `lua: unsafe reader is opt-in and warned about` — the raw path is reachable
  only through the ini key and always logs the warning.

**In game: UNVERIFIED** — that the crash is gone needs your machine. What can be
stated is that the module no longer dereferences an address it has not validated,
and that the remaining dereferences happen in C behind `ReadProcessMemory`.

---

## 12. "The window closes and nothing shows" — an installer that said nothing

**Symptom.** Reported from a real machine. `install_log.txt` stopped after
`copied NGB_Render.dll`, the console window vanished before the user could read
it, and the mod was not listed in Sider's overlay afterwards.

**What was actually wrong.** Two separate, unrelated defects that looked like
one:

1. **The installer's success path had no `pause`.** It printed the whole
   success screen and then hit `exit /b 0`, so the window closed the instant it
   finished. A user cannot tell "it worked" from "it crashed" when the window
   disappears either way. Worse, the `sider.ini` step was the one step that
   wrote *nothing* to the log before running, so a log that ends after the DLL
   copy could not distinguish "PowerShell failed" from "PowerShell succeeded
   and the window closed while it was still printing".
2. **A module that fails to load says nothing to the user.** Sider catches the
   error with `lua_pcall`, writes one line to `sider.log` and carries on, so a
   load-time error inside `m.init` looks exactly like "the mod was never
   installed" — no dialog, no overlay entry, no obvious file.

**Fix, part 1 — the installer.** Every step now writes `step N: ...` to
`install_log.txt` (0, 1, 2, 3, 4, 4b, 4c, 6), PowerShell's own output and
**exit code** are appended to the log, and *every* exit path ends with `pause`
(the success screen says so out loud). Without PowerShell — blocked by policy,
missing, or failing — the installer no longer falls straight to
Notepad-and-clipboard: it appends only the lines that are missing, terminating
the last line first so an append cannot glue itself onto it, then re-checks
with `findstr` and warns if `luajit.ext.enabled` is still `0`.

**Fix, part 2 — the doctor.** New `NGB_Doctor.bat` + `NGB_Doctor.ps1`. One
double-click answers "why is nothing happening", using the evidence that was
always there but buried:

| check | what it proves |
|---|---|
| `modules\NGB_Presentation.lua` size and `function m.init` | the real file is there, not a 0-byte copy |
| `ngb-render\NGB_Render.dll` PE `Machine == 0x8664` | the DLL is x64 and not truncated |
| the three `sider.ini` lines, plus duplicate `lua.module` entries | the module is registered exactly once |
| settings like `experimental_player_stats` sitting in `sider.ini` | they belong in `modules\NGB_Presentation.ini`; flagged, because that is a real mistake users make |
| `state.json` / `heartbeat.txt` / `render.txt` timestamps | which of the three stages actually ran, and how long ago |
| `sider.log` lines containing `NGB`, and `lua ERROR` lines | the load-time error text, if there is one |

**Fix, part 3 — the load itself.** `ffi.cdef` is global to the LuaJIT state, so
a declaration that clashes with another mod's (`DWORD` vs `unsigned long`,
`FARPROC` vs `void *`) raises *inside* `cdef`, and that raise kills this module
at load — silently, from the user's point of view. The module declared seven
Win32 calls and called four; the three unused ones (`FreeLibrary`,
`SetErrorMode`, `GetCurrentProcess`) were removed, `verify_mod.py` now fails if
a declared symbol is never used, and the cdef is preceded by a log line naming
exactly what is being declared, so the next `sider.log` ends with our last
words instead of nothing.

**Verified here:** `install: every exit path waits for a key`, `install: logs
each step`, `install: captures the PowerShell exit code in the log`,
`install: has a PowerShell-free sider.ini fallback`, `doctor: ...` (11 checks,
including PowerShell 5.1 compatibility and ASCII-only), `lua: every cdef'd
Win32 call is actually used`, `lua: the cdef list is minimal (4 calls)`.
**In game: UNVERIFIED** — the doctor has not been run on a real Windows machine
by me; it is written for PowerShell 5.1, which ships with every Windows 10/11.

---

## 13. "Module is NOT activated" — the DLL was never actually called

**Symptom**, from a real machine, found by `NGB_Doctor.bat`:

```
PROBLEM: Lua module (NGB_Presentation.lua) "init" function returned an error:
  [string "NGB_Presentation.lua"]:3991: 'void' is not callable
Module (NGB_Presentation.lua) is NOT activated
```

No cards, no `ngb-dll.log` (the DLL had never run), and no overlay entry.

**Root cause.** `GetProcAddress` returns a bare address (`void *`). LuaJIT cannot
call a bare address — it has no prototype, so it raises rather than guessing.
Every function pointer must be cast to its real signature first:

```lua
local start = get_proc(handle, "NGB_Start")   -- void*
local started = start(cfgtext)                -- 'void' is not callable
```

2.0.0 and 2.0.1 did that at **five** call sites (`NGB_Start`, `NGB_GetState`,
`NGB_Read`, `NGB_Write`, `NGB_Query`), so the renderer bridge could never have
worked — on any machine. The module died inside `m.init`, Sider logged one line
and marked it *NOT activated*, which from the user's side is indistinguishable
from "the mod was never installed". A second latent bug hid behind the first:
`NGB_GetState` returns `const char *`, which LuaJIT hands back as **cdata, not a
Lua string**, so the diagnostics panel would have shown nothing even after the
first fix.

**Why no test caught it.** `tools/verify_mod.lua` runs the module under Lua 5.5
through lupa, which has **no `ffi`**. Every line inside `m.load_renderer` that
touches the DLL was therefore dead code in every test run: the suite proved the
module was correct everywhere except the one place that actually loads the
renderer.

**Fix.**
* `get_proc(handle, name, ctype)` casts through `ffi.cast` and **refuses** to
  run without a signature (it logs `BUG: get_proc("X") called without a
  signature` instead of returning an uncallable pointer);
* one `PROTO` table holds the five prototypes, copied from
  `ngb-render/src/ngb.h`, so a signature can never drift from the C header;
* `NGB_GetState`'s `const char *` is converted with `ffi.string` before use.

**Proof.**
* new `tools/ffi_loader_test.lua`: a **fake FFI** in which `GetProcAddress`
  returns an object that raises `'void' is not callable` when called — the same
  message the user's log contained — and `ffi.cast` returns a callable. It runs
  the real `m.load_renderer` against a fake DLL and checks the config string,
  the casts, `renderer_status()`, the memory-backend switch, and the two
  failure paths (`NGB_Start` returning 0, missing export). **33 assertions.**
* the test has teeth: putting the bug back (`return fn` instead of
  `return ffi.cast(ctype, fn)`) makes it fail immediately — verified both ways.
* static gates: every `get_proc` call site carries a signature, every signature
  comes from `PROTO`, `PROTO` covers all five exports, and `NGB_GetState` goes
  through `ffi.string`.

**Also in 2.0.2.** The doctor now quotes the module's own environment lines
from `sider.log` back at the user — `luajit`, `ffi`, `memory lib`, `match lib`,
`folder layout`, `renderer wanted` — and flags a build that exposes no `match`
library, because that is what feeds the score and the clock (the reporting
machine's build has none, which is why its goal cards would have had no score
even after this fix).

**In game: UNVERIFIED.** The fix is proven against a fake FFI, not against
Windows. `NGB_Doctor.bat` will show `renderer: NGB_Render.dll loaded and
NGB_Start() called` and `ngb-dll.log` should appear the moment a match starts.

---

## Other changes in 2.0 (needed for the above)

| change | why |
| --- | --- |
| `heartbeat.txt`, rewritten every second | proves the module is ticking, and *which event* drives it (`ticks_from`) |
| `render.txt`, rewritten every second by the DLL | proves the renderer is inside a frame, plus hwnd / backbuffer / frames / kill-switch state |
| `state.json` schema v4 with `diag` and `game` blocks | one file answers "what is running and why is it not drawing" |
| state publish is write-temp-then-target | the renderer reads 10×/s; a half-written file could throw a card away. (`os.rename` is not in Sider's sandbox, so this is the closest portable equivalent — a short window remains, and the reader tolerates a truncated file.) |
| `publisher stats coherence` gate | see problem 7 |
| `renderer = dll \| overlay \| none`, `dll_enabled`, `dll_selftest_hotkey`, `dll_diag_hotkey`, `dll_kill_hotkey` | the renderer is configurable and can be switched off without editing code |
| `auto_launch_companion` removed | the module no longer starts a process (WinExec is gone); the DLL is loaded in-process |
| `allow_unsafe_memory_reads` (new, default 0) | problem 11: memory reads require the DLL, the only non-faulting reader |
| `NGB_Read` / `NGB_Write` / `NGB_Query` exports | problem 11: `ReadProcessMemory`/`WriteProcessMemory`/`VirtualQuery` on our own process |
| install.bat copies the prebuilt DLL; no compiler step | problem 10, and no more `error CS...` dead ends |
| uninstall.bat removes `ngb-render\` too | a clean removal; `sider.ini.ngb.bak` is left as a backup |
| `tools/test_ini.bat` / `test_ini.ps1` | the add/remove/reinstall cycle, as an executable test |
| verify_mod.py: real Lua lexer, DLL build, host tests | problem 6 |

## What is still missing / not done

* **In-game acceptance run.** Not performed — cannot be performed here.
* **Per-player stat offsets for FL_2025.exe.** Still unproven, still off by
  default. `tools/decode_probe.py` + `calibration.txt` exist so you can pin the
  layout without editing code. What *is* now proven: the tool runs end to end
  (`--selftest` builds a synthetic region and finds the layout again, is part of
  `verify_mod.py`, and no longer needs numpy — the pure-Python scan took minutes
  on a zero-filled dump and now takes seconds). What is still missing is one
  real `probe_region.bin` from your game.
* **Exclusive fullscreen with the DLL.** Expected to work (it is the whole point
  of hooking Present) but unproven on your machine.
* **Anti-cheat / online.** This is a single-player presentation mod. Do not use
  it online; the DLL hooks the swapchain and would be indistinguishable from a
  cheat overlay to any anti-cheat.
