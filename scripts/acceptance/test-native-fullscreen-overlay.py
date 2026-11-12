#!/usr/bin/env python3
"""Offline checks. No window, process, clipboard or window server is opened."""
import datetime as dt
import json
from pathlib import Path
import runpy
import tempfile
import unittest
import uuid

overlay = runpy.run_path(str(Path(__file__).with_name("verify-native-fullscreen-overlay.py")))
run = str(uuid.uuid4()).upper()
token = str(uuid.uuid4()).upper()
host_run = str(uuid.uuid4())
c = dict(run=run, token=token, boot="boot", build="26A428", source="A", fullscreenCurrent="F",
         display="secondary", pid=12, launch=12345, number=181, revision=3, expiresUptime=200.0,
         witnessSHA256="a"*64, readerSHA256="b"*64)
consent = dict(run=run, boot="boot", secondaryDisplay="secondary", source="A")
row = dict(**{k:c[k] for k in ("run","token","pid","launch","number","display","revision")},
           phase="native", acceptanceRun=host_run, hostPID=30, hostActive=False, hostMain=False,
           hostKey=False, edgeVisible=False, tool=399, frontPID=12)


class NativeFullscreenController(unittest.TestCase):
    def test_challenge_cannot_outlive_or_replace_enrollment(self):
        seals = (c["witnessSHA256"],c["readerSHA256"])
        verify = overlay["challenge_matches"]
        verify(c,consent,seals,180)
        for k,v in (("run",str(uuid.uuid4())),("boot","another"),("display","main"),("source","B"),
                    ("fullscreenCurrent","A"),("launch",0),("number",True),("expiresUptime",180),
                    ("expiresUptime",float("nan")),("readerSHA256","c"*64)):
            with self.subTest(k=k,v=v), self.assertRaises(ValueError):
                verify(dict(c,**{k:v}),consent,seals,180)

    def test_older_fullscreen_permission_has_no_tool_authority(self):
        utc=dt.timezone.utc
        with tempfile.TemporaryDirectory() as dd:
            here=Path(dd)
            grant=dict(**consent, starts="2030-01-01T12:00:00Z",ends="2030-01-01T12:10:00Z",
                       permitsSingleWindowFullscreen=True,permitsCalibrationAndThreeRoundTrips=False,target="")
            now=dt.datetime(2030,1,1,12,1,tzinfo=utc)
            for key in (None,False,True):
                if key is not None: grant["permitsFullscreenToolObservation"]=key
                (here/"unattended-consent.ready").write_text(json.dumps(grant))
                if key is True:
                    self.assertEqual(overlay["consent_for"](here,run,now),grant)
                else:
                    with self.assertRaises((KeyError,ValueError)): overlay["consent_for"](here,run,now)
            with self.assertRaises(ValueError): overlay["consent_for"](here,run,now+dt.timedelta(hours=1))

    def test_other_run_window_host_or_front_invalidates_surface(self):
        surface=overlay["surface"]
        self.assertTrue(surface(row,c,30,host_run))
        for k,v in (("acceptanceRun","old"),("hostPID",9),("run",token),("token",run),
                    ("display","main"),("number",1),("launch",32),("pid",3),("hostKey",True),
                    ("hostMain",True),("hostActive",True),("frontPID",30)):
            with self.subTest(k=k),self.assertRaises(ValueError):
                surface(dict(row,**{k:v}),c,30,host_run)
        for k,v in (("phase","waiting"),("phase","synthetic"),("tool",0),("edgeVisible",True),("revision",2)):
            self.assertFalse(surface(dict(row,**{k:v}),c,30,host_run))

    def test_open_and_close_need_distinct_visible_actionable_controls(self):
        opened,closed=overlay["OPEN"],overlay["CLOSE"]
        def labels(*ids):
            return {"controls":list(ids),"details":[dict(id=i,role="AXButton",enabled=True,actions=["AXPress"]) for i in ids]}
        for expanded,identifier,other in ((True,closed,opened),(False,opened,closed)):
            self.assertTrue(overlay["controls_match"](labels(identifier),expanded=expanded))
            for wrong in (labels(other),labels(identifier,other),labels(identifier,identifier)):
                self.assertFalse(overlay["controls_match"](wrong,expanded=expanded))
            wrong=labels(identifier)
            wrong["details"][0]["enabled"]=False
            self.assertFalse(overlay["controls_match"](wrong,expanded=expanded))

    def test_domain_changes_and_duplicate_publication_detected(self):
        base={"voiceInstance":"a"*64,"trayInstance":"c"*64,"recordings":[],"trayCount":0}
        self.assertTrue(overlay["same_domains"]([base]*3))
        for k,v in (("voiceInstance","b"*64),("trayInstance",None),("trayCount",1),("recordings",["stale"])):
            self.assertFalse(overlay["same_domains"]([base,dict(base,**{k:v}),base]))
        with tempfile.TemporaryDirectory() as dd:
            target=Path(dd)/"reply.json"
            overlay["publish"](target,{"seen":1})
            with self.assertRaises(FileExistsError): overlay["publish"](target,{"seen":2})
            self.assertEqual(json.loads(target.read_bytes()),{"seen":1})

    def test_overlay_result_alone_cannot_certify_panel_return_or_focus(self):
        result=dict(result="observed", ordinaryPanelReturn={"phase":"ordinaryReturned"},
                    normalHostDrain=True, postExitDomainUnchanged=True)
        self.assertTrue(overlay["complete"](result))
        for key, value in (("ordinaryPanelReturn",None),("normalHostDrain",False),
                           ("postExitDomainUnchanged",False),("result","inconclusive")):
            self.assertFalse(overlay["complete"](dict(result, **{key:value})))
        state=dict(pid=30,foreground=12,active=False,key=False,voice="paused",recordings=[],trayCount=0)
        opened=dict(kind="opened",state=state)
        verify=overlay["checked_host_events"]
        verify([opened],30,12)
        for kind, fields in (("appActivated",{}), ("sample",{"foreground":30}), ("sample",{"voice":"standby"})):
            with self.assertRaises(ValueError):
                verify([opened,dict(kind=kind,state=dict(state,**fields))],30,12)


if __name__=="__main__":
    unittest.main()
