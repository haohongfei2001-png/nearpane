# LyricTile product page

Bilingual, buildless static product pages for the existing HOLDSNOW / Nearpane website. Intended public mount: `https://nearpane.com/lyrictile/`; English: `/lyrictile/en/`.

The main branch's `website/README.md` and `.github/workflows/publish-nearpane-website.yml` identify GitHub Pages as the actual production host. Copy this directory's contents to `website/lyrictile/` on `main`; the existing Pages workflow publishes the whole `website` directory. No new Site, domain, account, framework, or paid hosting is needed. Do not replace the parent homepage or its approved design.

The layout follows the existing brand's pale desktop colors, system typography, restrained coral accent, and native product imagery. Screenshots come from the native implementation; `assets/SCREENSHOTS.json` identifies their exact source and fixture status. The current five captures are copied unchanged from CI49 (source `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`); the English page uses the actual English lyric fixtures. The manifest records SHA-256 for every file. When replacing captures, use one exact source snapshot and update this manifest. Never relabel authored test input as a real streaming-player session.

## Release state

`release.json` is the downloadable-release manifest. The script changes the download link only when `published` is true and complete valid version/build/commit/HTTPS URL/checksum fields are present. Each static HTML snapshot must retain its own verified status and matching URL: a candidate link before initial publication, or the last verified consumer release after publication. Failed, malformed or unpublished manifests leave those static links unchanged. There is no stale build 4 download fallback.

After publishing and verifying each Release, fill the manifest from that exact notarized DMG and update both language pages together: version, download URL, release URL, SHA-256, signing status and verified player support. This keeps the same usable download when JavaScript or the manifest request fails. Do not use repository-wide `/releases/latest` because this repository also publishes Nearpane. Keep the full commit and SHA-256 in the manifest.

## Verification

Run `python3 ../Scripts/verify-website.py .` from this directory, or `python3 Scripts/verify-website.py Website` from the product root. The check validates relative assets/links, bilingual pages, screenshot provenance, and safe download state. Browser rendering and click checks are separate evidence.
