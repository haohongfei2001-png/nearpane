#!/usr/bin/env python3
"""Covers composed from a reviewed real desktop frame, with original typography.

The portrait cover is independently laid out from native app/card crops.
Neither format reconstructs UI elements or invents a missing product state.
"""
import argparse,json
from pathlib import Path
from PIL import Image,ImageDraw,ImageFilter
from brand_frames import put,PAPER,INK,MUTED

def surface(image,size,radius):
    im=image.convert('RGBA').resize(size,Image.Resampling.LANCZOS)
    mask=Image.new('L',size,0)
    ImageDraw.Draw(mask).rounded_rectangle((0,0,size[0]-1,size[1]-1),radius,fill=255)
    im.putalpha(mask)
    return im

def place(canvas,im,xy,shadow=True):
    if shadow:
        pad=70
        alpha=Image.new('L',(im.width+pad*2,im.height+pad*2),0)
        alpha.paste(im.getchannel('A'),(pad,pad+16))
        alpha=alpha.filter(ImageFilter.GaussianBlur(28)).point(lambda v:round(v*.15))
        sh=Image.new('RGBA',alpha.size,(20,37,35,0));sh.putalpha(alpha)
        canvas.alpha_composite(sh,(xy[0]-pad,xy[1]-pad))
    canvas.alpha_composite(im,xy)

def main():
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--lang',choices=['zh','en'],default='zh');p.add_argument('--portrait',action='store_true')
    p.add_argument('--card',type=int,nargs=4,default=[3224,104,560,518]);p.add_argument('--work',type=int,nargs=4,default=[240,224,2704,1676])
    a=p.parse_args();source=Image.open(a.source).convert('RGBA')
    if source.size!=(3840,2160):raise ValueError('A reviewed 3840x2160 source frame is required; do not substitute an upscaled thumbnail.')
    if not a.portrait:
        cover=Image.new('RGBA',(3840,2160),PAPER)
        put(cover,'Nearpane',(420,160),144,anchor='lm',weight=510)
        put(cover,'让音乐，留在手边。' if a.lang=='zh' else 'Keep the music close.',(420,284),64,anchor='lm')
        put(cover,'HOLDSNOW',(3420,170),22,MUTED,anchor='rm')
        place(cover,surface(source,(3000,1688),18),(420,370))
        put(cover,'Music & album artwork: Josh Woodward · CC BY 3.0 US',(420,2113),18,MUTED,anchor='lm')
        put(cover,'nearpane.com',(3420,2113),23,MUTED,anchor='rm')
    else:
        cover=Image.new('RGBA',(1080,1920),PAPER)
        put(cover,'Nearpane',(66,126),62,anchor='lm',weight=510)
        title=['让音乐，','留在手边。'] if a.lang=='zh' else ['Keep the','music close.']
        for i,line in enumerate(title):put(cover,line,(66,260+i*79),64 if a.lang=='zh' else 58,anchor='lm')
        x,y,w,h=a.card
        if not (0<=x<x+w<=3840 and 0<=y<y+h<=2160):raise ValueError('Invalid native card crop')
        # Keep the native text, material and corner geometry. Only its editorial
        # placement changes for this vertical cover.
        card=surface(source.crop((x,y,x+w,y+h)),(450,round(h*450/w)),39)
        place(cover,card,(564,456))
        x,y,w,h=a.work
        work=surface(source.crop((x,y,x+w,y+h)),(948,round(h*948/w)),18)
        place(cover,work,(66,1010))
        put(cover,'换个窗口，歌还在。' if a.lang=='zh' else 'Your music stays with you.',(66,1715),31,anchor='lm')
        put(cover,'nearpane.com',(66,1820),23,MUTED,anchor='lm')
        put(cover,'产品预览' if a.lang=='zh' else 'Product preview',(1014,1820),18,MUTED,anchor='rm')
        put(cover,'Music & album artwork: Josh Woodward · CC BY 3.0 US',(66,1870),14,MUTED,anchor='lm')
    a.out.parent.mkdir(parents=True,exist_ok=True);cover.convert('RGB').save(a.out)
    a.out.with_suffix('.json').write_text(json.dumps({'native_source':str(a.source.resolve()),'source_pixels':source.size,'portrait_recomposition':a.portrait,'product_ui':'Unaltered native pixels; editorial cropping/scale/placement only.'},ensure_ascii=False,indent=2)+'\n')
    print(a.out)

if __name__=='__main__':main()
