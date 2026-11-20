#!/usr/bin/env python3
"""Complementary R4 interaction boards, using the main visual renderer.

All content is a constructed design fixture. These boards do not imply native
microphone, file storage, translation, or cross-application capabilities.
"""
import render_reference as r


INK = r.T['primaryColorLight']
MUTED = '#68716F'
FAINT = '#8A9290'
PAPER = '#F5F5F3'
ENVIRONMENT = '#CCD5D2'
PANEL_W = 240
INSET = r.L['outerInset']
CARD_W = PANEL_W - 2 * INSET


def small_arrow(x, y, size=14, color=MUTED, direction='right'):
    if direction == 'left':
        path = 'M15 4 7 12l8 8M7 12h14'
    else:
        path = 'm9 4 8 8-8 8M17 12H3'
    return f'<g transform="translate({r.n(x)} {r.n(y)}) scale({r.n(size/24)})" fill="none" stroke="{color}" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="{path}"/></g>'


def settings_icon(x, y, size=18, color=MUTED):
    return f'<g transform="translate({r.n(x)} {r.n(y)}) scale({r.n(size/24)})" fill="none" stroke="{color}" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3h4l.7 2.4L17 6.7l2.4-.6 2 3.4-1.7 1.8v2.6l1.7 1.8-2 3.4-2.4-.6-2.3 1.3L14 22h-4l-.7-2.4L7 18.3l-2.4.6-2-3.4 1.7-1.8v-2.6L2.6 9.3l2-3.4 2.4.6 2.3-1.3z"/><circle cx="12" cy="12.5" r="3.2"/></g>'


def panel_piece(a, x, y, h, w=PANEL_W):
    """A cropped 240 pt rail segment; independent shell and content tint."""
    shell_r = r.L.get('shellRadius', 28)
    card_r = r.L.get('toolRadius', 16)
    material = r.TOKENS['material'].get('balanced', {'shell': .58, 'textSurface': .88})
    a.add(r.rect(x, y, w, h + 2 * INSET, ENVIRONMENT, shell_r))
    a.add(r.rect(x, y, w, h + 2 * INSET, '#FFFFFF', shell_r, '#FFFFFFA8', .5, alpha=material['shell']))
    # Repaint the environmental source beneath the content. Tint does not stack.
    a.add(r.rect(x + INSET, y + INSET, w - 2 * INSET, h, ENVIRONMENT, card_r))
    a.add(r.rect(x + INSET, y + INSET, w - 2 * INSET, h, '#FFFFFF', card_r, '#FFFFFFB0', .5, alpha=material['textSurface']))
    return x + INSET, y + INSET, w - 2 * INSET, h


def label(a, x, y, title, subtitle=None, width=380):
    a.add(r.txt(x, y, title, 15, INK, 550))
    if subtitle:
        a.add(r.para(x, y + 23, subtitle, width, 10, 16, FAINT, 2))


def tray_fixture(a, x, y, items):
    """Exact visible cells in row-major order; never paints a vacant slot."""
    rows = 1 if len(items) <= 2 else 2
    h = 76 if rows == 1 else 144
    xx, yy, cw, _ = panel_piece(a, x, y, h)
    pad, gap = r.L['trayInset'], r.L['trayCellGap']
    cell_w = (cw - 2 * pad - gap) / 2
    cell_h = (h - 2 * pad - gap * (rows - 1)) / rows
    cells = [{'S1': 'browser', 'S2': 'code', 'S3': 'notes', 'C': 'camera', 'F': 'folder'}.get(item, 'file') for item in items]
    a.add(r.tray(a, xx, yy, cw, h, cells=cells))
    boxes = []
    for index, item in enumerate(items):
        cx = xx + pad + (index % 2) * (cell_w + gap)
        cy = yy + pad + (index // 2) * (cell_h + gap)
        boxes.append({'item': item, 'frame': [round(cx, 2), round(cy, 2), round(cell_w, 2), round(cell_h, 2)]})
    return {'visibleItems': items, 'rows': rows, 'moduleHeight': h, 'cells': boxes}


def tray_board():
    a = r.Art(1320, 1430)
    r.board_head(a, 'NEARPANE / TRAY FLOW', '一个托盘，两端都有秩序。', '截图从首端进入，文件留在末端。可见容量改变，内容的归属与保存不变。')
    states = [
        ('空托盘', '只有两个入口', ['C', 'F'], '无', False),
        ('一张截图', '文件入口自然后移', ['S1', 'C', 'F'], '无；第四位不绘制空框', False),
        ('两张截图', '文件入口到第四位', ['S1', 'S2', 'C', 'F'], '无', False),
        ('三张以上截图', '保留截图入口的原有路径', ['S1', 'S2', 'S3', 'C'], '文件入口、较早截图', False),
        ('一张截图、一个文件', '入口位于两类内容之间', ['S1', 'C', 'F', 'F1'], '无', False),
        ('多张截图、一个文件', '最新文件受到保护', ['S1', 'S2', 'C', 'F1'], '文件入口、较早截图', False),
        ('空间紧张时', '各保留最新一项', ['S1', 'F1'], '两个入口、较早内容', False),
        ('只有一个文件', '建议 · 一行呈现，文件在末端', ['C', 'F1'], '文件空入口', True),
        ('多个文件', '建议 · 从末端向前排列', ['C', 'F3', 'F2', 'F1'], '文件空入口、更早文件', True),
    ]
    metadata = []
    for i, (title, subtitle, items, hidden, recommended) in enumerate(states):
        x = 42 + (i % 3) * 426
        y = 170 + (i // 3) * 344
        label(a, x, y, f'{i+1:02d}  {title}', subtitle)
        geo = tray_fixture(a, x + 72, y + 46, items)
        sequence = ' · '.join(items[:2]) + ('  /  ' + ' · '.join(items[2:]) if len(items) > 2 else '')
        a.add(r.txt(x, y + 241, '可见  ' + sequence, 11, '#52605A'))
        a.add(r.para(x, y + 265, '隐藏  ' + hidden, 380, 11, 17, MUTED, 2))
        metadata.append({'name': title, 'recommendedCompletion': recommended, 'hiddenDescription': hidden, **geo})
    a.add(r.line(42, 1192, 1278, 1192, '#DADEDB', .7))
    a.add(r.txt(42, 1226, 'S1 最新截图  ·  F1 最新文件  ·  C 截图入口  ·  F 文件空入口', 12, '#505B55', 500))
    a.add(r.para(42, 1255, '字母只用于图外说明，不出现在产品里。文件空入口仍只确定位置，点击用途待定。', 780, 11, 18, MUTED, 2))
    a.add(r.para(42, 1296, '截图与文件各自保留原有队列。按下或拖动时锁定对象，新内容在手势结束后再排入；文件成功保存后约 60 秒退出临时显示。', 1180, 11, 18, MUTED, 2))
    r.board_foot(a, '状态顺序依据 Revision 02；仅文件的两种补全为设计建议，未定义新的文件入口用途。', 'NEARPANE / R4 / 2026.11.18')
    a.save('10-tray-flow')
    return metadata


def voice_fixture(a, x, y, state):
    compact = state in ('paused', 'permission')
    h = 40 if compact else 144
    xx, yy, w, _ = panel_piece(a, x, y, h)
    if state in ('active', 'waiting'):
        a.add(r.para(xx + 12, yy + 26, '今天先整理产品参考，再把关键的变化记下来。', w - 24, 14, 20, INK, 4))
    if not compact:
        cy = yy + h - 40
        a.add(r.rect(xx + 12, cy, 30, 27, '#FFFFFF', 9, alpha=.48))
        a.add(r.icon('copy', xx + 19, cy + 5, 16, r.T['secondaryColorLight']))
    else:
        cy = yy + 6
    a.add(r.rect(xx + w - 60, cy, 48, 27, '#FFFFFF', 14, alpha=.45))
    if state == 'paused':
        a.add(r.icon('play', xx + w - 43, cy + 6, 14, r.T['secondaryColorLight']))
    elif state == 'permission':
        a.add(r.txt(xx + 12, yy + 25, '麦克风不可用', 12, r.T['secondaryColorLight']))
        a.add(settings_icon(xx + w - 45, cy + 4.5, 18, r.T['secondaryColorLight']))
    else:
        heights = [6, 12, 17, 11, 6] if state == 'active' else [3, 3, 3, 3, 3]
        for j, bar_h in enumerate(heights):
            a.add(r.rect(xx + w - 49 + j * 5, cy + (27 - bar_h) / 2, 2.5, bar_h, r.T['secondaryColorLight'], 1.25))
    return {'state': state, 'moduleHeight': h, 'bodyVisible': state in ('active', 'waiting'), 'captureEnabled': state in ('active', 'waiting'), 'waveformActive': state == 'active'}


MEMO_EXPRESSION = '128 × 3 ='


def memo_fixture(a, x, y, result=False, more=False):
    xx, yy, w, h = panel_piece(a, x, y, 128)
    a.add(r.para(xx + 12, yy + 26, '周五前确认印刷报价。', w - 24, 14, 20, INK, 2))
    a.add(r.txt(xx + 12, yy + 73, MEMO_EXPRESSION, 14, INK))
    if result:
        a.add(r.rect(xx + 92, yy + 56, 42, 24, '#E9EDE9', 6))
        a.add(r.txt(xx + 113, yy + 73, '384', 14, INK, 500, 'middle'))
        a.add(r.icon('close', xx + 143, yy + 61, 14, '#65716A'))
    if more:
        # The context affordance appears only for this interaction illustration.
        for i in range(3):
            a.add(r.circle(xx + w - 28 + i * 4, yy + h - 18, 1, '#6C7670'))
    return {'expression': MEMO_EXPRESSION, 'temporaryResultVisible': result, 'moduleHeight': h}


def voice_memo_board():
    a = r.Art(1320, 1430)
    r.board_head(a, 'NEARPANE / VOICE & MEMO', '状态发生变化，内容保持连续。', '只在明确的用户动作后改变结构。无声不折叠，取消结果不改原表达式。')
    voices = [
        ('正在说话', '连续文字流与真实波形', 'active', '144 pt · 正文内部滚动'),
        ('已启用，暂时无声', '保留原内容与展开高度', 'waiting', '144 pt · 不因静音反复折叠'),
        ('明确暂停', '只留恢复操作', 'paused', '40 pt · 隐藏正文，保留记录'),
        ('麦克风权限不可用', '原控件打开系统权限设置', 'permission', '40 pt · 不显示正在收音'),
    ]
    voice_meta = []
    for i, (title, subtitle, state, note) in enumerate(voices):
        x = 42 + i * 318
        label(a, x, 170, title, subtitle, 282)
        voice_meta.append(voice_fixture(a, x + 21, 216, state))
        a.add(r.para(x, 418, note, 282, 11, 17, MUTED, 2))
    a.add(r.line(42, 470, 1278, 470, '#DADDDA', .7))
    a.add(r.txt(42, 514, '计算是备忘录里的一次动作。', 21, INK, 550))
    a.add(r.txt(42, 544, '同一份文字，临时查看结果；取消后原样保留。', 12, MUTED))
    memo_meta = []
    for i, (title, result, note) in enumerate([
        ('普通备忘', False, '普通内容与表达式保留在当前备忘中。'),
        ('临时结果', True, '按等号显示结果；结果不是替换文本。'),
        ('取消结果', False, '只撤去 384，原表达式逐字保留。'),
    ]):
        x = 42 + i * 426
        label(a, x, 590, title)
        memo_meta.append(memo_fixture(a, x + 72, 618, result))
        a.add(r.para(x, 802, note, 380, 11, 18, MUTED, 2))
    a.add(r.line(42, 857, 1278, 857, '#DADDDA', .7))
    a.add(r.txt(42, 902, '需要连续计算时，进入独立草稿。', 21, INK, 550))
    a.add(r.txt(42, 932, '入口只在备忘录的上下文中出现，不增加全局模块或标签。', 12, MUTED))
    memo_fixture(a, 105, 982, more=True)
    a.add(r.rect(298, 1100, 166, 46, '#FFFFFF', 11, '#DAE0DC', .7, extra='filter="url(#smallshadow)"'))
    a.add(r.txt(314, 1129, '计算草稿', 13, INK))
    a.add(small_arrow(434, 1116, 15, '#657169'))
    a.add(r.para(42, 1185, '备忘录上下文菜单\n打开时不迁移、不覆盖原备忘。', 430, 12, 21, MUTED, 2))
    a.add(small_arrow(598, 1050, 28, '#ABB4AE'))
    xx, yy, w, _ = panel_piece(a, 870, 982, r.M['memoHeight'])
    a.add(small_arrow(xx + 11, yy + 12, 16, '#59665E', 'left'))
    a.add(r.txt(xx + 34, yy + 25, '计算草稿', 12, '#59665E'))
    a.add(r.line(xx + 12, yy + 39, xx + w - 12, yy + 39, '#DEE4DF', .7))
    a.add(r.txt(xx + 12, yy + 65, '128 × 3 = 384', 14, INK))
    a.add(r.txt(xx + 12, yy + 92, '360 ÷ 8 = 45', 14, INK))
    a.add(r.line(xx + 12, yy + 103, xx + 12, yy + 117, '#718178', 1))
    a.add(r.para(818, 1185, '沿用同一编辑器与 128 pt 高度；长内容滚动。\n返回仍是原备忘，计算记录在独立草稿中保存。', 460, 12, 21, MUTED, 2))
    a.add(r.para(42, 1305, '此页呈现外观与状态关系。麦克风、持久保存、上下文导航与数据恢复仍须原生实现验证。', 1180, 11, 18, MUTED, 2))
    r.board_foot(a, '语音四态与备忘三态同源绘制；计算草稿没有成为新的常驻侧栏模块。', 'NEARPANE / R4 / 2026.11.18')
    a.save('11-voice-and-memo')
    return {'voice': voice_meta, 'memo': memo_meta, 'cancelPreservesExpression': memo_meta[0]['expression'] == memo_meta[2]['expression'], 'independentDraftNavigation': 'context menu -> draft -> back to unchanged memo'}


def translation_board():
    a = r.Art(1320, 1240)
    r.board_head(a, 'NEARPANE / INLINE TRANSLATION', '译文留在原词旁，回顾留在单词本。', '成功的主动查询自动记录。保持选区可见，不要求再次保存，不增加常驻翻译卡片。')
    wx, wy, ww, wh = 52, 176, 754, 574
    a.add(r.window(a, wx, wy, ww, wh, 'browser', title='阅读资料', shadow=True))
    # A reading fixture beneath the same browser chrome as the main renderer.
    a.add(r.rect(wx + 1, wy + 63, ww - 2, wh - 72, '#FDFDFC'))
    a.add(r.txt(wx + 40, wy + 112, 'Designing for continuity', 25, '#34423B', 550))
    a.add(r.txt(wx + 40, wy + 141, 'A quiet interface keeps attention on the work.', 13, '#849087'))
    a.add(r.txt(wx + 40, wy + 188, 'Good tools preserve', 15, '#56645A'))
    selection = [wx + 39, wy + 201, 80, 25]
    a.add(r.rect(*selection, '#DCE9E0', 3))
    a.add(r.txt(wx + 43, wy + 219, 'continuity', 15, '#2C4937'))
    a.add(r.txt(wx + 125, wy + 219, 'between one action and the next.', 15, '#56645A'))
    a.add(r.txt(wx + 40, wy + 266, 'Small, predictable actions make the next step feel natural.', 13, '#849087'))
    a.add(r.line(wx + 40, wy + 296, wx + ww - 40, wy + 296, '#E5E9E5', .7))
    a.add(r.para(wx + 40, wy + 333, '阅读与操作之间，不必切换到另一块工具面板。\n需要了解一个词时，就在它旁边继续。', ww - 80, 14, 24, '#8C9690', 3))
    pop = [wx + 32, wy + 236, 324, 166]
    px, py, pw, ph = pop
    a.add(r.rect(px, py, pw, ph, '#FFFFFF', 15, '#D5DED6', .7, extra='filter="url(#winshadow)"'))
    a.add(f'<path d="M{r.n(px+43)} {r.n(py+1)}l8-8 8 8" fill="#FFFFFF" stroke="#D5DED6" stroke-width=".7"/>')
    a.add(r.line(px + 44, py + 1, px + 58, py + 1, '#FFFFFF', 2))
    a.add(r.txt(px + 18, py + 35, 'continuity', 20, INK, 550))
    a.add(r.txt(px + 18, py + 58, '名词', 11, '#89918A'))
    a.add(r.txt(px + 18, py + 86, '连贯性；连续性', 15, '#364B3D'))
    a.add(r.txt(px + 18, py + 110, '此处指操作与思路的自然接续。', 12, '#77847A'))
    a.add(r.line(px + 18, py + 126, px + pw - 18, py + 126, '#E6EBE6', .7))
    a.add(r.txt(px + 18, py + 149, '在单词本中查看', 11, '#526C59'))
    a.add(small_arrow(px + pw - 33, py + 138, 14, '#526C59'))
    notes = [
        (212, '查询发生在原词旁', '浮层跟随明确选中的文本，避让原词和屏幕边缘。用户仍在原来的阅读位置。'),
        (372, '成功后自动留下记录', '一次成功结果对应一次查询；不增加保存按钮，不把流式片段存成多条。'),
        (532, '侧栏维持原有结构', '翻译不占用新的常驻卡片。只有需要回顾时，再进入主窗口的单词本。'),
    ]
    for y, title, body in notes:
        a.add(r.txt(858, y, title, 17, INK, 550))
        a.add(r.para(858, y + 33, body, 390, 13, 23, MUTED, 4))
    a.add(r.txt(52, 794, '回顾时，保留这个词出现过的语境。', 18, INK, 550))
    hx, hy, hw, hh = 52, 820, 754, 284
    a.add(r.rect(hx, hy, hw, hh, '#FCFDFB', 12, '#D7DED8', .7, extra='filter="url(#winshadow)"'))
    clip = a.clip(hx, hy, hw, hh, 12)
    chrome = r.rect(hx, hy, hw, 34, '#F0F3EF')
    for i, c in enumerate(['#DFA392', '#D9C495', '#AEC4AC']):
        chrome += r.circle(hx + 17 + 13 * i, hy + 17, 3.8, c)
    chrome += r.txt(hx + hw / 2, hy + 22, 'Nearpane · 单词本', 11, '#79847A', 400, 'middle')
    a.add(a.wrap(chrome, clip=clip))
    a.add(r.rect(hx + 1, hy + 34, 174, hh - 44, '#F4F6F2'))
    a.add(r.txt(hx + 19, hy + 69, '最近查询', 11, '#8B958B'))
    a.add(r.rect(hx + 10, hy + 84, 155, 43, '#E6ECE4', 8))
    a.add(r.txt(hx + 22, hy + 110, 'continuity', 14, '#485D4B', 500))
    dx = hx + 203
    a.add(r.txt(dx, hy + 80, 'continuity', 23, '#314737', 550))
    a.add(r.txt(dx, hy + 108, '连贯性；连续性', 14, '#677A69'))
    a.add(r.line(dx, hy + 129, hx + hw - 26, hy + 129, '#E3E9E0', .7))
    a.add(r.txt(dx, hy + 156, '今天 09:41 · 阅读资料', 11, '#909A8E'))
    a.add(r.para(dx, hy + 185, 'Good tools preserve continuity between one action and the next.', hw - 240, 13, 22, '#586C5B', 2))
    a.add(r.txt(dx, hy + 247, '同一词条可保留多次查询的时间与语境。', 11, '#8B9789'))
    a.add(r.txt(858, 870, '内容自动积累，来源保持清楚。', 17, INK, 550))
    a.add(r.para(858, 904, '原文、译文、查询时间与可得来源分开保存。重复查词可合并展示，但新的语境不会被覆盖。', 390, 13, 23, MUTED, 4))
    a.add(r.para(858, 1047, '阅读窗口与单词本均为合成设计样本，未使用用户的浏览历史或真实文本。', 390, 11, 19, FAINT, 3))
    r.board_foot(a, '交互设计样本；跨应用定位、翻译服务、焦点行为与记录持久化须分别完成原生验证。', 'NEARPANE / R4 / 2026.11.18')
    a.save('12-inline-translation')
    return {'selectionFrame': selection, 'popoverFrame': pop, 'selectionNotOccluded': py >= selection[1] + selection[3], 'saveButton': False, 'wordbookFrame': [hx, hy, hw, hh], 'containsUserData': False}


def make_supplements():
    return {
        'trayFlow': tray_board(),
        'voiceAndMemo': voice_memo_board(),
        'inlineTranslation': translation_board(),
    }


if __name__ == '__main__':
    import json
    print(json.dumps(make_supplements(), ensure_ascii=False, indent=2))
