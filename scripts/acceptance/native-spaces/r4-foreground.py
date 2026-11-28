"""Compare the interiors of fixed R4 sidebar strokes across two installed material settings."""
import argparse
import json
from pathlib import Path
from statistics import median

from PIL import Image


PATCHES = {
    'play': (181, 21, 19, 23),
    'camera': (51, 86, 31, 29),
    'folder': (157, 86, 30, 28),
    'permissionText': (18, 154, 133, 19),
}


def compare(baseline, preview, dark=False):
    def read(directory):
        trace = json.loads((directory / 'capture.json').read_bytes())
        row = next(item for item in trace['samples'] if item['file'] == 'blue.png')
        return row, Image.open(directory / 'blue.png').convert('RGB')

    first, original = read(baseline)
    second, alternate = read(preview)
    geometry = ('leftInCrop', 'topInCrop', 'panelPoints', 'pixels', 'scale', 'wallpaper')
    if any(first[name] != second[name] for name in geometry) or first['panelPoints'][0] != 240:
        raise ValueError('The material samples must show the same default-width panel on the same wallpaper')
    scale, left, top = (first[key] for key in ('scale', 'leftInCrop', 'topInCrop'))
    result = {}
    for name, (x, y, width, height) in PATCHES.items():
        box = tuple(round(v * scale) for v in (left+x, top+y, left+x+width, top+y+height))
        reference = list(original.crop(box).getdata())
        changed = list(alternate.crop(box).getdata())
        # Only rank the baseline. Low/high luminance selects stroke interiors and keeps antialias edges out.
        indices = sorted(range(len(reference)), key=lambda i: sum(reference[i]), reverse=dark)
        interiors = indices[:max(1, len(indices)//50)]
        errors = sorted(max(abs(a-b) for a, b in zip(reference[i], changed[i])) for i in interiors)
        result[name] = {'pixels': len(interiors), 'medianMaxChannelDelta': median(errors),
                        'p95MaxChannelDelta': errors[round(.95*(len(errors)-1))], 'sampleRectPixels': box}
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('baseline', type=Path)
    p.add_argument('preview', type=Path)
    p.add_argument('--dark', action='store_true')
    args = p.parse_args()
    print(json.dumps(compare(args.baseline, args.preview, args.dark), indent=2))
