#!/usr/bin/env python3
"""Build the ready-to-install ZIPs for the sample chat modules.

Every sample folder in `samples/` ships a pre-packaged `samples/<name>.zip`
next to it (tracked in git; test/unit/module_sdk_assets_test.dart guards
that each zip always matches its folder exactly). This script rebuilds
those archives:

    python3 scripts/build_module_zips.py               # all samples
    python3 scripts/build_module_zips.py agentic-wallet # one sample

Layout: the FOLDER is zipped (single top-level directory `<name>/`),
the same layout as a GitHub "Download ZIP" — the app unwraps it.
File timestamps are normalized so rebuilds are reproducible: a zip only
differs in git when its folder content actually changed.
"""

import json
import os
import sys
import zipfile
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLES = os.path.join(REPO, "samples")

# Every sample that ships a ready-made zip (keep in sync with samples/).
ENTRIES = [
    "agentic-wallet",
    "airplane-mode",
    "chat-streamer",
    "converters",
    "counter",
    "csv-data",
    "evm-wallet",
    "facebook-page",
    "file-notes",
    "network-fetcher",
    "onhomeroom-daily",
    "qr-tools",
    "rss-reader",
    "totp-auth",
    "twitter-x",
    "web-browser",
]

# Fixed timestamp (UTC) baked into every archive entry.
FIXED_DATE = (2024, 1, 1, 0, 0, 0)


def build_zip(name: str) -> str:
    folder = os.path.join(SAMPLES, name)
    if not os.path.isdir(folder):
        raise SystemExit(f"samples/{name} does not exist")

    manifest_path = os.path.join(folder, "module.json")
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)  # sanity: must be valid JSON
    print(f"  manifest: {manifest.get('name')} v{manifest.get('version')} "
          f"commands={manifest.get('commands')}")

    files = []
    for root, dirs, names in os.walk(folder):
        dirs.sort()
        for fn in sorted(names):
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, folder).replace(os.sep, "/")
            files.append((full, f"{name}/{rel}"))

    out_path = os.path.join(SAMPLES, f"{name}.zip")
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        # explicit top-level directory entry, matching the existing zips
        dinfo = zipfile.ZipInfo(f"{name}/", date_time=FIXED_DATE)
        dinfo.compress_type = zipfile.ZIP_STORED
        dinfo.external_attr = (0o755 << 16) | 0x10  # MS-DOS dir flag
        zf.writestr(dinfo, b"")
        for full, arc in files:
            info = zipfile.ZipInfo(arc, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(full, "rb") as fh:
                zf.writestr(info, fh.read())

    # Post-build guard: the archive must carry exactly the folder's files.
    with zipfile.ZipFile(out_path) as zf:
        in_zip = sorted(n for n in zf.namelist() if not n.endswith("/"))
    expected = sorted(arc for _, arc in files)
    if in_zip != expected:
        raise SystemExit(f"samples/{name}.zip drifted from samples/{name}/")
    size = os.path.getsize(out_path)
    print(f"  wrote samples/{name}.zip ({len(files)} files, {size} bytes)")
    return out_path


def main() -> int:
    targets = sys.argv[1:] or ENTRIES
    unknown = [t for t in targets if t not in ENTRIES]
    if unknown:
        print(f"unknown sample(s): {', '.join(unknown)}", file=sys.stderr)
        print(f"known entries: {', '.join(ENTRIES)}", file=sys.stderr)
        return 2
    built = [build_zip(t) for t in targets]
    print(f"done: {len(built)} zip(s) built at {datetime.now(timezone.utc).isoformat()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
