"""Offline tests for the two-card evidence stream. Never start a capture or an application."""
import copy
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from paired_card_film import verify

HERE=Path(__file__).resolve().parent

class CardFilmTests(unittest.TestCase):
    def example(self):
        fixture=[31,32];cardframes=[[0,0,80,25],[0,30,80,25]]
        proof=dict(hostPID=50,hostBirth=101,hostHash="a"*40,panel=55,fixturePID=65,fixtureBirth=111,
                   fixtureHash="b"*40,numbers=fixture,display="owned",space=13,present=[True,True],cardIdentityProven=True,
                   pictureInteriorsProven=True,windowCensus={"admitted":True},cardGeometry=[{"frame":r} for r in cardframes])
        data=b"\x00\x00\x00\x24ftyp"+b"x"*40
        times=[20.125+i*.4 for i in range(7)]
        frames=[dict(displayTicks=10000+i,ptsValue=100*i,ptsTimescale=250,presentationUptime=t,callbackUptime=t+.02,
                     relativeTime=t-times[0],encoded=i<len(times)-1,cardEpochs=[0,0] if i<2 else [0,3] if i==2 else [3,3],
                     scopeReads=[i,i+1],cropSHA256="c"*64) for i,t in enumerate(times)]
        film=dict(**{k:proof[k] for k in ("hostPID","hostBirth","hostHash","panel","fixturePID","fixtureBirth","fixtureHash","numbers","space","display")},
                  status="CAPTURED",file="paired-cards.mp4",sha256=hashlib.sha256(data).hexdigest(),includedWindowNumbers=[55],
                  captureSource="desktopIndependentWindow",captureIncludesChildWindows=False,timingMeasurement=False,
                  nativeTransparencyBacking="solidWhite",cardGapBacking="solidWhite",fixedCaptions=["Field Notes · 1","Field Notes · 2"],
                  audioTracks=0,retainedCardIDs=["current-desktop-window:65:31","current-desktop-window:65:32"],retainedCardFrames=cardframes,
                  crop=[0,0,80,55],scale=2,width=160,height=110,initialEpoch=0,newEpoch=3,fixtureChangedAt=20.8,
                  frames=frames,scopeReads=[[20+i*.4,20+i*.4+.03] for i in range(8)],
                  maximumPresentationGapSeconds=.4,bothChangedInEncodedFrames=True,sourceObservations=[
                      dict(stage="initial",epochs=[0,0],samples=[[19,19.1],[19,19.1]]),
                      dict(stage="postCommand",epochs=[3,3],samples=[[21,21.1],[21,21.1]]),
                      dict(stage="terminal",epochs=[3,3],samples=[[23,23.1],[23,23.1]])],
                  container=dict(videoTracks=1,audioTracks=0,duration=2.4,timescale=60000,encodedFrames=6))
        return proof,film,data

    def test_individual_native_cards_can_change_at_different_real_presentations(self):
        proof,film,data=self.example();verify(film,proof,data)
        film["frames"][3]["cardEpochs"]=[0,3]
        verify(film,proof,data)

    def test_reject_wrong_source_unknown_gap_audio_timing_or_unbound_frame(self):
        proof,film,data=self.example()
        for change in [lambda f:f.update(includedWindowNumbers=[55,56]),lambda f:f.update(hostBirth=12),
                       lambda f:f.update(fixtureChangedAt=22),lambda f:f["frames"][2].update(scopeReads=[4,5]),
                       lambda f:f["frames"][3].update(cardEpochs=[2,3]),lambda f:f["frames"][4].update(presentationUptime=21.87),
                       lambda f:f["frames"][3].update(ptsValue=-1),lambda f:f["frames"][0].update(encoded=False),
                       lambda f:f.update(sourceObservations=f["sourceObservations"][-1:]),lambda f:f["container"].update(audioTracks=1),
                       lambda f:f.update(sha256="d"*64)]:
            altered=copy.deepcopy(film);change(altered)
            with self.assertRaises((RuntimeError,ValueError)):verify(altered,proof,data)

    @unittest.skipUnless(sys.platform=="darwin" and shutil.which("xcrun"),"requires macOS native movie encoder")
    def test_native_vfr_timeline_decodes_without_a_screen_or_audio(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp",prefix="nearpane-card-film-test.") as tmp:
            folder=Path(tmp);main=folder/"offline.swift";binary=folder/"check"
            main.write_text('''import Foundation
@main struct Check {
    static func main() async throws {
        let g=[CardFilmScopeRead(start:1,end:1.05),CardFilmScopeRead(start:1.5,end:1.55),CardFilmScopeRead(start:1.9,end:1.99)]
        precondition(cardFilmBracket(1.1,1.15,g)==[0,1])
        precondition(cardFilmBracket(1.53,1.60,g)==[0,2])
        precondition(cardFilmBracket(0.9,1.1,g)==nil)
        precondition(cardFilmBracket(1.6,2.0,g)==nil)
        let mark=PairedFilmMarker(session:"run",pid:5,birth:12,numbers:[13,14],epoch:3,issued:10)
        precondition(mark.admits(session:"run",pid:5,birth:12,numbers:[13,14],now:11))
        precondition(!mark.admits(session:"run",pid:5,birth:12,numbers:[13,14],now:18))
        precondition(!mark.admits(session:"run",pid:5,birth:13,numbers:[13,14],now:11))
        try await PairedCardFilm.testEncoding(URL(fileURLWithPath:CommandLine.arguments[1]))
    }
}''')
            subprocess.run(["xcrun","swiftc","-suppress-warnings","-parse-as-library","-D","PAIRED_OVERVIEW_TEST","-D","CARD_FILM_TEST",
                            HERE/"paired-preview-palette.swift",HERE/"paired-preview-overview.swift",HERE/"paired-card-film.swift",main,"-o",binary],check=True,timeout=60)
            subprocess.run([binary,folder/"encoded.mp4"],check=True,timeout=8)

if __name__=="__main__":unittest.main()
