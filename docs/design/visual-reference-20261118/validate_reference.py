#!/usr/bin/env python3
"""Check the design deliverable, not the native macOS application."""
from pathlib import Path
import argparse, json
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops
import render_reference as r

ROOT = Path(__file__).resolve().parent
NS = {'s': 'http://www.w3.org/2000/svg'}
XLINK = '{http://www.w3.org/1999/xlink}href'

def require(condition, message):
    if not condition: raise AssertionError(message)

def validate(with_pdf=False):
    m=json.loads((ROOT/'render-measurements.json').read_text())
    checks=[]
    svgs=sorted((ROOT/'assets').glob('*.svg'))
    require(len(svgs)==16, 'All 16 design scenes must be present')
    dimensions={}
    for path in svgs:
        tree=ET.parse(path);root=tree.getroot()
        logical=(float(root.attrib['width']),float(root.attrib['height']))
        image=Image.open(path.with_suffix('.png'))
        require(image.size==tuple(round(v*2) for v in logical), f'2x output: {path.name}')
        for text in root.findall('.//s:text',NS):
            require(float(text.attrib.get('opacity','1'))==1, f'Opaque text: {path.name}')
            require(float(text.attrib.get('fill-opacity','1'))==1, f'Opaque text fill: {path.name}')
        dimensions[path.stem]={'logical':logical,'pixels':image.size}
    checks.append({'name':'SVG parsing, text alpha and exact 2x exports','status':'PASS','sceneCount':len(svgs)})
    require(r.L['shellRadius']-r.L['outerInset']==r.L['toolRadius'],'Concentric surface radii')
    require(r.default_width(1440)==240 and m['default']['panelWidth']==240,'Default width')
    require(m['default']['listY']==320 and m['threeTools']['listY']==458,'Tool height determines list start')
    require(all(c['fullyVisible'] for c in m['default']['cards']),'Default four-window fixture complete')
    require(not m['default']['overflow'],'Default fixture must fit')
    require(all(g['listY']==320 for g in m['width']),'Width comparison must keep tool heights fixed')
    require(all(g['sourceInventory']==m['width'][0]['sourceInventory'] for g in m['width']),'Width comparison must use identical source objects')
    checks.append({'name':'Default width, concentric corners, fixed-content width comparison and tool occupancy','status':'PASS','defaultWidth':240,'listTopTwoTools':320,'listTopThreeTools':458,'completeDefaultCards':4})
    for key,name in [('default','01-default-desktop'),('lived','00-lived-desktop')]:
        root=ET.parse(ROOT/'assets'/f'{name}.svg').getroot()
        uses=[u.attrib.get(XLINK) for u in root.findall('.//s:use',NS)]
        for projection in m[key]['projections']:
            require(uses.count('#'+projection['source'])>=2,f'Desktop and preview must reuse source: {projection["id"]}')
            sw,sh=projection['sourceSize'];pw,ph=projection['projectedSize']
            require(abs(pw/ph-sw/sh)<1e-9,'Fit must preserve source aspect')
    group=m['splitDesktop']['projections'][:2]
    require(len(group)==2 and abs(group[0]['scale']-group[1]['scale'])<1e-12,'Composite uses one transform')
    x0,y0,w0,h0=group[0]['projectedFrame'];x1,y1,w1,h1=group[1]['projectedFrame']
    require(abs((x1-x0-w0)-r.TOKENS['referenceFixture']['windowGutter']*group[0]['scale'])<1e-8,'Composite keeps actual window gap')
    asym=r.scene_fixture(1000,700,'asymmetric',apps=['browser','notes'])
    require(abs(asym[0]['frame'][2]/asym[1]['frame'][2]-2)<1e-12,'Exact 2:1 fixture')
    checks.append({'name':'Same desktop/preview source, aspect preservation, shared group geometry and exact 2:1','status':'PASS'})
    counts=[]
    original=r.scene_fixture(1176,849,'four')
    for count in [1,4,8,9]:
        inventory=[{**original[i%4],'id':f'test-window-{i+1}','birthOrdinal':i+1} for i in range(count)]
        a=r.Art(300,900);wall=r.wallpaper(a,300,900)
        geo=r.rail(a,20,20,240,861,wall,fixture=inventory)
        require(all(c['height']==122 for c in geo['cards']),'Window count cannot compress rows')
        require(geo['listY']==320,'Window count cannot compress tools')
        require(geo['overflow']==(count>4),'Overflow must scroll')
        counts.append({'windows':count,'rowHeight':122,'listTop':320,'overflow':geo['overflow']})
    checks.append({'name':'1/4/8/9 windows use constant tool and row sizes','status':'PASS','scenarios':counts})
    states=m['supplements']['trayFlow']
    expected=[['C','F'],['S1','C','F'],['S1','S2','C','F'],['S1','S2','S3','C'],['S1','C','F','F1'],['S1','S2','C','F1'],['S1','F1']]
    for i,items in enumerate(expected):
        require(states[i]['visibleItems']==items, f'Tray state {i+1} order')
        require(len(states[i]['cells'])==len(items)<=4,'No extra empty cells')
    voice=m['supplements']['voiceAndMemo']['voice']
    require([v['moduleHeight'] for v in voice]==[144,144,40,40],'Voice state heights')
    require([v['bodyVisible'] for v in voice]==[True,True,False,False],'Voice content visibility')
    require(m['supplements']['voiceAndMemo']['cancelPreservesExpression'],'Cancelling result preserves expression')
    translation=m['supplements']['inlineTranslation']
    require(translation['selectionNotOccluded']==True,'Translation avoids the selected word')
    checks.append({'name':'Seven required tray flows, voice visibility, calculation cancel and translation geometry','status':'PASS','trayStates':len(states)})
    # Compare only opaque interiors. Ignore at most one 8-bit rounding level in
    # fewer than 0.1% of pixels; SVG rasterization can round fractional transforms
    # differently at separate board coordinates. This does not permit opacity changes.
    im=Image.open(ROOT/'assets/04-material-comparison.png').convert('RGB')
    source=m['material'][0]['sourceInventory'][0]['sourceSize'];iw=258-24-8;ih=iw*.5;scale=ih/source[1]
    ox=42+12+4+(iw-source[0]*scale)/2;oy=161+42+m['material'][0]['listY']+4
    crop=(round((ox+6)*2),round((oy+10)*2),round((ox+source[0]*scale-6)*2),round((oy+ih-12)*2))
    windows=[im.crop((crop[0]+j*282*2,crop[1],crop[2]+j*282*2,crop[3])) for j in range(4)]
    image_differences=[]
    for window in windows[1:]:
        difference=ImageChops.difference(windows[0],window)
        pixels=list(difference.get_flattened_data())
        maximum=max(max(pixel) for pixel in pixels)
        changed=sum(any(pixel) for pixel in pixels)
        require(maximum<=1 and changed/len(pixels)<.001,'Image interior must be invariant within raster rounding tolerance')
        image_differences.append({'maximumChannelDifference':maximum,'changedPixels':changed,'comparedPixels':len(pixels)})
    cores=[]
    for j in range(3):
        region=im.crop(((66+j*282)*2,224*2,(246+j*282)*2,284*2))
        cores.append(sum(px==(37,39,42) for px in region.get_flattened_data()))
    require(cores[0]>0 and len(set(cores))==1,'Opaque body glyph cores are unchanged across light glass values')
    checks.append({'name':'Opaque window interiors within raster rounding tolerance and exact text-core pixels','status':'PASS','imageVariants':4,'imageDifferences':image_differences,'equalGlyphCorePixels':cores[0]})
    if with_pdf:
        from pypdf import PdfReader
        reader=PdfReader(ROOT/'Nearpane_Visual_Reference_R4.pdf')
        require(len(reader.pages)==18,'PDF includes 16 boards and 2 supporting pages')
        require(all(page.get_contents() is not None for page in reader.pages),'Every PDF page has content')
        checks.append({'name':'PDF page count and content streams','status':'PASS','pages':18,'visualReview':'See VALIDATION.md; programmatic checks cannot assess appearance'})
    report={'version':'R4','date':'2026-11-18','scope':'Static design source, rendered examples and PDF; not native application verification','status':'PASS','checks':checks,'dimensions':dimensions,'nativeOpticalCalibration':'NOT_RUN','nativeInteractionAcceptance':'NOT_RUN in this design task; retain separate existing native receipts'}
    (ROOT/'validation-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'status':'PASS','checks':len(checks),'scenes':len(svgs),'pdfChecked':with_pdf},ensure_ascii=False))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--pdf',action='store_true');args=parser.parse_args();validate(args.pdf)
