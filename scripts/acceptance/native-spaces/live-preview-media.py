#!/usr/bin/env python3
"""Publish lossless, original crops from a completed installed paired-preview run. No screen access."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import tempfile
import uuid
import zlib

PALETTE = (
    ((218,55,50), (35,115,230)), ((232,166,30), (102,48,195)),
    ((48,181,61), (213,47,158)), ((30,181,191), (148,76,29)),
    ((137,198,23), (47,65,167)), ((177,30,90), (33,127,93)),
    ((231,102,30), (134,40,143)),
)
LIVE = ["窗口画面", "窗口画面"]
SIGNATURE = b"\x89PNG\r\n\x1a\n"
MATCH_KEYS = ("display","space","hostPID","hostBirth","hostHash","panel","fixturePID","fixtureBirth","fixtureHash","numbers","sources","pictures")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular_file(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(fd)
        require(stat.S_ISREG(meta.st_mode) and 0 < meta.st_size <= limit, 'invalidEvidenceFile')
        data = stream.read(limit + 1)
        require(len(data) == meta.st_size, 'evidenceFileSizeChanged')
        return data


def binding(result,sampler=True):
    require(result.get('fixtureLaunched') is True and (not sampler or result.get('captureAttempted') is True) and
            result.get('cleanup', {}).get('status') == 'PASS' and result['cleanup'].get('windowNumbersGone') is True,
            'closedIsolatedFixtureRequired')
    if sampler or 'overviewBinding' not in result:
        base, final = result['binding'], result['finalBinding']
    else:
        base = final = result['overviewBinding']
    require(all((p.get('ready') is True or (not sampler and p.get('pictureInteriorsProven') is True)) and p.get('present') == [True, True] and (p.get('ordinaryCount') == 2 or (p.get('sourceProven') is True and p.get('cardIdentityProven') is True and p.get('windowCensus',{}).get('expectedProven') is True))
                for p in [base, final]) and all(k in base and base[k] == final.get(k) for k in MATCH_KEYS),
            'signedCardsOrDesktopChanged')
    require(str(uuid.UUID(base['display'])).lower() == base['display'].lower() and
            all(type(base[k]) is int and base[k] > 0 for k in ('space','panel','hostPID','hostBirth','fixturePID','fixtureBirth')) and
            base['hostPID'] != base['fixturePID'] and len(base['numbers']) == 2 and
            len(set([*base['numbers'],base['panel']])) == 3 and all(type(n) is int and n>0 for n in base['numbers']),
            'invalidWindowIdentity')
    app, fixture = result['installed'], result['fixture']
    require(app.get('bundle') == 'com.holdsnow.nearpane.alpha' and str(app.get('build')) == '90' and
            app.get('pid') == base['hostPID'] and app.get('cdHash') == base['hostHash'] and
            all(isinstance(base[k], str) and re.fullmatch('[0-9a-f]{40}',base[k]) for k in ('hostHash','fixtureHash')) and
            fixture.get('presentation') == 'paired-preview' and fixture.get('numbers') == base['numbers'] and
            fixture.get('pid') == base['fixturePID'] and fixture.get('birth') == base['fixtureBirth'], 'installedOrFixtureGenerationMismatch')
    crops = base['pictures']
    require(len(crops) == 2 and crops[0] != crops[1] and all(len(c) == 4 and c[2:] == [4,4] and all(math.isfinite(v) for v in c) for c in crops),
            'unboundPanelCrops')
    if not sampler:return base
    sampler = result['sampler']
    require(sampler.get('exit') == 0 and sampler.get('timedOut') is False and
            any(e.get('completedBatches') == len(result['samples']) for e in sampler['events']), 'incompletePhysicalSampler')
    return base


def known_patch(block, document, epoch):
    # Every raw byte must belong to one uniform opaque synthetic marker. A majority match
    # would expose minority pixels such as handwriting, a caret, or a piece of another app.
    p = block[:4]
    if len(block) != 256 or p[3] != 255 or p*64 != block:
        return False
    distances = sorted((max(abs(a-b) for a,b in zip(p[:3],rgb)),d,e)
                       for e,pair in enumerate(PALETTE) for d,rgb in enumerate(pair))
    best, next_ = distances[:2]
    return best[1:] == (document,epoch) and best[0] <= 29 and next_[0]-best[0] >= 9


def validated_frames(result, proof, folder):
    batches, seen, frames = result['samples'], set(), []
    for event in result['sampler']['events']:
        if 'witness' not in event:
            continue
        witness = event['witness']
        i, e = witness['batch'], witness['epoch']
        require(type(i) is int and 1 <= i <= len(batches) and i not in seen and
                type(e) is int and e in range(len(PALETTE)), 'invalidWitnessBatch')
        seen.add(i)
        require(all(witness.get(k) == proof[k] for k in ('hostPID','fixturePID','panel','numbers')) and (witness.get('cardKinds') == LIVE or (witness.get('physicalFourPatch') is True and proof.get('cardIdentityProven') is True)),
                'witnessNotBoundToBothLiveCards')
        row = batches[i-1]
        require(len(row) == 4 and [o['color'] for o in row] == [f'0/{e}',f'1/{e}']*2 and
                all(row[2].get(k) == row[3].get(k) for k in ('start','end','displayTime','frameStatus')),
                'differentPanelFrameOrSourceMarker')
        before, after = witness['bindingBefore'], witness['bindingAfter']
        require(all(isinstance(v,(float,int)) and math.isfinite(v) for v in (before,after)) and
                all(before <= o['start'] <= o['end'] <= after and o.get('frameStatus') in (None,0,4) for o in row) and
                after-before <= 3 and witness['uptime'] == row[2]['end'], 'unbracketedWindowAndPixelObservation')
        presented = row[2].get('displayTime')
        require(presented is None or math.isfinite(presented) and 0 < presented <= row[2]['end']+.005, 'invalidSystemDisplayTime')
        name = witness['file']
        require(isinstance(name,str) and re.fullmatch(r'preview-[0-9]{5}\.rgba',name) and int(name[8:13]) == i, 'invalidWitnessName')
        data = regular_file(folder/name, 1024)
        require(len(data) == 1024 and sha(data) == witness.get('sha256'), 'witnessDigestMismatch')
        patches = [data[j:j+256] for j in range(0,1024,256)]
        require(all(known_patch(p,j%2,e) for j,p in enumerate(patches)), 'nonFixturePixelOrWrongCard')
        frames.append({'batch':i,'epoch':e,'panelInterval':[row[2]['start'],row[2]['end']],
                       'displayTime':presented,'file':name,'sha256':sha(data),'panels':patches[2:]})
    frames.sort(key=lambda f:f['batch'])
    return frames


def chunk(kind, body):
    return struct.pack('>I',len(body)) + kind + body + struct.pack('>I',zlib.crc32(kind+body))


def encoded_crop(pixels):
    # All eight scanlines and all 64 pixels are copied directly from the panel's original sample.
    return zlib.compress(b''.join(b'\0'+pixels[i:i+32] for i in range(0,256,32)))


def make_png(frames, doc, times=None):
    pieces = [SIGNATURE,chunk(b'IHDR',struct.pack('>IIBBBBB',8,8,8,6,0,0,0))]
    if times is None:
        pieces.append(chunk(b'IDAT',encoded_crop(frames[0]['panels'][doc])))
    else:
        pieces.append(chunk(b'acTL',struct.pack('>II',len(frames),1)))
        seq=0
        for i,frame in enumerate(frames):
            ms = max(1,round(1000*(times[i+1]-times[i]))) if i+1 < len(times) else 1
            pieces.append(chunk(b'fcTL',struct.pack('>IIIIIHHBB',seq,8,8,0,0,ms,1000,0,0)))
            seq+=1
            raw=encoded_crop(frame['panels'][doc])
            if i==0:
                pieces.append(chunk(b'IDAT',raw))
            else:
                pieces.append(chunk(b'fdAT',struct.pack('>I',seq)+raw))
                seq+=1
    pieces.append(chunk(b'IEND',b''))
    return b''.join(pieces)


def choose_clip(frames):
    # Never bridge an unobserved/mismatching batch. Each selected sample comes from a
    # real panel frame. Delays describe playback only; continuous presentation is unmeasured.
    best, run = [], []
    for f in frames:
        if run and (f['batch'] != run[-1]['batch']+1 or not 0 < f['panelInterval'][1]-run[-1]['panelInterval'][1] <= .5):
            run=[]
        run.append(f)
        while run[-1]['panelInterval'][1]-run[0]['panelInterval'][1]>5:
            run.pop(0)
        if len({p['epoch'] for p in run})>1 and len(run)>len(best):
            best=run.copy()
    return best


def independent_window_crop(ov, proof):
    panel_frame=ov.get('panelFrame')
    cards=ov.get('retainedCardFrames')
    def rectangle(r):
        return isinstance(r,list) and len(r)==4 and all(type(v) in (int,float) and math.isfinite(v) for v in r) and r[2]>0 and r[3]>0
    def contains(outer,inner):
        x,y,w,h=inner
        return outer[0]<=x and outer[1]<=y and x+w<=outer[0]+outer[2] and y+h<=outer[1]+outer[3]
    census=proof.get('windowCensus') or {}
    require(ov.get('filterStyle')=='window' and ov.get('includedWindowNumbers')==[proof['panel']] and
            ov.get('nativeTransparencyBacking')==ov.get('cardGapBacking')=='solidWhite' and ov.get('captureIncludesChildWindows') is False and
            ov.get('retainedCardIDs')==[f"current-desktop-window:{proof['fixturePID']}:{n}" for n in proof['numbers']] and
            census.get('admitted') is True and census.get('expectedProven') is True and census.get('expected')==proof['numbers'] and
            census.get('unknown')==census.get('unresolved')==0,'uncertifiedIndependentWindow')
    require(rectangle(panel_frame) and isinstance(cards,list) and len(cards)==2 and all(rectangle(c) for c in cards) and
            cards==[r.get('frame') for r in proof.get('cardGeometry',[])] and
            all(contains(panel_frame,c) and contains(c,patch) for c,patch in zip(cards,proof['pictures'])),'unboundRetainedCardFrames')
    upper,lower=sorted(cards,key=lambda r:r[1])
    x0,y0=math.ceil(min(r[0] for r in cards)),math.ceil(upper[1])
    x1,y1=math.floor(max(r[0]+r[2] for r in cards)),math.floor(lower[1]+lower[3])
    require(0<=lower[1]-upper[1]-upper[3]<=18 and abs(upper[0]-lower[0])<=1 and
            abs(upper[0]+upper[2]-lower[0]-lower[2])<=1 and ov['crop']==[x0,y0,x1-x0,y1-y0] and ov['crop']!=panel_frame,
            'unboundedRetainedCardUnion')
    intervals=ov.get('sourceSamples')
    require(isinstance(intervals,list) and len(intervals)==2 and all(isinstance(t,list) and len(t)==2 and
            all(type(v) in (int,float) and math.isfinite(v) for v in t) and
            ov['bindingBefore']<=t[0]<=t[1]<=ov['bindingAfter'] for t in intervals),'unbracketedWindowReferences')
    return {k:ov[k] for k in ('captureSource','filterStyle','includedWindowNumbers','nativeTransparencyBacking','cardGapBacking',
                                'captureIncludesChildWindows','panelFrame','retainedCardFrames','retainedCardIDs','fixedCaptions','sourceSamples')}


def readable_overview(result,proof,witness):
    ov = result.get('overview') or {}
    if ov.get('status') != 'CAPTURED':
        reason=ov.get('reason','noPhysicalTwoCardCrop')
        return {'status':'BLOCKED','reason':reason if isinstance(reason,str) and re.fullmatch('[A-Za-z][A-Za-z0-9]{0,90}',reason) else 'unconfirmedTwoCardCrop'},None
    require(ov.get('file') == 'paired-overview.png' and all(ov.get(k) == proof[k] for k in ('display','space','hostPID','hostBirth','hostHash','panel','fixturePID','fixtureBirth','fixtureHash','numbers')) and
            all(ov.get(k) is True for k in ('singleIncludedHostWindow','beforeAfterScopeEqual','isolatedProfile','sourceDocumentsEmpty')) and
            ov.get('fixedCaptions') == ['Field Notes · 1','Field Notes · 2'] and ov.get('otherControlsInCrop') == 0,
            'uncertifiedReadableCrop')
    crop,scale=ov['crop'],ov['scale']
    require(isinstance(crop,list) and len(crop)==4 and all(math.isfinite(v) and int(v)==v for v in crop) and
            type(scale) is int and 1<=scale<=4 and 25<=crop[2]<=450 and 25<=crop[3]<=650 and
            (crop[2]*scale,crop[3]*scale)==(ov['width'],ov['height']) and
            all(crop[0]<=x and crop[1]<=y and x+w<=crop[0]+crop[2] and y+h<=crop[1]+crop[3] for x,y,w,h in proof['pictures']),
            'readableCropSizeOrGeometryChanged')
    timing=ov['panelSample']
    require(isinstance(timing,list) and len(timing)==2 and all(math.isfinite(n) for n in [*timing,ov['bindingBefore'],ov['bindingAfter']]) and
            0<ov['bindingBefore']<=timing[0]<=timing[1]<=ov['bindingAfter'], 'unbracketedReadableCrop')
    epoch=ov['epoch']
    require(type(epoch) is int and epoch in range(len(PALETTE)) and ov.get('sourceEpochs') == ov.get('cardEpochs') == [epoch,epoch], 'readableCropColorMismatch')
    if ov.get('captureSource')=='desktopIndependentWindow':
        evidence=independent_window_crop(ov,proof)
    else:
        require('captureSource' not in ov and ov.get('otherNonDesktopSurfacesInCrop')==0,'unrecognizedReadableCaptureSource')
        evidence={'captureSource':'displayIncludingBoundWindow'}
    data=regular_file(witness/'paired-overview.png',12_000_000)
    require(sha(data) == ov.get('sha256') and data[:8] == SIGNATURE and data[12:16] == b'IHDR' and
            len(data) >= 40 and struct.unpack('>II',data[16:24]) == (ov['width'],ov['height']), 'readablePNGChanged')
    evidence.update({k:ov[k] for k in ('status','file','sha256','width','height','crop','scale','epoch','panelSample')})
    return evidence,data


def public_reason(error):
    # Never copy an arbitrary path, private label or exception message into a shareable receipt.
    reason=str(error)
    return reason if re.fullmatch(r'[A-Za-z][A-Za-z0-9]{0,90}',reason) else 'invalidOrMissingEvidence'


def publish(output):
    output=output.resolve()
    receipt={'version':1,'status':'NOT_CAPTURED','nativeStageManagerComparison':{'status':'NOT_MEASURED','latencyMs':None,
              'reason':'No verified macOS thumbnail-to-fixture-window identity and same-frame camera entry point in this harness.'}}
    target=output/'media'
    require(not target.exists(), 'existingMediaDirectory')
    with tempfile.TemporaryDirectory(prefix='.paired-media-',dir=output) as temporary:
        staging=Path(temporary)/'media'
        staging.mkdir(mode=0o700)
        try:
            raw=regular_file(output/'result.json',12_000_000)
            result=json.loads(raw)
            proof=binding(result,sampler=False)
            witness=output/'witness'
            require(witness.is_dir() and not witness.is_symlink(), 'missingOriginalWitnessDirectory')
            failures=(ValueError,KeyError,TypeError,IndexError,AttributeError,OverflowError,OSError)
            try:
                frames=validated_frames(result,binding(result),witness)
                receipt['microCrops']={'status':'CAPTURED' if frames else 'NOT_CAPTURED','qualifiedFrames':len(frames)}
            except failures as error:
                frames=[]
                receipt['microCrops']={'status':'BLOCKED','reason':public_reason(error)}
            try:
                overview, image = readable_overview(result,proof,witness)
            except failures as error:
                overview,image={'status':'BLOCKED','reason':public_reason(error)},None
            receipt.update(sourceReceiptSHA256=sha(raw),physicalRunStatus=result['status'],readableOverview=overview,
                           binding={k:proof[k] for k in MATCH_KEYS if k not in ('sources',)},
                           sampling='Two native 8 by 8 physical-pixel card crops from the same installed Host panel frame. No interpolation.')
            files={}
            if image is not None:
                files['paired-overview.png']=image
            if "cardFilm" in result:
                from paired_card_film import NAME,verify
                film=result["cardFilm"]
                try:
                    if film.get("status")!="CAPTURED":raise ValueError(film.get("reason","uncertifiedCardFilm"))
                    bound=result["filmBinding"]
                    require(all(proof[k]==bound[k] for k in MATCH_KEYS),"filmSourceGenerationChanged")
                    movie=regular_file(witness/NAME,18_000_000);verify(film,bound,movie)
                    files[NAME]=movie;receipt["readableFilm"]=film
                except failures as error:
                    receipt["readableFilm"]={"status":"BLOCKED","reason":public_reason(error)}
            first={}
            for f in frames:
                first.setdefault(f['epoch'],f)
            for e,f in first.items():
                for d in range(2):
                    files[f'epoch-{e}-card-{d+1}.png']=make_png([f],d)
            receipt['samples']=[{k:v for k,v in frame.items() if k!='panels'} for frame in frames]
            clip=choose_clip(frames)
            if clip:
                times=[f['displayTime'] for f in clip]
                use_display=all(t is not None for t in times) and all(0<b-a<=.5 for a,b in zip(times,times[1:]))
                if not use_display:
                    times=[f['panelInterval'][1] for f in clip]
                for d in range(2):
                    files[f'sampled-card-{d+1}.apng']=make_png(clip,d,times)
                receipt['sampledClip']={'status':'CAPTURED','timing':'systemDisplayTime' if use_display else 'sampleCompletionTimes',
                    'batches':[f['batch'] for f in clip],'times':times,'maximumGapMs':max((b-a)*1000 for a,b in zip(times,times[1:]))}
            else:
                receipt['sampledClip']={'status':'NOT_CAPTURED','reason':'noConsecutiveCertifiedBatchesSpanningAColorChange'}
            receipt['files']={name:sha(data) for name,data in files.items()}
            for name,data in files.items():
                (staging/name).write_bytes(data)
            receipt['status']='CAPTURED' if files else 'NOT_CAPTURED'
            if not files:
                receipt['reason']='noVerifiedPixels'
        except (ValueError,KeyError,TypeError,IndexError,AttributeError,OverflowError,OSError) as error:
            # Keep output shareable even if input contains unrelated text or arbitrary paths.
            receipt['reason']=public_reason(error)
            for file in staging.iterdir():
                file.unlink()
        (staging/'receipt.json').write_text(json.dumps(receipt,indent=2,ensure_ascii=False,allow_nan=False)+'\n')
        staging.rename(target)
    return receipt


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path,help='completed isolated paired-preview output containing result.json and witness/')
    args=parser.parse_args()
    try:
        report=publish(args.output)
    except (OSError,ValueError):
        raise SystemExit('Output must be an existing physical receipt directory without a media directory.')
    print(json.dumps({'status':report['status'],'receipt':'media/receipt.json'}))
    raise SystemExit(0 if report['status']=='CAPTURED' else 2)
