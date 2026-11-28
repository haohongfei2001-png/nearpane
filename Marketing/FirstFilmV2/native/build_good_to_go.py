#!/usr/bin/env python3
"""Rebuild the licensed Good To Go playback asset for Apple Music.

Download only the reviewed CC BY originals; verify their identity before use.
The source is a released Vorbis recording. ALAC avoids a further lossy encode;
this is not a claim that the downloaded source was a lossless studio master.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ASSETS = {
    'good-to-go.ogg': (
        'https://upload.wikimedia.org/wikipedia/commons/7/71/Josh_Woodward_-_The_Simple_Life%2C_Part_2_-_07_-_Good_To_Go.ogg',
        'b11ff878042e2da9788590bbf71f73e4ed748e67456a393b7d9f5f9e8143cc64'),
    'simple-life-cover.jpg': (
        'https://upload.wikimedia.org/wikipedia/commons/b/ba/Josh_Wooward_-_The_Simple_Life.jpg',
        '1f309a4fb2127300b32495720f9a83cf44484dd12e3d6fc1826e08d0885e7682'),
}

def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=here/'good-to-go.m4a')
    parser.add_argument('--source-dir', type=Path, default=here/'source-assets')
    parser.add_argument('--lyrics', type=Path, default=here/'good-to-go-lyrics.txt')
    a = parser.parse_args()
    a.source_dir.mkdir(parents=True, exist_ok=True)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in ASSETS.items():
        p = a.source_dir/name
        if not p.exists():
            subprocess.run(['curl', '-fLsS', '--retry', '2', '--max-time', '90', url, '-o', str(p)], check=True)
        actual = hashlib.sha256(p.read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f'Source identity mismatch: {name}; expected {expected}, got {actual}')
    lyrics = a.lyrics.read_text(encoding='utf-8').strip()+'\n'
    cmd = [
        'ffmpeg', '-y', '-v', 'error',
        '-i', str(a.source_dir/'good-to-go.ogg'),
        '-i', str(a.source_dir/'simple-life-cover.jpg'),
        '-map', '0:a:0', '-map', '1:v:0',
        '-c:a', 'alac', '-c:v', 'copy', '-disposition:v:0', 'attached_pic',
        '-metadata', 'title=Good To Go',
        '-metadata', 'artist=Josh Woodward',
        '-metadata', 'album_artist=Josh Woodward',
        '-metadata', 'album=The Simple Life',
        '-metadata', 'date=2008', '-metadata', 'track=18',
        '-metadata', 'composer=Josh Woodward',
        '-metadata', 'lyrics='+lyrics,
        '-metadata', 'comment=Recording and song: Josh Woodward, CC BY 3.0 US. Original album artwork: Josh Woodward, CC BY 3.0 US; VRT permission 2013022010009149. www.joshwoodward.com. Converted from the licensed original OGG without speed/pitch change; see accompanying provenance.',
        str(a.output),
    ]
    subprocess.run(cmd, check=True)
    print(json.dumps({'output': str(a.output), 'sha256': hashlib.sha256(a.output.read_bytes()).hexdigest(),
                      'excerpt_source_seconds': [147.60, 183.60],
                      'lrc_clock': 'Absolute full-track seconds; do not reset LRC to excerpt zero.'}, indent=2))

if __name__ == '__main__':
    main()
