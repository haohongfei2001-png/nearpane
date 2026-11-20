#!/usr/bin/env python3
"""Build the R4 review book from the deterministic PNG exports.

All visible text uses the same Noto Sans CJK SC rendering as the design boards.
ReportLab only assembles images, metadata, page bookmarks and clickable sources;
it does not substitute a CJK serif font. Run after render_reference.py and
render_svg.cjs. Optional --output is useful for an isolated preliminary book.
"""
from __future__ import annotations

import argparse
import base64
import html
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / 'assets'
TMP = ROOT / 'tmp' / 'pdf'
FONT = 'Noto Sans CJK SC, sans-serif'
PAPER = '#F5F5F3'
INK = '#29343B'
MUTED = '#73808A'
TOKENS = json.loads((ROOT / 'design-tokens.json').read_text())
GITHUB = 'https://github.com/haohongfei2001-png/nearpane'
SOURCE_SHA = TOKENS['sourceCommit']
SOURCE_PATH = 'design/assets/2026-11-15-v2/interface-reference-original.png'


def esc(value):
    return html.escape(str(value), quote=True)


def num(value):
    return f'{value:g}'


def default_width(display_width):
    t = TOKENS['width']
    return round(min(display_width * t['manualFractionRange'][1],
                     max(display_width * t['manualFractionRange'][0],
                         min(t['normalCeiling'], max(t['normalFloor'],
                             display_width * t['commonScreenDefaultRatio'])))))


def text(x, y, value, size=14, color=INK, weight=400, extra=''):
    return (f'<text x="{num(x)}" y="{num(y)}" font-family="{FONT}" '
            f'font-size="{num(size)}" font-weight="{weight}" fill="{color}" '
            f'{extra}>{esc(value)}</text>')


def rectangle(x, y, width, height, fill, radius=0):
    return (f'<rect x="{num(x)}" y="{num(y)}" width="{num(width)}" '
            f'height="{num(height)}" rx="{num(radius)}" fill="{fill}"/>')


def rule(x1, y, x2, color='#D8DEE1'):
    return f'<path d="M{x1} {y}H{x2}" fill="none" stroke="{color}" stroke-width="0.7"/>'


def wrapped(x, y, value, width, size=14, leading=24, color=MUTED, weight=400):
    """Conservative CJK wrapping for short authored notes, with hanging punctuation."""
    result = []
    yy = y
    closing = set('，。！？；：、）》】」』％%…')
    for paragraph in value.split('\n'):
        line = ''
        used = 0
        for ch in paragraph:
            advance = size * (0.56 if ord(ch) < 128 else 1)
            if line and used + advance > width:
                if ch in closing:
                    carry = line[-1]
                    line = line[:-1]
                    result.append(text(x, yy, line, size, color, weight))
                    yy += leading
                    line = carry + ch
                    used = size * (0.56 if ord(carry) < 128 else 1) + advance
                else:
                    result.append(text(x, yy, line, size, color, weight))
                    yy += leading
                    line = ch
                    used = advance
            else:
                line += ch
                used += advance
        result.append(text(x, yy, line, size, color, weight))
        yy += leading
    return ''.join(result)


def embedded_image(path, x, y, width, height):
    with Image.open(path) as im:
        iw, ih = im.size
    scale = min(width / iw, height / ih)
    ww, hh = iw * scale, ih * scale
    xx, yy = x + (width - ww) / 2, y + (height - hh) / 2
    data = base64.b64encode(path.read_bytes()).decode('ascii')
    mime = 'image/png' if path.suffix.lower() == '.png' else 'image/jpeg'
    return (f'<image x="{xx:g}" y="{yy:g}" width="{ww:g}" height="{hh:g}" '
            f'href="data:{mime};base64,{data}"/>')


def write_svg(name, width, height, parts):
    path = TMP / f'{name}.svg'
    content = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:g}" height="{height:g}" '
               f'viewBox="0 0 {width:g} {height:g}"><title>Nearpane R4 design reference</title>'
               f'{rectangle(0, 0, width, height, PAPER)}{"".join(parts)}</svg>')
    path.write_text(content)
    return path


def find_original():
    candidates = []
    if os.environ.get('NEARPANE_ORIGINAL_REFERENCE'):
        candidates.append(Path(os.environ['NEARPANE_ORIGINAL_REFERENCE']))
    candidates.extend(ancestor / SOURCE_PATH for ancestor in ROOT.parents)
    found = next((p for p in candidates if p.is_file()), None)
    if found is None:
        raise FileNotFoundError('Original reference is required for the complete 18-page book. '
                                'Set NEARPANE_ORIGINAL_REFERENCE to its PNG path.')
    return found


def logical_size(name):
    element = ET.parse(ASSETS / f'{name}.svg').getroot()
    values = [float(v) for v in element.attrib['viewBox'].replace(',', ' ').split()]
    width, height = values[2:]
    with Image.open(ASSETS / f'{name}.png') as im:
        actual = im.size
    scale = TOKENS['layout']['referenceScale']
    expected = (round(width * scale), round(height * scale))
    if actual != expected:
        raise ValueError(f'{name}: PNG size {actual} does not match {scale}x SVG {expected}')
    return width, height


def desktop_page(name, title, detail):
    width, height = logical_size(name)
    panel = default_width(width)
    parts = [text(36, 36, 'NEARPANE / R4 / DESIGNED', 10, MUTED, 500,
                  'letter-spacing="1.8"'),
             text(36, 75, title, 28, INK, 550),
             text(36, 105,
                  f'{width:g} × {height:g} 逻辑点 · {panel} pt 侧栏 · {detail}', 13, MUTED),
             embedded_image(ASSETS / f'{name}.png', 0, 132, width, height)]
    path = write_svg(f'book-{name}', width, height + 132, parts)
    return {'name': name, 'title': title, 'svg': path, 'width': width, 'height': height + 132}


def comparison_page(original):
    width, height = 1200, 980
    parts = [text(42, 42, 'NEARPANE / SOURCE & CONTINUITY', 10, MUTED, 500,
                  'letter-spacing="1.8"'),
             text(42, 85, '保留原来的形态，把使用中的细节做完整。', 28, INK, 550),
             text(42, 116, '原始外观与 R4 场景不同；此页比较形态和秩序，不用于逐像素判断材质。', 13, MUTED),
             text(42, 168, '原始外观参考', 15, INK, 550),
             text(624, 168, 'R4 自然工作场景', 15, INK, 550),
             rectangle(42, 188, 534, 324, '#E9EDF0', 10),
             rectangle(624, 188, 534, 324, '#E9EDF0', 10),
             embedded_image(original, 42, 188, 534, 324),
             embedded_image(ASSETS / '00-lived-desktop.png', 624, 188, 534, 324),
             text(42, 565, '沿用的产品气质', 21, INK, 550),
             text(624, 565, '此次完成的设计', 21, INK, 550)]
    left = ['窄纵向、无标题，内容直接出现。',
            '连续玻璃外壳，原有的少控件结构。',
            '语音在上，统一托盘随后，调度紧接工具。',
            '中性表面接纳环境色，不把壁纸色当品牌染色。']
    right = ['默认宽度、正文底板与独立深色材质。',
             '同心圆角、轻边界与稳定的交互反馈。',
             '窗口同源缩放、清楚的对象含义与列表密度。',
             '文件流转、备忘计算、原处翻译的关键状态。']
    for index, value in enumerate(left):
        parts.append(text(42, 609 + index * 39, value, 15, '#586873'))
    for index, value in enumerate(right):
        parts.append(text(624, 609 + index * 39, value, 15, '#586873'))
    parts.extend([rule(42, 793, 1158),
                  wrapped(42, 827, '本页两侧均为设计参考。R4 使用确定性矢量场景和同源窗口内容，不冒充用户桌面截图。'
                          '原生光学与行为仍按真实 Mac 验收。', 1116, 13, 23),
                  text(42, 895, f'原图：{SOURCE_PATH}', 11, MUTED),
                  text(42, 921, f'基线：{SOURCE_SHA[:7]} · 设计规则：SPEC.md · 当前状态：Designed', 11, MUTED)])
    path = write_svg('book-source-comparison', width, height, parts)
    return {'name': 'source-comparison', 'title': '原始外观与 R4 延续关系', 'svg': path,
            'width': width, 'height': height,
            'links': [(42, 878, 1158, 902, f'{GITHUB}/blob/{SOURCE_SHA}/{SOURCE_PATH}')]}


def parameter_page():
    width, height = 1200, 1110
    layout, typography = TOKENS['layout'], TOKENS['typography']
    material, modules = TOKENS['material'], TOKENS['modules']
    interaction = TOKENS['interaction']
    standard = material[material['default']]
    dark = material['dark']
    examples = '；'.join(f'{d} → {default_width(d)} pt' for d in (1440, 1512, 1728, 1920))
    rows = [
        ('默认宽度', examples),
        ('正文与间距', f"{typography['primarySize']} pt / {typography['primaryLineHeight']} pt 行高；"
         f"内距 {layout['outerInset']} pt；工具间距 {layout['toolGap']} pt；窗口间距 {layout['windowGap']} pt。"),
        ('表面边界', f"外壳圆角 {layout['shellRadius']} pt；内卡 {layout['toolRadius']} pt；"
         f"细边 {num(layout['hairlinePt'])} pt（{layout['referenceScale']}×）；选中轮廓 {num(layout['selectionStrokePt'])} pt。"),
        ('工具高度', f"语音 {modules['voiceActiveHeight']} / 暂停 {modules['voicePausedHeight']} pt；"
         f"托盘 {modules['trayOneRowHeight']} / {modules['trayTwoRowHeight']} pt；备忘 {modules['memoHeight']} pt。"),
        ('标准浅色', f"外壳白色覆盖率 {num(standard['shell'])}；内容底板 {num(standard['textSurface'])}。"
         '原生按最终光学效果校准。'),
        ('标准深色', f"外壳 {dark['shellColor']} / {num(dark['shell'])}；"
         f"内容底板 {dark['textSurfaceColor']} / {num(dark['textSurface'])}。"),
        ('不透明前景', f"文字、图标与窗口图像 alpha = {num(typography['foregroundAlpha'])}；"
         '背景区域独立合成，避免重复 tint 或阴影。'),
        ('独立窗口密度', f"图槽最高为可用图宽 × {layout['independentImageHeightPerWidth']:.2f}；"
         f"Fit 保留完整源图；徽标尾部 {layout['previewBadgeTail']} pt。"),
        ('组合与全屏', '普通组合共用 WorkRect 坐标变换；原生全屏 / Split View 使用完整显示器。'),
        ('反馈与手势', f"悬停 {interaction['hoverDurationMs']} ms；状态 {interaction['stateDurationMs']} ms；"
         f"主动折叠 {interaction['explicitToolCollapseMs']} ms；拖动阈值 {interaction['dragThresholdPt']} pt。"),
        ('次序与保留', '窗口按稳定打开序列；不凭同桌面合组；点击不重排；文件空入口用途延期。'),
    ]
    parts = [text(42, 42, 'NEARPANE / IMPLEMENTATION REFERENCE', 10, MUTED, 500,
                  'letter-spacing="1.8"'),
             text(42, 85, '一套视觉源，对应一套实现参数。', 28, INK, 550),
             text(42, 117, '此页数值直接读取 design-tokens.json；完整语义、替代范围与验收要求见 SPEC.md。', 13, MUTED)]
    y = 161
    for index, (label, detail) in enumerate(rows):
        if index % 2 == 0:
            parts.append(rectangle(42, y, 1116, 58, '#E9EDEF', 8))
        parts.append(text(58, y + 34, label, 14, INK, 550))
        parts.append(wrapped(249, y + 34, detail, 885, 13, 21, '#566671'))
        y += 63
    parts.extend([rule(42, 874, 1158),
                  text(42, 909, 'Designed · R4 设计参考完成；实际静态检查结果见 VALIDATION.md。', 14, INK, 500),
                  text(42, 938, '原生光学校准待完成；保留 5.20 已有同桌面证据，跨 Space 状态按当前专项记录。', 13, MUTED),
                  text(42, 976, f'原生基线：{GITHUB}/tree/{SOURCE_SHA}', 10.5, MUTED),
                  text(42, 1002, f'设计交付：{GITHUB}/pull/13', 10.5, MUTED),
                  text(42, 1049, 'NEARPANE / R4', 10, MUTED, 500, 'letter-spacing="1.4"'),
                  text(1158, 1049, TOKENS['date'] + ' · 北京时间', 10, MUTED,
                       extra='text-anchor="end"')])
    path = write_svg('book-implementation-summary', width, height, parts)
    return {'name': 'implementation-summary', 'title': '实施参数与证据边界', 'svg': path,
            'width': width, 'height': height,
            'links': [(42, 960, 1158, 982, f'{GITHUB}/tree/{SOURCE_SHA}'),
                      (42, 987, 750, 1008, f'{GITHUB}/pull/13')]}


def render_book_pages(pages):
    """Render only temporary book pages, never modify the approved board exports."""
    node = os.environ.get('CODEX_PRIMARY_RUNTIME_NODE') or shutil.which('node')
    if not node:
        raise RuntimeError('Node.js is required to render the all-sans book pages.')
    script = TMP / 'render_book_pages.cjs'
    script.write_text('''const fs = require('fs');
const path = require('path');
const root = process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES;
const sharp = require(root ? path.join(root, 'sharp') : 'sharp');
(async () => {
  for (const p of process.argv.slice(2)) {
    await sharp(fs.readFileSync(p), {density:144}).png()
      .toFile(p.replace(/\\.svg$/, '.png'));
  }
})().catch(e => { process.stderr.write(e.stack + '\\n'); process.exit(1); });
''')
    subprocess.run([node, str(script), *[str(p['svg']) for p in pages if 'svg' in p]], check=True)
    for page in pages:
        if 'svg' in page:
            page['png'] = page['svg'].with_suffix('.png')


def build(output):
    TMP.mkdir(parents=True, exist_ok=True)
    original = find_original()
    all_names = [
        '00-lived-desktop', '01-default-desktop', '02-layout-comparison',
        '03-width-comparison', '04-material-comparison', '05-state-reference',
        '06-annotated-detail', '07-three-tools-desktop', '08-split-workspace-desktop',
        '09-native-and-accessibility', '10-tray-flow', '11-voice-and-memo',
        '12-inline-translation', '13-interaction-states', '14-background-stress',
        '15-density-comparison',
    ]
    sizes = {name: logical_size(name) for name in all_names}

    def board(name, title):
        width, height = sizes[name]
        return {'name': name, 'title': title, 'png': ASSETS / f'{name}.png',
                'width': width, 'height': height}

    pages = [
        desktop_page('00-lived-desktop', 'Nearpane R4 · 留在工作的一侧。',
                     '自然重叠窗口 · 同源预览 · 原生光学校准待完成'),
        board('06-annotated-detail', '结构、光学边界与主要尺寸'),
        comparison_page(original),
        desktop_page('01-default-desktop', '默认桌面 · 四个独立窗口',
                     '两个工具 · 独立窗口按稳定序列排列'),
        board('02-layout-comparison', '工具组合与顶部排列'),
        board('03-width-comparison', '同内容的窄、默认与宽幅对照'),
        board('15-density-comparison', '独立窗口密度与辨识度取舍'),
        board('04-material-comparison', '清透、标准、清晰与独立深色'),
        board('14-background-stress', '浅、深与复杂背景压力对照'),
        desktop_page('07-three-tools-desktop', '三个工具 · 列表自然接续',
                     '备忘录完整显示 · 列表独立滚动'),
        desktop_page('08-split-workspace-desktop', '明确组合 · 其他真实 Spaces',
                     '普通组合使用 WorkRect · 点击不自动重排'),
        board('05-state-reference', '独立窗口、组合与异常状态'),
        board('09-native-and-accessibility', '全屏、分屏与辅助显示'),
        board('10-tray-flow', '截图与文件的统一托盘流转'),
        board('11-voice-and-memo', '语音连续正文与备忘计算'),
        board('12-inline-translation', '原词附近翻译与单词本'),
        board('13-interaction-states', '悬停、选中、焦点与失败反馈'),
        parameter_page(),
    ]
    if len(pages) != 18:
        raise AssertionError('The R4 book requires all 16 boards plus two supplementary pages.')
    render_book_pages(pages)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = output.with_suffix('.building.pdf')
    book = canvas.Canvas(str(temporary_output), pageCompression=1)
    book.setTitle('Nearpane R4 · 视觉设计与实施参考')
    book.setAuthor('Nearpane design reference')
    book.setSubject(f"{TOKENS['date']} · Designed · Native optical calibration pending")
    book.setKeywords('Nearpane, R4, visual reference, glass, native implementation reference')
    book.setViewerPreference('DisplayDocTitle', 'true')
    for page in pages:
        width, height = page['width'], page['height']
        book.setPageSize((width, height))
        book.setFillColor(HexColor(PAPER))
        book.rect(0, 0, width, height, stroke=0, fill=1)
        book.bookmarkPage(page['name'])
        book.addOutlineEntry(page['title'], page['name'], level=0)
        book.drawImage(str(page['png']), 0, 0, width=width, height=height, mask='auto')
        for x1, y1, x2, y2, url in page.get('links', []):
            book.linkURL(url, (x1, height - y2, x2, height - y1), relative=0, thickness=0)
        book.showPage()
    book.save()
    temporary_output.replace(output)
    manifest = {'output': str(output), 'page_count': len(pages), 'board_count': len(all_names),
                'source_commit': SOURCE_SHA, 'original_reference': str(original),
                'pages': [{'number': i + 1, 'name': p['name'], 'title': p['title'],
                           'width': p['width'], 'height': p['height']} for i, p in enumerate(pages)]}
    (TMP / 'book-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(json.dumps({k: manifest[k] for k in ('output', 'page_count', 'board_count', 'source_commit')},
                     ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'Nearpane_Visual_Reference_R4.pdf')
    args = parser.parse_args()
    build(args.output)
