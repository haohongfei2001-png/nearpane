// Observe a fresh, official ChatGPT guest draft. The only attachment input comes from the installed Nearpane thumbnail.
import fs from 'node:fs';
import path from 'node:path';
import { once } from 'node:events';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';

const [mode, destination, capturePath, tool] = process.argv.slice(2);
if (!destination || !['preflight','draft'].includes(mode) || (mode === 'draft' && (!capturePath || !tool))) {
  throw Error('Usage: node tool-draft.mjs preflight NEW_OUTPUT | draft NEW_OUTPUT CAPTURE_RESULT TOOL_CAPTURE');
}
const output=path.resolve(destination);
fs.mkdirSync(output,{mode:0o700});
const root=fs.mkdtempSync('/private/tmp/nearpane-real-chrome-');
const profile=path.join(root,'user-data'); fs.mkdirSync(profile,{mode:0o700});
const chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const endpoint='https://chatgpt.com/';
const report={mode,provider:'ChatGPT',profile:'new signed-out browser profile',status:'BLOCKED',clicksIssued:0,
  productAttachment:false,documentStatus:null,blockedConversationRequests:0,submitEvents:0,enterEvents:0,sendButtonEvents:0};
let child, closed, boundaryArmed=false, clickCommandStarted=false, documentSession, command;
let nextID=0, buffer=''; const replies=new Map();
function homeSnapshot() {
  const editor = document.querySelector('#prompt-textarea');
  const form = editor?.closest('form,[data-testid="composer"],[data-composer-placement]');
  const visible = el => !!el?.getClientRects().length && !el.closest('[hidden],[aria-hidden="true"],[inert]');
  const challenge = !!document.querySelector('script[src*="/cdn-cgi/challenge"],iframe[src*="challenges.cloudflare"],#challenge-stage,#challenge-running') ||
      /just a moment|security verification/i.test(document.title);
  const cards = form ? [...form.querySelectorAll('[data-file-name],img[src^="blob:"],img[src^="data:image/"]')]
      .filter(visible).filter(e => !e.parentElement.closest('[data-file-name]')) : [];
  const matching = cards.flatMap(card=>[card,...card.querySelectorAll('[data-file-name],[title],[aria-label],img[alt]')])
      .flatMap(n => ['data-file-name','alt','title','aria-label'].map(k=>n.getAttribute(k)))
      .filter(x=>typeof x==='string' && /^riftlet-[0-9a-f-]{36}\.(png|jpg)$/i.test(x)).map(x=>x.toLowerCase());
  return {
    officialHome:location.href==='https://chatgpt.com/',timeOrigin:performance.timeOrigin,
    visibleComposer:visible(editor)&&visible(form),emptyComposer:!!editor&&!(editor.value||editor.innerText||'').trim(),
    userTurns:document.querySelectorAll('[data-message-author-role="user"]').length, ready:document.readyState,challenge,
    modal:[...document.querySelectorAll('dialog[open],[aria-modal=true]')].some(visible),
    previewCount:cards.length,previews: [...new Set(matching)],
    uploadBusy: !!form && [...form.querySelectorAll('[role=progressbar],progress,[aria-busy=true],[role=alert]')].some(visible),
    pageCounters:window.__nearpaneNoSendWitness?.counters??null
  };
}
function installGuard() {
 const root = document.documentElement, editor = document.querySelector('#prompt-textarea'), form=editor?.closest('form,[data-testid="composer"],[data-composer-placement]');
 if (location.href !== 'https://chatgpt.com/' || !editor || !form || document.querySelector('[data-message-author-role="user"]')) return false;
 const counters={submit:0,enter:0,sendButton:0};
 const refuse = (event,k) => { counters[k]++; event.preventDefault(); event.stopImmediatePropagation(); };
 document.addEventListener('submit', e => { if (e.target===form || form.contains(e.target)) refuse(e,'submit'); },true);
 document.addEventListener('keydown',e => { if (e.key==='Enter' && form.contains(e.target)) refuse(e,'enter'); },true);
 document.addEventListener('click',e=>{if (e.target.closest('[data-testid="send-button"],#composer-submit-button,button[type="submit"]') && form.contains(e.target)) refuse(e,'sendButton');},true);
 Object.defineProperty(window,'__nearpaneNoSendWitness',{value:{counters,root,editor,form}});
 editor.focus();
 return document.activeElement===editor && document.visibilityState==='visible' && document.hasFocus();
}
function requireFact(flag,reason){if(!flag)throw Error(reason);}
function snapshotForReceipt(s){return {officialHome:s.officialHome,visibleComposer:s.visibleComposer,emptyComposer:s.emptyComposer,
  userTurns:s.userTurns,challenge:s.challenge,modal:s.modal,previews:s.previewCount,identifiedPreviews:s.previews.length,uploadBusy:s.uploadBusy};}
function unsafeSend(url,method){
  if (!['POST','PUT','PATCH','DELETE'].includes(method)) return false;
  const u=new URL(url);
  return /(^|\.)(chatgpt\.com|openai\.com)$/.test(u.hostname) &&
    /(?:^|\/)(?:f\/)?(?:conversations?|conversation-submit|responses|messages|completions)(?:\/|$)/i.test(u.pathname);
}
async function onMessage(msg){
  if (msg.id) {const deliver=replies.get(msg.id);if(deliver){replies.delete(msg.id);deliver(msg);}return;}
  if(msg.sessionId!==documentSession)return;
  if (msg.method==='Network.responseReceived'&&msg.params.type==='Document'&&msg.params.response.url===endpoint)
    report.documentStatus=msg.params.response.status;
  if (msg.method==='Fetch.requestPaused'){
    const {requestId,request}=msg.params;
    if(boundaryArmed && unsafeSend(request.url,request.method)){
      report.blockedConversationRequests++; await command('Fetch.failRequest',{requestId,errorReason:'BlockedByClient'},documentSession);
    } else await command('Fetch.continueRequest',{requestId},documentSession);
  }
}
function connect(){
  command=(method,params={},sessionId)=>new Promise((resolve,reject)=>{
    const id=++nextID;
    const timer=setTimeout(()=>{replies.delete(id);reject(Error('Browser operation timed out: '+method));},12000);
    replies.set(id,msg=>{clearTimeout(timer);if(msg.error)reject(Error('Browser declined '+method));else resolve(msg.result);});
    child.stdio[3].write(JSON.stringify({id,method,params,sessionId})+'\0');
  });
  child.stdio[4].setEncoding('utf8').on('data',part=>{
    buffer+=part; let i;
    while((i=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,i));buffer=buffer.slice(i+1);void onMessage(msg).catch(()=>{});}
  });
}
async function dom(observe){
  const expression = '('+observe.toString()+')()';
  const result=await command('Runtime.evaluate',{expression,returnByValue:true},documentSession);
  requireFact(!result.exceptionDetails && result.result.type!=='undefined','Official page observation unavailable');
  return result.result.value;
}
async function runTool(action){
  const dir=path.join(output,action);
  const args=[action,dir,String(child.pid),capturePath];
  const proc=spawn(tool,args,{env:{...process.env,NEARPANE_TEST_CHROME_PROFILE:profile},stdio:'ignore'});
  const [code]=await once(proc,'exit');
  const receipt=JSON.parse(fs.readFileSync(path.join(dir,'result.json'),'utf8'));
  requireFact(code===0,receipt.reason??('Product '+action+' was not available'));
  return receipt;
}
function library(sql){
  const db=path.join(process.env.NEARPANE_TEST_GENERATION,'Riftlet','queue.sqlite');
  const data=execFileSync('/usr/bin/sqlite3',['-readonly','-json',db,sql],{encoding:'utf8'});
  return JSON.parse(data.trim()||'[]');
}
try {
  execFileSync('/usr/bin/codesign',['--verify','--strict','-R=anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV"',path.resolve(chrome,'../../..')]);
  let image;
  if (mode==='draft'){
    requireFact(process.env.NEARPANE_TEST_HOME && process.env.NEARPANE_TEST_GENERATION,'An isolated product generation is required');
    if(capturePath !== '-' && fs.existsSync(capturePath)){
      image=JSON.parse(fs.readFileSync(capturePath,'utf8'));
      if(image.status==='PASS'){
        const bytes=fs.readFileSync(path.join(path.dirname(capturePath),'screenshot.png'));
        requireFact(createHash('sha256').update(bytes).digest('hex')===image.sha256,'Fixture screenshot changed');
        report.assetSHA256=image.sha256;
      }
    }
    report.ownedCaptureAvailable=Boolean(image?.status==='PASS' && image.ownedPatternMatched && image.ownedCropSizeMatched);
  }
  child=spawn(chrome,[...(mode==='preflight'?['--headless=new']:[]),'--remote-debugging-pipe','--user-data-dir='+profile,
    '--use-mock-keychain','--no-first-run','--no-default-browser-check','--disable-sync','--disable-extensions','--disable-background-networking',
    '--disable-component-update','--window-size=820,650','--window-position=40,75','about:blank'],{stdio:['ignore','ignore','ignore','pipe','pipe']});
  closed=once(child,'close');connect();
  const {targetInfos}=await command('Target.getTargets');
  const blank=targetInfos.filter(t=>t.type==='page');
  requireFact(blank.length===1 && blank[0].url==='about:blank','Fresh Chrome did not have exactly one blank test tab');
  ({sessionId:documentSession}=await command('Target.attachToTarget',{targetId:blank[0].targetId,flatten:true}));
  await command('Page.enable',{},documentSession);await command('Network.enable',{},documentSession);
  report.browser=(await command('Browser.getVersion')).product;
  await command('Page.navigate',{url:endpoint},documentSession);
  let before;
  for(let i=0;i<28;i++){
    await sleep(600);
    try{before=await dom(homeSnapshot);}catch{continue;}
    if (before.challenge || (before.officialHome&&before.visibleComposer))break;
  }
  requireFact(before,'No official page observation');
  report.before=snapshotForReceipt(before);
  requireFact(!before.challenge,'Official guest page requires site verification');
  requireFact(report.documentStatus===200 && before.officialHome && before.visibleComposer && before.emptyComposer &&
    !before.modal && before.userTurns===0 && before.previewCount===0 && !before.uploadBusy,'The official site did not provide a blank usable guest composer');
  if(mode==='preflight'){report.status='READY';}
  else {
    requireFact(report.ownedCaptureAvailable,'The guest site is accessible, but a verified product capture is required for attachment');
    await command('Page.bringToFront',{},documentSession);await sleep(250);
    await runTool('authorize');await command('Page.bringToFront',{},documentSession);await sleep(250);
    requireFact((await dom(homeSnapshot)).timeOrigin===before.timeOrigin,'Official page changed before the single attachment attempt');
    await command('Fetch.enable',{patterns:[{urlPattern:'https://*/*',requestStage:'Request'}]},documentSession);
    boundaryArmed=true;
    requireFact(await dom(installGuard),'Could not arm no-send observations on the official editable composer');
    clickCommandStarted=true;
    const intent=await runTool('click');report.clicksIssued=intent.clicks;
    let last,ops=[],starts=[],calls=[],matched=false,matchedSince=null;
    for(let i=0;i<52;i++){
      await sleep(450);last=await dom(homeSnapshot);
      requireFact(last.timeOrigin===before.timeOrigin && last.officialHome && last.pageCounters,'Original unsent guest page or safety guard disappeared');
      ops=library('select id,asset_id,phase,target_json,receipt_json from operations order by sequence');
      starts=library('select operation_id,receipt_json from upload_starts');
      calls=library("select key from checkpoints where key like 'transfer-dispatch-call-v1:%'");
      matched=ops.length===1 && ops[0].asset_id.toLowerCase()===image.assetID.toLowerCase() &&
        last.previews.some(n=>n==='riftlet-'+ops[0].id.toLowerCase()+'.png');
      report.after=snapshotForReceipt(last);report.submitEvents=last.pageCounters.submit;report.enterEvents=last.pageCounters.enter;
      report.sendButtonEvents=last.pageCounters.sendButton;
      if(last.userTurns || report.submitEvents || report.enterEvents || report.sendButtonEvents || report.blockedConversationRequests)break;
      if(matched && !last.uploadBusy && ops[0].phase==='succeeded'){
        matchedSince??=performance.now();
        if(performance.now()-matchedSince>=5000)break;
      } else matchedSince=null;
      if(ops.some(op=>['failed','compensated'].includes(op.phase)))break;
    }
    report.after=snapshotForReceipt(last); report.submitEvents=last.pageCounters.submit; report.enterEvents=last.pageCounters.enter;
    report.sendButtonEvents=last.pageCounters.sendButton;
    report.storage={operations:ops.length,inputDispatches:calls.length,uploadStarts:starts.length,phase:ops.length===1?ops[0].phase:null};
    const noSend=!last.userTurns && !report.submitEvents && !report.enterEvents && !report.sendButtonEvents && !report.blockedConversationRequests;
    const op=ops[0], target=op?.target_json?JSON.parse(op.target_json):null;
    const bound=target?.applicationID==='com.google.Chrome' && target.adapterID==='chatgpt-web' && target.surface==='webChat' &&
      target.sessionID?.split(':')[1]===String(child.pid) && Boolean(target.windowID && target.tabID && target.documentID && target.composerID && target.draftGeneration);
    function receiptMatches(value){
      if(!value)return false;
      const r=JSON.parse(value);
      return r.operationID?.toLowerCase()===op.id.toLowerCase() && r.assetID?.toLowerCase()===image.assetID.toLowerCase() &&
        r.assetSHA256===image.sha256 && r.attempt===1 && r.target?.sessionID===target?.sessionID && r.target?.tabID===target?.tabID &&
        r.target?.windowID===target?.windowID && r.target?.documentID===target?.documentID && r.target?.composerID===target?.composerID;
    }
    report.productReceiptMatches=Boolean(bound && receiptMatches(op?.receipt_json) && receiptMatches(starts[0]?.receipt_json));
    report.observedQuietMilliseconds=matchedSince===null?0:Math.round(performance.now()-matchedSince);
    report.productAttachment=matched && report.productReceiptMatches && report.observedQuietMilliseconds>=5000 && last.previewCount===1 && last.previews.length===1 &&
      !last.uploadBusy && last.emptyComposer && noSend && op?.phase==='succeeded' && calls.length===1 &&
      calls[0].key.toLowerCase()==='transfer-dispatch-call-v1:'+op.id.toLowerCase() && starts.length===1 && starts[0].operation_id===op.id;
    const productFailed=['failed','compensated'].includes(op?.phase);
    report.status=report.productAttachment?'PASS':noSend&&!productFailed?'UNKNOWN':'FAIL';
    if(!report.productAttachment)report.reason=!noSend?'The guard observed an attempted submission':productFailed?'The installed Host recorded a failed operation':'An attachment could not be independently confirmed in the original stable guest composer';
    if(report.productAttachment){
      const screenshot=await command('Page.captureScreenshot',{format:'png',fromSurface:true},documentSession);
      fs.writeFileSync(path.join(output,'official-unsent-draft.png'),Buffer.from(screenshot.data,'base64'),{flag:'wx',mode:0o600});
    }
  }
} catch(e){report.reason=e.message; if(clickCommandStarted)report.status='UNKNOWN';}
finally {
  if(child){
    try{await command('Browser.close');}catch{}
    const ended=await Promise.race([closed.then(()=>true),sleep(3000).then(()=>false)]);
    if(!ended){child.kill('SIGTERM');await Promise.race([closed,sleep(2000)]);}
    report.browserClosed=child.exitCode!==null || child.signalCode!==null;
  }
  if(report.blockedConversationRequests || report.submitEvents || report.enterEvents || report.sendButtonEvents || report.after?.userTurns){
    report.status='FAIL';report.productAttachment=false;report.reason='Submission attempt observed and stopped';
  }
  if(!child||report.browserClosed)fs.rmSync(root,{recursive:true});
  report.profileRemoved=!fs.existsSync(root);
  fs.writeFileSync(path.join(output,'result.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
}
console.log(report.status,report.reason??'');
process.exitCode=['PASS','READY'].includes(report.status)?0:3;
