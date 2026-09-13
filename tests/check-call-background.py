#!/usr/bin/env python3
"""Check the source or a built Watch app's CallKit background-mode declaration."""
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "Configuration/Watch-Info.plist"
if path.is_dir():
    path /= "Info.plist"
info = plistlib.loads(path.read_bytes())
modes = info.get("UIBackgroundModes", [])
assert isinstance(modes, list) and {"audio", "voip"}.issubset(modes), (
    "Watch CallKit requires UIBackgroundModes containing audio and voip"
)
assert "audio" not in info.get("WKBackgroundModes", []), "audio belongs in UIBackgroundModes"
assert "voip" not in info.get("WKBackgroundModes", []), "voip belongs in UIBackgroundModes"
print(f"PASS: CallKit Audio/VoIP background modes in {path}")
