from pathlib import Path
from html import escape
ROOT=Path(__file__).resolve().parent
OUT=ROOT/'assets';OUT.mkdir(exist_ok=True)
FONT='-apple-system, BlinkMacSystemFont, PingFang SC, Noto Sans CJK SC, sans-serif'
C={'ink':'#312b3a','sub':'#6f5d7b','muted':'#6b5d73','accent':'#7051aa','accentbg':'#e7ddf4','outer':'#d9d1e8','surface':'#f6f2fb','line':'#ddd2e8','white':'#ffffff'}
D={'ink':'#e0d6e9','sub':'#c5afd8','muted':'#b39cc8','accent':'#b59ad6','accentbg':'#51405f','outer':'#43354f','surface':'#302735','line':'#584463','white':'#352b40'}
class SVG:
 def __init__(self,w,h,title):
  self.w=w;self.h=h;self.s=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><title>{escape(title)}</title><defs><linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#dcd6f0"/><stop offset=".45" stop-color="#d9d5ef"/><stop offset="1" stop-color="#a5b6da"/></linearGradient><linearGradient id="wave" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#b49ed3"/><stop offset=".65" stop-color="#cbc0e5"/><stop offset="1" stop-color="#c9d0ea"/></linearGradient><linearGradient id="wallDark" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#34253f"/><stop offset="1" stop-color="#28344b"/></linearGradient><linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#ffffff" stop-opacity=".97"/><stop offset="1" stop-color="#f4edff" stop-opacity=".87"/></linearGradient><filter id="shadow" x="-30%" y="-20%" width="160%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="15" flood-color="#574165" flood-opacity=".12"/></filter><filter id="soft" x="-30%" y="-20%" width="160%" height="150%"><feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#574165" flood-opacity=".12"/></filter></defs>'];self.count=0
 def raw(self,s):self.s.append(s)
 def rect(self,x,y,w,h,r=0,fill='none',stroke=None,sw=1,extra=''):
  self.raw(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"'+(f' stroke="{stroke}" stroke-width="{sw}"' if stroke else '')+f' {extra}/>')
 def text(self,x,y,t,size=14,color=None,weight=400,anchor='start',extra=''):
  if color and color.startswith('#') and len(color)==7 and color not in set(D.values()):
   rgb=[int(color[i:i+2],16)/255 for i in [1,3,5]]
   v=[z/12.92 if z<=.04045 else((z+.055)/1.055)**2.4 for z in rgb]
   lum=.2126*v[0]+.7152*v[1]+.0722*v[2]
   if (.901+.05)/(lum+.05)<4.5:color='#6b5d73'
  self.raw(f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" fill="{color or C["ink"]}" text-anchor="{anchor}" {extra}>{escape(str(t))}</text>')
 def lines(self,x,y,lines,size=14,color=None,line=21,weight=400):
  for i,t in enumerate(lines):self.text(x,y+i*line,t,size,color,weight)
 def line(self,x1,y1,x2,y2,color,sw=1,extra=''):self.raw(f'<path d="M{x1} {y1}L{x2} {y2}" stroke="{color}" stroke-width="{sw}" fill="none" {extra}/>')
 def circle(self,x,y,r,fill,stroke=None,sw=1):self.raw(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}"'+(f' stroke="{stroke}" stroke-width="{sw}"'if stroke else '')+'/>')
 def group(self,transform=''):self.raw(f'<g transform="{transform}">')
 def end(self):self.raw('</g>')
 def save(self,name):self.raw('</svg>');(OUT/name).write_text(''.join(self.s))

def board(s,index,title,subtitle):
 s.rect(0,0,s.w,s.h,fill='#f6f4f8');s.text(56,49,f'NEARPANE  /  {index}',12,'#8a7a98',550,extra='letter-spacing="2"');s.text(56,98,title,32,'#3f334b',520);s.text(57,130,subtitle,14,'#91819f');s.text(s.w-56,49,'DESIGNED · 高保真设计图',12,'#9f8eac',450,'end');s.line(56,s.h-72,s.w-56,s.h-72,'#e3dce9');s.text(56,s.h-43,'下一代交互提案 · 矢量设计资产，非原生或浏览器运行截图',12,'#9989a5');s.text(s.w-56,s.h-43,'2026.11',12,'#9f8eac',400,'end')

def wallpaper(s,x,y,w,h,dark=False,r=14):
 s.count+=1;clip='wallclip'+str(s.count);s.raw(f'<defs><clipPath id="{clip}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}"/></clipPath></defs>');s.raw(f'<g clip-path="url(#{clip})">');s.rect(x,y,w,h,fill='url(#wallDark)'if dark else'url(#wall)');s.raw(f'<path d="M{x-100} {y+h*.7} C{x+w*.2} {y+h*.22},{x+w*.65} {y+h*1.28},{x+w+90} {y+h*.48} L{x+w+90} {y+h+90} L{x-100} {y+h+90}Z" fill="'+('#665273'if dark else'url(#wave)')+'" opacity=".58"/>');s.end()

def icon(s,x,y,kind,color=None,scale=1):
 color=color or C['accent'];s.group(f'translate({x} {y}) scale({scale})')
 paths={'memo':'M4 2h12v16H4zM7 6h6M7 10h6M7 14h4','calc':'M2 5h6M5 2v6M12 5h6M3 12l5 5M8 12l-5 5M12 12h6M12 16h6','tasks':'M2 5l2 2 4-5M10 5h8M2 14l2 2 4-5M10 14h8','language':'M1 5h9M5 2v3M3 5c1 5 5 7 5 7M8 5c-1 4-4 6-6 7M11 18l3.5-10L18 18M12 14h5','copy':'M7 6h10v12H7zM13 3H3v12','expand':'M2 7V2h5M13 2h5v5M18 13v5h-5M7 18H2v-5','micro':'M7 3a3 3 0 016 0v7a3 3 0 01-6 0zM4 9a6 6 0 0012 0M10 15v4M7 19h6','file':'M4 2h8l5 5v11H4zM12 2v5h5','arrow':'M2 10h14M10 4l6 6-6 6','pause':'M6 3v14M14 3v14','camera':'M2 5h4l2-3h5l2 3h3v12H2zM6 11a4 4 0 108 0 4 4 0 10-8 0','music':'M7 15V4l9-2v11M7 5l9-2M7 15c0 4-6 4-6 1s6-4 6-1M16 13c0 4-6 4-6 1s6-4 6-1'}
 s.raw(f'<path d="{paths[kind]}" fill="none" stroke="{color}" stroke-width="1.45" stroke-linecap="round" stroke-linejoin="round"/>');s.end()

def tabs(s,x,y,w,active='memo',dark=False,only=False):
 c=D if dark else C
 for i,k in enumerate(['memo']if only else['memo','calc','tasks','language']):
  tx=x+i*w/4;s.rect(tx,y,w/4-3,28,6,c['accentbg']if k==active else'none');icon(s,tx+(w/4-3-16)/2,y+6,k,c['accent']if k==active else c['muted'],.8)
 s.line(x,y+37,x+w,y+37,c['line'])

def voice(s,x,y,w,compact=False,dark=False,permission=False):
 c=D if dark else C
 if permission:
  icon(s,x+w/2-10,y+8,'micro',c['muted']);s.lines(x+w/2,y+47,['开启麦克风后，','说出的内容会留在这里。'],12,c['sub'],19,400) if False else None
  s.text(x+w/2,y+48,'开启麦克风后，',12,c['sub'],400,'middle');s.text(x+w/2,y+68,'说出的内容',11,c['sub'],400,'middle');s.text(x+w/2,y+86,'会留在这里。',11,c['sub'],400,'middle');s.rect(x+w/2-44,y+102,88,26,6,fill='none',stroke=c['line']);s.text(x+w/2,y+120,'允许麦克风',11,c['accent'],500,'middle');return 142
 lines=['想法先留在这里，','下一步稍后再说。'] if compact else['我希望工具可以一直','在手边，但不需要一直','占据注意力。','','想法放下，','继续正在做的事。']
 s.lines(x,y+16,lines,14,c['ink'],21);h=len(lines)*21+16
 s.rect(x-3,y+h,29,28,8,fill=c['accentbg']);icon(s,x+4,y+h+5,'copy',c['accent'],.8)
 for i,hh in enumerate([6,11,17,11,14,7]):s.rect(x+w-60+i*3,y+h+14-hh/2,2,hh,1,c['accent'])
 s.circle(x+w-14,y+h+14,15,c['accentbg']);icon(s,x+w-22,y+h+5,'micro',c['accent'],.8)
 return h+34

def shot(s,x,y,w,h,variant=0,dark=False):
 c=D if dark else C;s.rect(x,y,w,h,6,fill='#bcb0ce'if dark else'#e2daee')
 if variant==3:icon(s,x+w/2-10,y+h/2-10,'camera',c['accent']);return
 ww=w*.86;hh=h*.75;xx=x+(w-ww)/2;yy=y+(h-hh)/2;s.rect(xx,yy,ww,hh,3,fill='#9a8aaa'if dark else'#fbf9fe',extra='filter="url(#soft)"');s.rect(xx,yy,ww,5,2,fill='#b4a4c6'if dark else'#ece5f5')
 if variant==1:s.rect(xx+3,yy+9,ww*.38,hh-12,1,'#d4c5e5');s.rect(xx+ww*.45,yy+9,ww*.48,hh-12,1,'#bdc4dd')
 else:
  for i in range(4):s.rect(xx+5,yy+9+i*5,ww*(.72 if i%2==0 else.5),1.5,1,'#cfc0df')

def shelf(s,x,y,w,kind='shots',dark=False,files=2,showfiles=True):
 c=D if dark else C;s.text(x,y+11,'截图',11,c['accent']if kind=='shots'else c['muted']);s.text(x+38,y+11,'文件',11,c['accent']if kind=='files'else c['muted'])if showfiles else None;s.text(x+w,y+11,'历史',11,c['accent'],400,'end');s.line(x+(0 if kind=='shots'else 38),y+16,x+(24 if kind=='shots'else 62),y+16,c['accent'],1.2)
 if kind=='shots':
  cell=(w-6)/2;hh=cell/1.4
  for i in range(4):shot(s,x+(i%2)*(cell+6),y+26+(i//2)*(hh+6),cell,hh,i,dark)
  s.text(x,y+26+hh*2+23,'点击附加，不自动发送',11,c['muted']);return 26+hh*2+30
 for i,name in enumerate(['下一阶段.pdf','灵感片段.md'][:files]):
  fy=y+27+i*47;s.rect(x,fy,25,31,4,c['accentbg']);s.text(x+12.5,fy+20,'PDF'if i==0 else'MD',8,c['accent'],450,'middle');s.text(x+33,fy+12,name,11,c['sub']);s.text(x+33,fy+30,'已留存 · 60 秒',11,c['muted'])
 return 31+files*47

def workpage(s,x,y,w,kind='memo',dark=False,expanded=False):
 c=D if dark else C
 if not expanded:tabs(s,x,y,w,kind,dark)
 top=y+(15 if expanded else 54)
 if kind=='memo':
  s.text(x,top,'11月17日 · 便笺',11,c['muted']);s.text(x,top+29,'一个小想法',14,c['ink'],550);s.lines(x,top+59,['把工具留在手边，','把注意力留给','正在做的事。','','下一步：','整理第一轮反馈。'],14,c['ink'],22);end=top+191
  if expanded:s.lines(x,end+32,['先把想法说出来。','再决定，放在哪里。','','一份安静的工作页。'],14,c['sub'],22);end+=151
 elif kind=='calc':
  s.text(x,top,'计算草稿',11,c['muted']);s.lines(x,top+34,['(248 + 136)','× 0.85'],14,c['ink'],23);s.text(x,top+92,'按 = 查看结果',11,c['muted']);s.rect(x-2,top+108,w+4,95,11,c['accentbg']);s.text(x+8,top+131,'=',12,c['sub']);s.text(x+8,top+165,'326.4',27,c['accent']);s.text(x+w-12,top+129,'×',17,c['accent'],400,'middle');s.text(x+8,top+188,'继续计算',11,c['accent']);s.text(x+w-8,top+188,'保存',11,c['accent'],400,'end');s.line(x,top+224,x+w,top+224,c['line']);s.text(x,top+245,'历史',11,c['muted']);s.text(x,top+265,'128 × 0.85 = 108.8',11,c['muted']);end=top+290
 elif kind=='tasks':
  s.text(x,top,'今天 · 本地清单',11,c['muted']);s.text(x,top+29,'接下来',14,c['ink'],550)
  for i,(txt,done) in enumerate([('整理设计反馈',False),('补充异常状态',False),('回看昨天的灵感',True)]):
   yy=top+61+i*34;s.circle(x+6,yy-4,6,c['accent']if done else'none',c['accent'],1);s.text(x+19,yy,txt,12,c['muted']if done else c['ink']);
   if done:s.line(x+19,yy-4,x+113,yy-4,c['muted'],.7)
  s.text(x,top+176,'＋ 添加一项',12,c['accent']);end=top+199
 else:
  s.text(x,top,'语言笔记 · 英语 → 中文',11,c['muted']);s.text(x,top+29,'原文',11,c['muted']);s.lines(x,top+52,['Make room for','what matters.'],14,c['ink'],22);s.text(x,top+112,'译文',11,c['muted']);s.line(x,top+127,x,top+171,c['accent'],2);s.lines(x+9,top+143,['为真正重要的事，','留出空间。'],14,c['ink'],22);s.text(x,top+209,'我的备注',11,c['muted']);s.lines(x,top+234,['room 在这里表示','“余地、空间”。'],13,c['sub'],22);end=top+286
 s.text(x,end,'已留在此页',11,c['muted']);icon(s,x+w-17,end-13,'expand',c['accent'],.8);return end-y+14

def spaces(s,x,y,w,h,count=3,current=1,dark=False,readonly=False,display='内建显示器'):
 c=D if dark else C;s.rect(x,y,w,h,12,c['surface'],stroke='#ffffff50');s.text(x+10,y+17,display,11,c['muted']);s.text(x+w-10,y+17,'只读'if readonly else str(count),11,c['accent']if readonly else c['muted'],400,'end');thumbw=w-20;th=thumbw/1.6
 s.count+=1;clip='spacesclip'+str(s.count);s.raw(f'<defs><clipPath id="{clip}"><rect x="{x+7}" y="{y+25}" width="{w-14}" height="{h-30}" rx="5"/></clipPath></defs>');s.raw(f'<g clip-path="url(#{clip})">')
 layouts=[[(.04,.06,.56,.86),(.64,.06,.32,.86)],[(.04,.06,.42,.87),(.5,.06,.46,.42),(.5,.54,.46,.39)],[(.13,.12,.68,.65),(.32,.36,.61,.55)],[(.05,.07,.9,.85)]]
 for i in range(count):
  yy=y+29+i*(th+24);xx=x+10
  if i+1==current:s.rect(xx-3,yy-3,thumbw+6,th+22,7,fill=c['accentbg'],stroke=c['accent'],sw=1)
  wallpaper(s,xx,yy,thumbw,th,dark,5)
  for wx,wy,ww,wh in layouts[i%4]:
   ax=xx+wx*thumbw;ay=yy+wy*th;aw=ww*thumbw;ah=wh*th;s.rect(ax,ay,aw,ah,2,fill='#9888a6'if dark else'#f6f2fb',stroke='#b8a7c455',sw=.5);s.rect(ax,ay,aw,max(4,ah*.12),2,fill='#ad9bbd'if dark else'#e7dff0')
   for j in range(4):s.rect(ax+aw*.09,ay+ah*.27+j*max(3,ah*.12),aw*(.72 if j%2==0 else.51),max(.7,ah*.023),1,'#bcadd0'if dark else'#d3c6e1')
  s.text(xx+2,yy+th+13,'桌面 '+str(i+1),11,c['muted']);
  if i+1==current:s.text(xx+thumbw-2,yy+th+13,'当前',11,c['accent'],400,'end')
 s.end()
 if count>4:s.rect(x+w-4,y+36,2,min(64,h*.26),1,c['muted'],extra='opacity=".35"')

def sidebar(s,x,y,w,h,variant='default',dark=False,page='memo',scale=1):
 s.group(f'translate({x} {y}) scale({scale})');x=0;y=0;c=D if dark else C;s.rect(0,0,w,h,19,c['outer'],stroke='#ffffff66',sw=1,extra='filter="url(#soft)"');pad=8;iw=w-16;noSpace=variant=='notes';spaceh=0 if noSpace else (278 if variant=='custom' else (373 if h>=800 else 270));toolh=h-16-(spaceh+11 if not noSpace else 0);s.rect(8,8,iw,toolh,12,c['surface'],stroke='#ffffff55');s.count+=1;clip='toolsclip'+str(s.count);s.raw(f'<defs><clipPath id="{clip}"><rect x="18" y="20" width="{w-36}" height="{toolh-21}" rx="4"/></clipPath></defs>');s.raw(f'<g clip-path="url(#{clip})">');tx=19;tw=w-38;ty=21
 if variant=='restricted':
  s.rect(tx-2,ty,tw+4,44,7,c['accentbg']);s.text(tx+6,ty+18,'让表达先发生…',12,c['ink']);s.text(tx+6,ty+36,'位置已变化',11,c['muted']);s.text(tx+tw-5,ty+36,'复制',11,c['accent'],400,'end');ty+=62;ty+=voice(s,tx,ty,tw,True,dark,True)
 elif variant!='notes':ty+=voice(s,tx,ty,tw,variant in ['custom','dense'],dark)
 if variant in ['custom','notes','dense']:
  if variant!='notes':s.line(tx,ty+10,tx+tw,ty+10,c['line']);ty+=23
  ty+=workpage(s,tx,ty,tw,'tasks'if variant=='dense'else page,dark,variant=='notes')
 if variant in ['default','custom','dense']:
  s.line(tx,ty+10,tx+tw,ty+10,c['line']);ty+=23;ty+=shelf(s,tx,ty,tw,'files'if variant=='custom'else'shots',dark,showfiles=variant!='default')
 if variant=='custom':
  s.line(tx,ty+8,tx+tw,ty+8,c['line']);s.text(tx+tw/2,ty+33,'Quiet Morning',12,c['sub'],400,'middle');s.text(tx+tw/2,ty+51,'Apple Music · 元信息',11,c['muted'],400,'middle')
 s.end()
 if variant in ['custom','dense']:s.rect(w-11,38,2,63,1,c['muted'],extra='opacity=".28"')
 if not noSpace:spaces(s,8,8+toolh+11,iw,spaceh,8 if variant=='dense'else 3,1,dark,variant=='restricted')
 s.end()

def desktop(s,x,y,w,h):
 wallpaper(s,x,y,w,h,False,14);s.rect(x,y,w,25,fill='#f8f6fc80');s.text(x+20,y+17,'●',12,'#5e506d');s.text(x+47,y+17,'备忘录',11,'#4b3e59',550)
 for i,t in enumerate(['文件','编辑','显示','窗口','帮助']):s.text(x+111+i*43,y+17,t,11,'#6f617b')
 s.text(x+w-20,y+17,'11月17日 周二  09:41',11,'#6f617b',400,'end');aw=w-w/8-100;ax=x+35;ay=y+64;ah=h-118;s.rect(ax,ay,aw,ah,11,'#fcfbfd',stroke='#ffffffcc',extra='filter="url(#shadow)"');s.rect(ax,ay,aw,39,11,'#f0edf5');s.rect(ax,ay+27,aw,13,fill='#f0edf5')
 for i,col in enumerate(['#e5a4a3','#e5ca9c','#a9c7ad']):s.circle(ax+18+i*16,ay+20,5,col)
 s.text(ax+aw/2,ay+25,'产品札记',11,'#a293ad',400,'middle');s.rect(ax,ay+40,151,ah-40,0,'#f0ecf5');s.text(ax+18,ay+80,'搜索',12,'#9a88ab');s.text(ax+18,ay+121,'我的文件夹',11,'#a897b7');s.rect(ax+9,ay+137,133,30,5,'#e5ddef');s.text(ax+24,ay+157,'产品札记',12,'#88689f');s.text(ax+24,ay+192,'随手记录',12,'#a18aaf');s.text(ax+24,ay+226,'阅读与灵感',12,'#a18aaf');dx=ax+211;dy=ay+101;s.text(dx,dy,'NOVEMBER 17 / FIELD NOTES',11,'#b3a5bf',500,extra='letter-spacing="1.8"');s.text(dx,dy+49,'让表达自然发生。',29,'#4c3e58',500);s.lines(dx,dy+90,['好的工具不应该要求我们不断切换状态。','它在需要的时候出现，在用完之后安静地留下。'],14,'#8b7b98',28);s.line(dx,dy+177,dx,dy+246,'#c8b7da',2);s.lines(dx+22,dy+196,['先把想法说出来。','再决定，把它放在哪里。'],20,'#856798',35);s.rect(dx,dy+279,64,22,4,'#eee6f7');s.text(dx+9,dy+294,'体验设计',11,'#a58cb8');s.text(dx,dy+348,'留在原来的工作现场',16,'#80708e',500);s.lines(dx,dy+383,['语音、片段、文件和待办，各自保持清晰。','当它们需要协作时，传递的是一次明确的选择。'],14,'#94849f',28);s.rect(dx,dy+446,aw-265,89,8,'#faf7fd',stroke='#e0d5ea');s.text(dx+15,dy+474,'继续写下你的想法…',13,'#b09cbc');s.text(dx,dy+559,'原目标输入框 · 原型内模拟',11,'#ae9aba');s.text(dx,dy+612,'接下来',14,'#9b82ac');
 for j in range(3):s.rect(dx,dy+633+j*17,(aw-270)*(.91 if j%2==0 else.73),5,3,'#eee7f3')
 sidebar(s,x+w-w/8-8,y+34,w/8,h-44,'default')

s=SVG(1552,1208,'Nearpane 默认完整桌面设计图');board(s,'01','边缘常驻，工作继续。','完整桌面 1440 × 900 逻辑点 · 侧栏 180 pt（12.5%）· 保留默认的语音、截图与 Spaces');desktop(s,56,180,1440,900);s.save('01-desktop-design.svg')

s=SVG(1600,1390,'Nearpane 三种配置的完整侧栏对照');board(s,'02','每个人，都有自己的刚刚好。','三个完整侧栏按 1.2 倍展示；每栏原始宽度 180 pt，来自 1440 × 900 逻辑点桌面。')
for x,title,sub,var in [(65,'01 / 日常','默认三项，轻量常驻','default'),(570,'02 / 我的工作台','一个编辑位置，独立内容','custom'),(1075,'03 / 只留笔记','其余能力关闭，照常使用','notes')]:
 s.text(x+30,194,title,19,'#675275',520);s.text(x+30,223,sub,12,'#a28eaf');wallpaper(s,x,250,460,1033,False,14);sidebar(s,x+121,267,180,832,var,False,'memo',1.2);s.text(x+30,1258,'180 pt × 1.2',11,'#8f779d')
s.save('02-three-configurations.svg')

s=SVG(1800,1300,'Nearpane 计算、文件历史与语言笔记细节');board(s,'03','同一种编辑手感，清楚的数据边界。','工作页以 2 倍展示（原始宽度 180 pt）；文件历史进入现有档案主窗口。功能不同，内容不混写。')
s.text(70,196,'计算草稿',19,'#6a507b',520);s.text(70,223,'结果临时出现；取消后原式仍在。',12,'#9d86ac');s.rect(70,251,360,900,28,'#d9d1e8');s.rect(84,265,332,872,20,'#f6f2fb');s.group('translate(108 291) scale(2)');workpage(s,0,0,144,'calc');s.end();s.text(108,1090,'只收起结果，不替换原文。',13,'#9d86ac')
s.text(500,196,'文件留存',19,'#6a507b',520);s.text(500,223,'一分钟结束的是最近展示，历史始终可取。',12,'#9d86ac');s.rect(500,251,700,540,18,'#fdfbff',stroke='#e4d7ec',extra='filter="url(#shadow)"');s.text(530,296,'档案 · 文件',23,'#6e4f80',520);s.text(530,324,'最近展示与持久保存各自独立',12,'#aa91ba');s.rect(530,345,640,40,8,'#f0e9f7');s.text(545,372,'搜索名称或类型',13,'#b09abb');s.text(538,425,'文件',12,'#aa93b8');s.text(865,425,'状态',12,'#aa93b8');s.line(530,440,1170,440,'#e4d9ed')
for i,(name,meta,st) in enumerate([('下一阶段.pdf','PDF · 1.6 MB','已收起 · 留存中'),('交互草稿.pdf','PDF · 2.4 MB','常用文件'),('设计记录.md','MD · 8 KB','已收起 · 留存中')]):
 y=480+i*83;s.text(540,y,'★'if i==1 else'☆',17,'#b299c6');s.text(567,y,name,15,'#7e6090');s.text(567,y+24,meta,11,'#aa96b7');s.text(865,y,st,12,'#a68bb5');s.rect(1077,y-21,90,31,6,fill='#f3ecf9',stroke='#dfd0e9');s.text(1122,y,'重新取用',11,'#9673ad',450,'middle');s.line(530,y+42,1170,y+42,'#eee4f3')
s.text(530,752,'已经收起的文件，随时可以重新取用。',11,'#ae99bc');s.rect(500,831,700,320,18,'#eee7f5');s.text(530,874,'收起与删除，是两件事。',21,'#7c5d8c',500);s.lines(530,913,['最近托盘  →  约 60 秒后收起  →  留存历史','重新取用  →  再次出现在托盘','','Riftlet 截图继续遵循原有队列、附加和失败恢复。'],14,'#9a7eab',30)
s.text(1280,196,'语言笔记',19,'#6a507b',520);s.text(1280,223,'原文、译文和备注独立保留。',12,'#9d86ac');s.rect(1280,251,360,900,28,'#d9d1e8');s.rect(1294,265,332,872,20,'#f6f2fb');s.group('translate(1318 291) scale(2)');workpage(s,0,0,144,'language');s.end();s.text(1318,1090,'示例译文 · 尚未连接模型',13,'#9d86ac');s.save('03-workpage-and-history.svg')

s=SVG(1600,1360,'Nearpane 小屏深色、受限与多显示器状态');board(s,'04','复杂的时候，也保持安静。','深色 / 小屏 / 权限受限 / 副屏仅 Spaces。全部为设计状态，不代表真实系统能力已验证。')
for x,title,sub in [(65,'高密度 · 深色','1280 × 800 · 160 pt · ×1.2'),(570,'权限受限','原目标变化，不向其他位置插入'),(1075,'副屏','仅显示该屏 Spaces；不复制语音与文件')]:s.text(x+28,191,title,19,'#6a507b',520);s.text(x+28,221,sub,11,'#9e87ac')
wallpaper(s,65,246,460,987,True,14);sidebar(s,199,268,160,756,'dense',True,'tasks',1.2)
wallpaper(s,570,246,460,987,False,14);sidebar(s,704,268,160,756,'restricted',False,'memo',1.2)
wallpaper(s,1075,246,460,987,False,14);s.group('translate(1209 268) scale(1.2)');s.rect(0,0,160,780,19,C['outer'],stroke='#ffffff66');spaces(s,8,8,144,764,5,2,False,False,'外接显示器');s.end();s.save('04-boundary-states.svg')
print('Created 4 SVG design boards.')
