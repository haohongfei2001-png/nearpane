// These pages are served by the local reject-only Chromium fixture. No account or live service.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createInterface} from 'node:readline';

const page = owned => '<main><form><textarea id="prompt-textarea">Unsent fixture note</textarea>' +
  '<button type="button" data-testid="composer-plus" aria-label="Attach file">+</button>' +
  '<button type="submit" aria-label="Send message">Send</button>' +
  (owned ? '<input type="file" accept="image/*">' : '') + '</form></main>';

function installObservers(detached, renderPreview=false) {
  const count = {setter:0,input:0,change:0,foreignSetter:0,foreignChange:0,sendClick:0,submit:0,foreignPickerRequests:0,previews:0};
  const form = document.querySelector('form');
  const input = detached ? document.createElement('input') : form.querySelector('input');
  const foreign = document.createElement('input');
  input.type = foreign.type = 'file';
  const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files');
  Object.defineProperty(HTMLInputElement.prototype,'files',{...desc,set(list){
    if (this===input && !detached) count.setter++;
    else count.foreignSetter++;
    return desc.set.call(this,list);
  }});
  document.addEventListener('submit',e=>{count.submit++;e.preventDefault();},true);
  document.addEventListener('click',e=>{if(e.target.closest('[type="submit"]'))count.sendClick++;},true);
  let hash, fileName, previewImage;
  const track = (el, isForeign) => {
    el.addEventListener('input',()=>{count.input++;});
    el.addEventListener('change',()=>{
      if(isForeign){count.foreignChange++;return;}
      count.change++;
      const file=el.files[0];
      fileName=file.name;
      hash=file.arrayBuffer().then(async a => [...new Uint8Array(await crypto.subtle.digest('SHA-256',a))]
        .map(b=>b.toString(16).padStart(2,'0')).join(''));
      // This is only the fixture application's local preview of its actual input.
      // The locked page program and queue independently decide what it proves.
      if(renderPreview){
        const preview=document.createElement('span');
        preview.dataset.fileName=file.name;
        previewImage=document.createElement('img');
        previewImage.alt='Local fixture attachment';
        previewImage.src=URL.createObjectURL(file);
        preview.append(previewImage);
        form.append(preview);
        count.previews++;
      }
    });
  };
  track(input,detached);track(foreign,true);
  if(detached) form.querySelector('[data-testid="composer-plus"]').addEventListener('click',()=>{
    setTimeout(()=>{count.foreignPickerRequests++;try{input.showPicker();}catch{}},20);
  });
  document.querySelector('#prompt-textarea').focus();
  globalThis.readFixture = async () => {
    if(previewImage) await previewImage.decode();
    return {...count, hash:await hash??null,fileName:fileName??null,
      previewSize:previewImage ? [previewImage.naturalWidth, previewImage.naturalHeight] : null,
      textPreserved:document.querySelector('#prompt-textarea')?.value==='Unsent fixture note'};
  };
}

async function drive(exe, args, settings, onCall) {
  const child=spawn(exe,args,{stdio:['pipe','pipe','inherit']});
  const exited=once(child,'exit');
  const watchdog=setTimeout(()=>child.kill('SIGKILL'),22000);
  child.stdin.on('error',()=>{});
  child.stdin.write(JSON.stringify(settings)+'\n');
  let result;
  try {
    for await (const line of createInterface({input:child.stdout})) {
      const message=JSON.parse(line);
      let response;
      if(message.cmd==='done'){ result=message; response={result:'ok'}; }
      else {
        const value=await onCall(message);
        response = value===undefined ? {rejected:true} : {result:value};
      }
      child.stdin.write(JSON.stringify(response)+'\n');
    }
    const [rc]=await exited;
    assert.equal(rc,0);assert.ok(result);
    return result;
  } finally {
    clearTimeout(watchdog);
    if(child.exitCode===null && child.signalCode===null)child.kill('SIGKILL');
    await exited;
  }
}

export async function runProductCases({run,compose,source,png,sha,fixture,call,send,evalPage,navigate,primary,chromePID}) {
  const cases=[];
  const id=fixture.assetID || randomUUID();
  const native={applicationID:'com.google.Chrome',sessionID:null,windowID:'1',tabID:'1'};
  const settings={assetID:id,sha256:sha,origin:fixture.origin??'systemScreenshot',
    width:fixture.width??2,height:fixture.height??2,chromePID};
  for(const scenario of ['owned-normal','owned','detached','composer-replaced','reload','tab-switch','route-changed','focused-other-editor','modal-over-composer']) {
    const folder=path.join(run,scenario);
    fs.mkdirSync(path.join(folder,'media'),{recursive:true,mode:0o700});
    fs.writeFileSync(path.join(folder,'media',id.toUpperCase()+'.png'),png,{flag:'wx'});
    const url='https://chatgpt.com/c/'+randomUUID();
    const html=page(scenario!=='detached');
    async function init() {
      await navigate(url,html);
      await evalPage('('+installObservers.toString()+')('+String(scenario==='detached')+','+String(scenario==='owned-normal')+')');
    }
    await init();
    if(scenario==='focused-other-editor'){
      await evalPage("(()=>{const other=document.createElement('textarea');document.body.prepend(other);other.focus()})()");
    } else if(scenario==='modal-over-composer'){
      await evalPage("(()=>{const dialog=document.createElement('dialog');dialog.textContent='fixture modal';document.body.append(dialog);dialog.showModal()})()");
    }
    let redirected=false,other,otherSession,documentBeforeReload,otherSnapshot,actionCounts={},nativeRefusals=0,pageRefusals=0;
    let selected=true;
    const pageObservations = [];
    async function callDriver(m) {
      if(m.cmd==='process'){native.sessionID=m.value;assert.ok(m.value.startsWith('chrome-kernel-v1:'+chromePID+':'));return 'ok';}
      if(m.cmd==='arm'){
        actionCounts.arm=(actionCounts.arm??0)+1;
        try {return await evalPage(m.script);} catch {pageRefusals++;return undefined;}
      }
      if(m.cmd==='selected') {
        if(!selected){nativeRefusals++;return undefined;}
        return 'ok';
      }
      assert.equal(m.cmd,'invoke');
      const action=m.command.action;actionCounts[action]=(actionCounts[action]??0)+1;
      if(action==='commit'&&!redirected){
        redirected=true;
        switch(scenario) {
        case 'composer-replaced':
          await evalPage(`(() => { const old=document.querySelector('form'), replacement=old.cloneNode(true);
             old.replaceWith(replacement); replacement.querySelector('textarea').focus(); })()`);break;
        case 'reload':
          documentBeforeReload=await evalPage('readFixture()');
          await init();break;
        case 'route-changed':
          await evalPage('history.pushState({},"","/c/'+randomUUID()+'")');break;
        }
      }
      if(!selected) {nativeRefusals++;return undefined;}
      // Withhold the owned fixture's commit reply AND later reads: an actual write may
      // have succeeded before a lost acknowledgement. Only the DOM observer knows it did.
      if(scenario==='owned' && action==='observe')return undefined;
      const expr='('+m.source+')('+JSON.stringify(m.command)+','+JSON.stringify(native)+')';
      let ret;
      try{ret=await evalPage(expr);}catch(e){pageRefusals++;fs.appendFileSync(path.join(folder,'refusals.log'),action+' '+String(e.message).slice(0,175)+'\n');return undefined;}
      const observation=ret?.observation;
      if(observation && !pageObservations.some(item=>item.action===action && item.state===observation.state)){
        pageObservations.push({action,state:observation.state,startSignal:observation.uploadStart?.signal,
          inputCount:observation.uploadStart?.inputCount,exactImage:observation.exactImageIdentity,
          operation:observation.identity?.operationID,attempt:observation.identity?.attempt});
      }
      // A real second target exists in this private headless instance. Use an explicitly
      // changed selection at the native boundary; headless does not publish Apple Events IDs.
      if(action==='captureTarget' && scenario==='tab-switch' && !other) {
        other=(await call('Target.createTarget',{url:'about:blank',background:true})).targetId;
        otherSession=(await call('Target.attachToTarget',{targetId:other,flatten:true})).sessionId;
        await navigate('https://chatgpt.com/c/'+randomUUID(),page(true),otherSession);
        await evalPage('('+installObservers.toString()+')(false)',otherSession);
        await call('Target.activateTarget',{targetId:other});
        selected=false;
      }
      if(action==='commit' && scenario==='owned'){
        return undefined;
      }
      return JSON.stringify(ret);
    }
    const domain=await drive(compose,[source,folder,'click'],settings,callDriver);
    fs.writeFileSync(path.join(folder,'first-click.json'),JSON.stringify({domain,actionCounts,nativeRefusals,pageRefusals,pageObservations,events:await evalPage('readFixture()')}));
    const firstClickCommands={...actionCounts};
    let repeat;
    if(scenario==='owned'){
      assert.equal(domain.status,'unknown'); assert.equal(domain.phase,'unknown');
      repeat=await drive(compose,[source,folder,'repeat'],settings,callDriver);
      assert.notEqual(repeat.driverPID,domain.driverPID);
      assert.equal(repeat.operation,domain.operation);
      assert.equal(repeat.attempt,domain.attempt);
      assert.equal(actionCounts.commit,1);
      for(const v of ['begin','chunk','commit'])assert.equal(actionCounts[v],firstClickCommands[v]);
    }
    const beforeRestart={...actionCounts};
    const fresh=await drive(compose,[source,folder,'restart'],settings,callDriver);
    assert.deepEqual(actionCounts,beforeRestart,'restart must never enter a browser command');
    assert.equal(fresh.status,domain.status);
    assert.notEqual(fresh.driverPID,domain.driverPID);
    if(other) {
      assert.equal(await evalPage('document.querySelectorAll("form input[type=file]").length',otherSession),1);
      otherSnapshot=await evalPage('readFixture()',otherSession);
      for(const event of ['setter','input','change','foreignSetter','foreignChange','sendClick','submit']){
        assert.equal(otherSnapshot[event],0,'newly selected draft must receive no input');
      }
      assert.equal(otherSnapshot.textPreserved,true);
      await call('Target.closeTarget',{targetId:other}); await call('Target.activateTarget',{targetId:primary});
    }
    const events=await evalPage('readFixture()');
    const positive=scenario==='owned'||scenario==='owned-normal';
    assert.equal(events.foreignSetter,0);assert.equal(events.foreignChange,0);
    assert.equal(events.setter,Number(positive));assert.equal(events.change,Number(positive));assert.equal(events.input,Number(positive));
    assert.equal(events.hash,positive?sha:null);
    assert.equal(events.sendClick,0);assert.equal(events.submit,0);
    assert.equal(events.textPreserved,true);
    if(positive){
      assert.equal(events.fileName,'riftlet-'+domain.operation.toUpperCase()+'.png');
      assert.equal(actionCounts.commit,1);
      assert.equal(domain.attempt,1);assert.notEqual(domain.status,'used');
      assert.notEqual(domain.receipt,'verifiedReady');
      assert.equal(fresh.feedback,domain.feedback);
      if(scenario==='owned'){
        assert.equal(domain.status,'unknown');assert.equal(domain.phase,'unknown');
        assert.match(domain.feedback,/结果未知/);assert.equal(domain.start,undefined);
      } else {
        assert.equal(events.previews,1);
        assert.deepEqual(events.previewSize,[settings.width,settings.height]);
        assert.equal(domain.start,'uploadStarted');
        assert.match(domain.feedback,/已开始上传，尚无完成回执/);
        assert.ok(pageObservations.some(item=>item.state==='uploadStarted' && item.startSignal==='attachmentAccepted'
          && item.inputCount===1 && item.exactImage && item.operation.toLowerCase()===domain.operation && item.attempt===1));
      }
    } else {
      assert.ok(!['used','verifiedReady'].includes(domain.status));
      if(scenario==='detached')assert.equal(events.foreignPickerRequests,1);
      if(scenario==='tab-switch'){ assert.ok(nativeRefusals>0); assert.ok(other); }
      if(['composer-replaced','route-changed','reload'].includes(scenario)){
        assert.ok(redirected);assert.equal(actionCounts.commit,1);assert.ok(pageRefusals>0);
      }
      if(scenario==='reload')assert.equal(documentBeforeReload.setter,0);
      if(['focused-other-editor','modal-over-composer'].includes(scenario)){
        assert.equal(actionCounts.arm,1);assert.ok(!actionCounts.commit);assert.ok(pageRefusals>0);
      }
    }
    cases.push({scenario,assetID:id,commands:actionCounts,events,domain,freshProcess:fresh,
      nativeRefusals,pageRefusals,pageObservations,repeat,firstClickCommands,changedTab:!!other,otherDraft:otherSnapshot,oldDocument:documentBeforeReload});
  }
  return {scope:'ordinary Swift tray, executor, WebAttachmentAdapter and original queue policy with pipe in place of OS Chrome addressing. Local intercepted DOMs; no ChatGPT service.',
    transport:'fresh headless profile; reject proxy; private CDP pipe; synthetic native window/tab route; intercepted fixture documents',
    candidateBrowserResources:fixture.candidateBrowserResources,assetSHA256:sha,cases};
}
