# &lt;Mod name&gt;

One paragraph: what the mod adds and when it appears in game.

| Feature | What it does |
|---------|--------------|
| ... | ... |

---

## Installation — 4 steps

1. Copy `modules\` into `<your Sider folder>\modules\`.
2. Copy any extra folder in this mod next to `sider.exe` (delete this step if
   there is none).
3. Add to `<your Sider folder>\sider.ini`:

   ```ini
   luajit.ext.enabled = 1          # only if the mod reads game memory
   lua.module = "Example.lua"
   ```

4. Launch the game.

---

## Hotkeys

| Key | Action |
|-----|--------|
| ... | ... |

## Configuration (`modules/Example.ini`)

| Key | Default | Meaning |
|-----|---------|---------|
| ... | ... | ... |

## Troubleshooting

**Nothing happens** — check `sider.log` for the mod's `[TAG]` lines.

---

## Verify

```bash
python3 mods/_template/tools/verify_mod.py
```
