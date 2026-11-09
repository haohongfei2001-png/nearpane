# Nearpane official website

The static website lives under `website/` and is independent of the native macOS app.

**Design baseline:** The user selected the earlier R2 website hero, "整个桌面。一侧掌握。", as the approved visual reference. This is a **reconstruction from the approved R2 screenshots**, not the exact original Sites source archive. Keep this distinction when editing.

**Hosting:** GitHub Pages, published by `.github/workflows/publish-nearpane-website.yml` from `main`. No Vercel, backend, framework, database, or paid build service is necessary.

**Custom domain:** `nearpane.com`, configured in the GitHub Pages repository settings. DNS remains with DNSPod. The repository's GitHub Actions Pages configuration is the publishing source; a `CNAME` file alone is not the domain binding.

**Local preview:** `cd website && python3 -m http.server 4173`, then open `http://localhost:4173`.

Only the website's demonstration state is changed in the browser. It does not control real macOS Spaces, record live microphone audio, or send actual screenshots.

Updates to the macOS project in `Sources/` and `Tests/` should not trigger a website deployment.
