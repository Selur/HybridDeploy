#!/usr/bin/env python3
# Hand-writes the VSScript config entry (`vapoursynth config` fails on this interpreter, see docs/32-linux-appimage-vapoursynth.md 4.10); must rerun every launch, the AppImage mount path changes each time.
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# HERE = <bundled-python-root>/lib/python3.14/site-packages/vapoursynth

vsscript = HERE / "libvsscript.so"
python_exe = HERE.parent.parent.parent.parent / "bin" / "python3.14"
libpython = HERE.parent.parent.parent / "libpython3.14.so"

for p in (vsscript, python_exe, libpython):
    if not p.exists():
        print(f"vsconfig-write: missing {p}", file=sys.stderr)
        sys.exit(1)

mtime = int(python_exe.stat().st_mtime)

config_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
config_path = Path(config_home) / "vapoursynth" / "vapoursynth.toml"
config_path.parent.mkdir(parents=True, exist_ok=True)


def esc(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


key = str(vsscript)
entries = {}
if config_path.exists():
    for line in config_path.read_text().splitlines():
        if "=" in line and line.strip().startswith('"'):
            k = line.split('"', 2)[1]
            entries[k] = line

entries[key] = f"{esc(key)} = [{esc(python_exe)},{esc(libpython)},{esc(mtime)}]"

config_path.write_text("\n".join(entries.values()) + "\n")
print(f"vsconfig-write: registered {key}")
