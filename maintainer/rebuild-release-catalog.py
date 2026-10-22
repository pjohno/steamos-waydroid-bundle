"""Build a deterministic targets.manifest from immutable GitHub Release assets."""

import argparse
import re
import sys
from pathlib import Path

VERSION_RE = re.compile(r"[A-Za-z0-9._-]+\Z")
TARGET_RE = re.compile(r"[A-Za-z0-9._-]+\Z")
KERNEL_RE = re.compile(r"[A-Za-z0-9._+:-]+\Z")
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")


def read_metadata(path):
    assets = {}
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        cols = line.split("\t")
        if len(cols) != 3:
            raise ValueError(f"{path}:{lineno}: expected asset name, created_at, size")
        name, timestamp, size = cols
        if name in assets:
            raise ValueError(f"duplicate asset: {name}")
        if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", timestamp):
            raise ValueError(f"invalid asset timestamp for {name}: {timestamp}")
        if not size.isdecimal():
            raise ValueError(f"invalid asset size for {name}")
        assets[name] = (timestamp, int(size))
    if not assets:
        raise ValueError("release has no assets")
    return assets


def read_manifest(path):
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"malformed line in {path.name}: {line!r}")
        key, value = line.split("=", 1)
        if key in result:
            raise ValueError(f"duplicate key {key} in {path.name}")
        result[key] = value
    return result


def build_catalog(assets, manifest_dir):
    choices = {}
    usable = 0
    skipped = 0
    for name, (timestamp, size) in assets.items():
        if not name.endswith(".manifest") or name in {
            "latest.manifest",
            "targets.manifest",
        }:
            continue
        version = name[: -len(".manifest")]
        if not VERSION_RE.fullmatch(version):
            raise ValueError(f"unsafe bundle version in asset name: {name}")
        manifest_path = manifest_dir / name
        if not manifest_path.is_file():
            raise ValueError(f"published manifest was not downloaded: {name}")
        fields = read_manifest(manifest_path)
        target = fields.get("TARGET_ENVIRONMENT_ID", "")
        abi = fields.get("ABI_SHA256", "")
        kernel = fields.get("KERNEL_RELEASE", "")
        archive = f"{version}.tar.gz"
        checksum = f"{archive}.sha256"
        if (
            fields.get("bundle_version") != version
            or fields.get("archive") != archive
            or not TARGET_RE.fullmatch(target)
            or not SHA_RE.fullmatch(abi)
            or not KERNEL_RE.fullmatch(kernel)
            or not SHA_RE.fullmatch(fields.get("sha256", ""))
        ):
            raise ValueError(f"invalid metadata in published manifest: {name}")
        if not (
            size > 0
            and archive in assets
            and assets[archive][1] > 0
            and checksum in assets
            and assets[checksum][1] > 0
        ):
            print(f"Skipping incomplete release bundle: {version}", file=sys.stderr)
            skipped += 1
            continue

        keys = (
            ("target", target),
            ("abi", abi),
            ("target-kernel", target, kernel),
            ("abi-kernel", abi, kernel),
        )
        for key in keys:
            current = choices.get(key)
            if current is None or (timestamp, version) > current[:2]:
                choices[key] = (timestamp, version)
        usable += 1
    if not usable:
        raise ValueError(
            "no complete published bundles found; refusing to replace catalog"
        )
    output = ["format=3"]
    for key in sorted(choices):
        output.append("|".join(key) + "=" + choices[key][1])
    return "\n".join(output) + "\n", usable, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--assets", required=True, type=Path, help="TSV: name, created_at, size"
    )
    parser.add_argument("--manifests", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        catalog, usable, skipped = build_catalog(
            read_metadata(args.assets), args.manifests
        )
        args.output.write_text(catalog, encoding="utf-8")
    except (OSError, ValueError) as exc:
        parser.exit(1, f"error: {exc}\n")
    print(
        f"Catalog includes {usable} complete bundles ({skipped} incomplete skipped); "
        f"wrote {args.output}"
    )


if __name__ == "__main__":
    main()
