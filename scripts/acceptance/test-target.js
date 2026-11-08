// Synthetic DOM only. The browser baseline and the last guard are the shipped sources.
'use strict';
const assert = require('node:assert/strict'), vm = require('node:vm'), fs = require('node:fs');
const {test} = require('node:test'), {resolve} = require('node:path');
const read = name => fs.readFileSync(resolve(__dirname, name), 'utf8');
const session = 'a701057b-e632-48c4-9272-f58e18379d12', nonce = '337122e7-25f5-4c1f-85dc-6aba2685af00';
function fixture() {
  const form = {isConnected:true, querySelectorAll:() => []};
  const editor = Object.assign(new EventTarget(), {innerText:'NEARPANE-TEST-'+session, isConnected:true,
    getClientRects:() => [1], closest:() => form});
  const document = Object.assign(new EventTarget(), {documentElement:{}, visibilityState:'visible', hasFocus:()=>true,
    querySelectorAll: selector => selector.includes('contenteditable') ? [editor] : [{closest:()=>({getAttribute:()=>'turn'})}]});
  const native = {sessionID:'chrome-kernel-v1:45:98:1',windowID:'10',tabID:'12',applicationID:'com.google.Chrome'};
  const b = {url:'https://chatgpt.com/c/fixture', nonce, session, expiresAt: Date.now()/1000+100,
    timeOrigin:100, process:native.sessionID, window:'10',tab:'12',assetID:session,sha256:'a'.repeat(64)};
  const cmd = {action:'commit',identity:{assetID:b.assetID,assetSHA256:b.sha256,attempt:1}};
  const c = vm.createContext({document, location:{href:b.url}, performance:{timeOrigin:100}, window:new EventTarget(), Event});
  vm.runInContext(read('draft-observation.js')+'\n'+read('../../Resources/AcceptanceTargetGuard.js'), c);
  assert.ok(c.observeTestDraft(b.url,editor.innerText,nonce,true));
  const x = {document, c, editor, form, b, native, cmd, inputs:0};
  x.press = () => c.nearpaneBoundDraft(b, {action:'captureTarget'}, native, false);
  x.commit = () => { c.nearpaneBoundDraft(b,cmd,native,true); x.inputs++; };
  return x;
}
test('armed original reaches the setter once in the fixture', () => {
  const x=fixture(); x.press(); x.commit(); assert.equal(x.inputs,1);
});
for (const [name, change] of Object.entries({
  'front tab after baseline': x => { x.native.tabID='13'; },
  'after press draft switched': x => { x.editor.innerText='another draft'; },
  'same URL new document': x => { x.document.documentElement={}; },
  'reused PID with new birth': x => { x.native.sessionID='chrome-kernel-v1:45:101:2'; },
  'window recreated': x => { x.native.windowID='11'; },
  'target gone': x => { x.editor.isConnected=false; },
  'same UUID different bytes': x => { x.cmd.identity.assetSHA256='b'.repeat(64); },
  'same bytes different asset': x => { x.cmd.identity.assetID=nonce; },
  'expired session': x => { x.b.expiresAt=1; },
  'different session': x => { x.b.session=nonce; },
  'away then back': x => { x.c.window.dispatchEvent(new Event('pagehide')); },
  'second attempt': x => { x.cmd.identity.attempt=2; },
})) test(name, () => {
  const x=fixture(); x.press(); change(x);
  assert.throws(x.commit, /TARGET_INVALID/); assert.equal(x.inputs,0);
  if (name === 'front tab after baseline') assert.throws(x.press,/TARGET_INVALID/);
});
