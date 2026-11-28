"""Bounded-memory, lossless scene cache for native footage composition."""
import hashlib,json,subprocess
from pathlib import Path

def cache_path(directory,spec):
    directory.mkdir(parents=True,exist_ok=True)
    fingerprint=hashlib.sha256(json.dumps(spec,sort_keys=True).encode()).hexdigest()[:24]
    return directory/(fingerprint+'.mkv')

def encode_scene(path,inputs,filters,label,frames):
    receipt=path.with_suffix('.json')
    if path.exists() and receipt.exists():
        saved=json.loads(receipt.read_text())
        if saved.get('frames')==frames and saved.get('bytes')==path.stat().st_size:return
    working=path.with_name(path.stem+'.rendering.mkv')
    from render_edit import bounded_inputs
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y',*bounded_inputs(inputs),
        '-filter_complex_threads','1','-filter_complex',';'.join(filters),'-map',f'[{label}]',
        '-an','-r','30','-frames:v',str(frames),'-c:v','libx264','-threads','2','-qp','0',
        '-preset','veryfast','-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709',
        '-color_primaries','bt709','-color_trc','bt709',str(working)],check=True)
    actual=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_packets',
        '-select_streams','v:0','-show_entries','stream=nb_read_packets','-of','json',str(working)]))
    count=int(actual['streams'][0]['nb_read_packets'])
    if count!=frames:raise ValueError(f'Native scene produced {count} frames, expected {frames}; no artificial padding allowed')
    working.replace(path)
    receipt.write_text(json.dumps({'frames':frames,'bytes':path.stat().st_size,'encoding':'lossless H.264, YUV420P at final canvas before final encode'})+'\n')

def concat_input(paths,directory,name):
    listing=directory/(name+'.ffconcat')
    lines=['ffconcat version 1.0']
    for path in paths:
        if "'" in str(path):raise ValueError('Apostrophe in staging path is not supported')
        lines.append("file '"+str(path.resolve())+"'")
    listing.write_text('\n'.join(lines)+'\n')
    return ['-f','concat','-safe','0','-i',str(listing)]
