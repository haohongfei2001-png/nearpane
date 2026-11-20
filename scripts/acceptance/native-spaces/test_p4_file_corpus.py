from array import array
import importlib
import random
import unittest

corpus=importlib.import_module("p4-file-corpus")


class DigitalOnsetEvidence(unittest.TestCase):
    def signal(self):
        rng=random.Random(41)
        return array("h",[0]*320+[rng.randint(-4500,4500) for _ in range(12000)])

    def test_identical_first_signal_and_truncated_first_block(self):
        data=self.signal();first=corpus.first_voicing(data)
        self.assertEqual(corpus.alignment(data,data,first)["offsetFrames"],0)
        self.assertEqual(corpus.alignment(data,data[1200:],first)["status"],"FAIL")
        self.assertTrue(corpus.whole_pcm(data,data)["identical"])
        self.assertFalse(corpus.whole_pcm(data,data[1:])["identical"])

    def test_unrelated_signal_and_silence_cannot_prove_onset(self):
        data=self.signal();first=corpus.first_voicing(data)
        self.assertEqual(corpus.alignment(data,array("h",reversed(data)),first)["status"],"UNKNOWN")
        self.assertEqual(corpus.alignment(data,array("h",[0]*len(data)),first)["status"],"UNKNOWN")
        altered=array("h",data);altered[3]+=1
        proof=corpus.whole_pcm(data,altered)
        self.assertNotEqual(proof["sourceSHA256"],proof["savedSHA256"])
        self.assertEqual(proof["first320SamplesMaxDelta"],1)
