import base64
import importlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import uuid

import p0_diagnostic_issuer as issuer
import p0_diagnostic_stage as stage

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

    def test_nonce_probe_works_without_ui_logs_and_refuses_dispatchable_capability(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            client=issuer.Issuer.__new__(issuer.Issuer)
            client.home=Path(tmp).resolve()
            client.host={"pid":71,"birth":712}
            client.generation=Path(str(uuid.uuid4()))
            client.revision="e"*40
            def ack(*args,**kw):
                nonce=str(uuid.uuid4()).upper()
                record=dict(nonce=nonce,operation=nonce,action="probe",state="ready",canSwitch=enabled,canMove=False,issued=False,
                            submittedSteps=0,stageManagerOwnsDispatch=True,pid=71,birth=712,revision=client.revision,
                            generation=client.generation.name,at=time.monotonic())
                (client.home/("p0-probe-"+nonce+".json")).write_text(json.dumps(record))
                return nonce
            with patch.object(issuer.subprocess,"check_output",side_effect=ack),patch.object(issuer,"owns_profile",return_value=True):
                enabled=False
                self.assertTrue(client.capabilities(client.home)["ready"])
                enabled=True
                with self.assertRaises(ValueError):
                    client.capabilities(client.home)

    def test_stage_loan_never_selects_a_noncurrent_existing_desktop(self):
        loan=stage.StageLoan.__new__(stage.StageLoan)
        loan.original=True
        args=Mock(stage_workspace="/prior",stage_space=5095,stage_original_checkout="/origin",stage_previous_archive="/archive",stage_install_receipt="/chain")
        log=Mock()
        with patch.object(stage.preview,"PreviewWorkspace") as open_lease:
            loan.existing(args,{"topology":{"current":4}},log)
        open_lease.assert_not_called()
        log.assert_called_once()

    def test_stage_hid_change_refuses_before_writing_and_untouched_loan_uses_readback(self):
        loan=stage.StageLoan.__new__(stage.StageLoan)
        loan.original=True
        loan.transaction=None
        loan.kit=Path("/private/tmp/kit")
        ws=Mock(kit=loan.kit)
        ws.hardware.return_value=[2]
        with patch.object(stage.preview,"lease_for"),patch.object(stage,"empty_system_desktop") as empty:
            with self.assertRaises(ValueError):
                loan.borrow(ws,5095,[1])
            empty.assert_not_called()
        with patch.object(stage.preview,"states",return_value=[{"state":True}]):
            self.assertEqual(loan.restore()["status"],"PASS")

    def test_no_action_receipt_is_synthesized_for_an_unacknowledged_signed_request(self):
        status,_,ms = cards.assess([],{},0,None,{"scope":issuer.SCOPE,"issued":False,"error":"fixture unavailable"})
        self.assertEqual((status,ms),("BLOCKED",None))


if __name__=="__main__":
    unittest.main()
