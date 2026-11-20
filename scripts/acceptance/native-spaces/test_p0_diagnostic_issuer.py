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

    def test_stage_hid_replays_the_eight_counters_and_checks_every_reader_position(self):
        baseline=[5759,70,0,3049,136752,19137,35,0]  # drift-materialized original, held and final
        with tempfile.TemporaryDirectory() as tmp:
            loan=stage.StageLoan.__new__(stage.StageLoan)
            loan.output=Path(tmp)
            for reader,size in (("before",8),("stage",5),("after",8)):
                for position in range(size):
                    case=f"{reader}-{position}"
                    with self.subTest(case=case):
                        values={"before":baseline[:],"stage":baseline[:5],"after":baseline[:]}
                        values[reader][position]+=1
                        loan.read_state=Mock(side_effect=[{"hid":values["before"],"uptime":1},{"hid":values["after"],"uptime":2}])
                        workspace=Mock()
                        workspace.hardware.return_value=values["stage"]
                        with self.assertRaisesRegex(ValueError,"physical input changed"):
                            loan.confirm_hid(workspace,baseline,case)
                        evidence=json.loads((loan.output/(case+"-hid.json")).read_bytes())
                        self.assertEqual(evidence["status"],"CHANGED")
                        field=stage.P0_HID[position]
                        self.assertEqual(evidence["stageChanged"] if reader=="stage" else evidence["p0Changed"],[field])
            loan.read_state=Mock(side_effect=[{"hid":baseline,"uptime":281684.6605901667},{"hid":baseline,"uptime":281688.0120485417}])
            workspace=Mock()
            workspace.hardware.return_value=baseline[:5]
            loan.confirm_hid(workspace,baseline,"materialized-readback")
            accepted=json.loads((loan.output/"materialized-readback-hid.json").read_bytes())
            self.assertEqual(accepted["status"],"CONFIRMED")
            self.assertEqual((accepted["original"],accepted["before"]["hid"],accepted["after"]["hid"]),(baseline,baseline,baseline))
            self.assertEqual(accepted["stage"],baseline[:5])

    def test_stage_hid_schema_refuses_before_writing_and_untouched_loan_uses_readback(self):
        loan=stage.StageLoan.__new__(stage.StageLoan)
        loan.original=True
        loan.transaction=None
        loan.kit=Path("/private/tmp/kit")
        ws=Mock(kit=loan.kit)
        baseline=[0]*8
        with tempfile.TemporaryDirectory() as tmp:
            loan.output=Path(tmp)
            loan.read_state=Mock(side_effect=[{"hid":baseline,"uptime":1},{"hid":baseline[:5],"uptime":2}])
            ws.hardware.return_value=baseline[:5]
            with patch.object(stage.preview,"lease_for"),patch.object(stage,"empty_system_desktop") as empty:
                with self.assertRaisesRegex(ValueError,"incomplete physical input"):
                    loan.borrow(ws,5095,baseline)
                empty.assert_not_called()
            self.assertEqual(json.loads((loan.output/"before-empty-check-hid.json").read_bytes())["status"],"UNKNOWN")
        with patch.object(stage.preview,"states",return_value=[{"state":True}]):
            self.assertEqual(loan.restore()["status"],"PASS")

    def test_no_action_receipt_is_synthesized_for_an_unacknowledged_signed_request(self):
        status,_,ms = cards.assess([],{},0,None,{"scope":issuer.SCOPE,"issued":False,"error":"fixture unavailable"})
        self.assertEqual((status,ms),("BLOCKED",None))


if __name__=="__main__":
    unittest.main()
