from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest


class PublishedHostScopeTests(unittest.TestCase):
    def test_reordered_fields_retain_the_same_cross_observer_identity(self):
        path = Path(__file__).resolve().parents[1] / "host/observe-scope.py"
        spec = spec_from_file_location("host_scope", path)
        reader = module_from_spec(spec)
        spec.loader.exec_module(reader)
        display = "71FD5DEC-CD59-4259-B934-31228A848C13"
        space = "87892BF9-B562-4335-A422-5D964B9B8564"
        result = reader.public_observation({
            "spaceScope": {"spaceUUID": space, "displayUUID": display},
            "guardianFixture": {"display": display.lower(), "nativeSpace": space.lower()},
        })
        self.assertEqual(result["spaceScope"]["displayUUID"], result["guardianFixture"]["display"])
        self.assertEqual(result["spaceScope"]["spaceUUID"], result["guardianFixture"]["nativeSpace"])
        self.assertNotEqual(result["guardianFixture"]["display"], result["guardianFixture"]["nativeSpace"])
        self.assertNotIn(display, str(result).upper())
        self.assertNotIn(space, str(result).upper())
