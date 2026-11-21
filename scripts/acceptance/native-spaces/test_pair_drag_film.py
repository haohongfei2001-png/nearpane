"""No screen capture or GUI. Exercise the matte, native clock encoding and runner failure paths."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

from pair_drag_film import PairDragFilm

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]


class PairDragFilmTests(unittest.TestCase):
    def test_absent_collector_does_not_change_gesture_or_write_media(self):
        with tempfile.TemporaryDirectory() as folder:
            run=SimpleNamespace(kit=Path(folder))
            entry={"issued":False,"status":"NOT_RUN"}
            film=PairDragFilm.start(run,entry,{},[])
            self.assertEqual(film.finish(entry)["status"],"NOT_RUN")
            self.assertEqual(entry,{"issued":False,"status":"NOT_RUN"})
            self.assertEqual(list(Path(folder).iterdir()),[])

    def test_unconfirmed_drag_discards_partial_movie(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);film=PairDragFilm();film.folder=root/"exclusive"
            film.folder.mkdir();(film.folder/"encoding.mp4").write_bytes(b"partial synthetic test")
            film.row["status"]="ARMED"
            self.assertEqual(film.finish({"status":"UNKNOWN","issued":True})["reason"],"rightDragLacksTwoSuccessfulNativeLayoutReads")
            self.assertEqual(list(root.iterdir()),[])

    def test_compositor_matte_and_original_timestamps(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);tool=root/"checks";reader=root/"reader.o";movie=root/"synthetic.mp4"
            inc=ROOT/"Sources/CReadOnlySpaces/include"
            subprocess.run(["xcrun","clang","-I",inc,"-c",ROOT/"Sources/CReadOnlySpaces/ReadOnlySpaces.c","-o",reader],check=True)
            names=("pair-pointer-palette.swift","screen-presentation-clock.swift","p2-document-physical.swift","paired-preview-palette.swift",
                   "paired-preview-overview.swift","paired-card-film.swift","paired-card-apng.swift","pair-drag-film.swift","pair-drag-film-checks.swift")
            subprocess.run(["xcrun","swiftc","-suppress-warnings","-D","PAIRED_OVERVIEW_TEST","-D","CARD_FILM","-D","PAIR_DRAG_FILM_SELFTEST",
                            "-parse-as-library","-Xcc","-I","-Xcc",inc,"-import-objc-header",HERE/"contract_members.h",
                            *(HERE/n for n in names),reader,"-o",tool],check=True,timeout=60)
            row=json.loads(subprocess.check_output([tool,movie],timeout=10))
            self.assertEqual(row,{"status":"PASS","mode":"offline","opaquePixelsChecked":6144,"decodedFrames":3,"audioTracks":0,"duration":0.275})


if __name__=="__main__":
    unittest.main()
