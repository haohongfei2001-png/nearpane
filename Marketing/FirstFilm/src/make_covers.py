#!/usr/bin/env python3
"""Recompose publication covers from the same native source and type system."""
from pathlib import Path
from PIL import Image,ImageOps
from render_film import ASSETS,ROOT,RESAMPLE,INK,read_image,paste,text

def make(lang='zh',portrait=False):
    w,h=(1080,1440) if portrait else (3840,2160)
    scale=1 if portrait else 2
    photo=read_image(str(ASSETS/'backgrounds/morning-water.png'))
    plate=photo if portrait else photo.crop((660,0,1672,570))
    im=ImageOps.fit(plate,(w,h),RESAMPLE,centering=(.75,.5) if portrait else (.5,.5))
    native=read_image(str(ASSETS/f'native/authored-native/{lang}-cue-2.png'))
    def tx(s,x,y,size,**kw): text(im,s,(x*scale,y*scale),size*scale,**kw)
    if portrait:
        tx('Nearpane',90,75,34,weight='bold')
        tx('产品预览' if lang=='zh' else 'PRODUCT PREVIEW',990,85,16,anchor='ra',opacity=.75)
        tx('让音乐，\n留在手边。' if lang=='zh' else 'Keep the\nmusic close.',90,205,72,spacing=10)
        paste(im,native,(270,575,540,540*192/208),shadow=True,radius=46)
        tx('Nearpane · 桌面歌词体验' if lang=='zh' else 'Lyrics, alongside your day.',90,445,25)
        tx('nearpane.com',540,1290,26,anchor='ma',color=(246,248,245))
    else:
        tx('Nearpane',100,70,34,weight='bold')
        tx('HOLDSNOW',1820,80,18,anchor='ra',opacity=.75)
        tx('让音乐，\n留在手边。' if lang=='zh' else 'Keep the\nmusic close.',150,330,84,spacing=15*scale)
        paste(im,native,tuple(v*scale for v in (1240,250,500,500*192/208)),shadow=True,radius=round(43*scale))
        tx('Nearpane · 桌面歌词体验' if lang=='zh' else 'Lyrics, alongside your day.',156,610,26)
        tx('nearpane.com',150,960,26,color=INK)
        tx('产品预览' if lang=='zh' else 'PRODUCT PREVIEW',1770,967,17,anchor='ra',opacity=.9,color=INK)
    file=ROOT/'renders'/f'Nearpane-Cover-{lang.upper()}-{"Mobile" if portrait else "4K"}.png'
    im.convert('RGB').save(file)
    print(file)

if __name__=='__main__':
    for lang in ['zh','en']:
        make(lang,False);make(lang,True)
