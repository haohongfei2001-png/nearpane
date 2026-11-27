# LyricTile product page

Bilingual, buildless static product pages for the existing HOLDSNOW / Nearpane website. Intended public mount: `https://nearpane.com/lyrictile/`; English: `/lyrictile/en/`.

The main branch's `website/README.md` and `.github/workflows/publish-nearpane-website.yml` identify GitHub Pages as the actual production host. Copy this directory's contents to `website/lyrictile/` on `main`; the existing Pages workflow publishes the whole `website` directory. No new Site, domain, account, framework, or paid hosting is needed. Do not replace the parent homepage or its approved design.

The layout follows the existing brand's pale desktop colors, system typography, restrained coral accent, and native product imagery. Screenshots come from the native implementation; `assets/SCREENSHOTS.json` identifies their exact source and fixture status. Replace with the corresponding latest native captures after CI and update this manifest. Never relabel authored test input as a real streaming-player session.

## Release state

`release.json` is the single downloadable-release manifest. Until `published` is true and complete valid version/build/commit/HTTPS URL/checksum fields are present, both languages retain a candidate status and link to the relevant GitHub Actions workflow. The static HTML also retains that honest state if JavaScript or the request fails. There is no stale build 4 download fallback.

After publishing and verifying the final Release, fill the manifest from that exact notarized DMG and update the verified player support text. Do not use repository-wide `/releases/latest` because this repository also publishes Nearpane. Keep the full commit and SHA-256 in the manifest.

## Verification

Run `python3 ../Scripts/verify-website.py .` from this directory, or `python3 Scripts/verify-website.py Website` from the product root. The check validates relative assets/links, bilingual pages, screenshot provenance, and safe download state. Browser rendering and click checks are separate evidence.
