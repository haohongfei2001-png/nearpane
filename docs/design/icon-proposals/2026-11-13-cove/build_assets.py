#!/usr/bin/env python3
"""Rebuild editable Nearpane icon candidates from authored cubic paths.
Requirements: Python 3.10+, Pillow, svgpathtools, Inkscape CLI.
No generated bitmap is embedded in an SVG.
"""
from pathlib import Path
import argparse, json, subprocess, struct, shutil, xml.etree.ElementTree as ET, hashlib, math
from PIL import Image, ImageCms
from svgpathtools import parse_path
ROOT=Path(__file__).resolve().parent
OUT=ROOT/'delivery/Nearpane-Icon-Design-20261113'
CFG=ROOT/'design-config.json'
SVGNS='http://www.w3.org/2000/svg'
SIZES=[16,32,64,128,256,512,1024]
ICC=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
TILE='M330 100 H694 C774 100 815 100 849 120 C885 141 907 174 917 210 C924 239 924 280 924 330 V694 C924 774 924 815 904 849 C883 885 850 907 814 917 C785 924 744 924 694 924 H330 C250 924 209 924 175 904 C139 883 117 850 107 814 C100 785 100 744 100 694 V330 C100 250 100 209 120 175 C141 139 174 117 210 107 C239 100 280 100 330 100 Z'

def write(p,s):
 p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s,encoding='utf-8')

def render(svg,out,size):
 out.parent.mkdir(parents=True,exist_ok=True)
 cmd=['inkscape',str(svg),'--export-filename='+str(out),'--export-width='+str(size),'--export-height='+str(size)]
 r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 if r.returncode: raise RuntimeError(r.stderr)
 im=Image.open(out).convert('RGBA');im.save(out,icc_profile=ICC,optimize=True)

def paths_svg(ds):return ''.join(f'<path d="{d}"/>' for d in ds)

def source_svg(label,ds,fill,kind='mark',appearance='light',small=False,flat=False):
 bg='';defs='';stroke=''
 if kind=='app':
  if appearance=='dark':
   shell0='#34373F';shell1='#202329';border='#525660';top='#FF805D';base='#F26745'
  else:
   shell0='#FFFFFF';shell1='#EEF0F4';border='#CED2D9';top='#F66B47';base='#E65334'
  if not flat and not small:
   defs=f'<defs><linearGradient id="surface" x1="0" y1="0" x2="0" y2="1"><stop stop-color="{shell0}"/><stop offset="1" stop-color="{shell1}"/></linearGradient><linearGradient id="enamel" x1="0" y1="0" x2="0.45" y2="1"><stop stop-color="{top}"/><stop offset="1" stop-color="{base}"/></linearGradient></defs>'
   bg=f'<path d="{TILE}" fill="url(#surface)" stroke="{border}" stroke-width="1.35"/>'
   fill='url(#enamel)'
  else:
   bg=f'<path d="{TILE}" fill="{shell1 if appearance=="dark" else "#F7F8FA"}"/>'
   fill=('#FF7955' if appearance=='dark' else '#DD4C2E') if small else fill
 if kind=='fullbleed':
  bg=f'<rect width="1024" height="1024" fill="{"#24272D" if appearance=="dark" else "#F7F8FA"}"/>'
 title=f'Nearpane / {label} / {kind} / {appearance}'
 return f'''<svg xmlns="{SVGNS}" width="1024" height="1024" viewBox="0 0 1024 1024" color-interpolation="sRGB"><title>{title}</title><desc>Unapproved design candidate. Original editable cubic paths. No embedded raster. 1024-unit master.</desc>{defs}{bg}<g fill="{fill}">{paths_svg(ds)}</g></svg>'''

def icns(iconset,out):
 slots=[('icp4',16,1),('icp5',32,1),('icp6',32,2),('ic07',128,1),('ic08',256,1),('ic09',512,1),('ic10',512,2),('ic11',16,2),('ic13',128,2),('ic14',256,2)]
 blocks=[]
 for tag,pt,scale in slots:
  name=f'icon_{pt}x{pt}'+('@2x' if scale==2 else '')+'.png';b=(iconset/name).read_bytes();blocks.append(tag.encode()+struct.pack('>I',len(b)+8)+b)
 b=b''.join(blocks);out.write_bytes(b'icns'+struct.pack('>I',len(b)+8)+b)


def build_candidate(c):
 p=OUT/c['folder'];src=p/'source';png=p/'png';src.mkdir(parents=True,exist_ok=True)
 master=c['paths'];opt16=c.get('optical16',master);opt32=c.get('optical32',master)
 for suffix,fill in [('color','#EB5D3B'),('black','#16191E'),('white','#FFFFFF')]:
  svg=src/f'mark-{suffix}.svg';write(svg,source_svg(c['name'],master,fill))
  for n in [1024,4096] if suffix=='color' else [1024]:render(svg,png/f'mark-{suffix}-{n}.png',n)
  for size,ds in [(16,opt16),(32,opt32),(64,master)]:
   s=src/f'mark-{suffix}-optical-{size}.svg';write(s,source_svg(c['name'],ds,fill))
   render(s,png/f'mark-{suffix}-{size}.png',size)
 for appearance in ['light','dark']:
  svg=src/f'app-icon-{appearance}.svg';write(svg,source_svg(c['name'],master,'#EB5D3B','app',appearance))
  for n in [1024,2048]:render(svg,png/f'app-icon-{appearance}-{n}.png',n)
  smallsrc=src/f'app-icon-{appearance}-optical-16.svg';write(smallsrc,source_svg(c['name'],opt16,'#DD4C2E','app',appearance,True))
  midsrc=src/f'app-icon-{appearance}-optical-32.svg';write(midsrc,source_svg(c['name'],opt32,'#EB5D3B','app',appearance,True))
  for n in [16,32,64,128,256,512]:render(smallsrc if n==16 else midsrc if n==32 else svg,png/f'app-icon-{appearance}-{n}.png',n)
  iconset=p/'macos'/f'Nearpane-{appearance}.iconset';iconset.mkdir(parents=True,exist_ok=True)
  for pt in [16,32,128,256,512]:
   for scale in [1,2]:
    n=pt*scale;name=f'icon_{pt}x{pt}'+('@2x' if scale==2 else '')+'.png'
    render(smallsrc if pt==16 else midsrc if pt==32 else svg,iconset/name,n)
  icns(iconset,p/'macos'/f'Nearpane-{appearance}.icns')
  full=src/f'app-icon-{appearance}-unmasked.svg';write(full,source_svg(c['name'],master,'#EB5D3B','fullbleed',appearance))
  render(full,png/f'app-icon-{appearance}-unmasked-1024.png',1024)
 # Asset catalog is the legacy static macOS slot set, separate from Composer.
 catalog=p/'macos/AppIcon.appiconset';catalog.mkdir(exist_ok=True)
 slots=[]
 for pt in [16,32,128,256,512]:
  for scale in [1,2]:
   name=f'icon_{pt}x{pt}'+('@2x' if scale==2 else '')+'.png'
   shutil.copy2(p/'macos/Nearpane-light.iconset'/name,catalog/name)
   slots.append({'idiom':'mac','size':f'{pt}x{pt}','scale':f'{scale}x','filename':name})
 write(catalog/'Contents.json',json.dumps({'images':slots,'info':{'author':'Nearpane design proposal','version':1}},indent=2))
 composer=p/'icon-composer';composer.mkdir(exist_ok=True)
 write(composer/'01-symbol.svg',source_svg(c['name'],master,'#EB5D3B'))
 write(composer/'layer-spec.json',json.dumps({'status':'import-ready source, not compiled .icon','canvas':[1024,1024],'background':{'light':'#F7F8FA','dark':'#24272D','set_in':'Icon Composer, full bleed, system mask'},'foreground':'01-symbol.svg','default_fill':'#EB5D3B','dark_fill':'#FF7955','mono_fill':'system primary','effects':'Start fully opaque. No imported shadow, blur or specular highlight. Preview effects in Icon Composer before shipping.'},ensure_ascii=False,indent=2))
 write(p/'design-parameters.json',json.dumps({k:v for k,v in c.items() if k not in ['paths','optical16','optical32']},ensure_ascii=False,indent=2))
 print(c['folder']+' exported',flush=True)


def main():
 config=json.loads(CFG.read_text());OUT.mkdir(parents=True,exist_ok=True)
 for c in config['candidates']:build_candidate(c)
 write(OUT/'design-config.json',json.dumps(config,ensure_ascii=False,indent=2))
 shutil.copy2(__file__,OUT/'build_assets.py')
 write(OUT/'brand-colors.json',json.dumps({'profile':'sRGB IEC61966-2.1','primary':{'name':'Nearpane Vermilion - proposed','hex':'#EB5D3B','rgb':[235,93,59]},'small_light':'#DD4C2E','dark_foreground':'#FF7955','ink':'#16191E','light_surface':'#F7F8FA','dark_surface':'#24272D','enamel_top':'#F66B47','enamel_base':'#E65334','approved':False},indent=2))
 write(OUT/'brand-colors.css',':root {\n  --nearpane-vermilion: #EB5D3B;\n  --nearpane-vermilion-small: #DD4C2E;\n  --nearpane-vermilion-on-dark: #FF7955;\n  --nearpane-ink: #16191E;\n  --nearpane-surface: #F7F8FA;\n  --nearpane-surface-dark: #24272D;\n}\n')
 print('Complete:',OUT)
if __name__=='__main__':main()
