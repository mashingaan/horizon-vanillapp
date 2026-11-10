"""Verify the pinned registry archive against its Git checkout, then stage its mixin."""

import hashlib
import json
from pathlib import Path
import sys
import zipfile


lock = json.loads(Path("pack.lock.json").read_text(encoding="utf-8"))
archive_path, checkout, output = map(Path, sys.argv[1:])
asset = lock["files"]["tectonic_horizon"]
archive_bytes = archive_path.read_bytes()
if len(archive_bytes) != asset["size"] or hashlib.sha256(archive_bytes).hexdigest() != asset["hash"]:
    raise SystemExit("Tectonic archive differs from pack.lock.json")

manifest = {
    "schema": 1,
    "id": "tectonic_horizon",
    "version": asset["version"],
    "game": lock["minecraft"],
    "horizon": lock["horizon"],
    "mixins": lock["mixins"],
}
bundle = Path("mixins/tectonic_horizon")
sources = {
    path.relative_to(checkout).as_posix(): path.read_bytes()
    for path in (checkout / bundle).iterdir()
    if path.is_file() and path.suffix in (".rs", ".toml")
}
if not sources or json.loads((checkout / "horizon-native.json").read_bytes()) != manifest:
    raise SystemExit("Tectonic source manifest or mixin directory differs from the lock")

with zipfile.ZipFile(archive_path) as archive:
    expected = set(sources) | {"horizon-native.json"}
    if sorted(archive.namelist()) != sorted(expected):
        raise SystemExit("Unexpected files in Tectonic archive")
    if json.loads(archive.read("horizon-native.json")) != manifest:
        raise SystemExit("Unexpected Tectonic archive manifest")
    for name, data in sources.items():
        if archive.read(name) != data:
            raise SystemExit(f"Archive bytes differ from pinned source: {name}")
    archive.extractall(output)

print(f"Tectonic manifest and {len(sources)} source files match")
