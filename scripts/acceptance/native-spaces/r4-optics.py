"""Measure wallpaper transmission in a default-width installed rail with a paused voice card."""
import argparse
import json
from pathlib import Path
from statistics import median

from PIL import Image


def measure(directory):
    capture = json.loads((directory / "capture.json").read_text())
    sample = next(row for row in capture["samples"] if row["file"] == "blue.png")
    width, height = sample["panelPoints"]
    if width != 240 or height < 400:
        raise ValueError("Calibration needs a 240 pt installed sidebar")
    ratio, left, top = sample["scale"], sample["leftInCrop"], sample["topInCrop"]
    names = ["blue.png", "yellow.png", "blue-background.png", "yellow-background.png"]
    images = [Image.open(directory / name).convert("RGB") for name in names]
    if len({im.size for im in images}) != 1:
        raise ValueError("Capture dimensions changed")
    patches = {"shell": (35, height - 62, 130, 24), "voiceCard": (47, 21, 54, 14), "trayCard": (45, 79, 22, 8)}
    result = {}
    for label, (x, y, w, h) in patches.items():
        box = tuple(round(ratio * v) for v in (left+x, top+y, left+x+w, top+y+h))
        regions = [im.crop(box).tobytes() for im in images]
        slopes = [(a-b)/(c-d) for a,b,c,d in zip(*regions) if abs(c-d) > 38]
        if len(slopes) < 100:
            raise ValueError("Insufficient wallpaper variation for " + label)
        result[label] = {"effectiveCoverage": round(1 - median(slopes), 3), "validChannels": len(slopes), "sampleRectPixels": box}
    return {"method": "1 minus median sRGB channel response of installed panel to blue/yellow wallpapers. Background channel difference > 38/255.",
            "patches": result, "wallpapers": ["Mac Blue.heic", "Mac Yellow.heic"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    print(json.dumps(measure(parser.parse_args().directory), ensure_ascii=False, indent=2))
