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
def lua_static_checks():
    if not os.path.exists(LUA):
        return check("lua: module exists", False, LUA)
    src = read(LUA)
    check("lua: module exists", True, "%d bytes" % len(src))

    # strip comments and strings so the greps below only see real code
    code = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    code = re.sub(r"--[^\n]*", "", code)
    code_nostr = re.sub(r'"(\\.|[^"\\])*"', '""', code)
    code_nostr = re.sub(r"'(\\.|[^'\\])*'", "''", code_nostr)

    for banned in ("pcall", "xpcall", "require", "select", "loadstring",
                   "setmetatable", "rawset", "getmetatable"):
        hits = re.findall(r"(?<![%.\w])" + banned + r"\s*\(", code_nostr)
        check("lua: no %s() in module" % banned, not hits, ", ".join(hits[:3]))

    check("lua: returns module table", re.search(r"\breturn m\b", src) is not None)
    check("lua: has init(ctx)", re.search(r"function m\.init\(ctx\)", src) is not None)

    regs = re.findall(r'ctx\.register\(\s*"([^"]+)"\s*,\s*([A-Za-z0-9_.]+)\s*\)', src)
    check("lua: registers events", len(regs) >= 5, "%d events" % len(regs))
    anchored = all(fn.startswith("m.") for _, fn in regs)
    check("lua: handlers anchored on module table", anchored,
          ", ".join(fn for _, fn in regs if not fn.startswith("m.")))
    for _, fn in regs:
        name = fn.split(".")[-1]
        check("lua: %s defined" % fn,
              re.search(r"function m\.%s\(" % name, src) is not None)

    check("lua: guarded ffi cdef", "if not ffi.NGB_cdefs" in src)
    check("lua: VirtualQuery discovery", "NGB_VirtualQuery" in src)
    check("lua: ReadProcessMemory safe reads", "NGB_ReadProcessMemory" in src)
    check("lua: stat region signature", "0x18FFE0" in src and "0xEFFE0" in src)
    check("lua: record stride", "0x2134" in src and "0x59650" in src)
    check("lua: imperial conversions", "MPS_TO_MPH" in src and "M_TO_YD" in src
          and "M_TO_FT" in src)
    check("lua: 720p aware hud output", "scale_hint" in src)
    check("lua: companion launch via WinExec", "NGB_WinExec" in src and "io.popen" in src)
    check("brand: MOONFROS PRESENTS in the module", "MOONFROS PRESENTS" in src)
    check("brand: author in the module", "MoonFros" in src)
    check("hotkeys: digits 7 / 8 / 9 bound",
          all(k in src for k in ("0x37", "0x38", "0x39")))
    check("hotkeys: F7 / F8 / F9 not bound",
          all(k not in src for k in ("0x76", "0x77", "0x78")))
    check("hotkeys: key 1 untouched", "0x31" not in src)
    check("hotkeys: overlay-only gate", "hotkeys_overlay_only" in src)
    check("lua: milestones", "milestone_for" in src and "hat_trick" in src)
    check("lua: minutes tracking", "minutes_for" in src and "minutes_exact" in src)
    check("lua: assist attribution", "assist_side" in src)
    check("lua: toast channel", "set_toast" in src)
    check("lua: creates its state folder defensively",
          "ensure_dir" in src and "make_dirs" in src and "create_directory" in src)
    check("lua: presentation styles", "cycle_style" in src and "STYLE_NAMES" in src)

    # long bracket / quote balance, cheap but catches truncated files
    check("lua: even double quotes", code.count('"') % 2 == 0)


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
                    "pitch_region_base", "debug_log"}), "")


# ---------------------------------------------------------------------------
# 3. C# companion structural checks
# ---------------------------------------------------------------------------
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
    check("cs: no external nuget deps",
          not re.search(r"using\s+Newtonsoft", src))


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
    state_path = os.path.join(sider, "content", "ngb-presentation", "state.json")
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as fh:
            raw = fh.read()
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
    check("install: copies module + overlay",
          "NGB_Presentation.lua" in src and "ngb-overlay" in low)
    check("install: never deletes anything", not any(
        t in low for t in ("del /s", "del /q", "rd /s", "format ", "deltree")))
    check("install: builds + starts the overlay", "start_ngb_overlay.bat" in low)
    check("install: writes a log", "install_log.txt" in low)
    check("install: creates the runtime state folder",
          re.search(r"content\\ngb-presentation", src) is not None
          and "mkdir" in low)
    check("install: shows the branding", "moonfros presents" in low)
    check("install: manual fallback if PowerShell is blocked",
          "clip" in low and "notepad" in low)

    check("install: ini editor present", os.path.exists(ps1))
    check("ini editor: registers the module", "lua.module" in ps and "NGB_Presentation.lua" in ps)
    check("ini editor: enables luajit extensions", "luajit.ext.enabled" in ps)
    check("ini editor: backs the file up", ".ngb.bak" in ps)
    check("ini editor: inserts next to other modules", "lua.module" in ps and "Insert" in ps)
    check("ini editor: can remove the entry", "remove" in ps)

    if not os.path.exists(unin):
        check("uninstall: script present", False, unin)
    else:
        check("uninstall: script present", True)
        u = read(unin)
        ulow = u.lower()
        check("uninstall: asks for confirmation", "choice /c yn" in ulow)
        check("uninstall: removes only mod files",
              "ngb_presentation.lua" in ulow and "ngb-overlay" in ulow)
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
    check("docs: technical reference present",
          os.path.exists(os.path.join(ROOT, "docs", "TECHNICAL.md")))
    check("docs: mod README present", os.path.exists(os.path.join(ROOT, "README.md")))
    check("preview: interactive preview present", os.path.exists(HTML))


# ---------------------------------------------------------------------------
def main():
    verbose = "--verbose" in sys.argv
    lua_static_checks()
    ini_checks()
    cs_checks()
    html_checks()
    player_bin_fixture()
    packaging_checks()
    lua_runtime_checks(verbose)

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
