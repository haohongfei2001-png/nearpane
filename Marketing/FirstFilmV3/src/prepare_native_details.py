#!/usr/bin/env python3
"""Editorial reframes of real native UI, respecting each observed card height."""
import hashlib,json,subprocess
from pathlib import Path
from PIL import Image,ImageDraw
from brand_frames import PAPER
from render_edit import bounded_inputs

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'assets/processed';OUT.mkdir(parents=True,exist_ok=True)
TEMP=OUT/'layout-mattes';TEMP.mkdir(exist_ok=True)
SIZE=(3840,2160)

def run(name,inputs,filters,frames,record):
    out=OUT/(name+'.mkv')
    filters+=['[finished]scale=out_color_matrix=bt709:out_range=tv,format=yuv444p,setsar=1[final]']
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y',*bounded_inputs(inputs),'-filter_complex_threads','1',
      '-filter_complex',';'.join(filters),'-map','[final]','-an','-r','30','-frames:v',str(frames),'-c:v','libx264','-threads','3',
      '-qp','0','-preset','veryfast','-pix_fmt','yuv444p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',str(out)],check=True)
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-select_streams','v:0','-show_entries','stream=nb_read_frames','-of','json',str(out)]))
    if int(probe['streams'][0]['nb_read_frames'])!=frames:
        raise ValueError('Native detail has the wrong frame count')
    record.update(product_pixels_redrawn=False,pixel_scale_cards=1,source_speed=1,
       output_sha256=hashlib.sha256(out.read_bytes()).hexdigest())
    out.with_suffix('.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print(out,flush=True)

def loop(path,duration):return ['-loop','1','-framerate','30','-t',str(duration),'-i',str(path)]

def main():
    paper=TEMP/'paper.png';Image.new('RGBA',SIZE,PAPER).save(paper)
    start=2.55774946126843;duration=8.29225053873157;frames=round(duration*30);first=round(start*30)
    rowmask=TEMP/'row-mask.png';im=Image.new('L',(2640,498));ImageDraw.Draw(im).rounded_rectangle((0,0,2639,497),22,fill=255);im.save(rowmask)
    inputs=['-i',str(ROOT/'assets/native/dual/host-fullscreen.mov'),'-i',str(OUT/'native-order-alpha.mov')]+loop(paper,duration)+loop(rowmask,duration)
    filters=[f'[0:v]fps=30:start_time=0,trim=start_frame={first}:end_frame={first+frames},setpts=N/(30*TB),crop=1950:368:624:488,scale=2640:498:flags=lanczos,format=rgb24[rows]',
       '[3:v]format=gray[mask]','[rows][mask]alphamerge,fade=t=out:st=6:d=0.4:alpha=1[rowsA]',
       '[2:v]format=rgba[paper]','[paper][rowsA]overlay=240:720:format=rgb:shortest=1[withrows]',
       '[withrows][1:v]overlay=3176:56:format=rgb:shortest=1[finished]']
    run('dual-order-detail-4k',inputs,filters,frames,{'source':'assets/native/dual/host-fullscreen.mov','source_in':start,
      'duration':duration,'management_crop':[624,488,1950,368],'native_cards':'native-order-alpha.json',
      'same_native_source_time_for_management_and_cards':True,'unreleased_rows_shown':False})

    duration=2.3;photo_path=ROOT/'assets/native/dual/actual-captured-water.png'
    photo=Image.open(photo_path).convert('RGBA').resize((2480,1128),Image.Resampling.LANCZOS)
    mask=Image.new('L',photo.size);ImageDraw.Draw(mask).rounded_rectangle((0,0,2479,1127),20,fill=255);photo.putalpha(mask)
    plate=Image.new('RGBA',SIZE,(0,0,0,0));plate.alpha_composite(photo,(240,420));plate_path=TEMP/'captured-photo.png';plate.save(plate_path)
    inputs=['-i',str(OUT/'native-expansion-alpha.mov')]+loop(paper,duration)+loop(plate_path,duration)
    filters=['[1:v]format=rgba[paper]','[2:v]format=rgba,fade=t=in:st=0.633333333:d=0.25:alpha=1[photo]',
       '[paper][photo]overlay=0:0:format=rgb:shortest=1[withphoto]',
       '[withphoto][0:v]overlay=3176:56:format=rgb:shortest=1[finished]']
    run('riftlet-expansion-detail-4k',inputs,filters,round(duration*30),{'source':'assets/native/dual/host-fullscreen.mov','source_in':20.6,
      'duration':duration,'native_cards':'native-expansion-alpha.json','actual_acquired_image':'assets/native/dual/actual-captured-water.png',
      'actual_acquired_image_sha256':hashlib.sha256(photo_path.read_bytes()).hexdigest(),
      'editorial_photo_reveal':'Original acquired PNG, revealed only after actual thumbnail arrival. No product movement invented.',
      'lyric_or_player_ui_in_cutaway':False})

if __name__=='__main__':main()
