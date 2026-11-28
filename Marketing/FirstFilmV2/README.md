# Nearpane — Keep the music close

The 39-second first-film revision uses a real released song, its actual album
cover, actual macOS application footage, and a real foreground-window change.
The lyric card stays at the upper-right edge. The final section demonstrates
two native cards, actual ordering and an actual screenshot acquired by Riftlet.

## Delivered picture

- Chinese and English editorial versions, 3840×2160 / 30 fps.
- Chinese and English 1080×1920 / 30 fps editions with separate compositions.
- 1920×1080 viewing copies, an 8-second native interaction sample, six final
  keyframes, and Chinese/English landscape/mobile covers.
- H.264, BT.709 limited range, AAC stereo 48 kHz; no optical-flow UI generation.

English editions translate editorial copy and the brand ending. Native captured
application labels and the reading document retain their actual language.
The project is a product preview, not an announcement of a public installer.

## Edit and evidence

| Film time | Actual material |
| --- | --- |
| 0–17.47 s | One continuous Music → Preview reading → native hover recording |
| 17.47–23 s | A second real client: QQ Music playing the same recording |
| 23–31.37 s | Same-time native enabled rows and two native cards; actual reorder |
| 31.37–32 s | Clean original desktop with the two cards after ordering |
| 32–34.5 s | Actual screenshot selection, with all lyric/player UI outside the crop |
| 34.5–36 s | Real acquired image and actual Riftlet thumbnail; end fade from 35.4 s |
| 36–39 s | Nearpane brand, verified website and explicit preview invitation |

Each visible lyric scene is matched to the original performance through recorded
system audio. The final four seconds of Riftlet detail use the same song as
score while excluding lyric/player UI. Native VFR recordings are conformed to
30 fps at their original speed. Cumulative cut points are quantized to frames;
the renderer clamps the resulting frame counts so a long final VFR packet
cannot push later scenes out of time. This is frame-rate conformance, not an
interpolated or recreated interface animation.

The management and result compositions are editorial crops of actual pixels.
They are not uncropped desktop screenshots. The two enabled management rows
are isolated to avoid promoting unfinished modules. The screenshot captures
the owned coastal wallpaper, not the reading PDF.

## Re-render

Python 3.11+, FFmpeg/ffprobe, Pillow, PyMuPDF and FontTools are required. The full
production ZIP includes source media, fonts and licenses beside this README.
The Git branch retains source code, configs and evidence; large assets stay in
the media package. Run commands from this directory.

```sh
python3 -m pip install -r requirements.txt
python3 src/prepare_native_layouts.py
python3 src/render_edit.py config/approved-edit.json --out outputs/Nearpane-ZH-4K.mp4 --width 3840 --height 2160 --lang zh
python3 src/render_edit.py config/approved-edit.json --out outputs/Nearpane-EN-4K.mp4 --width 3840 --height 2160 --lang en
python3 src/render_portrait.py config/approved-edit.json --out outputs/Nearpane-ZH-Vertical.mp4 --lang zh
python3 src/render_portrait.py config/approved-edit.json --out outputs/Nearpane-EN-Vertical.mp4 --lang en
python3 src/export_keyframes.py outputs/Nearpane-ZH-4K.mp4 --out outputs/keyframes
```

Use `--width 1920 --height 1080` for landscape viewing copies. The prepared
39-second soundtrack is included. To rebuild it from the licensed original,
preserving performance timing:

```sh
python3 src/prepare_audio.py assets/music-source/candidates/good-to-go.ogg --out assets/audio/good-to-go-master39.wav --start 147.6 --duration 39 --fade-in 0.005 --fade-out 2.4
```

Native scenes are first cached losslessly. Landscape captions and the short final
transition are then finished one scene at a time, and the encoded scenes are
joined without another picture encode. This bounds 4K rendering memory and
keeps each cut at its checked frame count.

`src/verify_video.py` checks actual outputs, including full decode, frame count,
color metadata and measured sound. Consult the final review records for visual
acceptance and its limits. Numerical audio checks are not subjective listening.

## Source organization

- `native/` and `host-capture/`: real macOS filming hosts/automation; not a
  downloadable release of Nearpane.
- `src/`, `config/`: reusable render code, typography, exact edit intervals.
- `assets/native/`: accepted core, QQ and Host recordings and capture receipts.
- `assets/processed/`: reproducible same-frame editorial intermediates.
- `assets/music-source/`, `assets/audio/`: original recording, canonical local
  LRC, real cover, source evidence and prepared audio.
- `assets/environment/`, `assets/workspace/`: original background and reading
  props. No generated product UI is used.
- `docs/`, `licenses/`: review records, product limits, brand system and credits.

## Release and rights

The current source does not establish lyrics enabled on a new installation,
an actual optional-module download/remove/re-add lifecycle, or a public
integrated Nearpane installer. The ending therefore uses `nearpane.com` and
“Product preview”. See `docs/RELEASE-GAPS.md` for the minimal remaining tasks.

The selected song's canonical lyrics were imported through the real local LRC
path. This footage does not certify an automatic online match for this song.
The two-player edit does not claim gapless automatic client handoff. Card
reordering uses the actual management view. Matched Riftlet exterior material
and geometry are the specifically authorized filming adaptation.

Music/lyrics and The Simple Life artwork are by Josh Woodward under CC BY 3.0 US.
Include the complete relevant attribution from `licenses/PUBLISHING_CREDITS.txt`
with every public posting. No artist or platform endorsement is implied.
