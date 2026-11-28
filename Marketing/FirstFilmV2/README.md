# Nearpane — first film, revision 2

This production revises the earlier film after product feedback: a real released
song and its actual album cover, lyrics continuing while the foreground app
changes, an upper-right card layout, and a restrained two-module extension.

## Source boundaries

- `native/`: a separate native filming host and actual macOS screen recording.
  The filming build is not a published Nearpane distribution.
- `src/`: original document content, editorial titles, and a deterministic
  FFmpeg compositor. These scripts do not reconstruct the product interface.
- `assets/workspace/`: small, relevant reusable document and environment assets.
- `licenses/`: source and attribution records for the real song, lyrics, cover,
  fonts, and original environment.
- `config/`: explicit edit intervals. Rendering requires real source footage.
- Large audio/video source media and rendered movies are delivered separately.

## Re-render

Python 3.11+, FFmpeg/ffprobe, Pillow, PyMuPDF and FontTools are required. Restore
the delivered media package beside this file before rendering. Font files stay
in that package with their licenses.

```sh
python3 src/brand_frames.py
python3 src/render_edit.py config/approved-edit.json --out outputs/Nearpane-ZH-4K.mp4 --width 3840 --height 2160 --lang zh
```

The configuration must list actual source in/out points, their provenance,
and a verified audio file. The renderer rejects missing footage, source ranges
longer than the recording, and audio shorter than the edit. It does not invent
missing product states or pad an unrecorded interaction.

## Release status

This remains a product preview. The source currently verifies native player
adaptation and host-managed module ordering, but does not establish a public
integrated Nearpane download, lyrics enabled on first launch, or a completed
network install/remove/re-add lifecycle. The end card therefore links to the
verified official site without asserting that a download is already available.

Detailed capture and final review results are added as they become available;
the existence of this project is not itself a visual-quality certification.
