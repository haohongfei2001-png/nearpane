NEARPANE — KEEP THE MUSIC CLOSE
HOLDSNOW first product film / 2026-11-28

CURRENT EDIT: PRODUCT PREVIEW, 34 seconds, Chinese and English.
This is not an assertion that the integrated Nearpane download is available.

The production SwiftUI lyric panel is captured on a cloud Mac. No product UI is
recreated in the compositor. High-resolution native stills use authored data.
Final moving passages require continuous WindowServer recordings of the same
production view, with actual Music playback and OS pointer input. The visible
photography window preserves the 208 x 192 logical layout on a genuine 2x
Retina display (416 x 384 recorded pixels); 4K describes the output canvas, not
a claim of a 4K native UI capture.
The native recording includes the mouse. Editorial camera, fades, wallpaper and
screen placement are postproduction, not new app capabilities.

The earlier state sequences showed no continuous lyric transition and are
excluded from final masters. Later runtime evidence found Reduce Motion enabled
on the cloud Mac, so a product animation defect was not established. The renderer deliberately
refuses final video output without the continuous WindowServer source passages.

Run (Python 3, Pillow, FFmpeg; assets folder from the companion asset package):
  python3 src/render_film.py --lang zh --width 3840 --height 2160
  python3 src/render_film.py --lang en --width 3840 --height 2160
  python3 src/render_film.py --lang zh --width 1080 --height 1920
  python3 src/render_film.py --lang en --width 1080 --height 1920
  python3 src/render_film.py --lang zh --frames
  python3 src/make_covers.py
  python3 src/verify_video.py renders/*.mp4 --output docs/video-verification.json
  python3 src/prepare_audio.py --duration 34 --output /tmp/origami-34s-rerender.wav

Extract the companion Nearpane-Film-Media-Assets.zip into this directory so that
assets/backgrounds, assets/audio, assets/fonts and assets/native exist. Install
requirements.txt and make ffmpeg/ffprobe available in PATH. The four language /
aspect-ratio outputs are rendered independently; portrait is not a center crop.

Native recordings can be conformed with src/ingest_windowserver.py. Supply the
actual recorded crop rectangle and frame rate from their capture manifest. Do
not infer a crop from the original 176pt display panel: the film photography
surface has a distinct, explicitly documented 208pt geometry. Native alpha from
an identical production still retains the real panel shape; no UI is redrawn.

Do not use --draft for a deliverable. It deliberately permits temporary low-res
placeholders and burns a composition-study label into every frame.

Large media are external deliverables, not committed to the application branch.
The native macOS capture workflow and source are in native/ and the repository's
dedicated film-native-capture workflow. The production app source is unchanged.

Music: “Origami” by Scott Buckley, CC BY 4.0. The author requires attribution in
the YouTube description, not only the end frame. Include the accompanying
publishing credits. Do not claim HOLDSNOW composed this track. The screen's
lyrics are original demonstration lyrics, not lyrics to the instrumental score.

The supplied film preview links to https://nearpane.com/ and says Product preview.
An integrated download CTA must wait for the release preset, validation and public installer listed in
docs/release-gaps.json. Do not simply relabel this preview as a launched product.

Both language takes retain original playback speed. Chinese controls start at
14.4 seconds, English controls at 17.0 seconds. After the actual source window
withdraws, an empty desktop can hold editorially. The English source recording
is 12.967 seconds, never represented as a 16-second continuous recording.

Color is explicitly tagged Rec.709 / limited range in H.264 VUI and MP4 colr.
See docs/quality-acceptance.json for review scope, technical measurements and
the unavailable subjective audio listening check.
