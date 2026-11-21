"""Record the installed Space title using independently admitted, product-only WindowServer frames."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

from acceptance import APP, encode, identity


def record(kit, output):
    output.mkdir(parents=True, exist_ok=False)
    host_hash = identity(APP / 'Contents/MacOS/NearpaneHost')['CDHash']
    receipt = {'method': 'WindowServer product-only crop before acquisition, individually verified frames, variable time base',
               'field': 'installed current Space title', 'hostCDHash': host_hash, 'samples': [], 'status': 'NOT_RUN'}
    def save():
        (output/'recording.json').write_text(encode(receipt))
    with tempfile.TemporaryDirectory(prefix='nearpane-title-film-') as scratch:
        frames = []
        folder = Path(scratch)
        start = time.monotonic()
        for index in range(16):
            time.sleep(max(0, start + index * .32 - time.monotonic()))
            image = folder/f'{index}.png'
            captured = subprocess.run([kit/'capture', kit/'observe', host_hash, image], capture_output=True, text=True, timeout=8)
            timepoint = time.monotonic() - start
            state = json.loads(captured.stdout) if captured.stdout else {}
            ready = bool(state.get('ready') and image.is_file())
            receipt['samples'].append({'index':index, 'time':timepoint, 'captured':ready,
                                       'sha256':hashlib.sha256(image.read_bytes()).hexdigest() if ready else None})
            save()
            if not ready:
                receipt.update(status='BLOCKED',reason='Installed title crop lost its independent geometry during recording');save();return
            frames.append((image, timepoint))
        manifest = folder/'timing.json'
        manifest.write_text(encode([{'file':image.as_uri(),'time':timestamp-frames[0][1]} for image,timestamp in frames]))
        movie = output/'installed-space-title.mp4'
        encoder=folder/'encoder'
        subprocess.run(['xcrun','swiftc','-parse-as-library',Path(__file__).with_name('title-movie.swift'),'-o',encoder],check=True)
        result=json.loads(subprocess.check_output([encoder,manifest,movie],timeout=35))
        receipt.update(status='CAPTURED',tracks=result,sha256=hashlib.sha256(movie.read_bytes()).hexdigest());save()



if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('kit',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();record(args.kit.resolve(), args.output.resolve())
