import importlib
from pathlib import Path
import unittest

route = importlib.import_module("installed-route")


class InstalledRouteTests(unittest.TestCase):
    def setUp(self):
        self.signed = dict(sourceMatches=True, team="team", cdhash="hash", declaresService=True, declaresAppleEvents=True,
                           p3GrantOnlyProbePackaged=True, p4RequestBoundPanelPackaged=True)
        self.process = dict(pid=71, birth=5, verified=True, location="selected", identifierMatches=True,
                            kernelExecutableMatches=True, team="team", cdhash="hash")
        self.state = dict(registered=["selected"], preferred="selected", processes=[self.process], pidSourcesAgree=True)
        self.service = [dict(message=True, menu=True, identifier=True, selectedPath=True, canonicalPath=True)]

    def result(self, app=None, candidate=None, first=None, last=None, providers=None, private=True, daily=False):
        return route.classify(app or route.APP, self.signed if candidate is None else candidate,
                              self.state if first is None else first, self.state if last is None else last,
                              self.service, self.service if providers is None else providers, private, daily)

    def test_readiness_requires_the_exact_running_ordinary_identity_and_private_profile(self):
        for proof in self.result().values():
            self.assertEqual(proof["status"], "READY_FOR_EXISTING_RUNNER")
        for invalid in [dict(private=False), dict(daily=True), dict(candidate=dict(self.signed, sourceMatches=False)),
                        dict(last=dict(self.state, processes=[dict(self.process, birth=9)])),
                        dict(first=dict(self.state, registered=["other","selected"])),
                        dict(last=dict(self.state, processes=[dict(self.process, cdhash="other")])),
                        dict(last=dict(self.state, pidSourcesAgree=False))]:
            self.assertTrue(all(proof["status"] == "BLOCKED" for proof in self.result(**invalid).values()))

    def test_staged_file_and_ambiguous_named_service_do_not_inherit_runtime_pass(self):
        alternate = self.result(app=Path("/private/tmp/owned/Nearpane.app"))
        self.assertIn("existingAcceptanceRunnersRequireCanonicalInstall", alternate["p3HostGrantReadback"]["reasons"])
        for providers in ([], self.service * 2, [dict(self.service[0], selectedPath=False)]):
            result = self.result(providers=providers)
            self.assertEqual(result["p4ServiceReadback"]["status"], "BLOCKED")
            self.assertEqual(result["p3HostGrantReadback"]["status"], "READY_FOR_EXISTING_RUNNER")

    def test_same_named_service_from_a_different_provider_is_also_counted(self):
        def entry(path, message, identifier):
            return (f'        {{\n        NSBundleIdentifier = "{identifier}";\n        NSBundlePath = "{path}";\n'
                    f'        NSMenuItem = {{\n            default = "{route.MENU}";\n        }};\n'
                    f'        NSMessage = {message};\n    }}')
        real = entry(route.APP, route.MESSAGE, route.BUNDLE)
        conflict = entry("/Applications/Other.app", "unrelatedSelector", "other")
        rows = route.services("(\n" + real + ",\n" + conflict + "\n)", route.APP)
        self.assertEqual([(row["menu"], row["message"], row["selectedPath"]) for row in rows],
                         [(True, True, True), (True, False, False)])
