#!/usr/bin/env python3
"""Transparent editorial labels and the Nearpane film end card.

No product interface is rendered by this module. Product pixels must come from
the independently recorded production SwiftUI views and actual applications.
"""
from pathlib import Path
from functools import lru_cache
import argparse
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
PAPER=(246,246,242,255)
INK=(34,45,45,255)
MUTED=(92,106,105,255)

@lru_cache(maxsize=40)
def font(size, chinese=False, weight=450):
    if chinese:
        f=ImageFont.truetype(str(ROOT/'assets/fonts/NotoSansCJK-Regular.ttc'), round(size),index=2)
    else:
        f=ImageFont.truetype(str(ROOT/'assets/fonts/InterVariable.ttf'), round(size))
        f.set_variation_by_axes([24,weight])
    return f

def put(im,txt,xy,size,color=INK,weight=450,anchor='mm'):
    ImageDraw.Draw(im).text(xy,txt,font=font(size,any(ord(c)>255 for c in txt),weight),fill=color,anchor=anchor)

def tracking(im,txt,xy,size,space,color=MUTED):
    f=font(size);d=ImageDraw.Draw(im)
    widths=[d.textlength(c,font=f) for c in txt]
    x=xy[0]-(sum(widths)+space*(len(txt)-1))/2
    for c,w in zip(txt,widths):
        d.text((x,xy[1]),c,font=f,fill=color,anchor='lm');x+=w+space

def end_frame(width,height,lang):
    portrait=height>width
    scale=width/(1080 if portrait else 1920)
    im=Image.new('RGBA',(width,height),PAPER)
    center=width/2
    if portrait:
        tracking(im,'HOLDSNOW',(center,580*scale),19*scale,5*scale)
        put(im,'Nearpane',(center,760*scale),126*scale,weight=510)
        put(im,'让音乐，留在手边。' if lang=='zh' else 'Keep the music close.',(center,914*scale),34*scale)
        put(im,'nearpane.com',(center,1235*scale),30*scale)
        put(im,'访问官网 · 产品预览' if lang=='zh' else 'Explore Nearpane · Product preview',(center,1294*scale),19*scale,MUTED)
        put(im,'“Good To Go” · Josh Woodward',(center,1785*scale),17*scale,MUTED)
        put(im,'CC BY 3.0 US · Edited excerpt',(center,1816*scale),15*scale,MUTED)
    else:
        tracking(im,'HOLDSNOW',(center,267*scale),17*scale,4.5*scale)
        put(im,'Nearpane',(center,443*scale),128*scale,weight=510)
        put(im,'让音乐，留在手边。' if lang=='zh' else 'Keep the music close.',(center,596*scale),32*scale)
        put(im,'nearpane.com',(center,790*scale),25*scale)
        put(im,'访问官网 · 产品预览' if lang=='zh' else 'Explore Nearpane · Product preview',(center,836*scale),16*scale,MUTED)
        put(im,'“Good To Go” · Josh Woodward · CC BY 3.0 US',(center,1016*scale),13*scale,MUTED)
    return im

CAPTIONS={
 'zh':{'continuity':'换个窗口，歌还在。','sources':'在你习惯的播放器里。','modules':'把需要的，放在一起。'},
 'en':{'continuity':'Your music stays with you.','sources':'With the player you already love.','modules':'Bring your essentials together.'}
}

def caption(width,height,lang,key):
    im=Image.new('RGBA',(width,height),(0,0,0,0))
    s=width/1920
    # The label stays below the captured application window and away from cards.
    put(im,CAPTIONS[lang][key],(120*s,1018*s),26*s,(246,246,242,255),anchor='lm')
    return im

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path,default=ROOT/'assets/brand');args=parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    for lang in ('zh','en'):
        for w,h,label in ((1920,1080,'1080p'),(3840,2160,'4k'),(1080,1920,'vertical')):
            end_frame(w,h,lang).save(args.out/f'end-{lang}-{label}.png')
            if h<w:
                for key in CAPTIONS[lang]:
                    caption(w,h,lang,key).save(args.out/f'caption-{key}-{lang}-{label}.png')
    print(args.out)

if __name__=='__main__':main()
