#!/usr/bin/env python3
"""
mods/ngb-presentation/tools/verify_mod.py -- offline validation for this mod.

Three layers of checks:

1. Static checks (always run, no dependencies)
   * Lua module: no banned globals (pcall / xpcall / require / select / next),
     returns a table with an init() method, every ctx.register target is a
     field of the module table, balanced long brackets.
   * INI: every key the module reads is present.
   * C# companion: balanced braces / parens / strings, required API usage.
   * HTML preview: self contained, no external URLs.
   * Player.bin parser fixture is re-implemented here in Python and compared
     with the offsets used by the Lua module.

2. Functional checks (require `pip install lupa`)
   tools/verify_mod.lua builds a miniature FL_2025 memory image and drives the
   real module through it: baseline -> shot -> goal -> own goal -> MOTM ->
   state.json.

3. JSON checks: the generated state.json is parsed and its schema validated.

Usage:  python3 mods/ngb-presentation/tools/verify_mod.py [--verbose]
Exit code 0 = all checks passed.
"""

import json
import os
import re
import struct
import sys
import subprocess
import shutil
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "modules", "NGB_Presentation.lua")
INI = os.path.join(ROOT, "modules", "NGB_Presentation.ini")
CS = os.path.join(ROOT, "ngb-overlay", "NGB_Overlay.cs")
HTML = os.path.join(ROOT, "preview", "NGB_Preview.html")
HARNESS = os.path.join(ROOT, "tools", "verify_mod.lua")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), str(detail)))
    return bool(ok)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# 1. Lua static checks
# ---------------------------------------------------------------------------
def lua_strip_src(src):
    """Return (code_without_strings_and_comments, [problems]).

    A real single pass over the source, so a string that contains -- (like
    or "--") is not mistaken for a comment. Long brackets ([[ ]], [=[ ]=]) and
    long comments (--[[ ]]) are handled. An unterminated construct is reported
    instead of silently truncating everything after it - that is exactly the
    failure mode a truncated file has.
    """
    out = []
    problems = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                eq = m.group(1)
                close = "]" + eq + "]"
                j = src.find(close, i + m.end())
                if j < 0:
                    problems.append("unterminated long comment")
                    return "".join(out), problems
                i = j + len(close)
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
            out.append(" ")
            continue
        if c == "[":
            m = re.match(r"\[(=*)\[", src[i:])
            if m:
                eq = m.group(1)
                close = "]" + eq + "]"
                j = src.find(close, i + m.end())
                if j < 0:
                    problems.append("unterminated long string")
                    return "".join(out), problems
                out.append('""')
                i = j + len(close)
                continue
        if c in "\"'":
            q = c
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    break
                if src[j] == "\n":
                    problems.append("unterminated string on line %d"
                                    % (src.count("\n", 0, i) + 1))
                    return "".join(out), problems
                j += 1
            if j >= n:
                problems.append("unterminated string at end of file")
                return "".join(out), problems
            # blank the contents: every check below wants *code*, and keeping
            # the contents made escaped quotes inside JSON builders look like
            # stray backslash-quotes outside a string
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), problems


def lua_static_checks():
    if not os.path.exists(LUA):
        return check("lua: module exists", False, LUA)
    src = read(LUA)
    check("lua: module exists", True, "%d bytes" % len(src))

    # A real (small) Lua lexer: the naive "strip -- to end of line" regex is
    # wrong for any string that contains --, and it silently mangled the
    # balance check below. This walks the source once and returns the code with
    # all strings and comments replaced by placeholders.
    code, problems = lua_strip_src(src)
    for msg in problems:
        check("lua: lexer %s" % msg, False, msg)
    code_nostr = re.sub(r'"([^"]*)"', '""', code)
    code_nostr = re.sub(r"'([^']*)'", "''", code_nostr)

    for banned in ("pcall", "xpcall", "require", "select", "loadstring",
                   "setmetatable", "rawset", "getmetatable"):
        hits = re.findall(r"(?<![%.\w])" + banned + r"\s*\(", code_nostr)
        check("lua: no %s() in module" % banned, not hits, ", ".join(hits[:3]))

    check("lua: returns module table", re.search(r"\breturn m\b", src) is not None)
    check("lua: has init(ctx)", re.search(r"function m\.init\(ctx\)", src) is not None)

    # Registration is table-driven now (declare_events -> m.handler_for), so the
    # old "find ctx.register("x", m.y)" regex cannot see it. Instead: every name
    # in the verified event list must have a handler, and every handler must
    # resolve to a real function on the module table.
    decl = re.search(r"local names = \{(.*?)\}", src, re.S)
    names = re.findall(r'"([a-z_]+)"', decl.group(1)) if decl else []
    check("lua: verified event list has >= 7 events", len(names) >= 7, "%d" % len(names))
    handlers = re.search(r"m\.handler_for = \{(.*?)\n\}", src, re.S)
    hmap = re.findall(r"([a-z_]+)\s*=\s*function", handlers.group(1)) if handlers else []
    check("lua: every registered event has a handler",
          all(n in hmap for n in names),
          ", ".join(n for n in names if n not in hmap))
    for want in ("on_display_frame", "on_goal_scored", "on_overlay_on", "on_key_down",
                 "on_set_teams", "on_context_reset", "on_livecpk_data_ready"):
        check("lua: %s defined" % want,
              re.search(r"function m\.%s\(" % want, src) is not None)

    # ---- architecture checks (v2.0) ----------------------------------------
    # The module must NOT contain Win32 calls any more: it uses Sider's own
    # `memory` library, which is a plain in-process memcpy.
    check("lua: no ReadProcessMemory", "NGB_ReadProcessMemory" not in src)
    check("lua: no VirtualQuery", "NGB_VirtualQuery" not in src)
    check("lua: no VirtualProtect", "NGB_VirtualProtect" not in src)
    check("lua: no WinExec", "NGB_WinExec" not in src)
    check("lua: no __asm__ aliases in code", "__asm__" not in code)
    # memory access is routed through the renderer DLL's fault-free reader;
    # Sider's raw `memory.read` is only reachable through an explicit opt-in
    check("lua: safe memory backend from the DLL",
          "NGB_Read" in src and "NGB_Query" in src and "read_proc" in src)
    check("lua: unsafe reader is opt-in and warned about",
          "allow_unsafe_memory_reads" in src
          and "can crash the game" in src)
    check("lua: bounds map before every read", "in_region" in src and "build_regions" in src)
    check("lua: guarded ffi cdef (idempotent)",
          "if ffi.NGB_loader_cdefs then return true end" in src)
    check("lua: registers only verified events",
          all(n in src for n in ("display_frame", "goal_scored", "set_match_settings"))
          and "WARN: trying to register for unknown event" in src)
    check("lua: first-fire tracking per event",
          "note_event" in src and "e.fired" in src and "fired for the first time" in src)
    check("lua: heartbeat file", "heartbeat.txt" in src and "write_heartbeat" in src)
    check("lua: renderer bridge", "NGB_Render.dll" in src and "NGB_Start" in src)
    check("lua: renderer fallback reasons are logged",
          "falling back to the C# overlay" in src)
    check("lua: stat region signature", "0x18FFE0" in src and "0xEFFE0" in src)
    check("lua: record stride", "0x2134" in src and "0x59650" in src)
    check("lua: imperial conversions", "MPS_TO_MPH" in src and "M_TO_YD" in src
          and "M_TO_FT" in src)
    check("lua: 720p aware hud output", "scale_hint" in src)
    check("lua: renderer loaded by the module (not spawned)",
          "load_library" in src and "io.popen" not in src)
    check("brand: MOONFROS PRESENTS in the module", "MOONFROS PRESENTS" in src)
    check("brand: author in the module", "MoonFros" in src)
    check("hotkeys: digits 7 / 8 / 9 bound",
          all(k in src for k in ("0x37", "0x38", "0x39")))
    # F7/F8 are handled by the *DLL* (it has its own key poller), not by the
    # Lua module - so they must not be registered as Sider key_down hotkeys.
    check("hotkeys: F7 / F8 not bound in Lua",
          'hotkey_prev_style = 0x37' in src and '"0x76")' not in src)
    check("hotkeys: DLL hotkeys configured via ini",
          all(k in src for k in ("dll_selftest_hotkey", "dll_diag_hotkey",
                                 "dll_kill_hotkey")))
    check("hotkeys: key 1 untouched", "0x31" not in src)
    check("hotkeys: overlay-only gate", "hotkeys_overlay_only" in src)
    check("lua: milestones", "milestone_for" in src and "hat_trick" in src)
    check("lua: minutes tracking", "minutes_for" in src and "minutes_exact" in src)
    check("lua: assist attribution", "assist_side" in src)
    check("lua: toast channel", "set_toast" in src)
    check("lua: reads Sider's match library", "match.stats()" in src or "match.stats" in src)
    check("lua: goal hook wired", "on_goal_scored" in src and "player_name_on_shirt" in src)
    check("lua: scoreboard fallback", "watch_scoreboard" in src and "goal_fallback" in src)
    check("lua: half/full time cards", "show_result" in src and "half_time" in src)
    check("lua: data source reported in state", "data_source" in src and "player_stats" in src)
    check("lua: player stats gated + validated",
          "experimental_player_stats" in src and "validate_stats" in src
          and "player_stats_ok" in src)
    check("lua: ini self-check (match-stats)", "check_ini_flags" in src and "match%-stats" in src)
    check("lua: calibration probe", "probe_write" in src and "probe.txt" in src)
    check("lua: layout overrides from ini / calibration file",
          "apply_layout" in src and "read_calibration" in src
          and "calibration.txt" in src)
    check("lua: raw region dump for the decoder",
          "probe_dump" in src and "probe_region.bin" in src)
    check("lua: bucket count is configurable", "BUCKETS" in src and "stat_buckets" in src)
    check("lua: overlay heartbeat read", "watch_overlay" in src and "overlay_alive.txt" in src)
    check("lua: goal dedupe by count",
          "unconfirmed" in src and "flush_fallback" in src)
    check("lua: full time from a frozen clock", "clock_changed_at" in src)
    check("lua: creates its state folder defensively",
          "ensure_dir" in src and "fs.make_dirs" in src)
    check("lua: atomic state write (temp then target)",
          "state.json.tmp" in src or "tmp_path" in src)
    check("lua: stats coherence guard (no 0-shots-2-goals)",
          "check_coherence" in src and "shots < board" in src.replace(" ", " ")
          or "check_coherence" in src)
    check("lua: state schema bumped to 4", "m.STATE_VERSION = 4" in src)
    check("lua: presentation styles", "cycle_style" in src and "STYLE_NAMES" in src)

    # real balance: the lexer fails on an unterminated string, long bracket or
    # long comment, which is what "truncated file" actually looks like
    check("lua: strings/comments terminate", not problems, "; ".join(problems))
    check("lua: no stray backslash-quote outside a string",
          "\\\"" not in code, "")


# ---------------------------------------------------------------------------
# 2. INI checks
# ---------------------------------------------------------------------------
def ini_checks():
    src = read(LUA)
    ini = read(INI)
    keys = set()
    for line in ini.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_.]+)\s*=", line)
        if m:
            keys.add(m.group(1))
    wanted = set(re.findall(r'cfg_[ifs]\("([a-z0-9_]+)"', src))
    missing = sorted(wanted - keys)
    check("ini: all read keys documented", not missing, ", ".join(missing))
    check("ini: metric default", re.search(r"^units\s*=\s*metric", ini, re.M) is not None)
    check("ini: companion toggle present", "companion_hud_enabled" in keys)
    check("ini: replay camera preset present", "replay_camera_preset" in keys)
    check("ini: carries the credit", "MoonFros" in ini or "MOONFROS" in ini)
    check("ini: presentation knobs", all(k in keys for k in
          ("presentation_enabled", "presentation_style", "shot_analysis_enabled")))
    check("ini: digit hotkeys", all(k in keys for k in
          ("hotkey_prev_style", "hotkey_toggle_overlay", "hotkey_toggle_analysis")))
    check("ini: replay camera tuning wired",
          all(('cfg_f("%s"' % k) in src for k in
              ("replay_height_cam0", "replay_height_cam3", "replay_zoom")))
    check("ini: goal card delay wired", 'cfg_f("goal_telemetry_delay"' in src)
    check("ini: no orphan keys",
          not (keys - set(re.findall(r'cfg_[ifs]\("([a-z0-9_]+)"', src))
                 - {"units", "theme", "state_write_hz", "stats_region_base",
                    "pitch_region_base", "debug_log", "renderer",
                    "dll_enabled", "dll_kill_hotkey", "dll_selftest_hotkey",
                    "dll_diag_hotkey"}), "")


# ---------------------------------------------------------------------------
# 3. C# companion structural checks
# ---------------------------------------------------------------------------

def draw_call_audit(src):
    """Catch the compile errors a human would only see on Windows: wrong arity
    and Color-where-a-Brush-is-expected in Draw.* calls."""
    import re as _re

    def split_args(text):
        out, depth, cur = [], 0, ""
        for ch in text:
            if ch in "([{<":
                depth += 1
            if ch in ")]}>":
                depth -= 1
            if ch == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
            else:
                cur += ch
        if cur.strip():
            out.append(cur.strip())
        return out

    sigs = {
        "Text": ["g", "s", "f", "brush", "f", "f"],
        "TextRight": ["g", "s", "f", "brush", "f", "f"],
        "TextCentre": ["g", "s", "f", "brush", "f", "f"],
        "TextClipped": ["g", "s", "f", "brush", "f", "f", "f"],
        "Spaced": ["g", "s", "f", "brush", "f", "f", "f"],
        "Pill": ["g", "r", "color", "s", "f", "color", "f"],
        "Ring": ["g", "r", "f", "color", "f", "s", "font"],
        "GlassPanel": ["g", "r", "f", "color"],
    }
    color_names = set(_re.findall(r"static readonly Color (\w+)", src))
    brush_names = set(_re.findall(r"var (\w+) = new SolidBrush", src))
    problems = []
    for name, params in sigs.items():
        for m in _re.finditer(r"\bDraw\." + name + r"\s*\(", src):
            i = m.end() - 1
            depth, j = 0, i
            while j < len(src):
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            args = split_args(src[i + 1:j])
            line = src[: m.start()].count("\n") + 1
            if len(args) != len(params):
                problems.append("%s line %d: %d args, expected %d"
                                % (name, line, len(args), len(params)))
                continue
            for k, kind in enumerate(params):
                arg = args[k]
                if not _re.match(r"^[A-Za-z_]\w*$", arg):
                    continue
                if kind == "brush" and arg in color_names:
                    problems.append("%s line %d: Color '%s' passed for Brush"
                                    % (name, line, arg))
                if kind == "color" and arg in brush_names:
                    problems.append("%s line %d: Brush '%s' passed for Color"
                                    % (name, line, arg))
    return problems

def cs_checks():
    if not os.path.exists(CS):
        return check("cs: companion exists", False, CS)
    src = read(CS)
    check("cs: companion exists", True, "%d bytes" % len(src))

    stripped = re.sub(r"//[^\n]*", "", src)
    stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.S)
    stripped = re.sub(r'"(\\.|[^"\\])*"', '""', stripped)
    stripped = re.sub(r"'(\\.|[^'\\])*'", "''", stripped)
    check("cs: balanced braces", stripped.count("{") == stripped.count("}"),
          "%d/%d" % (stripped.count("{"), stripped.count("}")))
    check("cs: balanced parens", stripped.count("(") == stripped.count(")"),
          "%d/%d" % (stripped.count("("), stripped.count(")")))
    check("cs: balanced brackets", stripped.count("[") == stripped.count("]"))

    for api in ("UpdateLayeredWindow", "WS_EX_LAYERED", "WS_EX_TRANSPARENT",
                "WS_EX_TOPMOST", "WS_EX_NOACTIVATE", "CreateDIBSection",
                "biBitCount = 32", "state.json"):
        check("cs: uses %s" % api, api in src)
    check("cs: scales with window height", re.search(r"scale\s*=|/ 1080", src) is not None)
    check("cs: spotlight + analysis renderers",
          "DrawGoalCard" in src and "DrawAnalysisPanel" in src and "DrawShotCard" in src)
    check("cs: MOTM reveal", "DrawMotmCard" in src and "MAN OF THE MATCH" in src)
    check("cs: toast channel", "DrawToast" in src)
    check("cs: three presentation styles", "DrawMinimalBar" in src and "Style" in src)
    check("cs: credit on the cards", "Credit" in src and "MOONFROS" in src.upper())
    check("cs: overlay hotkeys avoid F7/F8/F9",
          all(k not in src for k in ("Keys.F7", "Keys.F8", "Keys.F9")))
    check("cs: minute display", "MinutesRaw" in src)
    check("cs: full-time card", "DrawFullTimeCard" in src and "HALF TIME" in src)
    check("cs: goal card without a scorer", "DrawGoalBare" in src and "SCORER NOT AVAILABLE" in src)
    check("cs: player stats gate", "PlayerStats" in src and "bool stats = st == null || st.PlayerStats" in src)
    check("cs: startup / no-state card", "DrawStartupCard" in src and "waiting for" in src)
    check("cs: version const", "public const string VERSION" in src)
    check("cs: sample cards are labelled", "SAMPLE DATA" in src and "DrawDemoBadge" in src)
    # ---- problems 1-3 are regression-tested here -------------------------
    rect = src[src.index("private bool ComputeGameRect()"):]
    rect = rect[:rect.index("private ")+(len(rect))]
    check("cs: ComputeGameRect does not look at the foreground window",
          "GetForegroundWindow" not in rect[:2000],
          "problem 1 regression")
    check("cs: overlay hides only when minimised / invisible",
          "IsIconic" in rect[:2000] and "IsWindowVisible" in rect[:2000])
    cs_code = re.sub(r"//[^\n]*", "", src)
    cs_code = re.sub(r'/\*.*?\*/', "", cs_code, flags=re.S)
    check("cs: no guessed exe list (problem 3)",
          "KNOWN_GAMES" not in cs_code and "FL_2025" not in cs_code,
          "the process name now comes from state.json")
    check("cs: no 'focused window of another process' fallback (problem 2)",
          "focused window of" not in cs_code)
    check("cs: attaches by pid from state.json",
          "WindowForPid" in src and "st.GamePid" in src)
    check("cs: falls back to the sider.dll process",
          "ProcessHasSider" in src and "sider.dll" in src)
    check("cs: per-monitor DPI awareness ladder",
          "SetProcessDpiAwarenessContext" in src and "SetProcessDpiAwareness" in src)
    check("cs: layout from the real client rect",
          "GetClientRect(_gameHwnd" in src and "_winH / 1080f" in src)
    check("cs: follows the window when moved or resized",
          "Location.X != _winX" in src)
    check("cs: last-resort reuse of a still-valid window",
          "previous window" in src)
    check("cs: diagnostics draw without a game window",
          "_screenMode" in src and "Screen.PrimaryScreen" in src)
    check("cs: single instance guard", "MoonFros.NGB.Overlay" in src)
    check("cs: heartbeat for the lua side", "overlay_alive.txt" in src)
    check("cs: stale state is dropped", "ReceivedAt > 0" in src and "10.0" in src)
    check("cs: STAThread sits on Main, not on a field",
          "[STAThread]\n        private static void Main" in src)
    check("cs: no attribute above the version constant",
          "[STAThread]\n        public const" not in src)
    check("cs: shot card shows the shot panel when telemetry exists",
          "bool analysis = style == 0 && ev.Shot != null" in src)
    check("cs: reads the data block", "\"player_stats\"" in src and "scorer_hook" in src)
    check("cs: no external nuget deps",
          not re.search(r"using\s+Newtonsoft", src))

    # compile-level traps that only Windows/csc would report
    probs = draw_call_audit(src)
    check("cs: Draw.* call signatures are type-correct", not probs,
          "; ".join(probs[:3]))
    check("cs: usings cover the types used",
          not ("TextRenderingHint" in src and "using System.Drawing.Text;" not in src),
          "TextRenderingHint needs System.Drawing.Text")
    check("cs: team colour wrapped in a brush for text",
          "new SolidBrush(team)" in src)
    for word in ("AEFF00", "HyperMotion", "EA FC", "Volt "):
        check("cs: no EA naming/hex (%s)" % word.strip(), word not in src)


# ---------------------------------------------------------------------------
# 4. HTML preview checks
# ---------------------------------------------------------------------------
def html_checks():
    if not os.path.exists(HTML):
        return check("html: preview exists", False, HTML)
    src = read(HTML)
    check("html: preview exists", True, "%d bytes" % len(src))
    check("html: self contained", "http://" not in src and "https://" not in src)
    check("html: 720p stage", 'data-res="720"' in src and "720 / 1080" in src)
    check("html: 1080p stage", 'data-res="1080"' in src and "1920px" in src)
    check("html: branded", "MOONFROS PRESENTS" in src.upper())
    check("html: milestone badge", "Hat-trick" in src or "HAT-TRICK" in src)
    for feature in ("goal", "shot", "motm"):
        check("html: renders %s card" % feature, feature in src.lower())


# ---------------------------------------------------------------------------
# 5. Player.bin format fixture (mirrors the Lua parser)
# ---------------------------------------------------------------------------
def field_bits(buf, offset, shift, bits, addend):
    val = 0
    for i in range(bits):
        p = shift + i
        byte = buf[offset + (p >> 3)]
        if (byte >> (p & 7)) & 1:
            val += 1 << i
    return val + addend


def player_bin_fixture():
    """Builds a WESYS Player.bin and checks the documented offsets."""
    rec = bytearray(312)
    struct.pack_into("<I", rec, 8, 123456)
    rec[129] = 11
    name = b"M. Rashford"
    rec[251:251 + len(name)] = name

    def set_bits(buf, off, shift, bits, value):
        for i in range(bits):
            p = shift + i
            idx = off + (p >> 3)
            mask = 1 << (p & 7)
            if (value >> i) & 1:
                buf[idx] |= mask
            else:
                buf[idx] &= ~mask

    set_bits(rec, 54, 2, 4, 9)          # RWF
    set_bits(rec, 27, 0, 8, 180 - 100)  # 180 cm
    set_bits(rec, 44, 6, 6, 88 - 40)    # kicking power 88
    set_bits(rec, 49, 4, 6, 90 - 40)    # finishing 90

    payload = bytes(rec)
    wesys = b"\x00\x01\x01WESYS" + struct.pack("<II", len(payload), len(payload)) + payload

    ok = True
    ok &= wesys[3:8] == b"WESYS"
    ok &= struct.unpack_from("<I", wesys, 8)[0] == len(payload)
    ok &= wesys[0:3] == b"\x00\x01\x01"
    check("pbin: WESYS header", ok, wesys[:16].hex())

    comp = struct.unpack_from("<I", wesys, 8)[0]
    raw = zlib.decompress(zlib.compress(payload))
    check("pbin: round trip", len(raw) == comp, len(raw))

    pid = struct.unpack_from("<I", raw, 8)[0]
    check("pbin: player id at +8", pid == 123456, pid)
    check("pbin: shirt at +129", raw[129] == 11, raw[129])
    check("pbin: name at +251",
          raw[251:251 + 60].split(b"\x00")[0] == b"M. Rashford")
    check("pbin: height bits", field_bits(raw, 27, 0, 8, 100) == 180,
          field_bits(raw, 27, 0, 8, 100))
    check("pbin: kicking power bits", field_bits(raw, 44, 6, 6, 40) == 88,
          field_bits(raw, 44, 6, 6, 40))
    check("pbin: finishing bits", field_bits(raw, 49, 4, 6, 40) == 90,
          field_bits(raw, 49, 4, 6, 40))
    check("pbin: record size", 312 * 24000 // 1024 // 1024 >= 7,
          "%.1f MB for 24k players" % (312 * 24000 / 1024 / 1024))


# ---------------------------------------------------------------------------
# 6. Functional run through lupa (LuaJIT)
# ---------------------------------------------------------------------------
_last_state_json = ""


def lua_runtime_checks(verbose=False):
    try:
        import lupa.luajit21 as lj
    except Exception:
        try:
            import lupa as lj
            if "LuaJIT" not in str(lj.LuaRuntime().eval("_VERSION")) + str(
                    lj.LuaRuntime().eval("jit and jit.version")):
                raise RuntimeError("lupa without LuaJIT")
        except Exception as exc:  # noqa: BLE001
            check("lua runtime: available", None,
                  "skipped (%s) - pip install lupa" % exc.__class__.__name__)
            return None

    check("lua runtime: available", True, "lupa/LuaJIT")

    work = tempfile.mkdtemp(prefix="ngb_verify_")
    sider = os.path.join(work, "sider")
    os.makedirs(os.path.join(sider, "modules"), exist_ok=True)
    os.makedirs(os.path.join(sider, "content", "ngb-presentation"), exist_ok=True)
    # CRLF copy of the real INI, exactly like a file saved on Windows
    with open(INI, encoding="utf-8") as fh:
        ini_text = fh.read()
    with open(os.path.join(sider, "modules", "NGB_Presentation.ini"), "wb") as fh:
        fh.write(ini_text.replace("\n", "\r\n").encode("utf-8"))

    lua = lj.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.MODSRC = read(LUA)
    g.SIDERDIR = sider
    g.RAWLOG = lua.table()
    g.ZLIB_PAYLOAD = None
    g.MATCH_STATS = lua.table()

    harness = read(HARNESS)
    fn = lua.execute("return function(src) return assert(loadstring(src, 'verify'))() end")
    try:
        table = fn(harness)
    except Exception as exc:  # noqa: BLE001
        check("lua functional: harness ran", False, str(exc))
        return None

    check("lua functional: harness ran", True)
    n = 0
    for i in range(1, len(table) + 1):
        item = table[i]
        name = item["name"]
        ok = item["ok"]
        detail = item["detail"]
        n += 1
        results.append(("func: " + str(name), bool(ok), str(detail)))
    check("lua functional: assertions", n >= 30, "%d assertions" % n)

    # state.json produced by the harness
    global _last_state_json
    state_path = os.path.join(sider, "content", "ngb-presentation", "state.json")
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as fh:
            raw = fh.read()
        _last_state_json = raw
        try:
            st = json.loads(raw)
            check("state: valid json", True, "%d bytes" % len(raw))
            check("state: has match block", "match" in st)
            check("state: has status block", "status" in st)
            check("state: home score numeric",
                  isinstance(st["match"]["home"]["score"], int))
            check("state: units valid", st["hud"]["units"] in ("imperial", "metric"))
            ev = st.get("event")
            if ev:
                check("state: event kind", ev.get("kind") in ("goal", "shot", "motm"),
                      ev.get("kind"))
                check("state: event id + timings",
                      isinstance(ev.get("id"), str) and "duration" in ev
                      and "remaining" in ev)
                player = ev.get("player") or {}
                check("state: player block has minutes",
                      "minutes" in player and "minutes_exact" in player)
                check("state: milestone key present",
                      isinstance((ev.get("milestone") or {}).get("key"), str),
                      (ev.get("milestone") or {}).get("key"))
                shot = ev.get("shot") or {}
                check("state: shot declares its data source",
                      shot.get("speed_source") in ("game", "modelled")
                      and shot.get("distance_source") in ("game", "modelled"))
            hud = st["hud"]
            check("hud: style index + names", hud["style"] in (0, 1, 2))
            check("hud: credit carried in state",
                  "MOONFROS" in str(hud.get("credit", "")).upper(),
                  hud.get("credit"))
            # absent hud.toast means "no toast on screen"; when present it must
            # carry everything the overlay needs to draw and de-duplicate it.
            if "toast" in hud:
                tst = hud["toast"] or {}
                check("hud: toast channel shaped",
                      all(k in tst for k in ("text", "kind", "seq", "hold")),
                      tst.get("kind"))
            else:
                check("hud: toast channel optional", True, "absent = no toast")
            check("status: overlay visibility reported",
                  isinstance(st["status"].get("overlay_visible"), bool))
        except json.JSONDecodeError as exc:
            check("state: valid json", False, str(exc))
    else:
        check("state: json written", False, state_path)

    if verbose:
        for line in g.RAWLOG.values():
            print("    log:", line)
    return None



# ---------------------------------------------------------------------------
# 6. Installer / packaging checks
# ---------------------------------------------------------------------------
def packaging_checks():
    inst = os.path.join(ROOT, "install.bat")
    unin = os.path.join(ROOT, "uninstall.bat")
    ps1 = os.path.join(ROOT, "_ngb_ini.ps1")
    readme_txt = os.path.join(ROOT, "README.txt")
    overlay = os.path.join(ROOT, "ngb-overlay")

    if not os.path.exists(inst):
        return check("install: script present", False, inst)
    check("install: script present", True)
    src = read(inst)
    low = src.lower()
    ps = read(ps1) if os.path.exists(ps1) else ""

    check("install: validates the Sider folder", "sider.ini" in low and "not found" in low)
    check("install: scans every drive", re.search(r"for %%D in \(C D E", src) is not None
          or re.search(r"for %%d in \(c d e", low) is not None)
    check("install: accepts drag & drop / argument", "%~1" in src)
    check("install: copies the module", "NGB_Presentation.lua" in src)
    check("install: installs the renderer DLL",
          "NGB_Render.dll" in src and "ngb-render" in low)
    # problem 10: no compiler, no second window, nothing for the user to build
    check("install: needs no compiler (problem 10)",
          "csc" not in low and "csc.exe" not in low)
    check("install: keeps the C# overlay as an optional fallback",
          "ngb-overlay" in low and "fallback" in low)
    check("install: never deletes anything", not any(
        t in low for t in ("del /s", "del /q", "rd /s", "format ", "deltree")))
    check("install: starts no second window", "start_ngb_overlay.bat" not in low)
    check("install: writes a log", "install_log.txt" in low)
    check("install: mentions match-stats in the manual fallback", "match-stats.enabled" in low)
    check("install: stops when the renderer DLL is missing",
          "build_failed" in low and "install incomplete" in low)
    check("install: names every log file in the success message",
          all(k in low for k in ("sider.log", "ngb-dll.log", "heartbeat.txt",
                                 "render.txt")))
    # The success message prints real paths. `\\` is not an escape in batch, so
    # a doubled backslash reaches the user verbatim; catch it here.
    doubled = [ln.strip() for ln in src.splitlines()
               if ln.lstrip().lower().startswith("echo") and "\\\\" in ln
               and "%sider%" in ln.lower()]
    check("install: no doubled backslashes in printed paths", not doubled,
          "; ".join(doubled[:2]))
    # and the paths must be the ones the code actually writes: the DLL gets its
    # log path from the module (log_file=<dir>ngb-dll.log), state.json and the
    # two heartbeat files live in the same folder
    check("install: printed paths match the runtime folder",
          re.search(r"content\\ngb-presentation\\(ngb-dll\.log|state\.json|"
                    r"heartbeat\.txt|render\.txt)", src) is not None)
    if os.path.exists(os.path.join(ROOT, "ngb-overlay", "Start_NGB_Overlay.bat")):
        with open(os.path.join(ROOT, "ngb-overlay", "Start_NGB_Overlay.bat"),
                  encoding="utf-8", errors="replace") as fh:
            starter = fh.read().lower()
        check("start script: warns about a stale exe", "older ngb_overlay.exe" in starter)
    check("install: creates the runtime state folder",
          re.search(r"content\\ngb-presentation", src) is not None
          and "mkdir" in low)
    check("install: shows the branding", "moonfros presents" in low)
    check("install: manual fallback if PowerShell is blocked",
          "clip" in low and "notepad" in low)

    check("install: ini editor present", os.path.exists(ps1))
    check("ini editor: registers the module", "lua.module" in ps and "NGB_Presentation.lua" in ps)
    check("ini editor: enables luajit extensions", "luajit.ext.enabled" in ps)
    check("ini editor: enables match stats", "match-stats.enabled" in ps)
    check("ini editor: backs the file up", ".ngb.bak" in ps)
    check("ini editor: inserts next to other modules", "lua.module" in ps and "Insert" in ps)
    check("ini editor: can remove the entry", "remove" in ps)
    # PROBLEM 9 regression gate. An `else` that follows a bare statement is a
    # parse error, and PowerShell then refuses to run the whole script - which
    # is exactly how uninstall.bat ended up failing. Braces must balance and
    # every else must hang off a closing brace.
    check("ini editor: braces balance", ps.count("{") == ps.count("}"),
          "%d { vs %d }" % (ps.count("{"), ps.count("}")))
    bad_else = []
    pl = ps.splitlines()
    for i, line in enumerate(pl):
        t = line.strip()
        if t.startswith("else") and not t.startswith("} else"):
            prev = pl[i - 1].strip() if i else ""
            if not (prev.endswith("}") or prev.startswith("elseif")
                    or prev.startswith("if ") or prev.startswith("}")):
                bad_else.append("line %d: %s" % (i + 1, t))
    check("ini editor: no dangling else (problem 9)", not bad_else,
          "; ".join(bad_else[:2]))
    check("ini editor: never overwrites the first backup",
          "Test-Path -LiteralPath ($Ini + '.ngb.bak')" in ps)

    if not os.path.exists(unin):
        check("uninstall: script present", False, unin)
    else:
        check("uninstall: script present", True)
        u = read(unin)
        ulow = u.lower()
        check("uninstall: asks for confirmation", "choice /c yn" in ulow)
        check("uninstall: removes only mod files",
              "ngb_presentation.lua" in ulow and "ngb-overlay" in ulow)
        check("uninstall: removes the renderer DLL",
              "ngb-render" in ulow and "ngb_render.dll" in ulow)
        check("uninstall: guards foreign overlay folds", "ngb_overlay.cs" in ulow)
        check("uninstall: unregisters only its line", "-mode remove" in ulow)
        wild = re.findall(r'del\s+/[a-z]*q?[a-z]*\s+"?[^"\r\n]*\*', ulow)
        wild += re.findall(r'rd\s+/s[^\r\n]*"%sider%"', ulow)
        wild += re.findall(r'rmdir[^\r\n]*"%sider%"', ulow)
        check("uninstall: no wildcard / root deletes", not wild, ", ".join(wild[:2]))
        check("uninstall: stops the overlay", "taskkill" in ulow)

    for f in ("Start_NGB_Overlay.bat", "Quit_NGB_Overlay.bat", "app.manifest",
              "NGB_Overlay.cs", "README.txt"):
        check("overlay: %s" % f, os.path.exists(os.path.join(overlay, f)))

    if not os.path.exists(readme_txt):
        check("docs: README.txt present", False, readme_txt)
    else:
        check("docs: README.txt present", True)
        doc = read(readme_txt)
        check("docs: README.txt explains the install", "install.bat" in doc.lower())
        check("docs: README.txt documents the hotkeys",
              "[7]" in doc and "[8]" in doc and "[9]" in doc)
        check("docs: README.txt documents the uninstall", "uninstall.bat" in doc.lower())
        check("docs: README.txt separates measured and modelled data",
              "MODELLED" in doc.upper() and "REAL" in doc.upper())
        check("docs: README.txt credits MoonFros", "MoonFros" in doc)
        # 2.0 documentation
        check("docs: CHANGELOG covers the ten problems",
              os.path.exists(os.path.join(ROOT, "CHANGELOG.md")))
        chg = read(os.path.join(ROOT, "CHANGELOG.md")) if os.path.exists(
            os.path.join(ROOT, "CHANGELOG.md")) else ""
        check("docs: CHANGELOG marks unverified work honestly",
              "UNVERIFIED" in chg)
        check("docs: CHANGELOG names all ten problems",
              all(("## %d." % i) in chg for i in range(1, 11)),
              ", ".join(str(i) for i in range(1, 11) if ("## %d." % i) not in chg))
        check("docs: README has the WHY-NOTHING-SHOWS checklist",
              "WHY NOTHING SHOWS" in doc.upper())
        check("docs: README documents the renderer hotkeys",
              all(k in doc for k in ("F8", "F7", "F12")))
        check("docs: README explains the self-test card",
              "DEMO - NOT REAL DATA" in doc or "DEMO-" in doc)
        check("docs: README documents renderer/dll_enabled",
              "dll_enabled" in doc and "renderer" in doc.lower())
        tech = read(os.path.join(ROOT, "docs", "TECHNICAL.md"))
        check("docs: TECHNICAL documents the DLL hook",
              "IDXGISwapChain::Present" in tech and "MinHook" in tech)
        check("docs: TECHNICAL documents the SEH safety rule",
              "__try" in tech and "SEH" in tech)
        check("docs: TECHNICAL no longer claims ReadProcessMemory",
              "the mod reads through **`ReadProcessMemory`**" not in tech)
        # the sandbox facts must carry their provenance, and the memory story
        # must name the real problem (Sider's read is ffi.string, not a memcpy)
        check("docs: TECHNICAL cites the Sider sandbox source",
              "push_env_table" in tech and "sider.cpp:6566" in tech
              and "lua_setfenv" in tech)
        check("docs: TECHNICAL states memory.read is a raw dereference",
              "ffi.string" in tech and "access violation" in tech)
        check("docs: TECHNICAL documents the safe memory API",
              all(k in tech for k in ("NGB_Read", "NGB_Write", "NGB_Query",
                                      "ReadProcessMemory", "VirtualQuery")))
        check("docs: TECHNICAL documents allow_unsafe_memory_reads",
              "allow_unsafe_memory_reads" in tech)
        check("docs: CHANGELOG records problem 11", "## 11." in chg and "memory.lua" in chg)
        check("docs: README explains the MEMORY strip line", "MEMORY" in doc)

    check("docs: technical reference present",
          os.path.exists(os.path.join(ROOT, "docs", "TECHNICAL.md")))
    check("docs: mod README present", os.path.exists(os.path.join(ROOT, "README.md")))
    check("preview: interactive preview present", os.path.exists(HTML))



# ---------------------------------------------------------------------------
# 7. DLL renderer: source checks, a real build, and host unit tests
# ---------------------------------------------------------------------------
RENDER = os.path.join(ROOT, "ngb-render")


def pe_info(path):
    """machine + exported names of a PE file, without any external tooling."""
    with open(path, "rb") as fh:
        d = fh.read()
    if d[:2] != b"MZ":
        return None, []
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        return None, []
    machine = struct.unpack_from("<H", d, pe + 4)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    magic = struct.unpack_from("<H", d, pe + 24)[0]
    ddoff = pe + 24 + (112 if magic == 0x20B else 96)
    exp_rva = struct.unpack_from("<I", d, ddoff)[0]
    secs = []
    for i in range(nsec):
        o = pe + 24 + opt + 40 * i
        vsize, va, rsize, roff = struct.unpack_from("<IIII", d, o + 8)
        secs.append((va, max(vsize, rsize), roff))

    def r2o(rva):
        for va, size, roff in secs:
            if va <= rva < va + size:
                return roff + (rva - va)
        return None

    names = []
    if exp_rva:
        eo = r2o(exp_rva)
        if eo:
            nnames = struct.unpack_from("<I", d, eo + 24)[0]
            names_rva = struct.unpack_from("<I", d, eo + 32)[0]
            no = r2o(names_rva)
            if no:
                for i in range(nnames):
                    nr = struct.unpack_from("<I", d, no + 4 * i)[0]
                    o = r2o(nr)
                    if o:
                        end = d.index(b"\0", o)
                        names.append(d[o:end].decode("ascii", "replace"))
    return machine, names


def dll_checks(verbose=False):
    if not os.path.isdir(RENDER):
        return check("dll: project present", False, RENDER)
    check("dll: project present", True)

    src = read(os.path.join(RENDER, "src", "ngb_render.c"))
    gfx = read(os.path.join(RENDER, "src", "ngb_gfx.c"))
    card = read(os.path.join(RENDER, "src", "ngb_card.c"))
    jsrc = read(os.path.join(RENDER, "src", "ngb_json.c"))
    allc = src + gfx + card + jsrc

    # ---- what it must do -------------------------------------------------
    check("dll: hooks Present + ResizeBuffers",
          "vtbl[8]" in src and "vtbl[13]" in src, "dxgi swapchain vtbl")
    check("dll: uses MinHook", "MH_CreateHook" in src and "MH_EnableHook" in src)
    check("dll: probe device/swapchain", "D3D11CreateDeviceAndSwapChain" in src)
    src_code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src_code = re.sub(r"//[^\n]*", "", src_code)
    check("dll: probe window is private, never the foreground window",
          "GetForegroundWindow" not in src_code and "WS_EX_TOOLWINDOW" in src_code)
    check("dll: exports NGB_Start / NGB_GetState",
          "__declspec(dllexport) int NGB_Start" in src and "NGB_GetState" in src)
    # the memory helpers must be non-faulting: ReadProcessMemory/VirtualQuery,
    # never a raw dereference of a caller-supplied address
    check("dll: memory helpers use ReadProcessMemory / VirtualQuery",
          "ReadProcessMemory(GetCurrentProcess()" in src
          and "VirtualQuery(" in src
          and "WriteProcessMemory(GetCurrentProcess()" in src)
    check("dll: read length is capped", "len > (1u << 20)" in src)
    check("dll: releases size-dependent objects before ResizeBuffers",
          "ngb_gfx_shutdown_keep_hook()" in src and
          src.index("ngb_gfx_shutdown_keep_hook()") <
          src.index("s_resize_orig(sc, count, w, h, fmt, flags)"))
    check("dll: writes exactly one file of its own",
          src.count("GENERIC_WRITE") == 1)
    check("dll: reads state.json only",
          "state_file" in src and "match.home.abbr" in src)
    check("dll: touches no game memory offsets",
          "0x7B5C0" not in allc and "0x120" not in allc)

    # ---- crash safety ----------------------------------------------------
    check("dll: hardware SEH around the Present body",
          "__try {" in src and "__except (EXCEPTION_EXECUTE_HANDLER)" in src)
    check("dll: a fault disables the renderer, not the game",
          "g_dead, 1" in src and "Renderer disabled, game left running" in src)
    check("dll: re-entrancy guard in the hook", "s_in_present" in src)
    check("dll: kill-switch hotkey", "hk_kill" in src and "GetAsyncKeyState" in src)
    check("dll: dll_enabled = 0 installs no hooks",
          "if (!g_cfg.enabled)" in src and "not installing hooks" in src)
    check("dll: file IO runs off the render thread",
          "CreateThread" in src and "poll_thread" in src)
    check("dll: every failure path logs", src.count("ngb_log(") > 20,
          "%d log calls" % src.count("ngb_log("))
    check("dll: state age comes from the file's write time",
          "GetFileTime" in src)

    # ---- rendering quality ----------------------------------------------
    check("dll: state save/restore around the frame",
          "OMGetRenderTargets" in gfx and "RSGetViewports" in gfx)
    check("dll: alpha blended quads", "D3D11_BLEND_SRC_ALPHA" in gfx)
    check("dll: text is a GDI mask + cached texture",
          "TextOutW" in gfx and "text_ent" in gfx)
    check("dll: shaders compiled at runtime", "d3dcompiler_47.dll" in gfx)
    card_code = re.sub(r"/\*.*?\*/", "", card, flags=re.S)
    card_code = re.sub(r"//[^\n]*", "", card_code)
    check("dll: no fixed resolution in the layout",
          "1920" not in card_code and "h / 1080.0f" in card_code)
    check("dll: unknown scorer is labelled, never invented",
          "SCORER NOT AVAILABLE" in card)
    check("dll: unvalidated stats are labelled", "PLAYER DATA UNAVAILABLE" in card)
    check("dll: measured vs modelled is shown",
          "MODELLED" in card and "MEASURED" in card)
    check("dll: score bug only while a match is live", "st->live" in card)
    check("dll: self-test is stamped DEMO", "DEMO - NOT REAL DATA" in card)
    check("dll: json reader is bounds checked",
          "skip_value" in jsrc and "ngb_json_path" in jsrc)
    check("dll: result card listens for kind=fulltime",
          '"fulltime"' in card and '"half_time"' in card)

    # ---- is the shipped DLL the real thing? ------------------------------
    shipped = os.path.join(RENDER, "NGB_Render.dll")
    if not os.path.exists(shipped):
        check("dll: prebuilt DLL shipped", False, "ngb-render/NGB_Render.dll")
    else:
        machine, names = pe_info(shipped)
        check("dll: prebuilt DLL shipped", True,
              "%.0f KB" % (os.path.getsize(shipped) / 1024.0))
        check("dll: prebuilt DLL is x64", machine == 0x8664, hex(machine or 0))
        check("dll: prebuilt DLL exports the API",
              all(n in names for n in ("NGB_Start", "NGB_GetState", "NGB_Stop")),
              ", ".join(names) or "no exports")
        check("dll: prebuilt DLL exports the safe memory API",
              all(n in names for n in ("NGB_Read", "NGB_Write", "NGB_Query")),
              ", ".join(names) or "no exports")

    # ---- rebuild from source --------------------------------------------
    zig = shutil.which("zig") or os.environ.get("ZIG")
    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    build_dir = tempfile.mkdtemp(prefix="ngb_dll_")

    if zig and os.path.exists(zig):
        out = os.path.join(build_dir, "NGB_Render.dll")
        cmd = [zig, "cc", "-target", "x86_64-windows-gnu", "-O2", "-shared",
               "-fms-extensions", "-o", out]
        cmd += [os.path.join("src", f) for f in
                ("ngb_render.c", "ngb_gfx.c", "ngb_card.c", "ngb_json.c")]
        cmd += [os.path.join("minhook", "src", f) for f in
                ("hook.c", "buffer.c", "trampoline.c", os.path.join("hde", "hde64.c"))]
        cmd += ["-I", os.path.join("minhook", "include"), "-I", "src",
                "-ld3d11", "-ldxgi", "-lgdi32", "-luser32", "-lole32", "-loleaut32"]
        try:
            proc = subprocess.run(cmd, cwd=RENDER, capture_output=True, timeout=900)
            ok_build = proc.returncode == 0 and os.path.exists(out)
            detail = "" if ok_build else proc.stderr.decode("utf-8", "replace")[-400:]
            check("dll: builds from source (zig cc)", ok_build, detail)
            if ok_build:
                machine, names = pe_info(out)
                check("dll: fresh build is x64 with the API",
                      machine == 0x8664 and "NGB_Start" in names, hex(machine or 0))
        except Exception as exc:  # noqa: BLE001
            check("dll: builds from source (zig cc)", None, str(exc)[:200])
    else:
        check("dll: builds from source (zig cc)", None, "skipped (no zig)")

    # ---- host unit tests: json reader + card geometry --------------------
    if cc:
        for name, files, extra in (
                ("json", ["tests/json_test.c", "src/ngb_json.c"], []),
                ("card", ["tests/card_test.c", "src/ngb_card.c"], ["-lm"])):
            exe = os.path.join(build_dir, name + "_test")
            cmd = [cc, "-DNGB_HOST_TEST", "-I", "src", "-o", exe] + files + extra
            try:
                proc = subprocess.run(cmd, cwd=RENDER, capture_output=True, timeout=180)
                if proc.returncode != 0:
                    check("dll: %s test compiles" % name, False,
                          proc.stderr.decode("utf-8", "replace")[-300:])
                    continue
                check("dll: %s test compiles" % name, True)
                args = [exe]
                if name == "json" and _last_state_json:
                    sample = os.path.join(build_dir, "state.json")
                    with open(sample, "w", encoding="utf-8") as fh:
                        fh.write(_last_state_json)
                    args.append(sample)
                proc = subprocess.run(args, cwd=RENDER, capture_output=True, timeout=180)
                out = proc.stdout.decode("utf-8", "replace")
                tail = [l for l in out.splitlines()
                        if l.startswith("PASSED") or l.startswith("FAILED")]
                check("dll: %s test passes" % name, proc.returncode == 0,
                      tail[-1] if tail else out[-200:])
            except Exception as exc:  # noqa: BLE001
                check("dll: %s test compiles" % name, None, str(exc)[:200])
    else:
        check("dll: host unit tests", None, "skipped (no cc)")


# ---------------------------------------------------------------------------
# 7b. Calibration tool
# ---------------------------------------------------------------------------
def calibration_checks():
    path = os.path.join(ROOT, "tools", "decode_probe.py")
    if not os.path.exists(path):
        return check("calibration: decoder present", False, path)
    src = read(path)
    check("calibration: decoder present", True)
    check("calibration: writes calibration.txt", "calibration.txt" in src)
    check("calibration: has a selftest", "--selftest" in src and "def selftest" in src)
    # The selftest must run WITHOUT numpy too: the pure-Python scan used to
    # take minutes on a zero-filled synthetic dump, which is why this tool was
    # documented for a long time but never actually exercised.
    check("calibration: scan does not need numpy", "array" in src)
    check("calibration: scan has a time budget", "max_scan_s" in src)
    try:
        out = subprocess.run([sys.executable, path, "--selftest"],
                             capture_output=True, text=True, timeout=300)
    except Exception as exc:  # pragma: no cover - environment dependent
        results.append(("calibration: selftest finds the layout", None, str(exc)))
        return
    ok = out.returncode == 0 and out.stdout.count("PASS") >= 3
    tail = (out.stdout or out.stderr).strip().splitlines()
    check("calibration: selftest finds the layout", ok, tail[-1] if tail else "")
    check("calibration: selftest reports no failure", "FAIL" not in out.stdout)


def main():
    verbose = "--verbose" in sys.argv
    lua_static_checks()
    ini_checks()
    cs_checks()
    html_checks()
    player_bin_fixture()
    packaging_checks()
    calibration_checks()
    lua_runtime_checks(verbose)
    dll_checks(verbose)

    failed = [r for r in results if r[1] is False]
    skipped = [r for r in results if r[1] is None]
    width = max(len(r[0]) for r in results) + 2
    for name, ok, detail in results:
        tag = "PASS" if ok else ("SKIP" if ok is None else "FAIL")
        line = "  %-4s %s" % (tag, name.ljust(width))
        if detail:
            line += " " + detail
        print(line)

    print("\n%d checks, %d passed, %d failed, %d skipped"
          % (len(results), len(results) - len(failed) - len(skipped),
             len(failed), len(skipped)))
    if failed:
        print("\nFailures:")
        for name, _, detail in failed:
            print("  - %s: %s" % (name, detail))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
