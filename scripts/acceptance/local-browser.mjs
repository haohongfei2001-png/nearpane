// A new headless Chromium process with a local reject-only proxy and a private DevTools pipe.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const build = path.join(root, 'build');
const run = fs.mkdtempSync(path.join(build, 'local-browser-'));
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [compose, source] = process.argv.slice(2);
assert.equal(fs.realpathSync(compose).startsWith(build + '/'), true);
const fixture = JSON.parse(fs.readFileSync(0,'utf8') || '{}');
const png = Buffer.from(fixture.png ||
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNQ91/l1DGH4cwql/K0UAAk9wVzjPxe1gAAAABJRU5ErkJggg==','base64');
const sha = createHash('sha256').update(png).digest('hex');
if (fixture.png) assert.equal(sha,fixture.sha256);
const profile = path.join(run, 'user-data');
fs.mkdirSync(profile, {mode: 0o700});
const rejectProxy = net.createServer(socket => socket.destroy());
rejectProxy.listen(0,'127.0.0.1');
await once(rejectProxy,'listening');
const stderr = fs.openSync(path.join(run, 'chrome.log'), 'wx', 0o600);
const child = spawn(chrome, ['--headless=new', '--remote-debugging-pipe',
  '--proxy-server=http://127.0.0.1:'+rejectProxy.address().port, '--proxy-bypass-list=<-loopback>',
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1','--disable-quic','--disable-breakpad',
  '--user-data-dir=' + profile, '--use-mock-keychain', '--disable-background-networking', '--disable-sync',
  '--disable-extensions', '--no-first-run', '--no-default-browser-check', '--disable-component-update', 'about:blank'],
  {stdio:['ignore','ignore',stderr,'pipe','pipe']});
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
    } else handlers.get(msg.method)?.(msg);
  }
});
closed.then(() => { for (const waiter of pending.values()) waiter.reject(Error('Fixture browser exited')); });
const timeout = setTimeout(() => child.kill('SIGKILL'), 45000);
const draft = fs.readFileSync(path.join(root,'scripts/acceptance/draft-observation.js'),'utf8');
try {
  const version = await call('Browser.getVersion');
  const pages = (await call('Target.getTargets')).targetInfos.filter(t=>t.type==='page');
  assert.equal(pages.length,1); assert.equal(pages[0].url,'about:blank');
  const {sessionId} = await call('Target.attachToTarget',{targetId:pages[0].targetId,flatten:true});
  const send = (m,p) => call(m,p,sessionId);
  const evalPage = async expr => {
    const r=await send('Runtime.evaluate',{expression:expr,awaitPromise:true,returnByValue:true});
    if (r.exceptionDetails) throw Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  await send('Page.enable');
  await send('Emulation.setFocusEmulationEnabled',{enabled:true});
  await send('Fetch.enable',{patterns:[{urlPattern:'*'}]});
  let url, html, fulfilled=0, denied=0;
  handlers.set('Fetch.requestPaused', ({params}) => {
    if (params.resourceType === 'Document' && params.request.url === url && params.request.method === 'GET') {
      fulfilled++;
      void send('Fetch.fulfillRequest',{requestId:params.requestId,responseCode:200,
        responseHeaders:[{name:'Content-Type',value:'text/html; charset=utf-8'},
          {name:'Content-Security-Policy',value:"default-src 'none'; form-action 'none'; base-uri 'none'"}],
        body:Buffer.from(html).toString('base64')});
    } else { denied++; void send('Fetch.failRequest',{requestId:params.requestId,errorReason:'BlockedByClient'}); }
  });
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
} finally {
  if(child.exitCode===null && child.signalCode===null) await call('Browser.close').catch(()=>{});
  await closed; clearTimeout(timeout); rejectProxy.close();
}
