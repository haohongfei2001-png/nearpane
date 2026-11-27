#!/usr/bin/env python3
"""Nearpane / Close at hand — deterministic source-image film compositor.

Product pixels come only from the production SwiftUI view captured on macOS.
This renderer handles framing, typography, editorial timing and audio muxing.
It does not reimplement the product UI. See docs/ASSET_PROVENANCE.json.
"""
from __future__ import annotations
import argparse, bisect, json, math, os, subprocess, sys, time
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets'
INK = (34, 45, 45)
PAPER = (246, 246, 242)
MUTED = (92, 106, 105)
RESAMPLE = Image.Resampling.LANCZOS

def clamp(x): return max(0.0, min(1.0, x))
def ease(x):
    x = clamp(x)
    return x*x*x*(x*(x*6-15)+10)
def mix(a,b,p): return a+(b-a)*p
def envelope(t,a,b,fade=.4):
    return ease((t-a)/fade)*ease((b-t)/fade)
def interpolate(t, keys):
    if t <= keys[0][0]: return keys[0][1]
    for (ta,a),(tb,b) in zip(keys,keys[1:]):
        if t <= tb:
            p=ease((t-ta)/(tb-ta))
            return tuple(mix(x,y,p) for x,y in zip(a,b))
    return keys[-1][1]

@lru_cache(maxsize=80)
def font(size, weight='regular', chinese=False):
    if chinese:
        file=ASSETS/'fonts'/('NotoSansCJK-Bold.ttc' if weight=='bold' else 'NotoSansCJK-Regular.ttc')
        return ImageFont.truetype(str(file), max(1,int(size)), index=2)
    f=ImageFont.truetype(str(ASSETS/'fonts/InterVariable.ttf'), max(1,int(size)))
    try: f.set_variation_by_axes([14, 600 if weight=='bold' else 450])
    except Exception: pass
    return f

@lru_cache(maxsize=45)
def read_image(file): return Image.open(file).convert('RGBA')

def paste(dst, src, box, opacity=1, shadow=False, radius=20):
    if opacity <= .001: return
    x,y,w,h=map(round,box)
    if w<1 or h<1: return
    if shadow:
        margin=round(w*.20)
        sh=Image.new('RGBA',(w+2*margin,h+2*margin),(0,0,0,0))
        d=ImageDraw.Draw(sh)
        d.rounded_rectangle((margin,margin+round(w*.04),margin+w,margin+h+round(w*.04)),radius=radius,fill=(10,27,26,round(32*opacity)))
        sh=sh.filter(ImageFilter.GaussianBlur(max(1,w*.045)))
        dst.alpha_composite(sh,(x-margin,y-margin))
    if src.size!=(w,h): src=src.resize((w,h),RESAMPLE)
    if opacity<.999:
        src=src.copy(); src.putalpha(src.getchannel('A').point(lambda p:round(p*opacity)))
    dst.alpha_composite(src,(x,y))

def text(dst, s, xy, size, opacity=1, color=INK, weight='regular', anchor=None, spacing=0, align='left'):
    if opacity <= .001: return
    chinese=any(ord(x)>0x3000 for x in s)
    f=font(size,weight,chinese)
    layer=Image.new('RGBA',dst.size)
    d=ImageDraw.Draw(layer)
    kwargs={'font':f,'fill':(*color,round(255*opacity)),'anchor':anchor}
    if '\n' in s: d.multiline_text(xy,s,spacing=spacing,align=align,**kwargs)
    else: d.text(xy,s,**kwargs)
    dst.alpha_composite(layer)

class Film:
    def __init__(self, width, height, lang, draft=False):
        self.w,self.h,self.lang=width,height,lang
        self.portrait=height>width
        self.bw,self.bh=(1080,1920) if self.portrait else (1920,1080)
        self.s=width/self.bw
        self.draft=draft
        self.photo=read_image(str(ASSETS/'backgrounds/morning-water.png'))
        self.native=ASSETS/'native/authored-native'
        self.has_native=(self.native/f'{lang}-cue-0.png').exists()
        if not self.has_native and not draft:
            raise RuntimeError('Native macOS source frames are required; draft placeholders cannot ship.')
        self.sequences={}
        for key in ['music-lyrics','music-controls','authored-motion-zh','authored-motion-en']:
            folder=ASSETS/'native'/key
            manifest=folder/'capture.json'
            if manifest.exists():
                rows=json.loads(manifest.read_text()).get('frames',[])
                rows=[r for r in rows if r.get('file') and (folder/r['file']).exists()]
                if rows: self.sequences[key]=(folder,rows,[r['elapsed'] for r in rows])
        work=ASSETS/'workspace/textedit-native-window.png'
        self.work=read_image(str(work)) if work.exists() else None
        self.riftlet=read_image(str(ASSETS/'riftlet/riftlet-official-1024.png')) if (ASSETS/'riftlet/riftlet-official-1024.png').exists() else None
        self.static_bg=None
        self.static_bg_key=None

    def p(self, box): return tuple(round(x*self.s) for x in box)
    def txt(self, dst, s, x,y,size, **kw):
        if 'spacing' in kw: kw['spacing']*=self.s
        text(dst,s,(round(x*self.s),round(y*self.s)),round(size*self.s),**kw)

    def camera(self,t):
        return interpolate(t,[(0,(1.7,1340,390)),(4.7,(1.7,1340,390)),(7.1,(1,960,540)),
            (10.6,(1,960,540)),(13,(2.05,1670,335)),(21.1,(2.05,1670,335)),
            (23.4,(1,960,540)),(28.2,(1,960,540)),(29.2,(.985,960,540))])

    def background(self,t):
        if self.portrait:
            key=('p',self.w,self.h)
            if self.static_bg_key!=key:
                self.static_bg=ImageOps.fit(self.photo,(self.w,self.h),RESAMPLE,centering=(.78,.5))
                self.static_bg_key=key
            return self.static_bg.copy()
        z,cx,cy=self.camera(t)
        key=(round(z,5),round(cx,3),round(cy,3),self.w)
        if self.static_bg_key!=key:
            source=ImageOps.fit(self.photo,(2560,1440),RESAMPLE)
            # Exact crop window supplies an editorial camera; no product geometry changes.
            box=(cx-960/z+320,cy-540/z+180,cx+960/z+320,cy+540/z+180)
            bg=source.resize((self.w,self.h),RESAMPLE,box=box) if min(box)>=0 and box[2]<=2560 and box[3]<=1440 else None
            if bg is None:
                # Small overscan only at the end transition.
                bg=ImageOps.fit(source,(self.w,self.h),RESAMPLE)
            self.static_bg=bg
            self.static_bg_key=key
        return self.static_bg.copy()

    def world_box(self,t,box):
        z,cx,cy=self.camera(t)
        x,y,w,h=box
        return self.p(((x-cx)*z+960,(y-cy)*z+540,w*z,h*z))

    def panel_box(self,t):
        if not self.portrait: return self.world_box(t,(1540,195,260,240))
        box=interpolate(t,[(0,(250,650,580,535.38)),(4.7,(250,650,580,535.38)),
           (7.1,(640,430,330,304.62)),(10.6,(640,430,330,304.62)),
           (13,(240,620,600,553.85)),(21.1,(240,620,600,553.85)),
           (23.4,(640,430,330,304.62)),(25.5,(640,430,330,304.62)),
           (26.5,(260,480,560,516.92)),(28.2,(260,480,560,516.92))])
        return self.p(box)

    def cue(self,n,hover=False):
        if self.has_native:
            file=self.native/(f'{self.lang}-hover-layout-only.png' if hover else f'{self.lang}-cue-{max(0,min(7,n))}.png')
        else: file=ASSETS/'native'/f'placeholder-{self.lang}-{"controls" if hover else "lyrics"}.png'
        return read_image(str(file))

    def sequence(self,key,t):
        if key not in self.sequences: return None
        folder,rows,times=self.sequences[key]
        i=max(0,min(len(rows)-1,bisect.bisect_right(times,t)-1))
        return read_image(str(folder/rows[i]['file']))

    def panel(self,t):
        # A continuous six-second passage is native motion, not interpolated UI artwork.
        if 10.6<=t<16.6:
            key=f'authored-motion-{self.lang}'
            seq=self.sequence(key,t-10.6)
            if seq is not None: return seq
            if self.lang=='zh':
                seq=self.sequence('music-lyrics',t-10.6)
                if seq is not None: return seq
        if 16.6<=t<21.8:
            if self.lang=='zh':
                seq=self.sequence('music-controls',t-16.6)
                if seq is not None: return seq
            return self.cue(2,True)
        n=min(7,1+int(t/4))
        if t>25: n=5
        return self.cue(n)

    def cursor(self,frame,t,box):
        if not 16.2<t<21.7: return
        # Editorial cursor overlay follows the real control demonstration.
        # Its presence does not qualify an input test; the macOS capture manifest does.
        t0=t-16.2
        px,py=interpolate(t0,[(0,(1.22,.92)),(.7,(.57,.77)),(1.8,(.5,.76)),
                         (2.3,(.5,.76)),(3.5,(.71,.90)),(4.5,(.71,.90)),(5.5,(1.2,1.15))])
        x,y,w,h=box
        x+=w*px;y+=h*py
        sz=max(18,round(w*.068))
        cursor=Image.new('RGBA',(sz*2,sz*2))
        d=ImageDraw.Draw(cursor)
        points=[(2,2),(2,sz),(sz*.29,sz*.72),(sz*.48,sz*1.13),(sz*.68,sz*1.03),(sz*.48,sz*.62),(sz*.87,sz*.59)]
        d.polygon(points,fill=(24,29,29,255),outline=(255,255,255,255),width=max(1,round(sz*.055)))
        frame.alpha_composite(cursor,(round(x),round(y)))

    def frame(self,t):
        im=self.background(t)
        wide=envelope(t,5.2,28.2,.65)
        wide=min(1,wide)
        if self.work is not None and wide>.001:
            ratio=self.work.height/self.work.width
            if self.portrait: box=self.p((80,880,920,920*ratio))
            else: box=self.world_box(t,(100,145,1150,1150*ratio))
            paste(im,self.work,box,wide,True,radius=round(12*self.s))

        visible=ease((t-.35)/.48)
        visible*=1-ease((t-23.2)/.55)
        if t>=25.7: visible=ease((t-25.7)/.45)
        visible*=1-ease((t-28.1)/.6)
        box=self.panel_box(t)
        if visible>.001:
            box=(box[0],box[1]+round((1-visible)*8*self.s),box[2],box[3])
            paste(im,self.panel(t),box,visible,True,radius=round(box[2]*.09))
            self.cursor(im,t,box)

        # The primary brand is present from the first shot. The small stage label
        # prevents this preview from claiming an available integrated download.
        brandalpha=1-ease((t-28.1)/.6)
        if self.portrait:
            self.txt(im,'Nearpane',80,86,32,opacity=brandalpha,weight='bold')
            self.txt(im,'产品预览' if self.lang=='zh' else 'PRODUCT PREVIEW',1000,94,16,opacity=.7*brandalpha,anchor='ra')
        else:
            self.txt(im,'Nearpane',80,54,26,opacity=brandalpha,weight='bold')
            self.txt(im,'产品预览' if self.lang=='zh' else 'PRODUCT PREVIEW',1840,60,14,opacity=.7*brandalpha,anchor='ra')

        intro=envelope(t,1.35,4.9,.5)
        if self.portrait:
            self.txt(im,'让音乐，留在手边。' if self.lang=='zh' else 'Keep the music close.',540,1390,43,opacity=intro,anchor='ma')
        else:
            self.txt(im,'让音乐，留在手边。' if self.lang=='zh' else 'Keep the music close.',155,855,49,opacity=intro)

        working=envelope(t,7.1,10.9,.4)
        if self.portrait:
            self.txt(im,'做你的事。\n听你的歌。' if self.lang=='zh' else 'Stay in flow.\nStay with the music.',85,230,58,opacity=working,spacing=8)
        else:
            self.txt(im,'做你的事。听你的歌。' if self.lang=='zh' else 'Stay in flow. Stay with the music.',150,972,30,opacity=working,color=(243,247,243))

        leaving=envelope(t,22.7,25.6,.4)
        if self.portrait:
            self.txt(im,'不需要时，\n把空间还给你。' if self.lang=='zh' else 'When you are done,\nyour space is yours.',85,235,55,opacity=leaving,spacing=8)
        else:
            self.txt(im,'不需要时，把空间还给你。' if self.lang=='zh' else 'When you are done, your space is yours.',150,972,30,opacity=leaving,color=(243,247,243))

        extra=envelope(t,25.9,28.55,.35)
        if extra>.001:
            if self.portrait:
                self.txt(im,'更多可能，正在靠近。' if self.lang=='zh' else 'More, coming closer.',540,315,32,opacity=extra,anchor='ma')
                if self.riftlet: paste(im,self.riftlet,self.p((445,1150,190,190)),extra)
                self.txt(im,'Riftlet',540,1382,33,opacity=extra,anchor='ma',weight='bold')
                self.txt(im,'截图助手 · 规划接入' if self.lang=='zh' else 'Screenshots · planned integration',540,1440,23,opacity=extra,anchor='ma')
            else:
                
                if self.riftlet: paste(im,self.riftlet,self.p((1540,493,64,64)),extra)
                self.txt(im,'Riftlet',1628,490,25,opacity=extra,weight='bold')
                self.txt(im,'截图助手 · 规划接入' if self.lang=='zh' else 'Planned integration',1628,532,16,opacity=extra)

        outro=ease((t-28.0)/.65)
        if outro>.001:
            veil=Image.new('RGBA',im.size,(*PAPER,round(255*outro)))
            im.alpha_composite(veil)
            a=ease((t-28.3)/.6)
            if self.portrait:
                self.txt(im,'HOLDSNOW',540,560,19,opacity=a*.7,anchor='ma')
                self.txt(im,'Nearpane',540,665,108,opacity=a,anchor='ma',weight='bold')
                self.txt(im,'让音乐，留在手边。' if self.lang=='zh' else 'Keep the music close.',540,830,36,opacity=a,anchor='ma')
                self.txt(im,'nearpane.com',540,1084,34,opacity=a,anchor='ma')
                self.txt(im,'了解 Nearpane · 产品预览' if self.lang=='zh' else 'Discover Nearpane · Product preview',540,1152,21,opacity=a*.7,anchor='ma')
                self.txt(im,'为 Mac 而来' if self.lang=='zh' else 'Made for Mac',540,1570,22,opacity=a*.65,anchor='ma')
                self.txt(im,'Music: “Origami” by Scott Buckley · CC BY 4.0',540,1740,16,opacity=a*.7,anchor='ma')
                self.txt(im,'scottbuckley.com.au',540,1774,16,opacity=a*.7,anchor='ma')
            else:
                self.txt(im,'HOLDSNOW',960,245,18,opacity=a*.7,anchor='ma')
                self.txt(im,'Nearpane',960,334,122,opacity=a,anchor='ma',weight='bold')
                self.txt(im,'让音乐，留在手边。' if self.lang=='zh' else 'Keep the music close.',960,520,36,opacity=a,anchor='ma')
                self.txt(im,'nearpane.com',960,650,31,opacity=a,anchor='ma')
                self.txt(im,'了解 Nearpane · 产品预览' if self.lang=='zh' else 'Discover Nearpane · Product preview',960,706,20,opacity=a*.7,anchor='ma')
                self.txt(im,'Music: “Origami” by Scott Buckley · CC BY 4.0 · scottbuckley.com.au',960,1000,15,opacity=a*.7,anchor='ma')
        if self.draft:
            self.txt(im,'COMPOSITION STUDY / SOURCE CAPTURE PENDING',self.bw/2,self.bh-32,14,opacity=.7,anchor='ma')
        return im.convert('RGB')

def video(film, dest, start, duration, fps=30, crf=18):
    dest.parent.mkdir(parents=True,exist_ok=True)
    audio=ASSETS/'audio/origami-32s.wav'
    cmd=['ffmpeg','-y','-hide_banner','-loglevel','warning','-f','rawvideo','-pix_fmt','rgb24','-s',f'{film.w}x{film.h}','-r',str(fps),'-i','pipe:0',
         '-ss',str(start),'-i',str(audio),'-t',str(duration),'-map','0:v','-map','1:a',
         '-c:v','libx264','-preset','fast','-crf',str(crf),'-pix_fmt','yuv420p','-profile:v','high',
         '-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-c:a','aac','-b:a','256k','-ar','48000',
         '-movflags','+faststart','-metadata','title=Nearpane — Keep the music close (Product preview)',
         '-metadata','comment=Music: Origami by Scott Buckley, CC BY 4.0, https://www.scottbuckley.com.au/library/origami/; edited 32-second excerpt. Product footage provenance supplied separately.',str(dest)]
    p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
    total=round(duration*fps);clock=time.monotonic()
    try:
        for i in range(total):
            p.stdin.write(film.frame(start+i/fps).tobytes())
            if i%90==0: print(json.dumps({'frame':i,'total':total,'elapsed':round(time.monotonic()-clock,1)}),flush=True)
    finally: p.stdin.close()
    if p.wait()!=0: raise RuntimeError('FFmpeg encode failed')
    print(json.dumps({'output':str(dest),'bytes':dest.stat().st_size,'seconds':round(time.monotonic()-clock,2)}),flush=True)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--lang',choices=['zh','en'],default='zh')
    p.add_argument('--width',type=int,default=1920);p.add_argument('--height',type=int,default=1080)
    p.add_argument('--draft',action='store_true');p.add_argument('--frames',action='store_true')
    p.add_argument('--start',type=float,default=0);p.add_argument('--duration',type=float,default=32)
    p.add_argument('--fps',type=int,default=30);p.add_argument('--output',type=Path)
    a=p.parse_args();f=Film(a.width,a.height,a.lang,a.draft)
    if a.frames:
        directory=a.output or ROOT/'keyframes'/f'{a.lang}-{a.width}x{a.height}'
        directory.mkdir(parents=True,exist_ok=True)
        for n,t in enumerate([2.4,8.5,14.2,18.6,27.0,30.1],1):
            file=directory/f'{n:02d}-{t:04.1f}s.png';f.frame(t).save(file);print(str(file),flush=True)
    else:
        dest=a.output or ROOT/'renders'/f'Nearpane-Preview-{a.lang}-{a.width}x{a.height}.mp4'
        video(f,dest,a.start,a.duration,a.fps)
if __name__=='__main__': main()
