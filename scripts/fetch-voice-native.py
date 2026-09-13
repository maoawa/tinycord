#!/usr/bin/env python3
"""Fetch immutable upstream source versions; no credentials or system installs."""
from pathlib import Path
from urllib.request import urlopen
import io
import tarfile
import sys

if sys.version_info < (3, 12):
    raise SystemExit("Voice dependency downloads require Python 3.12 or newer.")

ROOT = Path(__file__).resolve().parents[1] / "VoiceNative" / "sources"
VERSIONS = {
    "libdave": ("discord/libdave", "5cb8952a8e6f08071d8c24edae2496199d7a9197"),
    "mlspp": ("cisco/mlspp", "1cc50a124a3bc4e143a787ec934280dc70c1034d"),
    "boringssl": ("google/boringssl", "58f3bc83230d2958bb9710bc910972c4f5d382dc"),
    "json": ("nlohmann/json", "9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03"),
    "opus": ("xiph/opus", "ddbe48383984d56acd9e1ab6a090c54ca6b735a6"),
}
for name, (repo, revision) in VERSIONS.items():
    destination = ROOT / name
    stamp = destination / ".tinycord-version"
    if stamp.exists() and stamp.read_text() == revision:
        continue
    if destination.exists():
        raise SystemExit(f"Incomplete or different source version at {destination}; move it aside and retry.")
    print(f"Fetching {repo} at {revision}", flush=True)
    payload = urlopen(f"https://codeload.github.com/{repo}/tar.gz/{revision}", timeout=120).read()
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
        for member in archive.getmembers():
            parts = member.name.split("/", 1)
            if len(parts) != 2 or not parts[1]:
                continue
            member.name = parts[1]
            archive.extract(member, destination, filter="data")
    stamp.write_text(revision)
