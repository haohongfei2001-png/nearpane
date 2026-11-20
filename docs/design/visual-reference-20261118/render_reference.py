#!/usr/bin/env python3
"""Deterministic Nearpane design reference. Vector UI, not native screenshots.

This renderer + design-tokens.json are the canonical visual source. Rasterize
SVG with render_svg.cjs. No network, browser, user data, or native APIs are used.
"""
from pathlib import Path
import json, math, html, re

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'assets'
OUT.mkdir(exist_ok=True)
TOKENS = json.loads((ROOT/'design-tokens.json').read_text())
FONT = 'Noto Sans CJK SC, sans-serif'
L = TOKENS['layout']
M = TOKENS['modules']
T = TOKENS['typography']

def default_width(display_width):
    t=TOKENS['width']
    return round(min(display_width*t['manualFractionRange'][1],
                     max(display_width*t['manualFractionRange'][0],
                         min(t['normalCeiling'],max(t['normalFloor'],display_width*t['commonScreenDefaultRatio'])))))

def fixture_work_rect(screen_width,screen_height,panel_width):
    f=TOKENS['referenceFixture']; inset=f['workAreaInset']; menu=f['menuBarHeight']
    return (inset, menu+inset, screen_width-panel_width-inset-f['sidebarSeparation'],screen_height-menu-2*inset)

def esc(s): return html.escape(str(s), quote=True)
def n(v): return f'{v:.6f}'.rstrip('0').rstrip('.')
def rect(x,y,w,h,fill,rx=0,stroke=None,sw=1,alpha=1,extra=''):
    return f'<rect x="{n(x)}" y="{n(y)}" width="{n(max(0,w))}" height="{n(max(0,h))}" rx="{n(rx)}" fill="{fill}" fill-opacity="{n(alpha)}"'+(f' stroke="{stroke}" stroke-width="{n(sw)}"' if stroke else '')+f' {extra}/>'
def line(x1,y1,x2,y2,c='#d2d8dd',sw=1,alpha=1):
    return f'<path d="M{n(x1)} {n(y1)}L{n(x2)} {n(y2)}" fill="none" stroke="{c}" stroke-width="{n(sw)}" stroke-opacity="{n(alpha)}" stroke-linecap="round"/>'
def txt(x,y,s,size=14,c='#25272A',weight=400,anchor='start',extra=''):
    family='' if 'font-family=' in extra else f'font-family="{FONT}"'
    return f'<text x="{n(x)}" y="{n(y)}" {family} font-size="{n(size)}" font-weight="{weight}" fill="{c}" text-anchor="{anchor}" {extra}>{esc(s)}</text>'
def circle(x,y,r,c,alpha=1):
    return f'<circle cx="{n(x)}" cy="{n(y)}" r="{n(r)}" fill="{c}" fill-opacity="{n(alpha)}"/>'
def para(x,y,s,maxw,size=14,leading=20,c='#25272a',maxlines=None):
    # CJK-safe deterministic line wrapping; actual native font must use same point size.
    out=[]; yy=y; count=0
    for paragraph in s.split('\n'):
        buf=''; width=0
        for ch in paragraph:
            step=size*(.54 if ord(ch)<128 else 1)
            if buf and width+step>maxw:
                # Keep Chinese closing punctuation off the beginning of a line.
                if ch in '，。！？；：、）》】」』％%…' and len(buf)>1:
                    carry=buf[-1];buf=buf[:-1]
                    out.append(txt(x,yy,buf,size,c));yy+=leading;count+=1
                    if maxlines and count>=maxlines:return ''.join(out)
                    buf=carry+ch;width=size*(.54 if ord(carry)<128 else 1)+step
                    continue
                out.append(txt(x,yy,buf,size,c));yy+=leading;count+=1;buf='';width=0
                if maxlines and count>=maxlines:return ''.join(out)
            buf+=ch;width+=step
        out.append(txt(x,yy,buf,size,c));yy+=leading;count+=1
        if maxlines and count>=maxlines:break
    return ''.join(out)

ICONS={
 'copy':'<rect x="8" y="8" width="11" height="12" rx="2"/><path d="M15 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
 'play':'<path d="m8 4 11 8-11 8z"/>',
 'camera':'<path d="M8 5 10 2h5l2 3h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z"/><circle cx="12" cy="12" r="4"/>',
 'folder':'<path d="M3 6a2 2 0 0 1 2-2h5l3 3h6a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
 'full':'<path d="M3 9V3h6M15 3h6v6M21 15v6h-6M9 21H3v-6"/>',
 'check':'<path d="m5 12 4 4 10-10"/>',
 'search':'<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>',
 'wifi':'<path d="M2 8a16 16 0 0 1 20 0M6 12a10 10 0 0 1 12 0M10 16a4 4 0 0 1 4 0"/><circle cx="12" cy="20" r=".7"/>',
 'close':'<path d="m7 7 10 10M17 7 7 17"/>',
}
def icon(name,x,y,size=18,c='#5d6973'):
    return f'<g transform="translate({n(x)} {n(y)}) scale({n(size/24)})" fill="none" stroke="{c}" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</g>'

class Art:
    def __init__(self,w,h):self.w=w;self.h=h;self.defs=[];self.parts=[];self.i=0;self.sources={};self.projections=[]
    def uid(self):self.i+=1;return f'x{self.i}'
    def add(self,s):self.parts.append(s)
    def clip(self,x,y,w,h,rx=0):
        i=self.uid();self.defs.append(f'<clipPath id="{i}">{rect(x,y,w,h,"white",rx)}</clipPath>');return i
    def wrap(self,body,clip=None,transform=None,filter_id=None):
        return '<g'+(f' clip-path="url(#{clip})"' if clip else '')+(f' transform="{transform}"' if transform else '')+(f' filter="url(#{filter_id})"' if filter_id else '')+'>'+body+'</g>'
    def save(self,name):
        sh=TOKENS['material']['shadow']
        common=f'''<filter id="blur" x="-30%" y="-30%" width="160%" height="160%" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="{TOKENS['material']['blurStdDeviationPt']}"/></filter><filter id="winshadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="5" stdDeviation="8" flood-color="#233649" flood-opacity=".15"/></filter><filter id="smallshadow" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="1.5" stdDeviation="1.5" flood-color="#1e3247" flood-opacity=".15"/></filter><filter id="shellshadow" x="-35%" y="-10%" width="170%" height="130%"><feDropShadow dx="0" dy="{sh['shell']['dy']}" stdDeviation="{sh['shell']['sigma']}" flood-color="#14212c" flood-opacity="{sh['shell']['alpha']}"/></filter><filter id="cardshadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="{sh['card']['dy']}" stdDeviation="{sh['card']['sigma']}" flood-color="#14212c" flood-opacity="{sh['card']['alpha']}"/></filter>'''
        svg=f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" role="img"><title>Nearpane R4 visual reference - design sample, not a native screenshot</title><defs>{common}{"".join(self.defs)}</defs>{"".join(self.parts)}</svg>'
        (OUT/(name+'.svg')).write_text(svg)

def app_icon(app,x,y,size=20):
    s=rect(0,0,32,32,'#f7f9f9',7,'#d8dfe5',.7)
    if app=='browser':
        s+=circle(16,16,12.5,'#639dbc')+circle(16,16,10.5,'none')+'<circle cx="16" cy="16" r="10.5" fill="none" stroke="#fff8" stroke-width=".8"/><path d="m21 8-3 11-8 5 3-11z" fill="#faf9f5"/><path d="m21 8-8 5 5 6z" fill="#ca7d73"/>'
    elif app=='code':s+='<path d="M23 5 11 15l-6-4-3 3 8 6L23 30l7-3V8z" fill="#6098c2"/><path d="M23 5v25l7-3V8z" fill="#4078a0"/><path d="m23 11-11 9-7 5-3-3 8-7 13-10z" fill="#83b7d9"/>'
    elif app=='notes':s+=rect(0,0,32,9,'#d9bd79',5)+line(6,15,26,15,'#b8c0c6')+line(6,20,26,20,'#b8c0c6')+line(6,25,22,25,'#b8c0c6')
    elif app=='finder':s=rect(0,0,32,32,'#a3cadf',7)+'<path d="M16 0h10a6 6 0 0 1 6 6v20a6 6 0 0 1-6 6H15l4-15h-6z" fill="#e0edf5"/><path d="M8 11v3M24 11v3M8 21q8 6 16 0M18 9l-3 9h4v8" stroke="#41627a" stroke-width="1.2" fill="none"/>'
    elif app=='video':s=rect(0,0,32,32,'#35414d',7)+'<path d="m12 8 12 8-12 8z" fill="#f1f4f2"/>'
    else:s+='<path d="M7 8h18v13H15l-6 5v-5H7z" fill="#6d8b7f"/>'+line(11,12,21,12,'#fff',1.5)+line(11,16,19,16,'#fff',1.5)
    return f'<g transform="translate({n(x)} {n(y)}) scale({n(size/32)})" filter="url(#smallshadow)">{s}</g>'

def wallpaper(a,w,h,kind='blue'):
    i=a.uid()
    colors={'blue':['#e0e6e9','#a9bdcf','#5c7ea7','#91adc6'], 'forest':['#d7dfce','#a5b89a','#577a65','#8ea786'], 'ink':['#354552','#213243','#142a42','#50677b'], 'paper':['#f2f0eb','#dddeda','#c0c8ca','#e1e4df']}
    cs=colors.get(kind,colors['forest'])
    g=a.uid();a.defs.append(f'<linearGradient id="{g}" x1="0" y1="0" x2=".7" y2="1"><stop stop-color="{cs[0]}"/><stop offset=".48" stop-color="{cs[1]}"/><stop offset="1" stop-color="{cs[2]}"/></linearGradient>')
    s=rect(0,0,w,h,f'url(#{g})')
    s+=f'<path d="M0 {h*.7}Q{w*.4} {h*.15} {w} {h*.54}V{h}H0Z" fill="{cs[3]}"/>'
    s+=f'<path d="M0 {h*.83}Q{w*.45} {h*.5} {w} {h*.78}V{h}H0Z" fill="{cs[2]}"/>'
    s+=f'<path d="M{w*.4} 0Q{w*.84} {h*.43} {w} {h*.48}V0Z" fill="{cs[0]}" fill-opacity=".54"/>'
    if kind=='busy':
        s=rect(0,0,w,h,'#829b79')
        for k in range(13):
            s+=f'<path d="M{-w*.2+k*w*.13} 0L{k*w*.13-w*.8} {h}" stroke="{["#d0bc7e","#25483e","#597054","#b1bf94"][k%4]}" stroke-width="{w*.13}"/>'
        for k in range(13):s+=line(w*.44,20+k*26,w*1.1,20+k*26,'#f0f0d4',2,.7)
    a.defs.append(f'<g id="{i}">{s}</g>');return i

def window(a,x,y,w,h,app='browser',title=None,shadow=False):
    # Real source aspect: this scene is later scaled as one entire window.
    title=title or {'browser':'设计系统的实践','notes':'项目计划','code':'Workspace.swift','finder':'设计资料','chat':'讨论','video':'视频'}[app]
    clip=a.clip(0,0,w,h,8)
    s=rect(0,0,w,h,'#fdfdfc')+rect(0,0,w,32,'#f3f4f5')+line(0,32,w,32,'#e0e4e7',.7)
    for j,c in enumerate(['#e68177','#e6bd6c','#7cbf95']):s+=circle(14+j*13,16,4,c)
    s+=txt(w/2,20,title,10,'#79848e',400,'middle')
    if app=='code':
        nav=max(70,min(130,w*.22));s+=rect(0,32,w,h-32,'#24292e')+rect(0,32,nav,h-32,'#2c3237')+rect(nav,32,w-nav,28,'#282d32')
        s+=txt(12,57,'EXPLORER',7,'#7d8b94')
        names=['⌄ nearpane','  ⌄ Sources','    Workspace.swift','    Geometry.swift','    Preview.swift','  ⌄ Design','    Reference.md','    Tokens.json']
        for j,ss in enumerate(names):
            if j==2:s+=rect(6,75+j*23,nav-12,21,'#3d454e',3)
            s+=txt(12,87+j*23,ss,8 if w<450 else 9,'#b8c3cc' if j==2 else '#8e9aa5')
        s+=txt(nav+17,50,'Workspace.swift',9,'#b7c5ce')
        rows=[('// Keep the real geometry.','#72868c'),('import AppKit','#a0b5d0'),('','#c3ced3'),('struct PreviewSurface {','#bfcbd4'),('  let space: SpaceID','#a5b9ca'),('  let windows: [Window]','#a5b9ca'),('','#c3ced3'),('  func render(in bounds: CGRect) {','#bfcbd4'),('    for window in windows {','#bfcbd4'),('      draw(window.content,','#b7c7b6'),('           at: window.frame)','#b7c7b6'),('    }','#bfcbd4'),('  }','#bfcbd4'),('}','#bfcbd4'),('','#bfcbd4'),('// Keep the order stable.','#72868c')]
        for j,(ss,c) in enumerate(rows):s+=txt(nav+15,87+j*18,ss,9 if w<500 else 10,c,400,extra='font-family="monospace"')
        s+=rect(0,h-21,w,21,'#2c343c')+txt(11,h-7,'main  ·  Swift                         UTF-8',8,'#96a4b0')
    elif app=='notes':
        pad=29;s+=txt(pad,77,'项目计划',23,'#2e3c46',550)+txt(pad,101,'把每一个重要决定，变得具体。',10,'#82909b')
        for j,ss in enumerate(['完善交互流程','核对窗口与空间的关系','整理视觉参考','准备开发与验收']):
            yy=135+j*39;s+=rect(pad,yy,12,12,'#7893a2' if j==0 else '#fcfcfb',3,'#b8c3cb',.8)
            if j==0:s+=icon('check',pad+1,yy+1,10,'#fff')
            s+=txt(pad+23,yy+11,ss,13,'#596974')
        if h>350:
            s+=line(pad,309,w-pad,309,'#e4e8e9')+para(pad,337,'内容的位置保持稳定。\n透明的外壳，清楚的文字。',w-2*pad,11,20,'#84909a')
    elif app=='finder':
        nav=w*.24;s+=rect(0,32,nav,h-32,'#edf1f3')
        for j,ss in enumerate(['个人收藏','最近使用','下载','文稿','图片','项目']):s+=txt(15,63+j*27,ss,10,'#83929e')
        fw=(w-nav-50)/3
        for r in range(3):
            for c in range(3):
                xx=nav+22+c*fw;yy=63+r*94
                s+=f'<path d="M{xx} {yy+4}h20l8 8h{fw-44}v36h-{fw-16}z" fill="#a9c6d8"/>'+txt(xx+fw/2-8,yy+65,['设计参考','产品资料','截图'][c],9,'#7a8996',400,'middle')
    elif app=='chat':
        pad=30;s+=txt(pad,71,'讨论',19,'#35434a',550)+txt(pad,93,'把想法接着说下去。',10,'#87928f')
        bw=min(280,w-90);s+=rect(w-pad-bw,119,bw,50,'#edf1ee',13)+para(w-pad-bw+14,139,'先核对默认的宽度和透明度。',bw-25,11,18,'#687b70',2)
        lines=['让文字所在的底板更白一些，','保留外沿的环境色和柔和边界。','窗口缩略图保持自己的颜色。','不需要为了看清内容，反复调参数。']
        for j,ss in enumerate(lines):s+=txt(pad,211+j*24,ss,11,'#7d8983')
        s+=rect(pad,h-63,w-2*pad,39,'#f9faf7',14,'#dce4dd',1)+txt(pad+14,h-39,'继续讨论…',10,'#a0aba3')
    elif app=='video':
        s+=rect(0,32,w,h-32,'#283d4a')
        s+=f'<ellipse cx="{w*.5}" cy="{h*.53}" rx="{w*.3}" ry="{h*.2}" fill="none" stroke="#9cb8b82e"/>'+circle(w*.5,h*.53,min(w,h)*.14,'#8aa3a3')
        s+=line(20,h-22,w-20,h-22,'#9ebbc4',2,.35)+circle(w*.44,h-22,3,'#d8e3e3')
    else:
        s+=rect(0,32,w,29,'#fafbfc')+rect(72,38,w-136,16,'#eef0f2',4)+txt(w/2,49,'design-notes.example / workspace',8,'#9aa3ad',400,'middle')
        pad=28;s+=txt(pad,102,'让工作，留在手边。',22,'#35444e',550)+txt(pad,126,'窗口、文字与刚刚留下的内容，在同一侧接续。',10,'#7f8b94')
        s+=rect(pad,148,w-2*pad,105,'#dce5e8',7)
        s+=f'<path d="M{pad} 222Q{w*.35} 160 {w-pad} 213V253H{pad}Z" fill="#b7cbd4"/><path d="M{pad} 236Q{w*.5} 194 {w-pad} 239V253H{pad}Z" fill="#97b4c3"/>'
        s+=txt(pad,285,'从清楚的边界开始',13,'#556671',550)
        s+=para(pad,311,'一个安静的界面，让内容成为主角。\n需要时，回到刚才的窗口；有想法时，先把它记下来。',w-2*pad,10,19,'#8a969e',4)
    body=a.wrap(s,clip=clip)
    return a.wrap(body,transform=f'translate({n(x)} {n(y)})',filter_id='winshadow' if shadow else None)

def source_window(a,app,source_w,source_h,title=None,fullscreen=False):
    """A source object is defined once and referenced by desktop and all previews."""
    key=(app,n(source_w),n(source_h),title,fullscreen)
    if key in a.sources:return a.sources[key]
    uid=a.uid()
    if fullscreen:
        content=a.wrap(window(a,0,0,source_w,source_h+32,app,title),transform='translate(0 -32)')
        content=a.wrap(content,clip=a.clip(0,0,source_w,source_h,2))
    else:content=window(a,0,0,source_w,source_h,app,title)
    a.defs.append(f'<g id="{uid}" data-source-app="{app}" data-source-width="{n(source_w)}" data-source-height="{n(source_h)}">{content}</g>')
    a.sources[key]=uid
    return uid

def tile_window(a,x,y,w,h,app,source_w=600,source_h=424,title=None,fullscreen=False):
    scale=min(w/source_w,h/source_h)
    xx=x+(w-source_w*scale)/2;yy=y+(h-source_h*scale)/2
    uid=source_window(a,app,source_w,source_h,title,fullscreen)
    return a.wrap(f'<use xlink:href="#{uid}"/>',transform=f'translate({n(xx)} {n(yy)}) scale({n(scale)})',filter_id='smallshadow')

def scene_fixture(work_w,work_h,scene='four',apps=None,ratio=None):
    """Immutable illustrative object inventory, with frames relative to WorkRect."""
    gap=TOKENS['referenceFixture']['windowGutter']
    apps=apps or (['browser','notes','code','chat'] if scene in ['four','lived'] else ['browser','code'])
    frames=[]
    if scene=='lived':
        frames=[(0,30,work_w*.65,work_h*.86),(work_w*.62,0,work_w*.38,work_h*.69),(work_w*.35,work_h*.43,work_w*.65,work_h*.57),(work_w*.12,work_h*.27,work_w*.46,work_h*.69)]
    elif len(apps)==1:frames=[(0,0,work_w,work_h)]
    elif len(apps)>=4:
        frames=[((j%2)*(work_w+gap)/2,(j//2)*(work_h+gap)/2,(work_w-gap)/2,(work_h-gap)/2) for j in range(len(apps))]
    else:
        fraction=2/3 if scene=='asymmetric' else .5
        first=(work_w-gap)*fraction
        frames=[(0,0,first,work_h),(first+gap,0,work_w-first-gap,work_h)]
    return [{'id':f'{app}-{j+1}','app':app,'frame':list(frame),'sourceSize':[frame[2],frame[3]],'birthOrdinal':j+1} for j,(app,frame) in enumerate(zip(apps,frames))]

def project_scene(a,x,y,w,h,members,viewport,fullscreen=False):
    """One uniform transform for all members, including their gaps and overlap."""
    vw,vh=viewport;scale=min(w/vw,h/vh);ox=x+(w-vw*scale)/2;oy=y+(h-vh*scale)/2
    body=''
    for member in members:
        fx,fy,fw,fh=member['frame'];sw,sh=member['sourceSize']
        uid=source_window(a,member['app'],sw,sh,fullscreen=fullscreen)
        body+=a.wrap(f'<use xlink:href="#{uid}"/>',transform=f'translate({n(fx)} {n(fy)})')
        a.projections.append({'id':member['id'],'source':uid,'sourceSize':[sw,sh],'frame':member['frame'],'scale':scale,'projectedFrame':[ox+fx*scale,oy+fy*scale,fw*scale,fh*scale]})
    body=a.wrap(body,clip=a.clip(0,0,vw,vh,0))
    return a.wrap(body,transform=f'translate({n(ox)} {n(oy)}) scale({n(scale)})')

def voice(a,x,y,w,h=144,paused=False,dark=False):
    ink=T['primaryColorDark' if dark else 'primaryColorLight'];sec=T['secondaryColorDark' if dark else 'secondaryColorLight']
    s=''
    if not paused:s+=para(x+12,y+26,'把设计系统的更新内容整理成一份简要汇报，重点包括组件优化和交互调整。',w-24,T['primarySize'],T['primaryLineHeight'],ink,4)
    cy=y+h-40 if not paused else y+6
    if not paused:
        s+=rect(x+12,cy,30,27,'#fff' if not dark else '#53585e',9,alpha=.48)+icon('copy',x+19,cy+5,16,sec)
    s+=rect(x+w-60,cy,48,27,'#fff' if not dark else '#53585e',14,alpha=.45)
    if paused:s+=icon('play',x+w-43,cy+6,14,sec)
    else:
        for j,hh in enumerate([6,12,17,11,6]):s+=rect(x+w-49+j*5,cy+(27-hh)/2,2.5,hh,sec,1.25)
    return s

def tray(a,x,y,w,h=144,compact=False,empty=False,dark=False,cells=None):
    s='';gap=L['trayCellGap'];pad=L['trayInset'];cols=(w-2*pad-gap)/2
    cells=cells or (['camera','folder'] if empty else (['browser','file'] if compact else ['browser','code','camera','file']))
    rows=1 if len(cells)<=2 else 2;ch=(h-2*pad-gap*(rows-1))/rows
    for j,app in enumerate(cells):
        xx=x+pad+(j%2)*(cols+gap);yy=y+pad+(j//2)*(ch+gap)
        if app in ['camera','folder']:
            s+=rect(xx,yy,cols,ch,'#fff' if not dark else '#c6d0d8',9,alpha=.18 if not dark else .06)
            s+=icon(app,xx+(cols-21)/2,yy+(ch-21)/2,21,'#c4d0d9' if dark else '#657581')
        elif app=='file':
            s+=rect(xx,yy,cols,ch,'#fcfcfb' if not dark else '#30363b',7,'#c6cdd333' if not dark else '#ffffff16',L['hairlinePt'])
            s+=rect(xx+cols/2-13,yy+ch/2-21,26,36,'#fff',3,'#dce2e6',.5)+f'<path d="M{xx+cols/2+5} {yy+ch/2-21}l8 8h-8z" fill="#edf0f2"/>'
            s+=rect(xx+cols/2-17,yy+ch/2-1,28,11,'#976c5b',2)+txt(xx+cols/2-3,yy+ch/2+7,'PDF',6.5,'#fff',550,'middle')
        else:
            s+=rect(xx,yy,cols,ch,'#f8fafb' if not dark else '#30363b',7,alpha=.28)
            s+=tile_window(a,xx+1,yy+1,cols-2,ch-2,app)
    return s

def memo(a,x,y,w,dark=False,tasks=False):
    ink=T['primaryColorDark' if dark else 'primaryColorLight'];sec=T['secondaryColorDark' if dark else 'secondaryColorLight'];s=''
    if tasks:
        for j,ss in enumerate(['整理参考图','核对默认比例','完成原生验收']):
            yy=y+17+j*31;s+=rect(x+12,yy,12,12,'#8194a0' if j==0 else 'none',3,'#a9b5bc',.8)
            if j==0:s+=icon('check',x+13,yy+1,10,'#fff')
            s+=txt(x+33,yy+11,ss,13,sec if j==0 else ink)
    else:
        s+=para(x+12,y+26,'周五前完成界面定稿。\n先核对宽度与玻璃。',w-24,14,20,ink,3)
        s+=txt(x+12,y+101,'128 × 3 =',13,sec)+rect(x+83,y+85,35,22,'#7b8991',4,alpha=.12)+txt(x+100.5,y+101,'384',13,ink,500,'middle')+icon('close',x+124,y+90,12,sec)
    return s

def thumb_card(a,x,y,w,kind='window',apps=None,title=None,selected=False,dark=False,work_ratio=1.4,label=None,ratio=None,fullscreen_ratio=1.6,members=None,viewport=None,state=None,density='balanced',contrast=False):
    apps=apps or ['browser'];inner=w-8
    aspect=ratio or (fullscreen_ratio if kind in ['fullscreen','splitfull'] else work_ratio)
    independent=kind in ['window','portrait','unavailable']
    source_w,source_h=(320,860) if kind=='portrait' else (600,600/aspect)
    if members and independent:source_w,source_h=members[0]['sourceSize'];aspect=source_w/source_h
    ph=min(inner/aspect,inner*L['independentImageHeightPerWidth']) if independent and density!='source' else inner/aspect
    if kind=='portrait' and density=='source':ph=inner/work_ratio
    total=ph+L['previewBadgeTail'];px=x+4;py=y+4
    state=state or ('selected' if selected else 'normal')
    fill='#fff' if not dark else '#dce5ec'
    border='#97a5b0' if not dark else '#c2cdd5'
    surface={'normal':.08,'hover':.24,'selected':.28,'pressed':.38,'focus':.23,'drop':.26}.get(state,.08)
    s=rect(x,y,w,total,fill,10,alpha=surface if not dark else surface*.25)
    if state in ['selected','pressed','focus','drop']:
        stroke=TOKENS['material']['contrast']['borderDark' if dark else 'borderLight'] if contrast else border
        sw=L['selectionStrokePt'] if state!='focus' else L['focusStrokePt']
        if state=='focus':stroke='#78A8DD' if dark else '#497FAB'
        s+=rect(x+.5,y+.5,w-1,total-1,'none',10,stroke,sw)
    if kind=='unavailable':
        s+=rect(px,py,inner,ph,'#e5eaed' if not dark else '#343d45',6)+txt(px+inner/2,py+ph/2+4,'预览暂不可用',11,'#65737e' if not dark else '#d0d9df',400,'middle')
    elif kind in ['group','space','quad','asymmetric','splitfull']:
        viewport=viewport or (1000,1000/aspect)
        members=members or scene_fixture(*viewport,scene=kind,apps=apps)
        s+=rect(px,py,inner,ph,'#dce4e8' if not dark else '#4b545e',6,alpha=.25)
        s+=project_scene(a,px,py,inner,ph,members,viewport,fullscreen=kind=='splitfull')
    else:
        s+=tile_window(a,px,py,inner,ph,apps[0],source_w,source_h,title=title,fullscreen=kind=='fullscreen')
        if members:
            fit=min(inner/source_w,ph/source_h)
            a.projections.append({'id':members[0]['id'],'source':source_window(a,apps[0],source_w,source_h,title),'sourceSize':[source_w,source_h],'scale':fit,'slot':[px,py,inner,ph],'projectedSize':[source_w*fit,source_h*fit]})
    if label:
        lw=sum(5 if ord(c)<128 else 9 for c in label)+12
        s+=rect(px+4,py+4,lw,16,'#263643',4,alpha=.8)+txt(px+10,py+15,label,9,'#fff')
    xx=x+w/2-(len(apps)*20+(len(apps)-1)*3)/2
    for j,app in enumerate(apps):s+=app_icon(app,xx+j*23,py+ph-6,20)
    return s,total

def rail(a,x,y,w,h,wall_id,tools=2,glass='balanced',dark=False,paused=False,compact=False,scene='four',screen=(1440,900),empty=False,window_ratio=None,blurred_wall_id=None,fixture=None,preview_density='balanced',contrast=False,tool_order=None,active_id=None):
    material=TOKENS['material'];palette=material['dark']
    reduced=glass=='reduceTransparency'
    if dark:shell_a,card_a=palette['shell'],palette['textSurface'];shell=palette['shellColor'];card=palette['textSurfaceColor']
    else:shell_a,card_a=[material[glass][v] for v in ['shell','textSurface']] if not reduced else (1,1);shell=card='#fff'
    if reduced:
        shell_a=card_a=1;shell=material['reduced']['shellColorDark' if dark else 'shellColorLight'];card=material['reduced']['textSurfaceColorDark' if dark else 'textSurfaceColorLight']
    pad=L['outerInset'];cw=w-2*pad;hair=L['hairlinePt']
    clip=a.clip(x,y,w,h,L['shellRadius'])
    # Shadows only belong to surface shapes. Foreground is a separate sibling.
    a.add(a.wrap(rect(x,y,w,h,'#152430',L['shellRadius']),filter_id='shellshadow'))
    bg=f'<use xlink:href="#{blurred_wall_id}"/>' if blurred_wall_id else f'<use xlink:href="#{wall_id}" filter="url(#blur)"/>'
    a.add(a.wrap(bg,clip=clip))
    cursor=y+pad;ms=[]
    order=tool_order or ['voice','tray','memo','tasks'][:tools]
    for name in order:
        if name=='voice':hh=M['voicePausedHeight' if paused else 'voiceActiveHeight']
        elif name=='tray':hh=M['trayOneRowHeight' if compact or empty else 'trayTwoRowHeight']
        else:hh=M[name+'Height']
        ms.append((name,cursor,hh));cursor+=hh+L['toolGap']
    # One blurred backdrop. Shell holes prevent double tinting under text cards.
    mask=a.uid();a.defs.append(f'<mask id="{mask}">{rect(x,y,w,h,"white",L["shellRadius"])}'+''.join(rect(x+pad,yy,cw,hh,'black',L['toolRadius']) for _,yy,hh in ms)+'</mask>')
    a.add(rect(x,y,w,h,shell,L['shellRadius'],alpha=shell_a,extra=f'mask="url(#{mask})"'))
    for name,yy,hh in ms:
        a.add(f'<g mask="url(#{mask})">'+a.wrap(rect(x+pad,yy,cw,hh,card,L['toolRadius']),filter_id='cardshadow')+'</g>')
        edge=material['contrast']['borderDark' if dark else 'borderLight'] if contrast else ('#ffffff85' if not dark else palette['hairline'])
        sw=material['contrast']['hairlinePt'] if contrast else hair
        a.add(rect(x+pad,yy,cw,hh,card,L['toolRadius'],edge,sw,alpha=card_a))
        a.add(line(x+pad+L['toolRadius'],yy+.5,x+w-pad-L['toolRadius'],yy+.5,'#fff',hair,.52 if not dark else .12))
        if name=='voice':a.add(voice(a,x+pad,yy,cw,hh,paused,dark))
        elif name=='tray':a.add(tray(a,x+pad,yy,cw,hh,compact,empty,dark))
        else:a.add(memo(a,x+pad,yy,cw,dark,name=='tasks'))
    a.add(rect(x+.25,y+.25,w-.5,h-.5,'none',L['shellRadius'],'#ffffffb8' if not dark else '#ffffff35',hair))
    listclip=a.clip(x+pad-2,cursor-2,cw+4,max(0,y+h-pad-cursor+2),3)
    _,_,work_w,work_h=fixture_work_rect(screen[0],screen[1],w);workratio=work_w/work_h
    inventory=fixture or scene_fixture(work_w,work_h,scene='lived' if scene=='lived' else 'four')
    cards=[]
    if empty:
        a.add(txt(x+w/2,cursor+24,'这个桌面还没有窗口',12,'#667580',400,'middle'))
        return {'listY':round(cursor-y,2),'toolCount':len(order),'overflow':False,'lastY':round(cursor-y+30,2),'cards':[]}
    if scene=='tools':
        cards=[]
    elif scene in ['group','spaces']:
        group=fixture or scene_fixture(work_w,work_h,scene='group')
        cards=[{'kind':'group','members':group,'apps':[m['app'] for m in group],'viewport':(work_w,work_h)}]
        if scene=='group':cards.append({'kind':'window','apps':['notes']})
        cards += [{'kind':'separator'},{'kind':'space','apps':['notes'],'label':'桌面 2'},{'kind':'fullscreen','apps':['video'],'label':'全屏'}]
        if scene=='spaces':cards.append({'kind':'space','apps':['browser','code'],'label':'桌面 4'})
    else:
        cards=[{'kind':'window','apps':[m['app']],'members':[m]} for m in inventory]
        if scene=='many':cards += [{'kind':'window','apps':[app]} for app in ['finder','notes','browser','chat','browser']]
    body='';start=cursor;positions=[]
    for j,c in enumerate(cards):
        kind=c['kind']
        if kind=='separator':body+=line(x+pad+5,cursor+3,x+w-pad-5,cursor+3,'#7b8a94',.5,.24);cursor+=16;continue
        cs,hh=thumb_card(a,x+pad,cursor,cw,selected=(any(m['id']==active_id for m in c.get('members',[])) if active_id else j==0),dark=dark,work_ratio=workratio,ratio=window_ratio if kind=='window' and not c.get('members') else None,fullscreen_ratio=screen[0]/screen[1],density=preview_density,contrast=contrast,**c)
        positions.append({'kind':kind,'top':round(cursor-y,2),'height':round(hh,2),'members':[m['id'] for m in c.get('members',[])],'fullyVisible':cursor+hh<=y+h-pad})
        body+=cs;cursor+=hh+L['windowGap']
    a.add(a.wrap(body,clip=listclip))
    overflow=cursor-L['windowGap']>y+h-pad
    # The static thumb shows the scroll affordance only when content exceeds the viewport.
    if overflow:a.add(rect(x+w-5,y+h-65,2,43,'#61717f' if not dark else '#b8c4cf',1,alpha=.3))
    return {'listY':round(start-y,2),'toolCount':len(order),'toolOrder':order,'overflow':overflow,'lastY':round(cursor-y,2),'cards':positions,'sourceInventory':inventory}

def menu(a,w,active_app='Safari'):
    a.add(rect(0,0,w,27,'#f7f9fb',alpha=.52))
    # Neutral desktop menu chrome; no invented Nearpane header.
    a.add(circle(22,14,5.4,'#31404b')+f'<path d="M23 6q1-4 5-3-1 4-5 4" fill="#31404b"/>')
    x=43
    labels = ([active_app,'文件','编辑','选择','查看','转到','运行','终端','窗口','帮助']
              if active_app == 'Code' else [active_app,'文件','编辑','显示','历史记录','书签','窗口','帮助'])
    for j,s in enumerate(labels):
        a.add(txt(x,18,s,11,'#33414d',600 if j==0 else 400))
        x += max(44, len(s) * (6.5 if s.isascii() else 11) + 18)
    a.add(icon('wifi',w-232,6,15,'#435461')+rect(w-205,9,18,9,'none',2,'#435461',1)+rect(w-202,11,11,5,'#435461',1)+txt(w-172,18,'11月18日 周三  09:41',11,'#435461'))

def desktop(name='01-default-desktop',tools=2,w=1440,h=900,panel=None,scene='four',dark=False,wall='blue',paused=False):
    if panel is None:panel=default_width(w)
    a=Art(w,h);wall_id=wallpaper(a,w,h,wall);a.add(f'<use xlink:href="#{wall_id}"/>');menu(a,w,'Code' if scene=='lived' else 'Safari')
    wx,wy,ww,wh=fixture_work_rect(w,h,panel)
    members=scene_fixture(ww,wh,scene if scene in ['four','lived'] else 'group')
    paint=members if scene!='lived' else [members[j] for j in [0,1,3,2]]
    for member in paint:
        fx,fy,fw,fh=member['frame'];uid=source_window(a,member['app'],fw,fh)
        a.add(a.wrap(f'<use xlink:href="#{uid}"/>',transform=f'translate({n(wx+fx)} {n(wy+fy)})',filter_id='winshadow'))
    geometry=rail(a,w-panel,33,panel,h-39,wall_id,tools=tools,dark=dark,paused=paused,scene=scene,screen=(w,h),fixture=members,active_id='code-3' if scene=='lived' else None)
    geometry.update({'screen':[w,h],'panelWidth':panel,'workRect':[wx,wy,ww,wh],'projections':a.projections})
    a.save(name);return geometry

def board_head(a,kicker,title,desc):
    a.add(rect(0,0,a.w,a.h,'#f5f5f3'))
    a.add(txt(42,43,kicker,10,'#85909a',500,extra='letter-spacing="1.8"'))
    a.add(txt(42,84,title,29,'#29343b',550))
    a.add(txt(42,113,desc,12,'#7d878e'))
def board_foot(a,left,right='NEARPANE  /  R4  /  2026.11.18'):
    a.add(line(42,a.h-62,a.w-42,a.h-62,'#d9dfe1',.8)+txt(42,a.h-37,left,10,'#7d888f')+txt(a.w-42,a.h-37,right,10,'#8d979e',400,'end'))
def sample(a,x,top,w,h,title,sub,footer,**kw):
    a.add(txt(x,top,title,14,'#35424c',550)+txt(x,top+23,sub,10,'#859099'))
    yy=top+42;bleed=TOKENS['material']['blurStdDeviationPt']*4
    local_wall=wallpaper(a,w+bleed*2,h+bleed*2,kw.pop('wall','blue'));wall=a.uid()
    a.defs.append(f'<g id="{wall}" transform="translate({n(x-bleed)} {n(yy-bleed)})"><use xlink:href="#{local_wall}"/></g>')
    blurred_wall=a.uid()
    a.defs.append(f'<g id="{blurred_wall}" transform="translate({n(x-bleed)} {n(yy-bleed)})"><use xlink:href="#{local_wall}" filter="url(#blur)"/></g>')
    cl=a.clip(x,yy,w,h,L['shellRadius'])
    a.add(a.wrap(f'<use xlink:href="#{wall}"/>',clip=cl))
    g=rail(a,x,yy,w,h,wall,blurred_wall_id=blurred_wall,**kw)
    a.add(para(x,yy+h+24,footer,w,10,17,'#7c8790',3))
    return g

def width_board():
    a=Art(1200,1180);board_head(a,'NEARPANE / WIDTH','默认先合适，再允许调整。','同一块 1440 × 900 pt 屏幕；正文始终为 14 pt，预览按真实比例变化。')
    cols=[(110,180,'紧凑 · 1/8','180 pt · 屏宽 12.5%','同样四格内容，字号不缩小；按需滚动。',False),(350,240,'推荐默认','240 pt · 屏宽 16.7%','中文正文与两列托盘都有足够宽度。',False),(650,360,'宽幅 · 1/4','360 pt · 屏宽 25%','缩略图自然变大，不再固定为 96 pt 高。',False)]
    gs=[];fixed=scene_fixture(1176,849,'four')
    for x,w,title,sub,foot,compact in cols:gs.append(sample(a,x,164,w,840,title,sub,foot,compact=compact,screen=(1440,900),fixture=fixed))
    board_foot(a,'内边距 12 pt · 模块间距 10 pt · 宽度不随内容自动改变');a.save('03-width-comparison');return gs

def glass_board():
    a=Art(1200,1020);board_head(a,'NEARPANE / MATERIAL','玻璃留给环境，白底承托文字。','同一复杂背景、同一内容、同一宽度；只改变背景的遮蔽强度。')
    specs=[('清透','0.48 / 0.82','airy',False,'透色更多，文字底板仍有稳定白度。'),('标准 · 默认','0.58 / 0.88','balanced',False,'外沿有环境感，文字区域更白、更清楚。'),('清晰','0.72 / 0.94','clear',False,'减少繁杂底色对内容的干扰。'),('深色外观','同一几何 · 中性深灰','balanced',True,'前景与图像保持不透明，不加入紫色染色。')]
    gs=[]
    for j,(title,sub,glass,dark,foot) in enumerate(specs):gs.append(sample(a,42+j*282,161,258,685,title,sub,foot,wall='busy',glass=glass,dark=dark,compact=True,screen=(1440,900)))
    board_foot(a,'数值为参考渲染器的背景覆盖率，不是现有原生设置的透明度百分比。','文字 / 图标 / 图片：alpha = 1');a.save('04-material-comparison');return gs

def layout_board():
    a=Art(1200,1200);board_head(a,'NEARPANE / LAYOUT','工具先显示，窗口紧接其后。','工具按实际高度占位；列表从上向下，余量自然留在底部。')
    specs=[('两个工具','语音 + 截图 / 文件',2,False,'four','四个独立窗口，按打开顺序依次排列。'),('三个工具','再加入备忘录',3,False,'four','第三个工具完整显示，窗口列表随之下移。'),('语音明确暂停','单行收起，记录保留',3,True,'four','主动暂停才收起；短暂静音不让布局跳动。'),('明确双窗组合','真实分屏布局，一张合成图',2,False,'group','明确组合后共用一张预览；成员可以分别点选。')]
    gs=[]
    for j,(title,sub,tools,paused,scene,foot) in enumerate(specs):gs.append(sample(a,42+j*282,166,258,850,title,sub,foot,tools=tools,paused=paused,scene=scene,screen=(1440,900)))
    board_foot(a,'不居中、不从底部起排、不再固定 3/8 工具区。');a.save('02-layout-comparison');return gs

def states_board():
    a=Art(1200,1100);board_head(a,'NEARPANE / STATES','一张缩略图，必须说清它代表什么。','窗口、明确的组合、原生桌面与全屏，具有不同且可预测的含义。')
    specs=[('普通单窗','window',['browser'],'按源窗口比例显示，不强行铺成整张桌面。',None),('明确双窗组合','group',['browser','code'],'真实 1:1 分屏，共用同一坐标缩放。',None),('不对称分屏','asymmetric',['browser','notes'],'真实 2:1，不能为了整齐重新平均。',None),('原生全屏','fullscreen',['video'],'独立系统 Space，采用完整屏幕比例。','全屏'),('明确四窗组合','quad',['browser','notes','code','chat'],'明确成组才合成；独立四窗仍为四张卡。',None),('高窄窗口','portrait',['notes'],'保持长宽比例，不拉宽，不裁掉正文。',None),('另一原生桌面','space',['browser','notes'],'轻标识说明这是桌面，不与窗口卡混淆。','桌面 2'),('暂时没有画面','unavailable',['browser'],'保留真实对象，不伪装成空桌面。',None)]
    for j,(title,kind,apps,desc,label) in enumerate(specs):
        x=42+(j%4)*282;y=160+(j//4)*258
        a.add(txt(x,y,title,13,'#40505b',550))
        a.add(rect(x,y+16,258,188,'#e8edef',13))
        s,hh=thumb_card(a,x+16,y+25,226,kind,apps,work_ratio=1.45,label=label)
        a.add(s);a.add(para(x,y+226,desc,258,10,17,'#7d8891',2))
    a.add(txt(42,724,'新增工具延续原来的安静外观',19,'#35434d',550))
    for j,(title,kind) in enumerate([('托盘空态 · 只有两格','empty'),('空间紧张 · 各留最新一项','compact'),('备忘录 · 临时计算','memo'),('可选待办 · 内容直接出现','tasks')]):
        x=42+j*282;y=760;a.add(txt(x,y,title,12,'#5f6e79'));a.add(rect(x,y+18,258,160,'#e6ebed',18));a.add(rect(x+12,y+30,234,128 if kind in ['memo','tasks'] else 76,'#fff',L['toolRadius'],alpha=.88))
        if kind in ['empty','compact']:a.add(tray(a,x+12,y+30,234,76,True,kind=='empty'))
        else:a.add(memo(a,x+12,y+30,234,tasks=kind=='tasks'))
    a.add(txt(42,978,'文件空入口只定义位置，点击用途待定；计算归备忘录，翻译在原词附近出现。',11,'#7d8891'))
    board_foot(a,'所有窗口画面都是设计示例；原生状态、几何与交互须由真实系统验证。');a.save('05-state-reference')

def focus_board():
    a=Art(1200,1120);board_head(a,'NEARPANE / REFERENCE','原来的形态，更新后的完整秩序。','中性白色磨砂外壳、清楚的正文、真实的窗口比例；没有新的标题栏或品牌装饰。')
    w=320;h=850;x=440;y=150;wall=wallpaper(a,1200,1060,'blue')
    a.add(a.wrap(f'<use xlink:href="#{wall}"/>',clip=a.clip(x-32,y-10,w+64,h+20,30)))
    geo=rail(a,x,y,w,h,wall,tools=3,scene='group',screen=(1920,1080))
    # Annotations live outside the product.
    pairs=[(214,'144 pt 语音区','连续文字流；两枚原有控件。',y+84),(386,'最多四格统一托盘','截图从前进入，文件留在末端。',y+228),(562,'可选第三个工具','备忘与临时计算直接显示内容。',y+374),(756,'调度紧随工具','独立窗口按打开顺序；组合保留布局。',y+522),(925,'连续外壳','标准白底承托文字，环境色留在外沿。',y+744)]
    for yy,title,desc,target in pairs:
        left=yy in [214,562,925]
        xx=58 if left else 815
        a.add(txt(xx,yy,title,15,'#43515d',550)+para(xx,yy+24,desc,290,11,18,'#7c8993',2))
        if left:a.add(line(346,yy-4,x-10,target,'#a8b6c0',.8)+circle(x-10,target,2,'#a8b6c0'))
        else:a.add(line(x+w+10,target,795,yy-4,'#a8b6c0',.8)+circle(x+w+10,target,2,'#a8b6c0'))
    board_foot(a,'本页为细节放大图；全屏母稿才用于判断默认占屏比例。');a.save('06-annotated-detail')

def boundaries_board():
    a=Art(1200,1020);board_head(a,'NEARPANE / NATIVE STATES','普通组合和原生分屏，使用各自真实的边界。','原生全屏与 Split View 使用完整显示器；空态与降低透明度保持相同的结构。')
    pairs=[('原生全屏','fullscreen',['video'],'全屏'),('原生 Split View','splitfull',['browser','notes'],'分屏')]
    for j,(title,kind,apps,label) in enumerate(pairs):
        x=42+j*282;y=162;a.add(txt(x,y,title,14,'#35424c',550));a.add(rect(x,y+20,258,190,'#e8edef',14))
        s,_=thumb_card(a,x+16,y+30,226,kind,apps,label=label,fullscreen_ratio=1440/900);a.add(s)
        a.add(para(x,y+235,'同为 1440 × 900 pt 的真实系统 Space；预览不再减去侧栏预留宽。',258,11,18,'#7d8891',3))
    a.add(txt(42,501,'两种分屏，点击不改布局。',21,'#35424c',550))
    a.add(para(42,538,'普通组合仍在 WorkRect 内，窗口与侧栏互不占位。原生 Split View 属于系统全屏 Space，两个应用共享完整显示器。',520,14,23,'#586975',4))
    a.add(para(42,670,'这里展示的是在普通桌面上看到的其他 Space 缩略图。进入原生全屏后，Nearpane 按既有策略隐藏，不把完整侧栏强行挤进全屏。',520,14,23,'#586975',4))
    a.add(para(42,801,'预览不可用：保留对象与可用操作。\n真正空桌面：只显示轻量空态，不绘制假窗口。',520,13,22,'#7d8891',4))
    sample(a,642,162,240,685,'空桌面 / 空托盘','1440 × 900 pt · 默认宽度','仅存在真实窗口或其他 Space 时，才生成对应预览。',empty=True,screen=(1440,900))
    sample(a,918,162,240,685,'降低透明度','不透明系统背景','前景、工具顺序、字号和缩略图比例保持一致。',glass='reduceTransparency',compact=True,screen=(1440,900))
    board_foot(a,'本页补全原生 Split View、真正空态和系统降低透明度；不是已完成的原生验收。');a.save('09-native-and-accessibility')

def interactions_board():
    a=Art(1200,1020)
    board_head(a,'NEARPANE / FEEDBACK','有反馈，也保持安静。','常态、悬停、选中和键盘焦点各司其职；任何状态都不稀释内容、不改变卡片位置。')
    styles=[('常态','normal','不描深框，内容与玻璃边界可辨。'),('悬停','hover','轻提亮，命中范围与常态一致。'),('当前窗口','selected','0.75 pt 中性轮廓，确认当前对象。'),('键盘焦点','focus','独立焦点环，不与当前窗口混淆。')]
    for j,(title,state,desc) in enumerate(styles):
        x=42+j*282;y=167;a.add(txt(x,y,title,14,'#35424c',550))
        a.add(rect(x,y+22,258,173,'#dce5eb',18))
        body,hh=thumb_card(a,x+13,y+37,232,state=state,work_ratio=1.4)
        a.add(body);a.add(para(x,y+222,desc,258,11,19,'#6c7882',2))
    a.add(txt(42,479,'操作中的信息，只在需要时出现。',23,'#35424c',550))
    samples=[('附加处理中','progress','仍保留原对象，收到接收回执后才退场。'),('附加失败 · 原项恢复','error','缩略图回到原位置，可再次尝试。'),('文件名 · 悬停显示','filename','类型图标提供初筛，完整名称按需显示。'),('窗口拖动 · 落点反馈','drop','只反馈目标；放下后执行，失败回原位。')]
    for j,(title,kind,desc) in enumerate(samples):
        x=42+j*282;y=521;a.add(txt(x,y,title,12,'#5f6e79'))
        a.add(rect(x,y+22,258,210,'#e5ebef',18))
        if kind=='drop':
            body,hh=thumb_card(a,x+13,y+37,232,'group',['browser','notes'],state='drop',work_ratio=1.5)
            a.add(body)
            a.add(rect(x+127,y+53,107,120,'#fff',6,'#687e8c',.75,alpha=.18,extra='stroke-dasharray="4 4"'))
        else:
            a.add(rect(x+12,y+39,234,144,'#fff',16,alpha=.88))
            a.add(tray(a,x+12,y+39,234,144))
            if kind=='progress':
                a.add(rect(x+18,y+99,102,3,'#9aabb7',1.5,alpha=.3)+rect(x+18,y+99,61,3,'#5f7585',1.5))
            elif kind=='error':
                a.add(circle(x+111,y+58,8,'#fff')+circle(x+111,y+58,6,'#a86650')+txt(x+111,y+61,'!',9,'#fff',600,'middle'))
            else:
                a.add(a.wrap(rect(x+72,y+185,172,26,'#fff',7,'#d2d9de',.5)+txt(x+84,y+202,'Nearpane 设计方案.pdf',10,'#42515d'),filter_id='smallshadow'))
        a.add(para(x,y+261,desc,258,11,19,'#6c7882',3))
    a.add(line(42,877,1158,877,'#d7dfe3',.5))
    a.add(txt(42,910,'悬停 120 ms · 状态变化 160 ms · 主动收起 180 ms · 系统减少动态效果时取消位移动画',12,'#53636f'))
    board_foot(a,'按下与拖动期间锁定对象身份；新内容在手势结束后再进入布局。')
    a.save('13-interaction-states')


def stress_board():
    a=Art(1200,1020)
    board_head(a,'NEARPANE / ENVIRONMENT','换一张桌面，文字仍有稳定的底板。','相同正文与托盘；浅色、深色、复杂背景，以及系统辅助显示分别对照。')
    samples=[('浅色桌面','paper',False,False,False),('深色桌面','ink',False,False,False),('复杂桌面','busy',False,False,False),('深色外观','busy',True,False,False),('降低透明度','busy',False,True,False),('增强对比度','busy',False,False,True)]
    gs=[]
    for j,(title,wall,dark,reduced,contrast) in enumerate(samples):
        x=84+(j%3)*364;top=169+(j//3)*365
        sub='同一默认光学目标' if j<3 else ('独立深色参数 0.72 / 0.94' if dark else ('背景实色，内容保持' if reduced else '边界 1 pt，结构保持'))
        gs.append(sample(a,x,top,304,254,title,sub,'',wall=wall,tools=2,compact=True,scene='tools',glass='reduceTransparency' if reduced else 'balanced',dark=dark,contrast=contrast,screen=(1440,900)))
    board_foot(a,'外壳可以透出环境；正文、图标与图像保持不透明。光学参数仍需 AppKit 校准。')
    a.save('14-background-stress');return gs


def density_board():
    a=Art(1200,1240)
    board_head(a,'NEARPANE / PREVIEW DENSITY','同样的 240 pt，把窗口排得更从容。','同一对象、同一比例、同一正文与四格托盘。这里只改变独立窗口的预览密度。')
    fixtures=scene_fixture(1176,849,'four')
    left=sample(a,90,165,240,861,'全宽预览','R3 的密度规则','窗口完整，但同一视口能辨认的对象较少。',fixture=fixtures,preview_density='source')
    right=sample(a,442,165,240,861,'本轮默认','按宽度计算高度上限，再 Fit','四个普通窗口可见；正文与工具不压缩。',fixture=fixtures)
    a.add(txt(770,244,'保留比例，减少重复空白',23,'#35424c',550))
    a.add(para(770,289,'独立窗口预览槽的最大高度，为可用图宽的一半；源图只做等比缩放。',335,15,26,'#566772',4))
    a.add(para(770,444,'240 pt 侧栏：208 × 104 pt 图槽。\n窗口图像按原比例居中。\n应用图标完整保留在每行底部。',335,14,24,'#566772',5))
    a.add(para(770,623,'代价也清楚：较高窗口的文字会更小。需要辨认细节时，可在独立设置中放大预览，或加宽侧栏。',335,14,24,'#566772',5))
    a.add(para(770,810,'组合与原生 Space 仍使用各自统一坐标。较短屏幕、更多窗口或三个工具继续滚动，不承诺永远显示四项。',335,14,24,'#566772',5))
    board_foot(a,'密度规则只影响显示尺度，窗口数量不驱动压缩；默认是本轮设计选择。')
    a.save('15-density-comparison');return {'source':left,'balanced':right}


def make_all():
    geometry={}
    geometry['lived']=desktop('00-lived-desktop',scene='lived')
    geometry['default']=desktop()
    geometry['threeTools']=desktop('07-three-tools-desktop',tools=3)
    geometry['splitDesktop']=desktop('08-split-workspace-desktop',scene='spaces')
    geometry['width']=width_board()
    geometry['material']=glass_board()
    geometry['layout']=layout_board()
    states_board();focus_board();boundaries_board()
    interactions_board()
    geometry['stress']=stress_board()
    geometry['density']=density_board()
    from render_supplement import make_supplements
    geometry['supplements']=make_supplements()
    (ROOT/'render-measurements.json').write_text(json.dumps(geometry,ensure_ascii=False,indent=2))
    print(json.dumps({'svg_count':len(list(OUT.glob('*.svg'))),'output':str(OUT),'default_width':geometry['default']['panelWidth'],'default_complete_cards':sum(c['fullyVisible'] for c in geometry['default']['cards'])},ensure_ascii=False))

if __name__=='__main__': make_all()
