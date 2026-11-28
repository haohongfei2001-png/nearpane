#!/usr/bin/env python3
"""Original reading prop, opened in real macOS Preview during filming.

This is document content, not a reconstruction of any application interface.
The landscape image is the existing original film environment asset.
"""
from pathlib import Path
import fitz
from PIL import Image
from fontTools.ttLib import TTCollection
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.ttLib import TTFont
from fontTools import subset

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/workspace'
OUT.mkdir(parents=True, exist_ok=True)
FONTDIR = OUT / 'fonts'
FONTDIR.mkdir(exist_ok=True)
latin = FONTDIR / 'Inter-Reading-Subset.ttf'
if not latin.exists():
    f = TTFont(ROOT / 'assets/fonts/InterVariable.ttf')
    instantiateVariableFont(f, {'wght': 450, 'opsz': 24}, inplace=True)
    sub = subset.Subsetter()
    sub.populate(text=Path(__file__).read_text())
    sub.subset(f)
    f.save(latin)
han = FONTDIR / 'NotoSansSC-Reading-Subset.otf'
if not han.exists():
    face = TTCollection(ROOT / 'assets/fonts/NotoSansCJK-Regular.ttc').fonts[2]
    sub = subset.Subsetter(options=subset.Options(retain_gids=True))
    sub.populate(text=Path(__file__).read_text())
    sub.subset(face)
    face.save(han)

INK = (0.13, 0.18, 0.18)
MUTED = (0.38, 0.43, 0.43)
PAPER = (0.985, 0.980, 0.965)

def make(lang):
    doc = fitz.open()
    p = doc.new_page(width=1200, height=800)
    p.draw_rect(p.rect, color=None, fill=PAPER)
    p.insert_font(fontname='Inter', fontfile=str(latin))
    if lang == 'zh':
        p.insert_font(fontname='Han', fontfile=str(han))
    def text(s, x, y, size, color=INK):
        p.insert_text((x, y), s, fontname='Han' if any(ord(c)>255 for c in s) else 'Inter', fontsize=size, color=color)
    text('FIELD NOTES', 64, 53, 12, MUTED)
    text('01 / THE COAST', 978, 53, 12, MUTED)
    p.draw_line((64, 72), (1136, 72), color=(0.82, 0.84, 0.81), width=.65)
    text('一日海边' if lang=='zh' else 'A day by the water', 64, 142, 42)
    text('周末拍摄笔记' if lang=='zh' else 'Notes for a slow weekend', 66, 177, 16, MUTED)
    # The original landscape is placed directly; no generated UI or photo edits.
    photo_file = OUT / 'morning-water-photography.jpg'
    if not photo_file.exists():
        Image.open(ROOT/'assets/environment/morning-water.png').convert('RGB').save(photo_file, quality=95, subsampling=0)
    source_image = fitz.open(photo_file)
    photo = fitz.open('pdf', source_image.convert_to_pdf())
    rect = photo[0].rect
    crop_height = rect.width * 417 / 1072
    crop_y = (rect.height - crop_height) * .42
    p.show_pdf_page(fitz.Rect(64, 213, 1136, 630), photo, 0,
                    clip=fitz.Rect(0, crop_y, rect.width, crop_y + crop_height))
    photo.close()
    source_image.close()
    text('01', 64, 677, 12, MUTED)
    text('光线' if lang=='zh' else 'Light', 102, 679, 20)
    text('早一点到，等雾慢慢散开。' if lang=='zh' else 'Arrive early. Let the mist lift.', 102, 710, 14, MUTED)
    text('把天空、水面和安静一起留下。' if lang=='zh' else 'Keep the sky, the water, and a little quiet.', 102, 733, 14, MUTED)
    text('02', 668, 677, 12, MUTED)
    text('构图' if lang=='zh' else 'Composition', 706, 679, 20)
    text('让地平线低一些，画面轻一些。' if lang=='zh' else 'A lower horizon. A little more breathing room.', 706, 710, 14, MUTED)
    text('不急着拍下一张。' if lang=='zh' else 'There is no hurry to take the next frame.', 706, 733, 14, MUTED)
    text('PERSONAL NOTEBOOK', 64, 774, 9, MUTED)
    text('1', 1129, 774, 10, MUTED)
    doc.set_metadata({'title':'一日海边' if lang=='zh' else 'A day by the water', 'author':'HOLDSNOW', 'subject':'Original document content for Nearpane film capture'})
    output=OUT / f'field-notes-{lang}.pdf'
    doc.save(output, deflate=True, garbage=4)
    doc.close()
    check=fitz.open(output)
    check[0].get_pixmap(matrix=fitz.Matrix(1,1)).save(OUT/f'field-notes-{lang}-preview.png')
    check.close()
    print(output)

if __name__=='__main__':
    make('zh')
    make('en')
