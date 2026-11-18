import unittest
from d01 import reached


class ReadbackTests(unittest.TestCase):
    def test_requires_the_target_and_unchanged_sibling_and_focus(self):
        good = dict(target=[2], sibling=[1], fixtureAXNumbers=[10, 11], front=12, focused=99)
        self.assertTrue(reached(good, [2], 1, [10, 11], (12, 99)))
        for bad in [dict(target=[1]), dict(sibling=[2]), dict(target=[1, 2]), dict(focused=100),
                    dict(front=9), dict(fixtureAXNumbers=[10]), dict(fixtureAXNumbers=[11, 12])]:
            self.assertFalse(reached({**good, **bad}, [2], 1, [10, 11], (12, 99)))

    def test_missing_membership_does_not_prove_source_closed(self):
        data = dict(target=None, sibling=[1], fixtureAXNumbers=[10, 11], front=12, focused=99)
        self.assertFalse(reached(data, None, 1, [10, 11], (12, 99), closed=True))
        data["fixtureAXNumbers"] = [11]
        self.assertTrue(reached(data, None, 1, [10, 11], (12, 99), closed=True))


if __name__ == "__main__":
    unittest.main()
