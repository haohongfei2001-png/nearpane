import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import contract_signing as signing
from space_scope import ScopeError


class InstallChainTests(unittest.TestCase):
    def test_each_intermediate_must_connect_original_and_live_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp)
            manifest=tmp/"chain.json"
            manifest.write_text(json.dumps({"schema":"nearpane-installed-signing-chain-v1",
                "intermediateInstalls":[{"installedArchive":str(tmp/"second.zip"),"receipt":str(tmp/"first-receipt")}],
                "finalInstallReceipt":str(tmp/"second-receipt")}))
            def proof(old,new):
                return dict(old=old,new=new,installReceiptSHA256="verified",requirementSHA256="stable")
            with (patch.object(signing,"unpack",side_effect=lambda archive,stack:archive),
                  patch.object(signing,"digest",return_value="test"),
                  patch.object(signing,"verify_pair") as pairs):
                pairs.side_effect=[proof("original","second"),proof("second","live")]
                result=signing.continuity(tmp/"first.zip",manifest,"original","live")
                self.assertEqual(len(result["installTransitions"]),2)
                self.assertEqual([args.args[2].name for args in pairs.call_args_list],["first-receipt","second-receipt"])
                pairs.side_effect=[proof("original","second"),proof("unrelated","live")]
                with self.assertRaises(ScopeError):
                    signing.continuity(tmp/"first.zip",manifest,"original","live")
