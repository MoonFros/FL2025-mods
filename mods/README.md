# mods/

One folder per mod. Each folder is self-contained: it holds the Sider module,
its settings file, anything else that is copied next to `sider.exe`, and its own
docs and verifier.

| Folder | Mod |
|--------|-----|
| `fc27-broadcast/` | EA FC 27 HyperMotion Broadcast & Replay Telemetry |
| `ngb-presentation/` | Next-Gen Football Broadcast Presentation (MOONFROS PRESENTS) |
| `_template/` | Skeleton to copy when starting a new mod |

The layout rules and the checklist for a new mod are in the
[repo README](../README.md#repo-conventions-for-adding-a-new-mod).

Every mod folder may ship an `Install.bat` at its root: copy the folders into a
Sider install, wire up `sider.ini`, and start whatever the mod needs.

```bash
python3 mods/<slug>/tools/verify_mod.py     # exit code 0 = all checks pass
```
