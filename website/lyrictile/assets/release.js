(() => {
  'use strict';
  const script = document.currentScript;
  if (!script) return;
  const manifest = new URL('../release.json', script.src);
  const english = document.documentElement.lang === 'en';
  const https = value => {
    try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password; }
    catch { return false; }
  };
  const set = (selector, value) => { const node = document.querySelector(selector); if (node && value) node.textContent = value; };
  fetch(manifest, { cache: 'no-cache', credentials: 'omit' }).then(response => {
    if (!response.ok) throw new Error('Release manifest unavailable');
    return response.json();
  }).then(release => {
    const button = document.querySelector('[data-candidate-link]');
    const support = release.support && release.support[english ? 'en' : 'zh'];
    if (support) set('[data-player-support]', support);
    if (release.published !== true || !https(release.downloadURL) || !https(release.releaseURL) ||
        !/^\d+\.\d+\.\d+$/.test(release.version || '') || !Number.isInteger(release.build) || release.build <= 4 ||
        !/^[a-f0-9]{64}$/.test(release.sha256 || '') || !/^[a-f0-9]{40}$/.test(release.commit || '')) return;
    if (button) { button.href = release.downloadURL; button.textContent = english ? 'Download for Mac' : '下载 Mac 版'; }
    set('[data-release-state]', `${release.version} (${release.build})`);
    set('[data-release-summary]', english ? 'The signed and notarized installer is ready. Download LyricTile and start a song in a supported player.' : '已签名并公证的正式安装包已就绪。安装 LyricTile，在支持的播放器中开始一首歌。');
    set('[data-download-meta]', english ? 'Apple silicon · macOS 27 or later' : 'Apple silicon · macOS 27 或更新');
    set('[data-download-hash]', `SHA-256 ${release.sha256}`);
    const details = document.querySelector('[data-downloads]'); if (details) details.hidden = false;
    const notes = document.querySelector('[data-release-link]'); if (notes) notes.href = release.releaseURL;
    const candidateNote = document.querySelector('[data-candidate-note]'); if (candidateNote) candidateNote.hidden = true;
  }).catch(() => { /* Keep the verified static page links when the manifest is unavailable. */ });
})();
