#!/usr/bin/env python3
"""
mods/_template/tools/verify_mod.py -- minimal, dependency-free verifier.

Copy this into a new mod folder and grow it as the mod grows. It checks the
things that historically break Sider modules:

  * the file loads as Lua and returns a table with an init(ctx) method
  * it never calls the globals Sider's sandbox does not provide
    (pcall / xpcall / require / select / next)
  * every callback registered with ctx.register is a field of that table
  * every setting the module reads (cfg_*("name")) is declared in the .ini
  * the .ini has no duplicate keys

Usage:  python3 mods/<slug>/tools/verify_mod.py [--verbose]
Exit code 0 = all checks passed. `pip install lupa` enables the load test.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = os.path.join(ROOT, "modules")
BANNED = ("pcall", "xpcall", "require", "select", "next")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), str(detail)))
    return bool(ok)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def pick(ext):
    if not os.path.isdir(MODULES):
        return []
    return sorted(os.path.join(MODULES, f) for f in os.listdir(MODULES)
                  if f.endswith(ext))


def strip_comments(src):
    src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    return re.sub(r"--[^\n]*", "", src)


def static_checks(lua_path, ini_path):
    src = read(lua_path)
    code = strip_comments(src)

    missing = [f for f in BANNED if re.search(r"(?<![\w.])%s\s*\(" % f, code)]
    check("lua: no sandbox-missing globals", not missing, ", ".join(missing))
    check("lua: returns module table", re.search(r"\breturn\s+m\b", code) is not None)
    check("lua: has init(ctx)",
          re.search(r"function\s+m\.init\s*\(\s*\w+\s*\)", code) is not None)

    regs = re.findall(r"ctx\.register\s*\(\s*\"([^\"]+)\"\s*,\s*m\.(\w+)\s*\)", code)
    check("lua: registers at least one event", len(regs) >= 1, "%d events" % len(regs))
    defined = set(re.findall(r"function\s+m\.(\w+)\s*\(", code))
    bad = sorted({fn for _, fn in regs if fn not in defined})
    check("lua: handlers are module fields", not bad, ", ".join(bad))

    # every setting the module reads must be declared in the ini
    keys = set(re.findall(r'cfg_[ifs]\(\s*"([\w.]+)"', code))
    if ini_path and os.path.exists(ini_path):
        ini = read(ini_path)
        declared, dupes = set(), []
        for line in ini.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            hit = re.match(r"^([\w.]+)\s*=", line)
            if hit:
                if hit.group(1) in declared:
                    dupes.append(hit.group(1))
                declared.add(hit.group(1))
        check("ini: declares every setting read", not (keys - declared),
              ", ".join(sorted(keys - declared)))
        check("ini: no duplicate keys", not dupes, ", ".join(sorted(set(dupes))))
        check("ini: comments every key", "#" in ini)
    else:
        check("ini: settings file exists", False, ini_path or "no .ini")

    check("lua: balanced long brackets",
          code.count("[[") == code.count("]]"), code.count("[[") - code.count("]]"))
    check("lua: even double quotes", code.count('"') % 2 == 0)
    return src


def load_check(lua_path, verbose=False):
    try:
        import lupa.luajit21 as lj
    except Exception:
        try:
            import lupa as lj  # fall back to whatever lupa provides
        except Exception:
            check("lua runtime: module loads", None, "pip install lupa to enable")
            return

    ok, detail, events = False, "", ""
    try:
        src = read(lua_path)
        runtime = lj.LuaRuntime(unpack_returned_tuples=True)
        g = runtime.globals()

        env = runtime.table()
        for lib in ("string", "math", "table", "tonumber", "tostring", "type",
                    "pairs", "ipairs", "error", "io", "os", "unpack", "assert"):
            env[lib] = g[lib]
        env["log"] = (lambda s: verbose and print("    log:", s))

        chunk = g.loadstring(src, lua_path)
        g.setfenv(chunk, env)
        mod = chunk()
        ok = mod is not None and mod["init"] is not None
        if ok:
            calls = []
            ctx = runtime.table()
            ctx["register"] = lambda name, fn: calls.append(str(name))
            ctx["sider_dir"] = ROOT + os.sep
            mod["init"](ctx)
            events = "events: " + ", ".join(calls)
            ok = True
    except Exception as exc:  # noqa: BLE001 - the message is the point
        ok, detail = False, str(exc).splitlines()[0][:160]
    check("lua runtime: module loads and inits", ok, detail or events)


def main():
    verbose = "--verbose" in sys.argv
    luas = pick(".lua")
    if not luas:
        check("module exists", False, MODULES)
    for lua in luas:
        ini = os.path.splitext(lua)[0] + ".ini"
        name = os.path.basename(lua)
        print("checking:", name)
        static_checks(lua, ini)
        load_check(lua, verbose)

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
