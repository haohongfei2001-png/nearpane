#!/usr/bin/env python3
"""Validate shipped page links and the truthful release/download manifest."""
import argparse
import json
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = []
        self.ids = set()
        self.language = None
        self.images_without_alt = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'html': self.language = attrs.get('lang')
        if 'id' in attrs: self.ids.add(attrs['id'])
        if tag == 'img' and 'alt' not in attrs: self.images_without_alt.append(attrs.get('src'))
        for key in ('href', 'src'):
            if key in attrs: self.refs.append(attrs[key])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    root = args.directory.resolve()
    failures = []
    pages = {}
    for path in root.rglob('*.html'):
        page = Page(); page.feed(path.read_text()); pages[path] = page
        if page.language not in ('zh-CN', 'en'): failures.append(f'{path.name}: missing supported language')
        if page.images_without_alt: failures.append(f'{path.name}: image missing alt')
    for relative in ('index.html', 'help.html', 'privacy.html', 'en/index.html', 'en/help.html', 'en/privacy.html'):
        if root / relative not in pages: failures.append('missing page: ' + relative)
    for path, page in pages.items():
        for ref in page.refs:
            url = urlparse(ref)
            if url.scheme or url.netloc: continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if target.is_dir(): target /= 'index.html'
            if not target.is_relative_to(root): failures.append(f'{path.name}: escapes site root {ref}')
            elif not target.is_file(): failures.append(f'{path.name}: missing {ref}')
            elif url.fragment and target in pages and url.fragment not in pages[target].ids:
                failures.append(f'{path.name}: missing anchor {ref}')
    release = json.loads((root / 'release.json').read_text())
    screenshots = json.loads((root / 'assets/SCREENSHOTS.json').read_text())
    if not re.fullmatch(r'[a-f0-9]{40}', screenshots.get('sourceCommit', '')): failures.append('screenshot source commit missing')
    for name in screenshots.get('files', {}):
        if not (root / 'assets' / name).is_file(): failures.append('screenshot missing: ' + name)
    if release.get('published'):
        for key in ('downloadURL', 'releaseURL'):
            url = urlparse(release.get(key) or '')
            if url.scheme != 'https' or not url.hostname or url.username or url.password: failures.append('unsafe release field: ' + key)
            if '/releases/latest' in url.path: failures.append('mixed-product latest endpoint is not a release pin')
        if not isinstance(release.get('build'), int) or release['build'] <= 4: failures.append('final build must supersede build 4')
        if not re.fullmatch(r'\d+\.\d+\.\d+', release.get('version') or ''): failures.append('version missing')
        for key, length in (('sha256', 64), ('commit', 40)):
            if not re.fullmatch('[a-f0-9]{%d}' % length, release.get(key) or ''): failures.append('invalid ' + key)
    elif any(release.get(k) for k in ('downloadURL', 'releaseURL', 'sha256')):
        failures.append('unpublished candidate must not contain a stale final download')
    report = {'status': 'FAIL' if failures else 'PASS', 'htmlPages': len(pages),
              'releasePublished': release.get('published') is True,
              'screenshotSourceCommit': screenshots.get('sourceCommit'), 'failures': failures,
              'browserRendering': 'NOT_ASSESSED', 'publicDeployment': 'NOT_ASSESSED'}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
