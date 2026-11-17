#!/usr/bin/env python3
"""
Add every installed Steam game to Sunshine's app list, with its cover art, so each game shows up
as its own tile in Moonlight and launches straight into the game.

Entries this script generates are recognised by their launch command
(`setsid steam steam://rungameid/<id>`); every other app in apps.json is kept as it is.
Sunshine re-reads apps.json whenever a client asks for the list, so no restart is needed.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
STEAM = HOME / ".local/share/Steam"
APPS = Path(os.environ.get("SUNSHINE_APPS", HOME / ".config/sunshine/apps.json"))
COVERS = HOME / ".config/sunshine/covers"
LAUNCH = "setsid steam steam://rungameid/{}"
NOT_GAMES = re.compile(r"proton|steam linux runtime|steamworks common|steam runtime|steamvr|redistributable", re.I)
FULLY_INSTALLED = 4


def libraries():
    vdf = STEAM / "steamapps/libraryfolders.vdf"
    paths = {STEAM}
    try:
        paths.update(Path(p) for p in re.findall(r'"path"\s+"([^"]+)"', vdf.read_text()))
    except OSError:
        pass
    return [p / "steamapps" for p in paths if (p / "steamapps").is_dir()]


def installed_games():
    games = {}
    for lib in libraries():
        for acf in lib.glob("appmanifest_*.acf"):
            text = acf.read_text(errors="replace")
            appid = re.search(r'"appid"\s+"(\d+)"', text)
            name = re.search(r'"name"\s+"([^"]+)"', text)
            flags = re.search(r'"StateFlags"\s+"(\d+)"', text)
            if not appid or not name or NOT_GAMES.search(name.group(1)):
                continue
            if flags and not int(flags.group(1)) & FULLY_INSTALLED:
                continue
            games[appid.group(1)] = name.group(1)
    return games


def cover(appid):
    """Steam's portrait library art converted to PNG (Sunshine serves PNG box art)."""
    cache = STEAM / "appcache/librarycache"
    folder = cache / appid
    candidates = []
    # Newer Steam clients keep art in hashed sub-folders; prefer the largest portrait capsule.
    for pattern in ("library_600x900_2x.jpg", "library_600x900.jpg", "library_capsule_2x.jpg", "library_capsule.jpg"):
        candidates += sorted(folder.rglob(pattern), key=lambda p: p.stat().st_size, reverse=True) if folder.is_dir() else []
    candidates.append(cache / f"{appid}_library_600x900.jpg")
    src = next((c for c in candidates if c.exists()), None)
    if src is None:
        return None
    dst = COVERS / f"{appid}.png"
    if not dst.exists() or dst.stat().st_mtime < src.stat().st_mtime:
        COVERS.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), str(dst)], capture_output=True)
        if r.returncode != 0:
            return None
    return str(dst)


def is_generated(app):
    return any(str(c).startswith("setsid steam steam://rungameid/") for c in app.get("detached", []))


def main():
    try:
        data = json.loads(APPS.read_text())
    except (OSError, ValueError):
        data = {"env": {"PATH": "$(PATH):$(HOME)/.local/bin"}, "apps": [{"name": "Desktop", "image-path": "desktop.png"}]}

    kept = [a for a in data.get("apps", []) if not is_generated(a)]
    games = []
    for appid, name in sorted(installed_games().items(), key=lambda kv: kv[1].lower()):
        app = {"name": name, "detached": [LAUNCH.format(appid)]}
        art = cover(appid)
        if art:
            app["image-path"] = art
        games.append(app)
    data["apps"] = kept + games

    APPS.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=APPS.parent, prefix=".apps.", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, APPS)
    print(f"{len(games)} Steam games in {APPS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
