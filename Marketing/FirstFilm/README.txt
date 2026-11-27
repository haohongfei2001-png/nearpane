NEARPANE — KEEP THE MUSIC CLOSE
HOLDSNOW first product film / 2026-11-28

CURRENT EDIT: PRODUCT PREVIEW, 32 seconds, Chinese and English.
This is not an assertion that the integrated Nearpane download is available.

The production SwiftUI lyric panel is captured on a cloud Mac. No product UI is
recreated in the compositor. High-resolution native stills use authored data.
Final moving passages require continuous WindowServer recordings of the same
production view, with actual Music playback and OS pointer input. The visible
photography window preserves the 208 x 192 logical layout at three times size.
The native recording includes the mouse. Editorial camera, fades, wallpaper and
screen placement are postproduction, not new app capabilities.

The earlier cacheDisplay frame sequences did not capture SwiftUI presentation
animation. They are excluded from final masters. The renderer deliberately
refuses final video output without the continuous WindowServer source passages.

Run (Python 3, Pillow, FFmpeg; assets folder from the companion asset package):
  python3 src/render_film.py --lang zh --width 3840 --height 2160
  python3 src/render_film.py --lang en --width 3840 --height 2160
  python3 src/render_film.py --lang zh --width 1080 --height 1920
  python3 src/render_film.py --lang en --width 1080 --height 1920
  python3 src/render_film.py --lang zh --frames
  python3 src/make_covers.py
  python3 src/verify_video.py renders/*.mp4 --output docs/video-verification.json

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
An integrated download CTA must wait for the product integration listed in
docs/release-gaps.json. Do not simply relabel this preview as a launched product.
