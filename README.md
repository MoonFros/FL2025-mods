# FL2025-mods

Mods for **SmokePatch Football Life 2025 / PES 2021** (Sider 7), by and for the
FL 2025 community. Every mod lives in its **own self-contained folder** under
[`mods/`](mods), so this repo can hold many mods without them interfering.

| Mod | Folder | What it does |
|-----|--------|--------------|
| **EA FC 27 HyperMotion Broadcast** | [`mods/fc27-broadcast`](mods/fc27-broadcast) | EA FC style goal‑replay camera sweep, live goal/shot telemetry cards, per‑player popup and post‑match MOTM card, drawn by a transparent click‑through HUD |

---

## Install a mod (the same 3 steps for every mod)

1. Open the mod's folder — e.g. [`mods/fc27-broadcast`](mods/fc27-broadcast) —
   and read its `README.md` (each one has a 4‑step install section). If it ships
   an `Install.bat`, just double‑click it (or drag your Sider folder onto it) and
   skip to step 4.
2. Copy the mod's `modules\` folder into `<your Sider folder>\modules\` and any
   other folder it ships (e.g. `fc27-overlay\`) next to `sider.exe`.
3. Add the mod's `lua.module = "..."` line to `<your Sider folder>\sider.ini`
   and launch the game. Anything else (extra folders, settings files, hotkeys)
   is described in that mod's README.

Nothing in this repo touches game data files, save files or EDIT data. Each mod
keeps its runtime output inside its own folder (`content\...`), and generated
files (`*.exe`, `state.json`, logs) are git‑ignored.

---

## Repo conventions (for adding a new mod)

```
mods/
└─ <mod-slug>/                 lower-case, hyphenated: "fc27-broadcast"
   ├─ README.md                what it does, requirements, 4-step install,
   │                           hotkeys, config table, troubleshooting
   ├─ modules/<Name>.lua       the Sider module (returns a table with init(ctx))
   ├─ modules/<Name>.ini       every setting the module reads, commented
   ├─ <extra-folder>/          anything else that is copied next to sider.exe
   │                           (e.g. fc27-overlay/ for a companion app)
   ├─ preview/                 optional: browser preview / screenshots
   ├─ docs/TECHNICAL.md        optional: offsets, detection logic, calibration
   └─ tools/verify_mod.py      offline test-suite: `python3 <path>` exits 0 on pass
```

Rules that keep mods independent:

* **One folder per mod.** The folder mirrors what gets copied into the Sider
  folder, so installation is always "copy these folders, add one ini line".
* **Never share files between mods.** If two mods need the same helper, copy it
  into both — a mod must survive the other being deleted.
* **Every mod ships a verifier.** Static checks plus a functional run on a
  simulated memory image, so changes can be validated without launching the
  game: `python3 mods/<slug>/tools/verify_mod.py`.
* **No generated files in git** — see `.gitignore`.
* **Document the config.** The verifier should fail when the module reads a key
  the `.ini` does not declare.

---

## Status

* `mods/fc27-broadcast` — v1.0.0, 145/145 offline checks passing
  (`python3 mods/fc27-broadcast/tools/verify_mod.py`).
