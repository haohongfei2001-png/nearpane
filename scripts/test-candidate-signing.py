"""Unsigned, offline regression tests for candidate identity selection and replacement."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import candidate_signing as signing


class CandidateIdentityTests(unittest.TestCase):
    fingerprint = "AB" * 20
    identity = f'  1) {fingerprint} "Developer ID Application: Nearpane Test (A012345678)"'

    def test_selects_only_exact_valid_application_fingerprint(self):
        self.assertEqual(signing.require_developer_team(self.fingerprint.lower(), self.identity), "A012345678")
        for fingerprint, listing in (
                ("Nearpane Test", self.identity), ("CD" * 20, self.identity),
                (self.fingerprint, self.identity + "\n" + self.identity),
                (self.fingerprint, self.identity.replace("Application", "Installer")),
                (self.fingerprint, self.identity + " (CSSMERR_TP_CERT_EXPIRED)")):
            with self.subTest(fingerprint=fingerprint, listing=listing):
                with self.assertRaises(ValueError):
                    signing.require_developer_team(fingerprint, listing)

    def test_shipping_identity_rejects_version_specific_designated_requirement(self):
        with patch.object(signing.gate, "cmd", return_value=""), patch.object(
                signing, "designated_requirement", return_value="cdhash H'1234'"):
            with self.assertRaisesRegex(ValueError, "Unstable permission identity"):
                signing.verify_install_identity(Path("candidate.app"))

    def test_default_install_selects_exactly_one_certificate_of_the_product_team(self):
        matching = self.identity.replace("A012345678", signing.PRODUCT_SIGNING_TEAM)
        self.assertEqual(signing.product_fingerprint(self.identity + "\n" + matching), self.fingerprint)
        for listing in (self.identity, matching + "\n" + matching, matching + " (expired)"):
            with self.assertRaises(ValueError):
                signing.product_fingerprint(listing)

    def test_only_signs_private_staging_directory(self):
        with tempfile.TemporaryDirectory() as work, patch.object(signing.gate, "cmd") as command:
            outer = Path(work)
            for name, mode in (("installed", 0o700), (".nearpane-stage.shared", 0o755)):
                stage = outer / name
                stage.mkdir()
                stage.chmod(mode)
                with self.assertRaises(ValueError):
                    signing.sign_staged(stage / "Nearpane.app", self.fingerprint)
            command.assert_not_called()

    @patch.object(signing.gate, "cmd", return_value="Signature=adhoc\nTeamIdentifier=not set")
    def test_legacy_adhoc_can_migrate_once(self, command):
        signing.check_continuity(Path("/old.app"), Path("/new.app"))
        self.assertEqual(command.call_count, 1)

    def test_replacement_checks_host_and_every_helper_in_both_directions(self):
        with tempfile.TemporaryDirectory() as work:
            old, new = (Path(work) / name for name in ("old.app", "new.app"))
            subjects = (".", "Contents/Helpers/Reader")
            for root in old, new:
                (root / subjects[1]).parent.mkdir(parents=True)
                (root / subjects[1]).touch()

            def command(*args):
                if "-dvv" in args:
                    return "TeamIdentifier=A012345678"
                if "-r-" in args:
                    return "designated => " + args[-1]
                return ""

            with patch.object(signing, "PRODUCT_IDENTIFIERS", subjects), patch.object(signing.gate, "cmd", side_effect=command) as calls:
                signing.check_continuity(old, new)
                for subject in subjects:
                    for left, right in ((old, new), (new, old)):
                        calls.assert_any_call("/usr/bin/codesign", "--verify", "--strict",
                                              "-R=" + str(left / subject), str(right / subject))

            def wrong_signer(*args):
                if "--verify" in args and args[-1] == str(new / subjects[1]):
                    raise subprocess.CalledProcessError(3, args)
                return command(*args)

            with patch.object(signing, "PRODUCT_IDENTIFIERS", subjects), patch.object(signing.gate, "cmd", side_effect=wrong_signer):
                with self.assertRaises(subprocess.CalledProcessError):
                    signing.check_continuity(old, new)


if __name__ == "__main__":
    unittest.main()
