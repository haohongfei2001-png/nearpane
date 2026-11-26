#!/usr/bin/env python3
"""Render the authored design sources. This does not run or simulate a music player."""
from pathlib import Path
import base64, html, json, mimetypes, os, re
import markdown
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
BROWSER = os.environ.get('LYRICTILE_RENDER_BROWSER', str(ROOT.parent/'.render-runtime/chrome-headless-shell-linux64/chrome-headless-shell'))
DESIGN = ROOT/'design/LyricTile-Design.html'
(ROOT/'qa').mkdir(exist_ok=True)

def data_uri(path):
    return 'data:'+mimetypes.guess_type(str(path))[0]+';base64,'+base64.b64encode(path.read_bytes()).decode()

def embed_assets(source):
    # Chromium rejects custom-property values over ~1 MiB. A short Blob URL keeps
    # the self-contained full-resolution cover intact without that CSS limit.
    source=source.replace("--cover:url('../assets/sample-cover-original.png')",'--cover:none')
    source=re.sub(r'\.\./assets/([\w.-]+)', lambda m: data_uri(ROOT/'assets'/m[1]), source)
    return source.replace('</head>',cover_bootstrap()+'</head>')

def cover_bootstrap():
    encoded=base64.b64encode((ROOT/'assets/sample-cover-original.png').read_bytes()).decode()
    return '<script>\n(()=>{const raw=atob("'+encoded+'"),bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);const url=URL.createObjectURL(new Blob([bytes],{type:"image/png"}));document.documentElement.style.setProperty("--cover",`url("${url}")`);})();\n</script>'

def page_markup(number, title, sub, content, class_name=''):
    return f'<section class="book-page {class_name}"><header class="book-head"><div><span>HOLDSNOW / LYRICTILE</span><h1>{title}</h1></div><b>{number:02d}</b></header><p class="book-sub">{sub}</p><div class="book-body">{content}</div><footer class="book-foot"><span>PRODUCT DESIGN · 2026.11.26</span><span>原创排版样张 · 非播放器运行截图</span></footer></section>'

def grid(cards):
    return '<div class="states-grid">'+''.join(cards)+'</div>'

def static_card(tile_markup, title, desc, background=''):
    return f'<article class="state"><div class="state-preview {background}">{tile_markup}</div><h3 class="state-label">{title}</h3><p class="state-desc">{desc}</p></article>'

def run():
    source=DESIGN.read_text()
    portable=embed_assets(source)
    (ROOT/'LyricTile-Design.html').write_text(portable)
    css=re.search(r'<style>(.*?)</style>',portable,re.S)[1]
    qa={'scope':'HTML design prototype and artifact QA only. macOS 27 / native app: NOT_RUN.','date':'2026-11-26 Asia/Shanghai','checks':{},'page_errors':[]}
    with sync_playwright() as p:
        browser=p.chromium.launch(executable_path=BROWSER,headless=True,args=['--no-sandbox'])
        page=browser.new_page(viewport={'width':1440,'height':1100},device_scale_factor=1.5)
        page.on('pageerror',lambda e:qa['page_errors'].append(str(e)))
        page.goto((ROOT/'LyricTile-Design.html').as_uri(),wait_until='networkidle')
        page.evaluate('document.fonts.ready')
        page.mouse.move(1,1)
        qa['checks']['all_image_elements_loaded']=page.locator('img').evaluate_all('(els)=>els.every(x=>x.complete&&x.naturalWidth>0)')
        qa['checks']['cover_background_loaded']=page.evaluate('async()=>{const bg=getComputedStyle(document.querySelector(".cover")).backgroundImage;if(bg==="none")return false;const i=new Image();i.src=bg.slice(5,-2);try{await i.decode();return i.naturalWidth>0}catch{return false}}')
        defs=page.locator('body > svg').evaluate('(x)=>x.outerHTML')
        directions=page.locator('.directions').evaluate('(x)=>x.outerHTML')
        for index,tab in enumerate(['directions','final','states','onboarding','ecosystem'],1):
            page.locator(f'.tab[data-tab="{tab}"]').click()
            page.mouse.move(1,1)
            page.wait_for_timeout(500)
            page.screenshot(path=str(ROOT/f'design/{index:02d}-{tab}.png'),full_page=True,animations='disabled')
        page.locator('.tab[data-tab="directions"]').click()
        page.mouse.move(1,1)
        page.locator('#directions').screenshot(path=str(ROOT/'LyricTile-Three-Directions.png'),animations='disabled')

        page.locator('.tab[data-tab="final"]').click()
        hero=page.locator('#hero-tile')
        page.mouse.move(1,1)
        page.wait_for_timeout(500)
        before=hero.bounding_box(); cue_before=hero.locator('.current').bounding_box()
        hero.hover()
        page.wait_for_timeout(400)
        after=hero.bounding_box(); cue_after=hero.locator('.current').bounding_box()
        qa['checks']['hover_outer_frame_unchanged']=before==after
        qa['checks']['hover_current_lyric_anchor_unchanged']=cue_before==cue_after
        qa['checks']['hover_controls_visible']=hero.locator('.controls').evaluate('(x)=>getComputedStyle(x).opacity')=='1'
        page.screenshot(path=str(ROOT/'design/06-hover.png'),full_page=True,animations='disabled')
        hero.locator('[data-menu]').click()
        qa['checks']['song_menu_opens']=page.locator('#song-menu').is_visible() and page.locator('#song-menu button').count()==4
        page.keyboard.press('Escape')
        qa['checks']['escape_closes_song_menu']=not page.locator('#song-menu').is_visible()
        page.locator('#hover-toggle').click()
        page.mouse.move(1,1)
        page.wait_for_timeout(500)
        hero_desktop=page.locator('#hero-desktop').evaluate('(x)=>x.outerHTML')

        extra_cards=[]
        for state,title,desc in [('plain','只有纯文本','未同步的文本供手动阅读；没有自动切句。'),('positionUnavailable','源不提供进度','明确说明能力缺失，进度不可拖动，不无限重连。'),('unknown','暂时失去位置','冻结歌词高亮，等待真实锚点；时间显示为未知。')]:
            page.locator('#state-select').select_option(state)
            page.wait_for_timeout(250)
            if state!='plain':
                qa['checks'][state+'_seek_disabled']=hero.locator('input[type=range]').is_disabled()
                qa['checks'][state+'_time_unknown']=hero.locator('.elapsed').inner_text()=='—:—'
            extra_cards.append(static_card(hero.evaluate('(x)=>x.outerHTML').replace('id="hero-tile"','').replace('hero-tile',''),title,desc))
        page.locator('#state-select').select_option('default')
        page.locator('[data-bg="night"]').click();page.mouse.move(1,1);page.wait_for_timeout(400)
        page.screenshot(path=str(ROOT/'design/07-dark.png'),full_page=True,animations='disabled')
        dark_card=hero.evaluate('(x)=>x.outerHTML').replace('id="hero-tile"','').replace('hero-tile','')
        page.locator('[data-bg="day"]').click()
        page.locator('#state-select').select_option('paused')
        page.mouse.move(1,1);page.wait_for_timeout(400)
        hero.locator('.play-toggle').click()
        qa['checks']['play_preview_removes_pause_badge']=not hero.evaluate('(x)=>x.classList.contains("pause")') and hero.locator('.state-caption').is_hidden()
        page.locator('.tab[data-tab="states"]').click();page.mouse.move(1,1);page.wait_for_timeout(400)
        cards=page.locator('#states .state').evaluate_all('(xs)=>xs.map(x=>x.outerHTML)')
        qa['checks']['rendered_state_and_typography_cards']=len(cards)
        page.locator('.tab[data-tab="onboarding"]').click()
        windows=page.locator('#onboarding .native-window').evaluate_all('(xs)=>xs.map(x=>x.outerHTML)')
        page.locator('.tab[data-tab="ecosystem"]').click()
        ecosystem=page.locator('.ecosystem-pair').evaluate('(x)=>x.outerHTML')

        page.set_viewport_size({'width':390,'height':844})
        page.locator('.tab[data-tab="final"]').click();page.mouse.move(1,1);page.wait_for_timeout(350)
        qa['checks']['mobile_review_no_horizontal_overflow']=page.evaluate('document.documentElement.scrollWidth<=innerWidth')
        page.screenshot(path=str(ROOT/'design/08-mobile-review.png'),full_page=True,animations='disabled')
        page.close()

        icon_section='<div class="icon-showcase">'+''.join(f'<div><img src="{data_uri(ROOT/f"assets/app-icon-{v}.svg")}"><h3>{label}</h3></div>' for v,label in [('master','Light'),('dark','Dark'),('tinted','Tinted')])+'</div>'
        icon_section+='<div class="brand-notes"><h2>三行歌词，一个阅读游标。</h2><p>LyricTile · 歌词板<br>HOLDSNOW / 握雪</p><p>珠白基底、石墨笔画、微量紫灰点。主体符号保持可辨认，材质交给原生系统。<br>提供独立可编辑SVG母版；正式系统资源需在当前Xcode/Icon Composer中导出并验证小尺寸。</p><div class="icon-sizes">'+''.join(f'<img width="{s}" height="{s}" src="{data_uri(ROOT/"assets/app-icon-master.svg")}">' for s in [24,32,64,128])+'</div></div>'
        pages=[]
        def add(title,sub,content,cls=''):
            pages.append(page_markup(len(pages)+1,title,sub,content,cls))
        add('三个方向，一个正式选择。','结构与注意力分配不同；最终只实现 A「雾白词页」。',directions,'directions-page')
        add('雾白词页 · 歌词，自然在旁。','悬停显示封面与控制，当前歌词与外框保持原位。',hero_desktop,'hero-page')
        final_states=grid([cards[0],cards[1],cards[2],static_card(dark_card,'深色 · 控制状态','背景与封面变化，阅读层级保持一致。','darkbg')])
        add('常态、悬停与暂停，始终是一张词页。','208 × 272 pt 参考尺寸 · 外框22 pt圆角 · 当前句20 pt · 系统字体',final_states,'final-states-page')
        add('音乐的每种停顿，都有准确表达。','间奏、纯音乐、缺词与未播放分别处理，不用同一张空白卡代替。',grid([cards[3],cards[4],cards[5],cards[7]]),'state-page')
        add('能力不足时，保持诚实也保持可用。','这些状态是产品的正式组成部分；不会用计时器或预置歌词冒充真实播放。',grid(extra_cards+[cards[6]]),'state-page')
        add('中文、长句与多语言。','保留原文字形、组合字符与真实时间；支持已有译文，不伪造词级数据。',grid(cards[8:12]),'state-page')
        add('同一阅读层，适应不同桌面。','复杂背景、深色、降低透明度与较大文字。浏览器材质仅作视觉参考，原生效果须实机核验。',grid(cards[12:16]),'state-page')
        add('首次使用，只解释当下需要的权限。','一个欢迎页，首次连接才请求对应自动化授权。所示四平台是实施目标，非本轮实机支持声明。','<div class="onboard-grid">'+''.join(windows[:2])+'</div>','onboard-page')
        add('设置保持简单，修正留在这首歌。','歌曲菜单提供版本选择、时间校准、导入与来源；不进入完整播放器功能。','<div class="onboard-grid">'+''.join(windows[2:])+'</div>','onboard-page')
        add('独立成列，原生归入 Nearpane。','左侧需兼容版本接入TileKit；右侧是Host内部模块。旧版不会凭空获得自动排列能力。',ecosystem,'ecosystem-page')
        add('LyricTile · 阅读中的音乐。','应用标识与可编辑矢量母版；不把生成图片的边缘细节作为工程规范。',icon_section,'brand-page')
        book_css='''
@page{size:A4 landscape;margin:0}
html,body{margin:0;background:#f5f4f0;-webkit-print-color-adjust:exact;print-color-adjust:exact}
.book-page{width:1122px;height:793.65px;padding:30px 36px 32px;position:relative;overflow:hidden;break-after:page;page-break-after:always;background:#f5f4f0;box-sizing:border-box}
.book-page:last-child{break-after:auto;page-break-after:auto}
.book-head{height:62px;display:flex;justify-content:space-between;align-items:start;border-bottom:1px solid #dededb}
.book-head span{font-size:9px;letter-spacing:.18em;color:#777982}.book-head h1{font-size:23px;font-weight:500;letter-spacing:-.025em;margin:8px 0 0}.book-head b{font-size:28px;line-height:1;font-weight:400;color:#a9aaa8}
.book-sub{font-size:11px;line-height:1.6;color:#6c7076;margin:13px 0 21px}
.book-foot{position:absolute;bottom:18px;left:36px;right:36px;display:flex;justify-content:space-between;font-size:8px;letter-spacing:.04em;color:#81838a}
.book-body{height:604px}.book-page .directions{grid-template-columns:repeat(3,minmax(0,1fr));gap:20px}.book-page .direction-preview{height:405px}
.book-page .states-grid{grid-template-columns:repeat(4,minmax(0,1fr));gap:18px}.book-page .state-preview .tile{backdrop-filter:none;-webkit-backdrop-filter:none}.book-page .state-preview{height:354px}.book-page .state-label{font-size:14px;margin-top:20px}.book-page .state-desc{font-size:11px;line-height:1.8}
.book-page .desktop{height:560px}.book-page.hero-page .work-window{height:390px;top:74px}.book-page.hero-page .desktop-note{bottom:24px}.book-page.hero-page .hero-tile{top:108px}
.book-page .onboard-grid{grid-template-columns:1fr 1fr;gap:24px}.book-page .native-window{min-height:498px}.book-page .onboard-main{padding:27px 32px}.book-page .settings{padding:20px 27px}.book-page .settings-title{margin-top:12px}
.book-page .setting{min-height:37px}.book-page .footer-line{margin-top:18px}
.book-page .ecosystem-pair{grid-template-columns:1fr 1fr;gap:20px}.book-page.ecosystem-page .desktop{height:620px}.book-page.ecosystem-page .book-body{width:1120px;transform:scale(.9375);transform-origin:top left}.book-page.ecosystem-page .smallcaption{font-size:12px;margin-top:9px}.book-page.ecosystem-page .smallcaption span{font-size:10px;line-height:1.5}.book-page.ecosystem-page .book-sub{margin-bottom:9px}
.icon-showcase{display:flex;justify-content:center;gap:110px;padding:26px 0 18px;text-align:center}.icon-showcase img{width:158px;height:158px}.icon-showcase h3{font-size:13px;font-weight:400;margin:12px 0;color:#6e7178}.brand-notes{text-align:center}.brand-notes h2{font-size:24px;font-weight:500;margin:14px 0}.brand-notes p{font-size:12px;line-height:1.9;color:#70727a}.icon-sizes{display:flex;align-items:center;justify-content:center;gap:27px;margin-top:20px}
'''
        book='<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>LyricTile · High Fidelity Design</title><style>'+css+book_css+'</style>'+cover_bootstrap()+'</head><body>'+defs+''.join(pages)+'</body></html>'
        (ROOT/'design/LyricTile-Visual-Book.html').write_text(book)
        page=browser.new_page(viewport={'width':1122,'height':794},device_scale_factor=2)
        page.goto((ROOT/'design/LyricTile-Visual-Book.html').as_uri(),wait_until='networkidle');page.evaluate('document.fonts.ready');page.mouse.move(1,1)
        qa['checks']['visual_book_pages']=page.locator('.book-page').count()
        qa['checks']['book_windows_clear_footer']=page.locator('.onboard-page').evaluate_all('(xs)=>xs.every(x=>[...x.querySelectorAll(".native-window")].every(z=>z.getBoundingClientRect().bottom<x.querySelector(".book-foot").getBoundingClientRect().top-8))')
        qa['visual_book_geometry']=page.locator('.book-page').evaluate_all('(xs)=>xs.map(x=>({page:x.querySelector(".book-head b").textContent,title:x.querySelector("h1").textContent,bodyBottom:x.querySelector(".book-body").getBoundingClientRect().bottom-x.getBoundingClientRect().top,footerTop:x.querySelector(".book-foot").getBoundingClientRect().top-x.getBoundingClientRect().top}))')
        page.locator('.final-states-page').screenshot(path=str(ROOT/'LyricTile-Final-States.png'),animations='disabled')
        page.locator('.brand-page').screenshot(path=str(ROOT/'design/09-brand.png'),animations='disabled')
        page.pdf(path=str(ROOT/'LyricTile-Visuals.pdf'),print_background=True,prefer_css_page_size=True)
        page.close()

        report_markdown=(ROOT/'docs/LyricTile-Decision.md').read_text()
        report_content=markdown.markdown(report_markdown,extensions=['tables','fenced_code'])
        report_css='''@page{size:A4;margin:18mm 17mm 19mm}html{-webkit-print-color-adjust:exact;print-color-adjust:exact}body{font-family:"Noto Sans CJK SC",sans-serif;font-size:9.1pt;line-height:1.68;color:#282d36}h1{font-size:24pt;font-weight:500;line-height:1.45;margin:5mm 0 8mm;border-bottom:1px solid #cfd2d7;padding-bottom:5mm}h2{font-size:15pt;font-weight:500;margin:9mm 0 4mm;break-after:avoid}h3{font-size:11.5pt;margin:6mm 0 3mm;break-after:avoid}p{margin:0 0 3mm}li{margin:1.7mm 0}ul,ol{padding-left:5.5mm}table{border-collapse:collapse;width:100%;font-size:8pt;line-height:1.62;margin:4mm 0 5mm;table-layout:auto}thead{display:table-header-group}th{background:#edf0f3;font-weight:500;text-align:left}th,td{border:1px solid #d6dbe2;padding:2.1mm 2.3mm;overflow-wrap:anywhere}tr{break-inside:avoid}td:first-child{min-width:19mm}strong{font-weight:700}code{font-family:"Noto Sans Mono CJK SC",monospace;font-size:.88em;background:#f2f3f5;border-radius:2px;padding:0 2px;overflow-wrap:anywhere}pre{background:#f1f2f4;border:1px solid #dee1e6;padding:3mm;white-space:pre-wrap;overflow-wrap:anywhere;font-size:8pt;line-height:1.5;break-inside:avoid}pre code{background:none;padding:0}a{color:#525f89;text-decoration:none;overflow-wrap:anywhere}blockquote{margin:4mm 0;padding:2mm 4mm;border-left:2px solid #8b83b5;color:#5d6470}hr{border:0;border-top:1px solid #ddd;margin:7mm 0}.document-label{font-size:9pt;letter-spacing:.15em;color:#7a7e87;margin-top:4mm}'''
        report='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>LyricTile · Product and Technical Decision</title><style>'+report_css+'</style><body><div class="document-label">HOLDSNOW / PRODUCT DECISION / 2026.11.26</div>'+report_content+'</body></html>'
        (ROOT/'design/LyricTile-Decision-Print.html').write_text(report)
        page=browser.new_page()
        page.goto((ROOT/'design/LyricTile-Decision-Print.html').as_uri(),wait_until='networkidle');page.evaluate('document.fonts.ready')
        page.pdf(path=str(ROOT/'LyricTile-Decision.pdf'),print_background=True,prefer_css_page_size=True,display_header_footer=True,header_template='<div></div>',footer_template='<div style="width:100%;font-size:8px;color:#8a8f98;padding:0 65px;display:flex;justify-content:space-between"><span>HOLDSNOW / LyricTile / 2026.11.26</span><span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>')
        browser.close()
    qa['checks']['no_javascript_errors']=not qa['page_errors']
    qa['checks']['json_artifacts_parse']=True
    for path in (ROOT/'contracts').glob('*.json'):
        json.loads(path.read_text())
    (ROOT/'qa/design-validation.json').write_text(json.dumps(qa,ensure_ascii=False,indent=2)+'\n')
    assert all(v for v in qa['checks'].values()),qa
    print(json.dumps({'files':['LyricTile-Visuals.pdf','LyricTile-Decision.pdf','LyricTile-Design.html','LyricTile-Three-Directions.png','LyricTile-Final-States.png'],'checks':qa['checks'],'page_errors':qa['page_errors']},ensure_ascii=False,indent=2))

if __name__=='__main__':run()
