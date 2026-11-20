// A new headless Chromium process with a local reject-only proxy and a private DevTools pipe.
import assert from 'node:assert/strict';
import { spawn, execFileSync, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const build = path.join(root, 'build');
const [compose, source] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(0,'utf8') || '{}');
assert.ok(!(fixture.qualificationBrowser && fixture.capabilityBrowser), 'Select one browser fixture');
let fixtureRoot = build;
if (fixture.qualificationBrowser) {
  fixtureRoot = fs.realpathSync(fixture.qualificationScratch);
  assert.equal(path.dirname(fixtureRoot), fs.realpathSync(build));
  assert.ok(path.basename(fixtureRoot).startsWith('p3-qualified-'));
}
const run = fs.mkdtempSync(path.join(fixtureRoot, 'local-browser-'));
const requestedBrowser = fixture.qualificationBrowser ?? fixture.capabilityBrowser;
if (requestedBrowser) assert.ok(['chrome', 'edge'].includes(requestedBrowser));
if (!fixture.capabilityBrowser) assert.equal(fs.realpathSync(compose).startsWith(build + '/'), true);
const chrome = requestedBrowser === 'edge' ? '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge' :
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const intercepted = fixture.productDriver || requestedBrowser;

const png = Buffer.from(fixture.png ||
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNQ91/l1DGH4cwql/K0UAAk9wVzjPxe1gAAAABJRU5ErkJggg==','base64');
const sha = createHash('sha256').update(png).digest('hex');
if (fixture.png) assert.equal(sha,fixture.sha256);
const profile = path.join(run, 'user-data');
fs.mkdirSync(profile, {mode: 0o700});
const profileIdentity = fs.lstatSync(profile);
const rejectProxy = net.createServer(socket => socket.destroy());
rejectProxy.listen(0,'127.0.0.1');
await once(rejectProxy,'listening');
const stderr = fs.openSync(path.join(run, 'chrome.log'), 'wx', 0o600);
const child = spawn(chrome, ['--headless=new', '--remote-debugging-pipe',
  '--proxy-server=http://127.0.0.1:'+rejectProxy.address().port, '--proxy-bypass-list=<-loopback>',
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1','--disable-quic','--disable-breakpad',
  '--user-data-dir=' + profile, '--use-mock-keychain', '--disable-background-networking', '--disable-sync',
  '--disable-extensions', '--no-first-run', '--no-default-browser-check', '--disable-component-update', 'about:blank'],
  {stdio:['ignore','ignore',stderr,'pipe','pipe'], detached: Boolean(fixture.qualificationRestart)});
fs.closeSync(stderr);
const closed = once(child, 'exit');
let seq = 0, pending = new Map(), handlers = new Map(), bytes = '';
function call(method, params = {}, sessionId) {
  const id = ++seq;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    child.stdio[3].write(JSON.stringify({id,method,params,sessionId}) + '\0');
  });
}
child.stdio[4].setEncoding('utf8').on('data', part => {
  bytes += part;
  let index;
  while ((index=bytes.indexOf('\0')) >= 0) {
    const msg = JSON.parse(bytes.slice(0,index)); bytes = bytes.slice(index+1);
    if (msg.id) {
      const waiter = pending.get(msg.id); pending.delete(msg.id);
      if (msg.error) waiter.reject(Error(msg.error.message)); else waiter.resolve(msg.result);
    } else (handlers.get(msg.method+'@'+msg.sessionId) ?? handlers.get(msg.method))?.(msg);
  }
});
closed.then(() => { for (const waiter of pending.values()) waiter.reject(Error('Fixture browser exited')); });
const driverRun = fixture.productDriver || fixture.qualificationBrowser;
const timeout = setTimeout(() => child.kill('SIGKILL'), driverRun ? 180000 : 45000);
let verified = false;
let restartEvidence;
const draft = fs.readFileSync(path.join(root,'scripts/acceptance/draft-observation.js'),'utf8');
try {
  const version = await call('Browser.getVersion');
  const pages = (await call('Target.getTargets')).targetInfos.filter(t=>t.type==='page');
  assert.equal(pages.length,1); assert.equal(pages[0].url,'about:blank');
  const {sessionId} = await call('Target.attachToTarget',{targetId:pages[0].targetId,flatten:true});
  const send = (m,p) => call(m,p,sessionId);
  const evalPage = async (expr, targetSession=sessionId) => {
    const r=await call('Runtime.evaluate',{expression:expr,awaitPromise:true,returnByValue:true},targetSession);
    if (r.exceptionDetails) throw Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  await send('Page.enable');
  await send('Emulation.setFocusEmulationEnabled',{enabled:true});
  await send('Fetch.enable',{patterns:[{urlPattern:'*'}]});
  let url, html, fulfilled=0, denied=0;
  const fixtureDocuments = new Map();
  handlers.set('Fetch.requestPaused', ({params,sessionId:targetSession}) => {
    const expected = intercepted ? fixtureDocuments.get(targetSession) : {url,html};
    if (expected && params.resourceType === 'Document' && params.request.url === expected.url && params.request.method === 'GET') {
      fulfilled++;
      void call('Fetch.fulfillRequest',{requestId:params.requestId,responseCode:200,
        responseHeaders:[{name:'Content-Type',value:'text/html; charset=utf-8'},
          {name:'Content-Security-Policy',value:"default-src 'none'; form-action 'none'; base-uri 'none'" +
            (driverRun ? "; img-src blob:" : "")}],
        body:Buffer.from(expected.html).toString('base64')},targetSession);
    } else { denied++; void call('Fetch.failRequest',{requestId:params.requestId,errorReason:'BlockedByClient'},targetSession); }
  });
  if (intercepted) {
    const navigate = async (next, body, targetSession=sessionId) => {
      fixtureDocuments.set(targetSession,{url:next,html:body});
      if(targetSession!==sessionId) {
        await call('Page.enable',{},targetSession);
        await call('Fetch.enable',{patterns:[{urlPattern:'*'}]},targetSession);
      }
      const loaded = new Promise(yes => handlers.set('Page.loadEventFired@'+targetSession,yes));
      await call('Page.navigate',{url:next},targetSession); await loaded;
      assert.equal(await evalPage('location.href',targetSession),next);
    };
    let evidence;
    if (fixture.qualificationBrowser && fixture.qualificationRestart) {
      const { runColdRestart } = await import('./draft-qualification/cases.mjs');
      evidence = await runColdRestart({ exe: compose, run, browser: fixture.qualificationBrowser,
        chromePID: child.pid, navigate, evalPage, restart: fixture.qualificationRestart });
      restartEvidence = evidence;
    } else if (fixture.qualificationBrowser) {
      const { runQualifiedCases } = await import('./draft-qualification/cases.mjs');
      evidence = await runQualifiedCases({
        exe: compose, run, browser: fixture.qualificationBrowser, chromePID: child.pid, navigate, evalPage, sha,
      });
    } else if (fixture.capabilityBrowser) {
      const {runCapabilityCases} = await import('./draft-capability-cases.mjs');
      evidence=await runCapabilityCases({guard:fs.readFileSync(path.join(root,'Resources/AcceptanceTargetGuard.js'),'utf8'),navigate,evalPage});
      evidence.browser = fixture.capabilityBrowser;
    } else if (fixture.restartFrom) {
      const {runBrowserRestart}=await import('./product-browser-cases.mjs');
      evidence=await runBrowserRestart({root,compose,source,fixture,chromePID:child.pid,navigate,evalPage});
    } else {
      const {runProductCases} = await import('./product-browser-cases.mjs');
      evidence=await runProductCases({run,root,compose,source,png,sha,fixture,call,send,evalPage,navigate,
        primary:pages[0].targetId,chromePID:child.pid});
    }
    Object.assign(evidence, {chrome:version.product, fixtureDocumentResponses:fulfilled, otherRequestsDenied:denied});
    fs.writeFileSync(path.join(run,'receipt.json'), JSON.stringify(evidence,null,2), {flag:'wx'});
    if (!restartEvidence) console.log(JSON.stringify({directory:run,...evidence}));
  } else {
  const cases=[];
  for (const owned of [true,false]) {
    const session=randomUUID(), marker='NEARPANE-TEST-'+session;
    url='https://chatgpt.com/c/'+session;
    html='<article data-message-author-role="user" data-message-id="fixture-turn">fixture</article><form>'+
      '<textarea id="prompt-textarea">'+marker+'</textarea><button type="button" data-testid="composer-plus" aria-label="Attach file">+</button>'+
      (owned ? '<input type="file" accept="image/*">' : '')+'</form>';
    const loaded=new Promise(r => handlers.set('Page.loadEventFired',r));
    await send('Page.navigate',{url}); await loaded;
    assert.equal(await evalPage('location.href'),url);
    const now=Date.now()/1000, assetID=fixture.assetID || randomUUID();
    const binding={session,process:'chrome-kernel-v1:'+child.pid+':1:1',window:'1',tab:'1',url,nonce:randomUUID(),assetID,
      sha256:sha,timeOrigin:await evalPage('performance.timeOrigin'),boundAt:now,expiresAt:now+120};
    const script=execFileSync(compose,[source],{input:JSON.stringify(binding),encoding:'utf8',cwd:root});
    await evalPage('globalThis.fixtureProgram=('+script+'); void 0');
    const row=await evalPage('('+ (async function(b, positive, payload, observe) {
      const form=document.querySelector('form'), entry=form.querySelector('button'), editor=form.querySelector('textarea');
      const input=positive ? form.querySelector('input') : document.createElement('input');
      input.type='file';
      const count={setter:0,input:0,change:0,submit:0}; let fileHash=null;
      const descriptor=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files');
      Object.defineProperty(HTMLInputElement.prototype,'files',{...descriptor,set(value){
        if(this===input)count.setter++; return descriptor.set.call(this,value);
      }});
      form.addEventListener('submit', e=>{e.preventDefault();count.submit++;});
      input.addEventListener('input',()=>count.input++);
      input.addEventListener('change',()=>{
        count.change++;
        const file=input.files[0], preview=document.createElement('span'); preview.dataset.fileName=file.name;
        preview.textContent='fixture preview';form.append(preview);
        fileHash=file.arrayBuffer().then(bytes=>crypto.subtle.digest('SHA-256',bytes))
          .then(d=>[...new Uint8Array(d)].map(n=>n.toString(16).padStart(2,'0')).join(''));
      });
      if(!positive) entry.addEventListener('click',()=>setTimeout(()=>{try{input.showPicker();}catch{}},20));
      editor.focus();
      const before=observe(b.url,editor.value,b,true);
      if(!before) throw Error('No authorized baseline in local fixture: '+JSON.stringify({
        visible:document.visibilityState,focus:document.hasFocus(),route:location.href===b.url,editor:editor.getClientRects().length}));
      const native={applicationID:'com.google.Chrome',sessionID:b.process,windowID:b.window,tabID:b.tab};
      const target=fixtureProgram({action:'captureTarget'},native), operationID=crypto.randomUUID();
      const identity={operationID,assetID:b.assetID,attempt:1,assetSHA256:b.sha256,target};
      const base={identity,target,invocationID:crypto.randomUUID()}, name='riftlet-'+operationID+'.png';
      const invoke=(action,params={})=>fixtureProgram({...base,action,...params},native);
      const begin=invoke('begin',{uploadName:name,mediaType:'image/png',byteCount:atob(payload).length});
      const chunk=invoke('chunk',{chunkIndex:0,chunkBase64:payload});
      if(begin.nextChunk!==0 || chunk.nextChunk!==1)throw Error('Unexpected upstream sequence');
      let result;
      try{result=await invoke('commit',{chunkIndex:1});}catch(e){result={error:e.message};}
      const after=observe(b.url,editor.value,b,false);
      return {owned:positive,count,fileSHA256:await fileHash,files:input.files.length,
        beforePreviews:before.previews,afterPreviews:after?.previews,exactName:after?.previewNames[0]===name,
        preserved:editor.value==='NEARPANE-TEST-'+b.session && JSON.stringify(after?.ids)===JSON.stringify(before.ids),
        inputCount:result.inputCount ?? null,operation:operationID};
    }).toString()+')('+JSON.stringify(binding)+','+owned+','+JSON.stringify(png.toString('base64'))+',('+draft+'))');
    assert.deepEqual(row.count, owned?{setter:1,input:1,change:1,submit:0}:{setter:0,input:0,change:0,submit:0});
    assert.equal(row.files,Number(owned)); assert.equal(row.beforePreviews,0); assert.equal(row.afterPreviews,Number(owned));
    assert.equal(row.exactName,owned); assert.equal(row.preserved,true); assert.equal(row.fileSHA256,owned?sha:null);
    cases.push(row);
  }
  assert.equal(fulfilled,2);
  const evidence={scope:'local intercepted DOM, no upstream service or domain completion',chrome:version.product,
    assetID:fixture.assetID || null,assetSHA256:sha,
    transport:'new process; pipe; reject-only loopback proxy; DNS blocked; fixture documents intercepted',fixtureDocumentResponses:fulfilled,otherRequestsDenied:denied,cases};
  fs.writeFileSync(path.join(run,'receipt.json'),JSON.stringify(evidence,null,2),{flag:'wx'});
  console.log(JSON.stringify({directory:run,...evidence}));
  }
  verified = true;
} finally {
  const terminateOriginal = restartEvidence?.stage === 'original';
  const singleton = path.join(profile, 'SingletonLock');
  const beforeLock = terminateOriginal ? fs.lstatSync(singleton, {throwIfNoEntry:false}) : undefined;
  const beforeTarget = beforeLock?.isSymbolicLink() ? fs.readlinkSync(singleton) : undefined;
  const initialGroup = restartEvidence && spawnSync('/bin/ps', ['-p', String(child.pid), '-o', 'pgid='],
    {encoding:'utf8', timeout:1000});
  if (child.exitCode === null && child.signalCode === null) {
    if (terminateOriginal) assert.ok(child.kill('SIGTERM'), 'Could not terminate the owned predecessor');
    else await call('Browser.close').catch(()=>{});
  }
  const [exitCode, signal] = await closed;
  clearTimeout(timeout);
  rejectProxy.close();
  try {
    if (verified) {
      if (terminateOriginal) assert.ok(signal === 'SIGTERM' || exitCode === 0, 'Unexpected original process exit');
      else {
        assert.equal(exitCode, 0, 'Fixture browser did not exit normally');
        assert.equal(signal, null);
      }
    }
    if (exitCode !== null || signal !== null) {
      const now = fs.lstatSync(profile);
      assert.ok(now.isDirectory() && now.dev === profileIdentity.dev && now.ino === profileIdentity.ino,
        'Fixture profile identity changed');
      if (restartEvidence) {
        assert.ok(initialGroup?.status === 0 && initialGroup.stdout.trim() === String(child.pid),
          'Browser did not own its dedicated process group');
        // Query only the new process group. macOS can deny signal permission to
        // an exiting signed helper while still allowing a read-only group query.
        const deadline = performance.now() + 4000;
        let gone = false;
        do {
          const group = spawnSync('/bin/ps', ['-g', String(child.pid), '-o', 'pgid='], {encoding:'utf8', timeout:1000});
          if (group.status === 1 && !group.stdout.trim() && !group.stderr.trim()) { gone = true; break; }
          assert.ok(group.status === 0 && group.stdout.trim().split(/\s+/).every(id => id === String(child.pid)),
            'Could not verify the owned process group');
          await new Promise(resolve => setTimeout(resolve, 40));
        } while (performance.now() < deadline);
        restartEvidence.isolatedProcessGroupGone = gone;
        assert.ok(gone, 'Owned browser process group is still present');
      }
      const afterLock = fs.lstatSync(singleton, {throwIfNoEntry:false});
      if (afterLock && terminateOriginal) {
        assert.ok(beforeLock?.isSymbolicLink() && afterLock.isSymbolicLink() &&
          beforeLock.dev === afterLock.dev && beforeLock.ino === afterLock.ino &&
          beforeTarget.endsWith('-' + child.pid) && fs.readlinkSync(singleton) === beforeTarget,
          'Singleton does not match the reaped predecessor');
        restartEvidence.retainedSingletonWasReapedOwner = true;
      } else assert.equal(afterLock, undefined, 'Fixture profile is still locked');
      fs.rmSync(profile, {recursive: true});
    }
  } catch (error) {
    if (!restartEvidence) throw error;
    restartEvidence.status = 'FAIL_FIXTURE';
    restartEvidence.cleanupIssue = String(error.message).split('\n')[0].slice(0, 110);
  }
  if (restartEvidence) console.log(JSON.stringify({directory:run,...restartEvidence, reaped:true, exitCode, signal,
    requestedTermination: terminateOriginal ? 'SIGTERM' : 'Browser.close', privateProfileRemoved: !fs.existsSync(profile)}));
}
