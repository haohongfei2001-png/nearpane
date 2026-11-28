#!/usr/bin/env python3
"""Export six exact movie frames and a review board. Never redraw product UI."""
import argparse, hashlib, json, subprocess
from pathlib import Path
from PIL import Image
from brand_frames import PAPER, INK, MUTED, put

KEYS=[
 ('01-music',1.4,'音乐就在手边'),
 ('02-reading',7.8,'换个窗口，歌词还在'),
 ('03-controls',14.0,'移入，即可控制'),
 ('04-together',28.8,'空托盘一行'),
 ('05-captured',35.0,'收图后展开两行'),
 ('06-nearpane',37.5,'Nearpane')
]

def export(movie,out):
 out.mkdir(parents=True,exist_ok=True)
 records=[]
 for name,time,label in KEYS:
  path=out/(name+'.png')
  subprocess.run(['ffmpeg','-v','error','-y','-ss',str(time),'-threads','1','-i',str(movie),'-frames:v','1',str(path)],check=True)
  im=Image.open(path)
  records.append({'file':path.name,'source_time':time,'label':label,'size':list(im.size),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
 width=2880;margin=96;gap=64;tile=(width-2*margin-gap)//2;th=tile*9//16
 row=th+100;top=228;height=top+row*3+96
 board=Image.new('RGBA',(width,height),PAPER)
 put(board,'Nearpane',(margin,106),72,INK,weight=510,anchor='lm')
 put(board,'让音乐，留在手边。',(width-margin,110),31,MUTED,anchor='rm')
 for i,r in enumerate(records):
  x=margin+(i%2)*(tile+gap);y=top+(i//2)*row
  im=Image.open(out/r['file']).convert('RGBA').resize((tile,th),Image.Resampling.LANCZOS)
  board.alpha_composite(im,(x,y))
  put(board,f'{i+1:02d}   {r["label"]}',(x,y+th+44),27,MUTED,anchor='lm')
 put(board,'Music / The Simple Life artwork: Josh Woodward · CC BY 3.0 US',(margin,height-54),24,MUTED,anchor='lm')
 board.convert('RGB').save(out/'Nearpane-Key-Visuals.jpg',quality=96,subsampling=0)
 (out/'keyframes.json').write_text(json.dumps({'source_movie':movie.name,'source_movie_sha256':hashlib.sha256(movie.read_bytes()).hexdigest(),'method':'Exact decoded final-film frames; original native UI, no image generation or retouching.','frames':records},ensure_ascii=False,indent=2)+'\n')
 print(out/'Nearpane-Key-Visuals.jpg')

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('movie',type=Path);p.add_argument('--out',type=Path,required=True)
 a=p.parse_args();export(a.movie,a.out)
