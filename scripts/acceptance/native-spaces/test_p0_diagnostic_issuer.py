import base64
import importlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

import p0_diagnostic_issuer as issuer

cards = importlib.import_module("p0-cards")


class IsolatedIssuerTests(unittest.TestCase):
    def test_key_is_publicly_verifiable_and_payload_changes_do_not_verify(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            folder = Path(tmp).resolve()
            key = folder/"issuer.pem"
            program = issuer.openssl()
            subprocess.run([program,"genpkey","-algorithm","ED25519","-out",key],check=True)
            key.chmod(0o600)
            program,public = issuer.key_identity(key)
            payload = {"scope":issuer.SCOPE,"target":17,"operation":str(uuid.uuid4())}
            signed = issuer.signed_request(program,key,payload)
            data = base64.b64decode(signed["payload"])
            self.assertEqual(json.loads(data),payload)
            (folder/"key.der").write_bytes(issuer.PREFIX+public)
            (folder/"signature").write_bytes(base64.b64decode(signed["signature"]))
            verify=[program,"pkeyutl","-verify","-pubin","-keyform","DER","-inkey",folder/"key.der","-rawin",
                    "-in",folder/"payload","-sigfile",folder/"signature"]
            for content,status in [(data,0),(data.replace(b"17",b"18"),1)]:
                (folder/"payload").write_bytes(content)
                self.assertEqual(subprocess.run(verify,capture_output=True).returncode,status)
            key.chmod(0o644)
            with self.assertRaises(ValueError):
                issuer.key_identity(key)

    def test_diagnostic_evidence_never_counts_as_an_official_card_press(self):
        trial=dict(scope=issuer.SCOPE,status="PASS",axIssued=False,hostIssued=True,blankScreen="PASS",
                   navigationStatus="PASS",continuousClassification="settled",retainedTargetFocus={"status":"PASS"})
        stage={"samples":[trial]}
        cards.evaluate_gate(stage,"diagnostic",1)
        self.assertEqual(stage["navigationDispatched"],0)
        self.assertEqual(stage["diagnosticHostDispatches"],1)
        self.assertFalse(stage["officialGateEligible"])
        self.assertEqual(stage["status"],"PASS")
        self.assertTrue(all(name!="diagnostic" for name,_ in cards.GATES))

    def test_no_action_receipt_is_synthesized_for_an_unacknowledged_signed_request(self):
        status,_,ms = cards.assess([],{},0,None,{"scope":issuer.SCOPE,"issued":False,"error":"fixture unavailable"})
        self.assertEqual((status,ms),("BLOCKED",None))


if __name__=="__main__":
    unittest.main()
