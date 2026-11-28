"""Validate and copy a separately timed, silent recording of exactly two installed Host cards."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import tempfile
import subprocess
import zlib

from space_scope import private_file, require

NAME="paired-cards.mp4"
KEYS=("hostPID","hostBirth","hostHash","panel","fixturePID","fixtureBirth","fixtureHash","numbers","display","space")


def verify(film, proof, data):
    require(film.get("status")=="CAPTURED" and film.get("file")==NAME and all(film.get(k)==proof[k] for k in KEYS),
            "filmSignedWindowBindingChanged")
    require(proof["present"]==[True,True] and proof["cardIdentityProven"] is True and proof["pictureInteriorsProven"] is True
            and proof["windowCensus"].get("admitted") is True and film.get("includedWindowNumbers")==[proof["panel"]]
            and film.get("captureSource")=="desktopIndependentWindow" and film.get("captureIncludesChildWindows") is False
            and film.get("timingMeasurement") is False and film.get("nativeTransparencyBacking")==film.get("cardGapBacking")=="solidWhite"
            and film.get("fixedCaptions")==["Field Notes · 1","Field Notes · 2"] and film.get("audioTracks")==0,
            "filmCaptureScopeUnconfirmed")
    require(film.get("retainedCardIDs")==[f"current-desktop-window:{proof['fixturePID']}:{n}" for n in proof['numbers']]
            and film.get("retainedCardFrames")==[r['frame'] for r in proof['cardGeometry']], "filmCardGeometryUnconfirmed")
    upper,lower=sorted(film["retainedCardFrames"],key=lambda c:c[1])
    x=math.ceil(min(upper[0],lower[0]));y=math.ceil(upper[1]);right=math.floor(max(c[0]+c[2] for c in (upper,lower)))
    bottom=math.floor(lower[1]+lower[3])
    require(len(data)<=18_000_000 and len(data)>32 and data[4:8]==b"ftyp" and hashlib.sha256(data).hexdigest()==film.get("sha256")
            and film.get("crop")==[x,y,right-x,bottom-y] and 0<=lower[1]-upper[1]-upper[3]<=18
            and abs(upper[0]-lower[0])<=1 and abs(upper[0]+upper[2]-lower[0]-lower[2])<=1
            and type(film["scale"]) is int and 1<=film["scale"]<=4 and
            (film["width"],film["height"])==((right-x)*film["scale"],(bottom-y)*film["scale"]), "filmFileOrNativeDimensionsChanged")
    frames,checks,container=film["frames"],film["scopeReads"],film["container"]
    require(5<=len(frames)<=110 and container["encodedFrames"]==len(frames)-1 and container["audioTracks"]==0
            and container["videoTracks"]==1 and container["timescale"]==60000,"filmEncodedFramesUnconfirmed")
    def finite(t):
        return type(t) in (int,float) and math.isfinite(t)
    require(all(isinstance(c,list) and len(c)==2 and all(finite(t) for t in c) and c[0]<=c[1] for c in checks)
            and all(a[1]<=b[0] for a,b in zip(checks,checks[1:])),"filmScopeReadBoundariesChanged")
    base,new=film["initialEpoch"],film["newEpoch"]
    require(type(base) is int and type(new) is int and base in range(7) and new in range(7) and base!=new
            and frames[0]["cardEpochs"]==[base,base] and finite(film["fixtureChangedAt"]),"filmFixtureEpochUnconfirmed")
    references=film["sourceObservations"]
    require(references[0]["stage"]=="initial" and references[0]["epochs"]==[base,base] and
            any(r["stage"]=="postCommand" and r["epochs"]==[new,new] for r in references),"filmMissingIndependentSourceRead")
    for r in references:
        require(len(r["samples"])==2 and all(len(times)==2 and all(finite(t) for t in times) and times[0]<=times[1] for times in r["samples"]),
                "filmUnclockedSourceRead")
    coverage=film.get("coverage","completeInterval")
    if coverage=="certifiedPrefix":
        cut=film.get("markerRefusal",{})
        require(cut.get("reason") in ("unexpectedFixtureMarker","unconfirmedPixelsInFixtureBody") and
                cut["site"] in ("hostCard","terminalSource") and (cut["document"] in (0,1) if cut["site"]=="hostCard" else cut["document"] is None) and
                cut.get("pixelsRetained") is False and finite(cut["cutoffUptime"]) and finite(cut["callbackUptime"]) and
                cut["cutoffUptime"]<=cut["callbackUptime"]+.01 and checks[-1][1]<cut["cutoffUptime"] and frames[-1]["callbackUptime"]<=checks[-1][0] and
                all(any(c[1]<=a for c in checks) and any(c[0]>=b for c in checks) for r in references for a,b in r["samples"]),
                "filmUnverifiedFrameOrReferenceInPrefix")
    else:
        require(coverage=="completeInterval" and "markerRefusal" not in film and references[-1]["stage"]=="terminal" and
                references[-1]["epochs"]==[new,new],"filmTerminalSourceUnconfirmed")
    max_gap=0
    for i,f in enumerate(frames):
        before,after=f["scopeReads"];t=f["presentationUptime"];callback=f["callbackUptime"]
        require(type(before) is int and type(after) is int and 0<=before<after<len(checks) and
                all(finite(v) for v in (t,callback,f["relativeTime"])) and checks[before][1]<=t<=callback+0.01 and
                callback<=checks[after][0] and checks[after][1]-checks[before][0]<=2.5 and
                f["encoded"] is (i<len(frames)-1) and len(f["cardEpochs"])==2 and
                all(c==base or (c==new and t>=film["fixtureChangedAt"]) for c in f["cardEpochs"]) and
                re.fullmatch("[0-9a-f]{64}",f["cropSHA256"]) and type(f["displayTicks"]) is int and f["displayTicks"]>0 and
                type(f["ptsValue"]) is int and type(f["ptsTimescale"]) is int and f["ptsTimescale"]>0 and
                abs(f["relativeTime"]-(t-frames[0]["presentationUptime"]))<0.00001,"filmUnboundPresentation")
        if i:
            p=frames[i-1];gap=t-p["presentationUptime"]
            require(0<gap<=0.75 and f["displayTicks"]>p["displayTicks"] and
                    f["ptsValue"]*p["ptsTimescale"]>p["ptsValue"]*f["ptsTimescale"],"filmUnobservedInterval")
            max_gap=max(max_gap,gap)
    require(abs(max_gap-film["maximumPresentationGapSeconds"])<0.00001 and
            2<=frames[-1]["relativeTime"]<=10 and abs(container["duration"]-frames[-1]["relativeTime"])<=0.002 and
            film["bothChangedInEncodedFrames"] is any(f["cardEpochs"]==[new,new] for f in frames[:-1]),"filmDurationOrChangeUnconfirmed")


APNG_NAME = "paired-cards.apng"
APNG_LIMIT = 48 * 1024 * 1024


def verify_lossless(film, data):
    """Decode each full RGBA raster and match its sealed BGRA digest and display time."""
    animation = film["losslessAnimation"]
    frames = film["frames"]
    width, height = film["width"], film["height"]
    scale = 60_000
    require(
        film["status"] == animation["status"] == "CAPTURED" and animation["file"] == APNG_NAME
        and animation["frames"] == len(frames) - 1 == film["container"]["encodedFrames"]
        and animation["systemDecodedExactBGRAFrames"] == animation["frames"]
        and animation["width"] == width and animation["height"] == height
        and 0 < width <= 8192 and 0 < height <= 8192 and width * height <= 1_000_000
        and 2 <= len(frames) <= 110 and animation["timescale"] == scale
        and animation["plays"] == 1 and animation["includesTerminalPicture"] is False
        and animation["originalPTS"] == "NearpanePresentationTimes"
        and 0 < len(data) <= APNG_LIMIT and hashlib.sha256(data).hexdigest() == animation["sha256"]
        and data.startswith(bytes.fromhex("89504e470d0a1a0a")), "losslessFilmEnvelopeChanged")

    pos = 8
    def payload(expected):
        nonlocal pos
        require(pos + 12 <= len(data), "losslessTruncatedChunk")
        size, tag = struct.unpack_from(">I4s", data, pos)
        end = pos + 8 + size
        require(tag == expected and end + 4 <= len(data)
                and zlib.crc32(data[pos+4:end]) == struct.unpack_from(">I", data, end)[0],
                "losslessUnexpectedOrCorruptedChunk")
        contents = data[pos+8:end]
        pos = end + 4
        return contents

    require(payload(b"IHDR") == struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
            and payload(b"sRGB") == bytes(1)
            and payload(b"acTL") == struct.pack(">II", len(frames) - 1, 1), "losslessNativeRasterChanged")
    embedded = payload(b"iTXt")
    keyword = b"NearpanePresentationTimes" + bytes(5)
    clock_fields = ("displayTicks", "ptsValue", "ptsTimescale", "ptsEpoch")
    clocks = [[f[key] for key in clock_fields] for f in frames]
    require(embedded.startswith(keyword) and json.loads(embedded[len(keyword):]) == clocks,
            "losslessOriginalPTSChanged")

    sequence = total = 0
    max_boundary_error = max_delay_error = 0.0
    stride = 1 + width * 4
    for index, (frame, following) in enumerate(zip(frames, frames[1:])):
        control = payload(b"fcTL")
        require(len(control) == 26, "losslessFrameControlLength")
        number, w, h, x, y, delay, den, dispose, blend = struct.unpack(">IIIIIHHBB", control)
        require((number, w, h, x, y, den, dispose, blend) == (sequence, width, height, 0, 0, scale, 0, 0)
                and delay > 0 and frame["encoded"] is True, "losslessFrameReorderedOrBlended")
        sequence += 1
        total += delay
        start, end = frame["relativeTime"], following["relativeTime"]
        require(delay == math.floor(end * scale + .5) - math.floor(start * scale + .5),
                "losslessFrameDurationChanged")
        error = abs(total / scale - end)
        require(error <= .5 / scale + 1e-10, "losslessFrameDurationChanged")
        max_boundary_error = max(max_boundary_error, error)
        max_delay_error = max(max_delay_error, abs(delay / scale - (end - start)))

        compressed = payload(b"IDAT" if index == 0 else b"fdAT")
        if index:
            require(compressed[:4] == struct.pack(">I", sequence), "losslessDataSequenceMismatch")
            sequence += 1
            compressed = compressed[4:]
        decoder = zlib.decompressobj()
        scan = decoder.decompress(compressed, stride * height + 1)
        require(len(scan) == stride * height and decoder.eof and not decoder.unused_data
                and not decoder.unconsumed_tail and scan[::stride] == bytes(height), "losslessUnverifiedScanline")
        rgba = b"".join(scan[y*stride+1:(y+1)*stride] for y in range(height))
        require(rgba[3::4] == bytes([255]) * (width * height), "losslessNonOpaquePixels")
        bgra = bytearray(rgba)
        bgra[0::4] = rgba[2::4]
        bgra[2::4] = rgba[0::4]
        require(hashlib.sha256(bgra).hexdigest() == frame["cropSHA256"], "losslessDecodedPixelsDifferFromOriginal")

    require(payload(b"IEND") == b"" and pos == len(data) and frames[-1]["encoded"] is False
            and abs(1e6 * max_boundary_error - animation["maxPlaybackBoundaryErrorMicroseconds"]) < .001
            and abs(1e6 * max_delay_error - animation["maxFrameDelayErrorMicroseconds"]) < .001,
            "losslessTerminalOrPlaybackErrorChanged")
    return {"frames": len(frames)-1, "exactBGRA": True, "originalPTS": True,
            "maxPlaybackBoundaryErrorMicroseconds": 1e6 * max_boundary_error,
            "maxFrameDelayErrorMicroseconds": 1e6 * max_delay_error}


def capture(kit, folder, out, proof):
    binary=kit/"paired-overview"
    if not binary.is_file():return {"status":"BLOCKED","reason":"optionalFilmKitUnavailable"}
    subprocess.run(["/usr/bin/codesign","--verify","--strict",str(binary)],check=True,timeout=4)
    # Acquisition has its own 5.5 s deadline; H.264 and lossless readback run after the stream closes.
    run=subprocess.run([binary,folder,"--film"],input=json.dumps(proof),text=True,capture_output=True,timeout=30)
    film=json.loads(run.stdout)
    if film.get("status")!="CAPTURED":return film
    require(run.returncode==0,"filmReaderFailed")
    data=private_file((folder/NAME).absolute(),limit=18_000_000)
    verify(film,proof,data)
    target=out/"witness";target.mkdir(mode=0o700,exist_ok=True)
    with (target/NAME).open("xb") as f:f.write(data)
    animation=film.get("losslessAnimation",{})
    if animation.get("status")=="CAPTURED":
        try:
            raw=private_file((folder/APNG_NAME).absolute(),limit=APNG_LIMIT)
            verify_lossless(film,raw)
            # Publish a completed file without clobbering existing evidence.
            with tempfile.NamedTemporaryFile(dir=target,prefix=".paired-apng-") as tmp:
                tmp.write(raw);tmp.flush()
                os.link(tmp.name,target/APNG_NAME)
        except (ValueError,KeyError,TypeError,IndexError,OSError,struct.error,zlib.error):
            film["losslessAnimation"]={"status":"BLOCKED","reason":"losslessReadbackOrWitnessCopyFailed"}
    return film

if __name__=="__main__":
    import argparse
    parser=argparse.ArgumentParser(description="Verify the two-card film and decode every APNG pixel against its original presentation receipt.")
    parser.add_argument("output",type=Path,help="directory containing result.json and the local witness/ or archived media/")
    args=parser.parse_args()
    try:
        run=json.loads((args.output/"result.json").read_bytes())
        folder=args.output/"witness" if (args.output/"witness"/APNG_NAME).is_file() else args.output/"media"
        film=run["cardFilm"]
        verify(film,run["filmBinding"],(folder/NAME).read_bytes())
        if film.get("losslessAnimation",{}).get("status") != "CAPTURED":
            parser.exit(2,"No certified lossless frame file was retained for this capture.\n")
        print(json.dumps(verify_lossless(film,(folder/APNG_NAME).read_bytes()),sort_keys=True))
    except (KeyError,TypeError,ValueError,OSError,IndexError,struct.error,zlib.error) as error:
        parser.exit(2,f"Cannot verify lossless pair ({type(error).__name__}).\n")
