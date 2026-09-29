#!/usr/bin/python3
"""Keep this installer's non-Steam shortcuts unique and apply local artwork."""

import argparse
import os
import re
import shutil
import struct
import sys
import tempfile
import zlib
from pathlib import Path


TARGETS = {
    "waydroid": {
        "name": "Waydroid",
        "executables": ("Android_Waydroid_Cage.sh",),
    },
    "waydroid-test": {
        "name": "Waydroid Test",
        "executables": ("Android_Waydroid_Test_Cage.sh",),
    },
    "nested-desktop": {
        "name": "steamos-nested-desktop",
        "executables": ("/usr/bin/steamos-nested-desktop", "steamos-nested-desktop"),
    },
}

ARTWORK_SUFFIXES = {
    "grid": "",
    "poster": "p",
    "hero": "_hero",
    "logo": "_logo",
    "icon": "_icon",
}
ARTWORK_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp", ".gif")


def read_cstring(fp):
    chars = []
    while (char := fp.read(1)) and char != b"\x00":
        chars.append(char)
    return b"".join(chars).decode("utf-8", errors="replace")


def parse_binary_vdf(fp):
    stack = [{}]
    while True:
        value_type = fp.read(1)
        if not value_type:
            break
        if value_type == b"\x08":
            if len(stack) > 1:
                stack.pop()
                continue
            break

        key = read_cstring(fp)
        current = stack[-1]
        if value_type == b"\x00":
            child = {}
            current[key] = child
            stack.append(child)
        elif value_type == b"\x01":
            current[key] = read_cstring(fp)
        elif value_type == b"\x02":
            current[key] = struct.unpack("<i", fp.read(4))[0]
        elif value_type == b"\x03":
            current[key] = struct.unpack("<f", fp.read(4))[0]
        elif value_type == b"\x07":
            current[key] = struct.unpack("<Q", fp.read(8))[0]
        elif value_type == b"\x0A":
            current[key] = struct.unpack("<q", fp.read(8))[0]
        else:
            raise ValueError(f"unknown VDF type {value_type!r} for key {key!r}")
    return stack[0]


def write_cstring(fp, value):
    fp.write(value.encode("utf-8") + b"\x00")


def write_binary_vdf(fp, values):
    for key, value in values.items():
        if isinstance(value, dict):
            fp.write(b"\x00")
            write_cstring(fp, key)
            write_binary_vdf(fp, value)
            fp.write(b"\x08")
        elif isinstance(value, str):
            fp.write(b"\x01")
            write_cstring(fp, key)
            write_cstring(fp, value)
        elif isinstance(value, int):
            fp.write(b"\x02")
            write_cstring(fp, key)
            fp.write(struct.pack("<i", value))
        elif isinstance(value, float):
            fp.write(b"\x03")
            write_cstring(fp, key)
            fp.write(struct.pack("<f", value))
        else:
            raise ValueError(f"unsupported value type {type(value)} for {key!r}")


def most_recent_steam_id(home):
    login_paths = (
        home / ".steam/root/config/loginusers.vdf",
        home / ".local/share/Steam/config/loginusers.vdf",
    )
    for login_path in login_paths:
        if not login_path.is_file():
            continue
        content = login_path.read_text(encoding="utf-8", errors="ignore")
        matches = re.findall(r'"(\d{17})"\s*\{([^}]+)}', content)
        candidates = []
        for steam_id64, block in matches:
            timestamp_match = re.search(r'"Timestamp"\s+"(\d+)"', block)
            timestamp = int(timestamp_match.group(1)) if timestamp_match else 0
            most_recent = bool(re.search(r'"MostRecent"\s+"1"', block))
            candidates.append((most_recent, timestamp, int(steam_id64)))
        if candidates:
            steam_id64 = max(candidates)[2]
            return steam_id64 - 76561197960265728
    return None


def shortcuts_path(home):
    steam_id3 = most_recent_steam_id(home)
    if steam_id3 is not None:
        return home / f".steam/root/userdata/{steam_id3}/config/shortcuts.vdf"

    # Fallback for a Deck with a usable shortcuts file but stale login metadata.
    candidates = list((home / ".steam/root/userdata").glob("*/config/shortcuts.vdf"))
    if candidates:
        return max(candidates, key=lambda path: path.stat().st_mtime)
    return None


def field(shortcut, name, default=""):
    wanted = name.casefold()
    for key, value in shortcut.items():
        if key.casefold() == wanted:
            return value
    return default


def is_target(shortcut, target):
    return match_kind(shortcut, target) is not None


def match_kind(shortcut, target):
    definition = TARGETS[target]
    app_name = str(field(shortcut, "AppName")).casefold()
    executable = str(field(shortcut, "Exe")).replace("\\", "/").casefold()
    if any(candidate.casefold() in executable
           for candidate in definition["executables"]):
        return "executable-path match"
    if app_name == definition["name"].casefold():
        return "name-only match"
    return None


def load_shortcuts(path):
    with path.open("rb") as fp:
        data = parse_binary_vdf(fp)
    shortcuts = data.get("shortcuts", data)
    if not isinstance(shortcuts, dict):
        raise ValueError("shortcuts.vdf has no shortcuts dictionary")
    return data, shortcuts


def matching_shortcuts(path, target):
    if path is None or not path.is_file():
        return []
    _, shortcuts = load_shortcuts(path)
    return [shortcut for shortcut in shortcuts.values()
            if isinstance(shortcut, dict) and is_target(shortcut, target)]


def describe_shortcuts(path, target):
    matches = matching_shortcuts(path, target)
    for index, shortcut in enumerate(matches, start=1):
        kind = match_kind(shortcut, target)
        app_name = str(field(shortcut, "AppName", "(unnamed)"))
        executable = str(field(shortcut, "Exe", "(missing executable)"))
        # Keep one record on one terminal line even if a malformed local VDF
        # contains control characters.
        app_name = " ".join(app_name.split())
        executable = " ".join(executable.split())
        print(f"{index}. [{kind}] {app_name}: {executable}")
    return 0 if matches else 1


def write_shortcuts(path, data, shortcuts):
    compacted = {str(index): shortcut for index, shortcut in enumerate(shortcuts)}
    if "shortcuts" in data:
        data["shortcuts"] = compacted
    else:
        data = compacted

    backup = path.with_suffix(path.suffix + ".waydroid-backup")
    if not backup.exists():
        shutil.copy2(path, backup)
    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as fp:
        temporary = Path(fp.name)
        write_binary_vdf(fp, data)
        fp.write(b"\x08")
        fp.flush()
        os.fsync(fp.fileno())
    temporary.chmod(mode)
    temporary.replace(path)


def shortcut_app_id(shortcut):
    stored = field(shortcut, "appid", None)
    if isinstance(stored, int):
        return stored & 0xFFFFFFFF
    executable = str(field(shortcut, "Exe"))
    app_name = str(field(shortcut, "AppName"))
    return (zlib.crc32((executable + app_name).encode("utf-8")) | 0x80000000) & 0xFFFFFFFF


def find_artwork_assets(artwork_dir=None, artwork=None, icon=None):
    assets = {}
    if artwork_dir is not None:
        if not artwork_dir.is_dir():
            raise ValueError(f"artwork directory does not exist: {artwork_dir}")
        for artwork_type in ARTWORK_SUFFIXES:
            matches = [artwork_dir / f"{artwork_type}{extension}"
                       for extension in ARTWORK_EXTENSIONS
                       if (artwork_dir / f"{artwork_type}{extension}").is_file()]
            if len(matches) > 1:
                raise ValueError(
                    f"multiple {artwork_type} artwork files found in {artwork_dir}")
            if matches:
                assets[artwork_type] = matches[0]

    # Retain compatibility with the previous single-image command line.
    if artwork is not None and artwork.is_file():
        for artwork_type in ("grid", "poster", "hero"):
            assets.setdefault(artwork_type, artwork)
    if icon is not None and icon.is_file():
        assets.setdefault("icon", icon)
        assets.setdefault("logo", icon)
    return assets


def install_artwork(path, shortcut, assets):
    app_id = shortcut_app_id(shortcut)
    grid = path.parent / "grid"
    grid.mkdir(parents=True, exist_ok=True)

    # Remove every supported old extension first, so a JPG-to-PNG change does
    # not leave Steam free to select a stale file.
    removed = remove_artwork(path, shortcut)
    installed = {}
    for artwork_type, source in assets.items():
        suffix = ARTWORK_SUFFIXES[artwork_type]
        destination = grid / f"{app_id}{suffix}{source.suffix.lower()}"
        shutil.copy2(source, destination)
        installed[artwork_type] = destination
    print(f"Installed {len(installed)} local Steam artwork file(s) for app "
          f"{app_id} in {grid}; replaced {removed} old file(s).")
    return installed


def remove_artwork(path, shortcut):
    app_id = shortcut_app_id(shortcut)
    grid = path.parent / "grid"
    removed = 0
    for suffix in ARTWORK_SUFFIXES.values():
        for extension in ARTWORK_EXTENSIONS:
            artwork = grid / f"{app_id}{suffix}{extension}"
            if artwork.is_file():
                artwork.unlink()
                removed += 1
    return removed


def reconcile(home, path, target, artwork_dir=None, artwork=None, icon=None,
              keep_duplicates=False):
    if path is None or not path.is_file():
        print("No shortcuts.vdf found; add the shortcut first.", file=sys.stderr)
        return 1

    data, shortcuts_dict = load_shortcuts(path)
    shortcuts = [value for value in shortcuts_dict.values() if isinstance(value, dict)]
    matches = [shortcut for shortcut in shortcuts if is_target(shortcut, target)]
    if not matches:
        print(f"No {target} Steam shortcut found.", file=sys.stderr)
        return 1

    # steamos-add-to-steam appends a newly created shortcut. When the user
    # deliberately requested another shortcut, decorate that newest match and
    # leave all earlier matches untouched.
    primary = matches[-1] if keep_duplicates else matches[0]
    definition = TARGETS[target]
    primary["AppName"] = definition["name"]

    try:
        assets = find_artwork_assets(artwork_dir, artwork, icon)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    if artwork_dir is not None and not assets:
        print(f"No supported artwork files found in {artwork_dir}.", file=sys.stderr)
        return 1

    duplicates = [] if keep_duplicates else matches[1:]
    duplicate_ids = {id(shortcut) for shortcut in duplicates}
    retained = [shortcut for shortcut in shortcuts if id(shortcut) not in duplicate_ids]
    for duplicate in duplicates:
        remove_artwork(path, duplicate)

    if assets:
        installed = install_artwork(path, primary, assets)
        if "icon" in installed:
            primary["icon"] = str(installed["icon"])
    write_shortcuts(path, data, retained)

    removed = len(matches) - 1
    if keep_duplicates:
        print(f"Decorated the newly added {target} shortcut; kept all "
              f"{len(matches)} matching shortcut(s).")
    else:
        print(f"Kept one {target} Steam shortcut; removed {removed} duplicate(s).")
    return 0


def remove_target(path, target):
    if path is None or not path.is_file():
        print("No shortcuts.vdf found; nothing to remove.")
        return 0

    data, shortcuts_dict = load_shortcuts(path)
    shortcuts = [value for value in shortcuts_dict.values() if isinstance(value, dict)]
    matches = [shortcut for shortcut in shortcuts if is_target(shortcut, target)]
    if not matches:
        print(f"No {target} Steam shortcut found; nothing to remove.")
        return 0

    retained = [shortcut for shortcut in shortcuts if not is_target(shortcut, target)]
    artwork_removed = sum(remove_artwork(path, shortcut) for shortcut in matches)
    write_shortcuts(path, data, retained)
    print(f"Removed {len(matches)} {target} shortcut(s) and {artwork_removed} artwork file(s).")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("has", "count", "describe", "reconcile", "remove"), nargs="?",
                        default="reconcile")
    parser.add_argument("target", choices=tuple(TARGETS), nargs="?", default="waydroid")
    parser.add_argument("--artwork-dir", type=Path)
    parser.add_argument("--artwork", type=Path)
    parser.add_argument("--icon", type=Path)
    parser.add_argument("--keep-duplicates", action="store_true")
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args()

    try:
        path = shortcuts_path(args.home)
        if args.action == "has":
            return 0 if matching_shortcuts(path, args.target) else 1
        if args.action == "count":
            print(len(matching_shortcuts(path, args.target)))
            return 0
        if args.action == "describe":
            return describe_shortcuts(path, args.target)
        if args.action == "remove":
            return remove_target(path, args.target)
        return reconcile(args.home, path, args.target, args.artwork_dir,
                         args.artwork, args.icon, args.keep_duplicates)
    except (OSError, ValueError, EOFError, struct.error) as error:
        print(f"Unable to read or update Steam shortcuts: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
