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

@lru_cache(maxsize=12)
def read_image(file):
    im=Image.open(file).convert('RGBA')
    im.info['_film_source']=file
    return im

@lru_cache(maxsize=4)
def resized_source(file,w,h): return read_image(file).resize((w,h),RESAMPLE)

@lru_cache(maxsize=16)
def shadow_sprite(w,h,radius,opacity):
    margin=round(w*.20)
    sh=Image.new('RGBA',(w+2*margin,h+2*margin),(0,0,0,0))
    d=ImageDraw.Draw(sh)
    d.rounded_rectangle((margin,margin+round(w*.04),margin+w,margin+h+round(w*.04)),radius=radius,fill=(10,27,26,round(32*opacity/255)))
    return sh.filter(ImageFilter.GaussianBlur(max(1,w*.045))),margin

def paste(dst, src, box, opacity=1, shadow=False, radius=20):
    if opacity <= .001: return
    x,y,w,h=map(round,box)
    if w<1 or h<1: return
    if shadow:
        sh,margin=shadow_sprite(w,h,radius,round(opacity*255))
        dst.alpha_composite(sh,(x-margin,y-margin))
    if src.size!=(w,h):
        file=src.info.get('_film_source')
        src=resized_source(file,w,h) if file else src.resize((w,h),RESAMPLE)
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
        # The two real takes have different timings. Keep both at original speed.
        self.controls_start=14.4 if lang=='zh' else 17.0
        self.photo=read_image(str(ASSETS/'backgrounds/morning-water.png'))
        self.native=ASSETS/'native/authored-native'
        self.has_native=(self.native/f'{lang}-cue-0.png').exists()
        if not self.has_native and not draft:
            raise RuntimeError('Native macOS source frames are required; draft placeholders cannot ship.')
        self.sequences={}
        for key in ['windowserver-lyrics-zh','windowserver-lyrics-en','windowserver-controls-zh','windowserver-controls-en',
                    'music-lyrics','music-controls','music-controls-en','authored-motion-zh','authored-motion-en']:
            folder=ASSETS/'native'/key
            manifest=folder/'capture.json'
            if manifest.exists():
                capture=json.loads(manifest.read_text())
                rows=capture.get('frames',[])
                for row in rows:
                    if capture.get('cursorIncluded'): row['cursorIncluded']=True
                rows=[r for r in rows if r.get('file') and (folder/r['file']).exists()]
                if rows: self.sequences[key]=(folder,rows,[r['elapsed'] for r in rows])
        work=ASSETS/f'workspace/textedit-{lang}-native.png'
        if not work.exists(): work=ASSETS/'workspace/textedit-native-window.png'
        self.work=read_image(str(work)) if work.exists() else None
        self.riftlet=read_image(str(ASSETS/'riftlet/riftlet-official-1024.png')) if (ASSETS/'riftlet/riftlet-official-1024.png').exists() else None
        self.static_bg=None
        self.static_bg_key=None
        self.scene_key=None
        self.scene_base=None

    def p(self, box): return tuple(round(x*self.s) for x in box)
    def txt(self, dst, s, x,y,size, **kw):
        if 'spacing' in kw: kw['spacing']*=self.s
        text(dst,s,(round(x*self.s),round(y*self.s)),round(size*self.s),**kw)

    def camera(self,t):
        return interpolate(t,[(0,(1.7,1340,390)),(4.7,(1.7,1340,390)),(5.5667,(1,960,540)),
            (10.5,(1,960,540)),(11.5667,(1.85,1595,340)),(24.8,(1.85,1595,340)),
            (25.9667,(1,960,540)),(30.2,(1,960,540)),(31.2,(.985,960,540))])

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
           (5.5667,(640,430,330,304.62)),(10.5,(640,430,330,304.62)),
           (11.5667,(240,620,600,553.85)),(24.8,(240,620,600,553.85)),
           (25.9667,(260,480,560,516.92)),(30.2,(260,480,560,516.92))])
        return self.p(box)

    def cue(self,n,hover=False):
        if hover:
            actual=ASSETS/'native/evidence-run5/real-music'/('real-music-next-hover.png' if self.lang=='en' else 'real-music-hover.png')
            if actual.exists(): return read_image(str(actual))
        if self.has_native:
            file=self.native/(f'{self.lang}-hover-layout-only.png' if hover else f'{self.lang}-cue-{max(0,min(7,n))}.png')
        else: file=ASSETS/'native'/f'placeholder-{self.lang}-{"controls" if hover else "lyrics"}.png'
        return read_image(str(file))

    def sequence(self,key,t):
        if key not in self.sequences: return None
        folder,rows,times=self.sequences[key]
        # Floating subtraction at CFR boundaries must not repeat the previous
        # frame and then skip a native animation/pointer frame on the next tick.
        i=max(0,min(len(rows)-1,bisect.bisect_right(times,t+1e-8)-1))
        im=read_image(str(folder/rows[i]['file']))
        if 'windowVisible' in rows[i]: im.info['film_visible']=rows[i]['windowVisible']
        im.info['film_frame_metadata']=rows[i]
        return im

    def panel(self,t):
        # Final masters use WindowServer video, which includes the presentation-layer
        # animation. cacheDisplay state sequences are useful only for composition drafts.
        if .35<=t<self.controls_start:
            seq=self.sequence(f'windowserver-lyrics-{self.lang}',t-.35)
            if seq is not None: return seq
        if t>=self.controls_start:
            seq=self.sequence(f'windowserver-controls-{self.lang}',t-self.controls_start)
            if seq is not None: return seq
        # Retained to reproduce early documented studies, never allowed in final video.
        if .35<=t<6.35:
            seq=self.sequence(f'authored-motion-{self.lang}',t-.35)
            if seq is not None: return seq
        if 10.4<=t<16.4:
            key=f'authored-motion-{self.lang}'
            seq=self.sequence(key,t-10.4)
            if seq is not None: return seq
            if self.lang=='zh':
                seq=self.sequence('music-lyrics',t-10.4)
                if seq is not None: return seq
        if 16.4<=t<21.8:
            key='music-controls-en' if self.lang=='en' and 'music-controls-en' in self.sequences else 'music-controls'
            seq=self.sequence(key,t-16.4)
            if seq is not None: return seq
            return self.cue(2,True)
        n=min(7,1+int(t/4))
        if t>25: n=5
        return self.cue(n)

    def cursor(self,frame,t,box,metadata=None):
        if not 16.2<t<21.7: return
        if metadata and metadata.get('cursorIncluded'): return
        if not self.draft: return
        # Early composition studies only. Final video contains the actual OS pointer.
        t0=t-16.2
        px,py=interpolate(t0,[(0,(1.22,.92)),(.7,(.57,.77)),(1.8,(.5,.76)),
                         (2.3,(.5,.76)),(3.5,(.71,.90)),(4.5,(.71,.90)),(5.5,(1.2,1.15))])
        if metadata:
            pointer=metadata.get('pointerNormalized',{})
            if 'x' in pointer and 'y' in pointer: px,py=pointer['x'],pointer['y']
            elif 'pointerX' in metadata and 'pointerY' in metadata: px,py=metadata['pointerX'],metadata['pointerY']
        if px < -.6 or px > 1.8 or py < -.6 or py > 1.8: return
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
        wide=envelope(t,5.2,25.5 if self.portrait else 30.2,.65)
        wide=min(1,wide)
        if self.work is not None and wide>.001:
            ratio=self.work.height/self.work.width
            if self.portrait: box=self.p((40,850,780,780*ratio))
            else: box=self.world_box(t,(300,90,900,900*ratio))
            scene_key=(self.static_bg_key,box,round(wide,5))
            if self.scene_key==scene_key:
                im=self.scene_base.copy()
            else:
                paste(im,self.work,box,wide,False,radius=round(12*self.s))
                self.scene_key=scene_key
                self.scene_base=im.copy()

        visible=ease((t-.35)/.48)
        # The actual recorded window visibility supplies retirement; the final
        # editorial fade is only the transition onto the brand end frame.
        visible*=1-ease((t-30.1)/.6)
        box=self.panel_box(t)
        if visible>.001:
            panel=self.panel(t)
            if panel.info.get('film_visible') is False: visible=0
            if not self.draft and abs(panel.width/panel.height-208/192)>.02:
                raise RuntimeError('Product source aspect ratio differs from the 208x192 photography view. Never stretch the native interface.')
            box=(box[0],box[1]+round((1-visible)*8*self.s),box[2],box[3])
            paste(im,panel,box,visible,True,radius=round(box[2]*.09))
            self.cursor(im,t,box,panel.info.get('film_frame_metadata'))

        # The primary brand is present from the first shot. The small stage label
        # prevents this preview from claiming an available integrated download.
        brandalpha=1-ease((t-30.1)/.6)
        if self.portrait:
            self.txt(im,'Nearpane',80,86,32,opacity=brandalpha,weight='bold')
            self.txt(im,'产品预览' if self.lang=='zh' else 'PRODUCT PREVIEW',1000,94,16,opacity=.7*brandalpha,anchor='ra')
        else:
            self.txt(im,'Nearpane',80,54,26,opacity=brandalpha,weight='bold')
            self.txt(im,'产品预览' if self.lang=='zh' else 'PRODUCT PREVIEW',1840,60,14,opacity=.7*brandalpha,anchor='ra')

        intro=envelope(t,1.35,4.9,.5)
        if self.portrait:
            self.txt(im,'让音乐，留在手边。' if self.lang=='zh' else 'Keep the music close.',540,1390,43,opacity=intro,anchor='ma',color=INK)
        else:
            self.txt(im,'让音乐，留在手边。' if self.lang=='zh' else 'Keep the music close.',155,855,49,opacity=intro)

        extra=envelope(t,25.9,30.55,.35)
        if extra>.001:
            if self.portrait:
                self.txt(im,'更多可能，正在靠近。' if self.lang=='zh' else 'More, coming closer.',540,315,32,opacity=extra,anchor='ma')
                if self.riftlet: paste(im,self.riftlet,self.p((445,1150,190,190)),extra)
                self.txt(im,'Riftlet',540,1382,33,opacity=extra,anchor='ma',weight='bold',color=INK)
                self.txt(im,'截图助手' if self.lang=='zh' else 'Screenshot assistant',540,1440,28,opacity=extra,anchor='ma',color=INK)
            else:
                
                if self.riftlet: paste(im,self.riftlet,self.p((1540,493,64,64)),extra)
                self.txt(im,'Riftlet',1628,490,25,opacity=extra,weight='bold')
                self.txt(im,'截图助手' if self.lang=='zh' else 'Screenshot assistant',1628,532,16,opacity=extra)

        outro=ease((t-30.4)/.3667)
        if outro>.001:
            veil=Image.new('RGBA',im.size,(*PAPER,round(255*outro)))
            im.alpha_composite(veil)
            a=ease((t-30.3667)/.4)
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
    working=dest.with_name(dest.stem+'.rendering'+dest.suffix)
    if not film.draft:
        for kind,a,b in [('lyrics',.35,film.controls_start),('controls',film.controls_start,30.4)]:
            if start>=b or start+duration<=a: continue
            seconds=max(0,min(start+duration,b)-a)
            key=f'windowserver-{kind}-{film.lang}'
            if key not in film.sequences:
                raise RuntimeError(f'Final video requires continuous native WindowServer {kind} footage ({seconds}s), not state snapshots.')
            rows,times=film.sequences[key][1:]
            # Once the recorded OS window is absent, the desktop can remain empty
            # editorially. This does not extend or fabricate the source recording.
            retired=(kind=='controls' and times[-1]>=min(10,seconds) and
                     len(rows)>=6 and all(r.get('windowVisible') is False for r in rows[-6:]))
            if times[-1]<seconds-.05 and not retired:
                raise RuntimeError(f'Native {kind} passage ends before its required action or verified window withdrawal.')
    audio=ASSETS/'audio/origami-34s.wav'
    cmd=['ffmpeg','-y','-hide_banner','-loglevel','warning','-f','rawvideo','-pix_fmt','rgb24','-s',f'{film.w}x{film.h}','-r',str(fps),'-i','pipe:0',
         '-ss',str(start),'-i',str(audio),'-t',str(duration),'-map','0:v','-map','1:a',
         '-c:v','libx264','-threads','3','-preset','fast','-crf',str(crf),'-vf','scale=out_color_matrix=bt709:out_range=tv,format=yuv420p','-profile:v','high',
         '-color_range','tv','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-c:a','aac','-b:a','256k','-ar','48000',
         '-bsf:v','h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0',
         '-movflags','+faststart+write_colr','-metadata','title=Nearpane — Keep the music close (Product preview)',
         '-metadata','comment=Music: Origami by Scott Buckley, CC BY 4.0, https://www.scottbuckley.com.au/library/origami/; edited 34-second excerpt. Product footage provenance supplied separately.',str(working)]
    p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
    total=round(duration*fps);clock=time.monotonic()
    try:
        for i in range(total):
            p.stdin.write(film.frame(start+i/fps).tobytes())
            if i%90==0: print(json.dumps({'frame':i,'total':total,'elapsed':round(time.monotonic()-clock,1)}),flush=True)
    finally: p.stdin.close()
    if p.wait()!=0: raise RuntimeError('FFmpeg encode failed')
    working.replace(dest)
    print(json.dumps({'output':str(dest),'bytes':dest.stat().st_size,'seconds':round(time.monotonic()-clock,2)}),flush=True)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--lang',choices=['zh','en'],default='zh')
    p.add_argument('--width',type=int,default=1920);p.add_argument('--height',type=int,default=1080)
    p.add_argument('--draft',action='store_true');p.add_argument('--frames',action='store_true')
    p.add_argument('--start',type=float,default=0);p.add_argument('--duration',type=float,default=34)
    p.add_argument('--fps',type=int,default=30);p.add_argument('--output',type=Path)
    a=p.parse_args();f=Film(a.width,a.height,a.lang,a.draft)
    if a.frames:
        directory=a.output or ROOT/'keyframes'/f'{a.lang}-{a.width}x{a.height}'
        directory.mkdir(parents=True,exist_ok=True)
        for n,t in enumerate([2.4,8.5,12.4,18.6,26.7,32.1],1):
            file=directory/f'{n:02d}-{t:04.1f}s.png';f.frame(t).save(file);print(str(file),flush=True)
    else:
        dest=a.output or ROOT/'renders'/f'Nearpane-Preview-{a.lang}-{a.width}x{a.height}.mp4'
        video(f,dest,a.start,a.duration,a.fps)
if __name__=='__main__': main()
