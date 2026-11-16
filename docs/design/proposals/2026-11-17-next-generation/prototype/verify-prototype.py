"""Reproduce HTML design checks. Requires Playwright and a permitted Chromium runtime.
This verifies the browser prototype only; no native platform capability is tested.
"""
from pathlib import Path
from playwright.sync_api import sync_playwright
import json
import os

ROOT = Path(__file__).resolve().parent
ART = ROOT / 'assets'
ART.mkdir(exist_ok=True)
URL = (ROOT / 'index.html').as_uri()
checks = []

def check(name, condition):
    checks.append({'check': name, 'pass': bool(condition)})
    if not condition:
        raise AssertionError(name)

with sync_playwright() as p:
    options = {'headless': True}
    if os.environ.get('NEARPANE_CHROMIUM'):
        options['executable_path'] = os.environ['NEARPANE_CHROMIUM']
    browser = p.chromium.launch(**options)
    page = browser.new_page(viewport={'width': 1680, 'height': 1300}, device_scale_factor=1)
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.goto(URL)
    page.wait_for_timeout(200)
    check('default has voice, screenshot and Spaces; no workspace', page.locator('#voice-module').is_visible() and page.locator('#shelf-module').is_visible() and page.locator('#spaces-region').is_visible() and not page.locator('#workspace-module').is_visible())
    check('default sidebar width is 1/8 of simulated screen', abs(page.evaluate("document.querySelector('#nearpane').offsetWidth/window.NearpanePrototype.state.width") - .125) < .001)
    page.screenshot(path=str(ART / '01-desktop.png'), full_page=True)
    page.locator('[data-scene="custom"]').click()
    page.locator('#memo-input').fill('这段便笺需要保持独立。')
    page.locator('[data-page="calc"]').click()
    page.locator('#calc-input').fill('(248 + 136) × 0.85')
    page.locator('#calc-input').press('=')
    check('calculation produces the expected result', page.locator('.result-number').inner_text() == '326.4')
    page.locator('#cancel-result').click()
    check('cancelling result preserves expression', page.locator('#calc-input').input_value() == '(248 + 136) × 0.85' and page.locator('.calc-result').count() == 0)
    page.locator('#calc-input').press('=')
    page.locator('#keep-calc').click()
    check('calculation has independent history', page.locator('[data-history]').count() == 1)
    page.locator('#continue-calc').click()
    check('continuous calculation starts from prior result', page.locator('#calc-input').input_value() == '326.4 + ')
    page.locator('[data-page="memo"]').click()
    check('memo content survives switching', page.locator('#memo-input').input_value() == '这段便笺需要保持独立。')
    y_before = page.locator('#spaces-region').bounding_box()['y']
    page.locator('#append-voice').click()
    check('voice append leaves Spaces boundary unchanged', abs(page.locator('#spaces-region').bounding_box()['y'] - y_before) < .1)
    page.locator('#simulate-file').click()
    count_before = page.evaluate('NearpanePrototype.state.files.length')
    shots_before = page.evaluate('NearpanePrototype.state.shots')
    page.locator('#advance-time').click()
    check('file expiry preserves all historical records', page.evaluate('NearpanePrototype.state.files.length') == count_before)
    check('file expiry does not clear screenshots', page.evaluate('NearpanePrototype.state.shots') == shots_before)
    page.locator('#library-open').click()
    check('expired file remains in history', page.locator('[data-reopen]').count() == count_before)
    page.locator('[data-reopen]').first.click()
    check('history item can reappear in tray', page.locator('.file-row').count() >= 1)
    page.locator('#simulate-copy').click()
    page.locator('#insert-clip').click()
    check('valid target receives demo clipboard', page.locator('#target-editor').inner_text() == '让表达先发生，选择稍后再做。')
    page.locator('#invalidate-target').click()
    page.locator('#simulate-copy').click()
    unchanged = page.locator('#target-editor').inner_text()
    page.locator('#insert-clip').click()
    check('invalid target never receives insertion', page.locator('#target-editor').inner_text() == unchanged and page.locator('#copy-fallback').is_visible())
    page.locator('[data-scene="custom"]').click()
    page.locator('#zoom-toggle').click()
    page.locator('[data-page="calc"]').click()
    page.locator('#calc-input').fill('(248 + 136) × 0.85')
    page.locator('#calc-input').press('=')
    page.screenshot(path=str(ART / '02-workspace-calculation.png'), full_page=True)
    page.locator('#simulate-file').click()
    page.locator('#advance-time').click()
    page.locator('#library-open').click()
    page.screenshot(path=str(ART / '03-file-history.png'), full_page=True)
    page.locator('[data-close="library-overlay"]').click()
    page.locator('#zoom-toggle').click()
    page.locator('[data-scene="dense"]').click()
    page.locator('#screen-size').select_option('1280x800')
    check('small screen remains exactly 1/8', page.evaluate("document.querySelector('#nearpane').offsetWidth") == 160)
    check('dense Spaces independently scroll', page.evaluate("document.querySelector('#spaces-list').scrollHeight>document.querySelector('#spaces-list').clientHeight"))
    page.locator('#theme-toggle').click()
    page.screenshot(path=str(ART / '04-dense-dark.png'), full_page=True)
    page.locator('[data-scene="restricted"]').click()
    page.locator('#theme-toggle').click()
    page.locator('#zoom-toggle').click()
    page.screenshot(path=str(ART / '05-permission-restricted.png'), full_page=True)
    page.locator('[data-scene="notes"]').click()
    check('notes work with all other modules disabled', page.locator('#workspace-module').is_visible() and not page.locator('#voice-module').is_visible() and not page.locator('#shelf-module').is_visible() and not page.locator('#spaces-region').is_visible())
    page.locator('#screen-size').select_option('1920x1080')
    check('large screen remains exactly 1/8', page.evaluate("document.querySelector('#nearpane').offsetWidth") == 240)
    check('no JavaScript page errors', not errors)
    browser.close()

(ROOT / 'prototype-checks.json').write_text(json.dumps({'scope':'HTML prototype only; not native verification','checks':checks,'errors':errors}, ensure_ascii=False, indent=2))
print(json.dumps({'passed':len(checks),'checks':checks}, ensure_ascii=False, indent=2))
