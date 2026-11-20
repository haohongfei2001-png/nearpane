"""Private preparation, original archive binding and local-only recovery."""
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

import private_notary as n


class PrivateNotaryTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root=Path(tmp.name).resolve()
        self.name="Nearpane-5.22-90-test.zip"
        self.job=str(uuid.uuid4())
        self.sub={"id":self.job}
        self.info={"id":self.job,"name":self.name,"status":"Accepted"}
        self.candidate={"source":"1"*40,"binaries":{"MacOS/NearpaneHost":{"slices":{
            "arm64":{"cdhash":"1"*40},"x86_64":{"cdhash":"2"*40}}}}}
        self.prepared={"archive":self.name,"sha256":"8"*64,"candidate":self.candidate, "status":"PREPARED"}
        self.log={"jobId":self.job,"archiveFilename":self.name,"sha256":"8"*64,"status":"Accepted","statusCode":0,
                  "ticketContents":[dict(path=self.name+"/Nearpane.app/Contents/MacOS/NearpaneHost",
                  digestAlgorithm="SHA-256",arch=a,cdhash=sl["cdhash"]) for a,sl in self.candidate["binaries"]["MacOS/NearpaneHost"]["slices"].items()]}

    def test_correlates_service_job_archive_and_both_code_slices(self):
        self.assertEqual(n.accepted(self.prepared,self.sub,self.info,self.log),self.job)
        for change in ({"jobId":str(uuid.uuid4())},{"archiveFilename":"different.zip"},{"sha256":"9"*64},
                       {"status":"Invalid"},{"statusCode":1},{"statusCode":False},{"ticketContents":self.log["ticketContents"][:1]},
                       {"ticketContents":[dict(e,cdhash="3"*40) for e in self.log["ticketContents"]]}):
            with self.subTest(change=change),self.assertRaises(ValueError):
                n.accepted(self.prepared,self.sub,self.info,self.log|change)
        with self.assertRaises(ValueError):
            n.accepted(self.prepared,{"id":str(uuid.uuid4())},self.info,self.log)

    def test_pending_failed_and_accepted_without_log_do_not_admit_stapling(self):
        for status,want in (("In Progress","IN_PROGRESS"),("Rejected","REJECTED"),
                            ("Invalid","INVALID"),("Accepted","SERVICE_ACCEPTED_AWAITING_LOG")):
            r=n.reconciliation(self.prepared,self.sub,self.info|{"status":status})
            self.assertEqual(r["status"],want)
            self.assertFalse(r["matchesAppleArchiveDigest"] or r["ticketValidated"])
        r=n.reconciliation(self.prepared,self.sub,self.info,self.log)
        self.assertEqual(r["status"],"ACCEPTED_EXACT_ARCHIVE")
        self.assertFalse(r["ticketValidated"])
        with self.assertRaises(ValueError):
            n.reconciliation(self.prepared,self.sub,self.info|{"status":"Invalid"},self.log)

    def test_source_digest_checked_before_unpack_and_resumption_retains_input(self):
        src=self.root/self.name
        src.write_bytes(b"original")
        expected=n.sha(src)
        session=self.root/"session"
        with patch.object(n,"unpack",return_value="staged") as unpack,patch.object(n,"fingerprint",return_value=self.candidate):
            with self.assertRaisesRegex(ValueError,"SHA-256"):
                n.prepare(src,session,"1"*40,"0"*64)
            unpack.assert_not_called()
            n.prepare(src,session,"1"*40,expected)
            with self.assertRaisesRegex(ValueError,"session exists"):
                n.prepare(src,session,"1"*40,expected)
            self.assertEqual(n.verified(session,self.root)[0]["sha256"],expected)
            (session/self.name).write_bytes(b"different")
            with self.assertRaisesRegex(ValueError,"SHA-256"):
                n.verified(session,self.root)
        self.assertEqual(n.sha(src),expected)

    def test_failed_service_evidence_never_touches_an_app_and_survives_recovery(self):
        for name,obj in [("submit",self.sub),("info",self.info),("log",self.log|{"sha256":"f"*64})]:
            n.save(self.root/name,obj)
        with patch.object(n,"verified",return_value=(self.prepared,self.root/n.BUNDLE)),patch.object(n.gate,"cmd") as tool:
            with self.assertRaisesRegex(ValueError,"archive"):
                n.finalize(self.root,self.root/"submit",self.root/"info",self.root/"log")
        tool.assert_not_called()
        self.assertFalse((self.root/"stapled").exists())
        rec=n.read_json(self.root/"last-finalize-failure.json")
        self.assertEqual((rec["status"],rec["stage"],rec["originalArchiveRetained"]),("BLOCKED","AppleResult",True))

    def test_local_gatekeeper_needs_notarized_source_and_both_processes(self):
        with patch.object(n.gate,"cmd",return_value="source=Developer ID\n") as tool:
            with self.assertRaisesRegex(ValueError,"Notarized"):
                n.gatekeeper(self.root)
            self.assertEqual(tool.call_count,1)
        with patch.object(n.gate,"cmd",side_effect=["source=Notarized Developer ID\n","{}"]) as tool:
            self.assertEqual(n.gatekeeper(self.root)["syspolicyCheck"],"PASS")
            self.assertEqual(tool.call_count,2)

    def test_finalize_only_packages_after_stapling_and_reads_the_distinct_archive(self):
        for name,obj in [("submit",self.sub),("info",self.info),("log",self.log)]:n.save(self.root/name,obj)
        calls=[]
        def tool(*args):
            calls.append(args)
            if args[0]=="/usr/sbin/spctl":return "source=Notarized Developer ID\n"
            return ""
        def pack(app,archive):
            self.assertTrue(any("staple" in c for c in calls))
            archive.write_bytes(b"ticket-bearing synthetic archive")
        with patch.object(n,"verified",return_value=(self.prepared,self.root/n.BUNDLE)),patch.object(n,"fingerprint",return_value=self.candidate), \
             patch.object(n,"archive_app",side_effect=pack) as packer,patch.object(n,"unpack",side_effect=lambda a,d:d/n.BUNDLE),patch.object(n.gate,"cmd",side_effect=tool):
            result=n.finalize(self.root,self.root/"submit",self.root/"info",self.root/"log")
            second=n.finalize(self.root,self.root/"submit",self.root/"info",self.root/"log")
        self.assertEqual(result,second)
        self.assertEqual(packer.call_count,1)
        self.assertEqual(result["sha256"],n.sha(self.root/"stapled"/"Nearpane-stapled.zip"))
        self.assertNotEqual(result["sha256"],result["inputSHA256"])
        self.assertFalse(result["publicRelease"])
        self.assertEqual(sum("staple" in row for row in calls),1)

    def test_foreign_locale_timestamps_retain_cryptographic_identity(self):
        import copy
        one=copy.deepcopy(self.candidate)
        one["binaries"]["MacOS/NearpaneHost"]["slices"]["arm64"]["secureTimestamp"]="Nov 20 18:42 UTC"
        two=copy.deepcopy(one)
        record=two["binaries"]["MacOS/NearpaneHost"]["slices"]["arm64"]
        record["secureTimestamp"]="21 Nov 02:42 CST"
        self.assertTrue(n.same_code(one,two))
        record["cdhash"]="f"*40
        self.assertFalse(n.same_code(one,two))
        record["cdhash"]="1"*40
        record["secureTimestamp"]=""
        self.assertFalse(n.same_code(one,two))

    def test_zip_accepts_ordinary_bundle_objects_and_refuses_other_top_level(self):
        archive=self.root/self.name
        def create(paths):
            with zipfile.ZipFile(archive,"w") as z:
                for name in paths:
                    entry=zipfile.ZipInfo(name);entry.external_attr=(stat.S_IFREG|0o644)<<16
                    z.writestr(entry,b"test")
        create(["Nearpane.app/Contents/MacOS/NearpaneHost","__MACOSX/Nearpane.app/Contents/MacOS/._NearpaneHost"])
        n.archive_names(archive)
        for others in [["Other.app/Contents/test"],["Nearpane.app/Contents/item","Nearpane.app/Contents/ITEM"],
                       ["Nearpane.app/readme","__MACOSX/Nearpane.app/._Missing"]]:
            create(others)
            with self.assertRaises(ValueError):n.archive_names(archive)


if __name__=="__main__":
    unittest.main()
