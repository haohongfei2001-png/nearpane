"""Retain and verify real system-wide foreground references during the P0 isolation round trip."""
import json
import os
from pathlib import Path
import select
import subprocess
import time


class OriginalFocus:
    def __init__(self,tool):
        self.proc=subprocess.Popen([tool,'hold-original'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    def reply(self,timeout=4):
        if not select.select([self.proc.stdout],[],[],timeout)[0]:return {'error':'original AX reference timed out'}
        line=self.proc.stdout.readline()
        return json.loads(line) if line else {'error':'original AX reference unavailable'}
    def finish(self,restore,ordinary=None,expected=None):
        current=(expected or {}).get('systemFocus') or {}
        may_restore=restore and isinstance(current.get('pid'),int) and current['pid']>1
        try:
            if self.proc.poll() is not None:return {'issued':False,'reason':'retained window helper exited'}
            command=(f"restore {ordinary or '-'} {current['pid']} {current.get('number') or 0}" if may_restore else 'release')
            self.proc.stdin.write(command+'\n');self.proc.stdin.flush()
            if may_restore:return self.reply(timeout=10)
            return {'issued':False,'reason':'no independent system-wide foreground' if restore else 'released'}
        finally:
            self.proc.stdin.close();self.proc.stdout.close()
            if self.proc.poll() is None:
                try:self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:self.proc.terminate();self.proc.wait(timeout=3)


def exact_focus(snapshot,held):
    actual=snapshot.get('systemFocus') or {}
    return bool(held.get('held') and actual.get('pid')==held['pid'] and actual.get('number')==held['number'] and
                snapshot.get('topology')==held['topology'])


def restore_context(current,held):
    """Only an unchanged native inventory and a currently observed ordinary Space can lead back to an off-Space reference."""
    original=held.get('topology') or {};now=current.get('topology') or {};actual=current.get('systemFocus') or {}
    if (not held.get('held') or not actual.get('pid') or current.get('hid')!=held.get('hid') or
            now.get('display')!=original.get('display') or now.get('records')!=original.get('records')):
        return False,None
    if now.get('current')==original.get('current'):return True,None
    known_ordinary=any(r['id']==now.get('current') and r['type']==0 for r in original['records'])
    return (True,now['current']) if known_ordinary else (False,None)


def kit_for(command,explicit=None):
    script=Path(__file__).with_name('p0-cards.py').resolve()
    choice=explicit
    if choice is None:
        for index,arg in enumerate(command[:-1]):
            if Path(arg).name=='p0-cards.py' and Path(arg).resolve()==script:
                choice=command[index+1];break
    if choice is None:return None
    kit=Path(choice)
    if (not str(kit).startswith('/private/tmp/nearpane-d01.') or kit.resolve()!=kit or not kit.is_dir() or
            kit.stat().st_uid!=os.getuid() or kit.stat().st_mode&0o022):
        raise ValueError('P0 focus keeper requires the owned temporary kit')
    reader=kit/'p0-card'
    if reader.resolve()!=reader or not reader.is_file() or reader.stat().st_uid!=os.getuid() or not os.access(reader,os.X_OK):
        raise ValueError('P0 focus reader is missing from its verified kit')
    subprocess.run(['/usr/bin/codesign','--verify','--strict',reader],check=True,capture_output=True,timeout=5)
    return reader


class DailyFocus:
    def __init__(self,tool,output,original_host):
        self.tool=tool;self.file=output/'daily-focus.json';self.original_host=original_host;self.anchors={}
        self.info={'scope':'user foreground before and after the daily Host profile round trip','status':'UNKNOWN'}
        self.capture('original')
    def save(self):
        temp=self.file.with_suffix('.new')
        with temp.open('w') as f:json.dump(self.info,f,indent=2);f.write('\n')
        temp.replace(self.file)
    def state(self):
        result=subprocess.run([self.tool,'state'],capture_output=True,text=True,timeout=5)
        if result.returncode!=0:raise ValueError('independent system focus reader failed')
        return json.loads(result.stdout)
    def capture(self,name,excluded=None):
        holder=None
        try:
            state=self.state();self.info[name]={'independent':state}
            current=state.get('systemFocus') or {}
            if not current.get('number') or current.get('pid')==excluded:
                self.info[name]['reason']='no durable user window in the actual foreground';return
            holder=OriginalFocus(self.tool);held=holder.reply()
            if not exact_focus(state,held) or state.get('hid')!=held.get('hid'):
                self.info[name]['reason']='the two independent focus reads or human input disagreed';return
            self.anchors[name]=(holder,held);holder=None;self.info[name]['held']=held
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:self.info[name]={'reason':str(error)}
        finally:
            if holder:holder.finish(False)
            self.save()
    def before_daily(self,isolated_pid):
        try:
            state=self.state();self.info['beforeStoppingIsolatedHost']=state
            admitted=self.info.get('original',{}).get('independent') or {}
            if admitted.get('hid')!=state.get('hid'):
                # Preserve the user's latest focus if the subsequent background reopening changes it.
                self.capture('newerUser',excluded=isolated_pid)
        except (OSError,ValueError,subprocess.SubprocessError) as error:self.info['beforeStoppingError']=str(error)
        self.save()
    def finish(self,daily_restored,*,preserve_new_input=False):
        try:
            if preserve_new_input:
                self.info.update(status='NEWER_INPUT_PRESERVED',reason='registered document trial yielded to physical input',restorationRequested=False)
                return
            last=self.state();self.info['afterDailyHost']=last
            original=self.info.get('original',{}).get('independent') or {}
            newer=last.get('hid')!=original.get('hid')
            which='newerUser' if newer else 'original'
            self.info['selectedReference']=which if which in self.anchors else None
            if not daily_restored:self.info['reason']='daily application state was not restored';return
            if not self.anchors.get(which):
                self.info.update(status='NEWER_INPUT_PRESERVED' if newer else 'UNKNOWN',reason='no live exact admitted reference for this foreground');return
            holder,held=self.anchors[which]
            if (not newer and held['pid']==self.original_host and not exact_focus(last,held)):
                self.info['reason']='the foreground daily Host was replaced, so the original PID and window reference no longer exist';return
            allowed,ordinary=restore_context(last,held)
            if not allowed:
                self.info.update(status='NEWER_INPUT_PRESERVED' if last.get('hid')!=held.get('hid') else 'UNKNOWN',
                                 reason='current focus, human input or desktop identities differ from the admitted reference');return
            associated=self.info.get('beforeStoppingIsolatedHost') or {}
            if ordinary and associated.get('topology',{}).get('current')!=ordinary:
                self.info['reason']='background relaunch reached an unadmitted other Space';return
            if not exact_focus(last,held):
                self.anchors.pop(which)
                self.info['restoration']=holder.finish(True,ordinary,expected=last)
            follow=[]
            for _ in range(2):
                follow.append(self.state())
                if len(follow)==1:time.sleep(.11)
            self.info['finalIndependentReads']=follow
            if all(exact_focus(r,held) and r.get('hid')==held['hid'] for r in follow):
                self.info['status']='NEWER_FOCUS_CONFIRMED' if newer else 'ORIGINAL_FOCUS_CONFIRMED'
            elif any(r.get('hid')!=held['hid'] for r in follow):self.info['status']='NEWER_INPUT_PRESERVED'
            else:self.info['reason']='two independent system-wide AX, window and Space reads did not verify the retained focus'
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:self.info['reason']=str(error)
        finally:
            for holder,_ in self.anchors.values():
                try:holder.finish(False)
                except (OSError,ValueError,subprocess.SubprocessError):pass
            self.anchors.clear();self.save()
