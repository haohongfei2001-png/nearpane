import unittest
from preview_continuity import measured_intervals


def sample(color, rgba):
    return dict(color=color, minimum=rgba, maximum=rgba, median=rgba, dominantFraction=1)


def frame(t, sequence, *points):
    return dict(time=t, sequence=sequence, basis="SCDisplayTime", samples=list(points))


class ContinuityTests(unittest.TestCase):
    def setUp(self):
        self.a=sample("0/1",[237,171,35,255])
        self.b=sample("1/1",[107,53,200,255])
        self.grey=sample("unknown",[131,131,132,159])
        self.sources=[[frame(t,i,marker) for i,t in enumerate((.001,.016,.031,.046))]
                      for marker in (self.a,self.b)]

    def test_successful_color_does_not_hide_two_neutral_presentations(self):
        panel=[frame(t,i,self.a,b) for i,(t,b) in enumerate(((.005,self.grey),(.020,self.grey),(.035,self.b)))]
        result=measured_intervals([*self.sources,panel],1/60)
        self.assertEqual(result["status"],"FAIL")
        self.assertEqual(result["windows"][1]["confirmed"][0]["observedSpanMs"],15)

    def test_unbracketed_or_different_source_epochs_are_unknown(self):
        self.sources[1][1]["samples"]=[sample("1/2",[218,52,163,255])]
        panel=[frame(t,i,self.a,self.grey) for i,t in enumerate((.005,.020,.08))]
        result=measured_intervals([*self.sources,panel],1/60)
        self.assertFalse(result["windows"][1]["confirmed"])
        self.assertEqual(result["windows"][1]["neutralFramesWithoutQualifiedSourceBracket"],3)

    def test_opaque_picture_and_isolated_single_observation_are_distinct(self):
        panel=[frame(.005,1,self.a,self.b),frame(.020,2,self.a,self.grey),frame(.035,3,self.a,self.b)]
        result=measured_intervals([*self.sources,panel],1/60)
        self.assertEqual(result["status"],"NO_CONFIRMED_INTERVAL")
        self.assertEqual(result["windows"][1]["singleFrameObservations"],1)
