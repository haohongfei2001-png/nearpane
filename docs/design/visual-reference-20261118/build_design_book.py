#!/usr/bin/env python3
"""Create the review book from the inspected PNG exports; no browser required."""
from pathlib import Path
import os, json
from PIL import Image
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.lib.colors import HexColor

ROOT=Path(__file__).resolve().parent
ASSETS=ROOT/'assets'
OUT=ROOT/'Nearpane_Visual_Reference_R3.pdf'
TOKENS=json.loads((ROOT/'design-tokens.json').read_text())
pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
C=canvas.Canvas(str(OUT),pageCompression=1)
C.setTitle('Nearpane R3 — 视觉基准与关键状态')
C.setAuthor('Nearpane design reference')
C.setSubject('2026-11-18 · Designed; native optical calibration pending')

def text(x,y,s,size=15,color='#29343b'):
    C.setFillColor(HexColor(color));C.setFont('STSong-Light',size);C.drawString(x,y,s)
def lines(x,y,items,size=16,leading=27,color='#53636e'):
    for item in items:text(x,y,item,size,color);y-=leading
def background(w,h):
    C.setPageSize((w,h));C.setFillColor(HexColor('#f5f5f3'));C.rect(0,0,w,h,fill=1,stroke=0)
def bookmark(title,key):
    C.bookmarkPage(key);C.addOutlineEntry(title,key,level=0)
def fitted_image(path,x,y,w,h):
    iw,ih=Image.open(path).size;scale=min(w/iw,h/ih);dw=iw*scale;dh=ih*scale
    C.drawImage(str(path),x+(w-dw)/2,y+(h-dh)/2,width=dw,height=dh,mask='auto')
def image_page(name,title,desktop_caption=None):
    p=ASSETS/(name+'.png');pw,ph=Image.open(p).size;w=pw/2;h=ph/2
    if desktop_caption:
        background(w,h+132);bookmark(title,name)
        text(36,h+94,title,28);text(36,h+60,desktop_caption,15,'#72818b')
        C.drawImage(str(p),0,0,width=w,height=h,mask='auto')
    else:
        background(w,h);bookmark(title,name);C.drawImage(str(p),0,0,width=w,height=h,mask='auto')
    C.showPage()

image_page('01-default-desktop','Nearpane R3｜默认桌面母稿',
           '1440 × 900 逻辑点 · 240 pt 侧栏 · 两个工具 · 四个独立窗口 · 设计提案 / 原生待校准')

# Historical reference is optional when the exported source package is used alone.
candidates=[]
if os.environ.get('NEARPANE_ORIGINAL_REFERENCE'):candidates.append(Path(os.environ['NEARPANE_ORIGINAL_REFERENCE']))
for ancestor in ROOT.parents:candidates.append(ancestor/'design/assets/2026-11-15-v2/interface-reference-original.png')
original=next((p for p in candidates if p.is_file()),None)
if original:
    background(1200,1000);bookmark('原图与本轮更新','source-comparison')
    text(42,944,'保留原来的形态，把比例与状态补齐。',29)
    text(42,906,'左：原始外观参考。右：本轮默认母稿。两者场景和屏幕比例不同，不用于逐像素材质比较。',15,'#74828c')
    fitted_image(original,42,500,542,350);fitted_image(ASSETS/'01-default-desktop.png',616,500,542,350)
    text(42,467,'继续保留',22);text(616,467,'有依据地更新',22)
    lines(42,421,['无标题的纵向侧栏与连续玻璃外壳。','语音在上、统一托盘居中、调度在下。','少控件，正文直接出现。','中性透明白底，环境色来自桌面。'],18,38)
    lines(616,421,['默认约16%屏宽，正文不随宽度缩小。','文字底板更白，前景始终不透明。','工具按实际高度排布，新增工具优先显示。','窗口保持真实比例、稳定次序和对象含义。'],18,38)
    text(42,173,'参考源：71dd29d / design/assets/2026-11-15-v2/interface-reference-original.png',12,'#7b8890')
    text(42,136,'历史图用于形态参考；R3 的具体尺寸、状态与规则见本图册及 SPEC.md。',15,'#53636e')
    C.showPage()

for name,title in [('06-annotated-detail','结构与标注'),('02-layout-comparison','工具与调度布局'),('03-width-comparison','宽度对照'),('04-material-comparison','玻璃材质对照'),('05-state-reference','对象与工具状态')]:image_page(name,title)
image_page('07-three-tools-desktop','三个工具｜完整桌面',
           '同一1440 × 900 pt屏幕 · 侧栏仍为240 pt · 备忘录完整显示，窗口列表起点下移138 pt')
image_page('08-split-workspace-desktop','明确双窗组合｜其他真实Spaces',
           '普通双窗仍位于WorkRect · 组合保留真实分屏 · 其他Space有轻标识 · 点击不自动重排布局')
image_page('09-native-and-accessibility','原生分屏、空态与辅助显示')

background(1200,1000);bookmark('实施参数摘要','implementation-summary')
text(42,945,'把这套图落实为同一套参数。',30)
text(42,905,'完整逻辑、来源、替代范围与验收矩阵：SPEC.md；可复现数值：design-tokens.json。',16,'#72818b')
rows=[
 ('默认宽度','约16%逻辑屏宽，常见宽度240–360 pt；整体仍位于约1/8–1/4区间。'),
 ('常见屏宽 → 侧栏','1440 → 240 pt；1512 → 242 pt；1728 → 276 pt；1920 → 307 pt。'),
 ('正文与间距','14 pt正文 / 20 pt行高；12 pt内边距；10 pt工具间距；11 pt预览间距。'),
 ('工具高度','语音144 pt / 暂停40 pt；托盘76或144 pt；备忘与待办128 pt。'),
 ('默认材质','外壳覆盖率0.58；文字底板0.88；单一模糊源，两个互不叠乘的区域。'),
 ('不透明前景','正文、图标与窗口图像alpha = 1；透明设置只作用于玻璃背景。'),
 ('稳定顺序','按可靠出生序号；未知历史以首次观察初始化；不按最近聚焦反复重排。'),
 ('预览坐标','单窗按源窗口；普通组合按WorkRect；原生全屏与Split View按完整显示器。'),
 ('交互边界','同桌面不自动合组；组与独立窗统一排序；点击不顺带恢复或重排布局。'),
 ('继承产品约束','统一托盘、暂停保留正文、备忘内计算、原词翻译；文件空入口用途仍待定义。')]
y=841
for i,(k,v) in enumerate(rows):
    if i%2==0:C.setFillColor(HexColor('#e9edef'));C.roundRect(42,y-48,1116,61,8,fill=1,stroke=0)
    text(58,y-12,k,17);text(272,y-12,v,15,'#566671');y-=68
text(42,112,'已完成：确定性SVG / PNG、尺寸核对、视觉排版与图册检查。',16)
text(42,79,'待完成：真实Mac玻璃校准、原生对象库存、稳定次序与点击/迁移的实机验收。',16,'#72818b')
C.showPage();C.save()
print(json.dumps({'output':str(OUT),'original_reference_included':bool(original)},ensure_ascii=False))
