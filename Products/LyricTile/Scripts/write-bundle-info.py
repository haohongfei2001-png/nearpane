#!/usr/bin/env python3
"""Create truthful candidate metadata. Release feed keys are supplied by the owner."""
import argparse
import base64
import os
import plistlib
from urllib.parse import urlparse

p = argparse.ArgumentParser()
p.add_argument("output")
p.add_argument("--version", default="1.0.0")
p.add_argument("--build", default="1")
p.add_argument("--commit", required=True)
args = p.parse_args()
feed = os.environ.get("LYRICTILE_UPDATE_FEED", "")
key = os.environ.get("LYRICTILE_UPDATE_PUBLIC_KEY", "")
if not (feed or key) and os.environ.get("LYRICTILE_SIGN_IDENTITY", "-") != "-":
    feed = ("https://raw.githubusercontent.com/haohongfei2001-png/nearpane/"
            "refs/heads/codex/lyrictile-standalone-20261126/Products/LyricTile/Updates/appcast.xml")
    key = "NjwCt0hsJ9Ps97gwa1ZQvHfaVkr69TN0JIjNi7E522w="
if bool(feed) != bool(key):
    p.error("Update feed and Ed25519 public key must be configured together.")
if feed:
    parsed = urlparse(feed)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        p.error("Update feed must be an HTTPS URL without credentials.")
    try:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError("key length")
    except Exception:
        p.error("Sparkle public key must be a base64-encoded 32-byte Ed25519 key.")
info = {
    "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans"], "CFBundleExecutable": "LyricTile",
    "CFBundleIdentifier": "com.holdsnow.lyrictile", "CFBundleName": "LyricTile",
    "CFBundleDisplayName": "LyricTile", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": args.version, "CFBundleVersion": args.build,
    "CFBundleIconFile": "LyricTile", "LSMinimumSystemVersion": "27.0",
    "LSApplicationCategoryType": "public.app-category.music", "LSUIElement": True,
    "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
    "NSAppleEventsUsageDescription": "LyricTile reads the current song and playback position from your chosen music player, and controls playback only when you use its controls.",
    "NSHumanReadableCopyright": "© 2026 HOLDSNOW",
    "LyricTileBuildCommit": args.commit, "LyricTileDistributionChannel": "candidate",
    "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
}
if feed:
    info.update(SUFeedURL=feed, SUPublicEDKey=key, SUVerifyUpdateBeforeExtraction=True)
with open(args.output, "wb") as f:
    plistlib.dump(info, f, sort_keys=True)
