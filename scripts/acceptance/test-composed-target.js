// Swift supplies the exact source returned by TestTargetBinding.program. Only platform objects are doubles.
'use strict';
const {test} = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm'), crypto = require('node:crypto');
const {binding: b, source, png} = JSON.parse(fs.readFileSync(process.env.NEARPANE_COMPOSED_FIXTURE));
const baseline = fs.readFileSync(require('node:path').join(__dirname, 'draft-observation.js'), 'utf8');

function page() {
  let clock = 101000, seq = 0, currentEvent, beforeWrite;
  const timers = new Map(), observers = new Set();
  const later = (fn, ms) => { const id = ++seq; timers.set(id, {at:clock + ms, fn}); return id; };
  class PageEvent {
    static AT_TARGET = 2;
    constructor(type, options = {}) { Object.assign(this, options, {type, target:null, currentTarget:null, eventPhase:0, defaultPrevented:false}); }
    preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
    composedPath() { return this.path; }
  }
  class Hub {
    listeners = new Map();
    addEventListener(type, fn, options) {
      const list = this.listeners.get(type) || []; this.listeners.set(type, list);
      list.push({fn, capture:options === true || !!options?.capture});
    }
    removeEventListener(type, fn, options) {
      const capture = options === true || !!options?.capture;
      this.listeners.set(type, (this.listeners.get(type) || []).filter(x => x.fn !== fn || x.capture !== capture));
    }
    dispatchEvent(e) {
      const path = [this];
      for (let at = this; (at = at.parentElement || at.eventParent);) path.push(at);
      const outer = currentEvent; currentEvent = e; e.target = this; e.path = path;
      const fire = (at, capture, phase) => {
        e.currentTarget = at; e.eventPhase = phase;
        for (const handler of [...(at.listeners.get(e.type) || [])]) if (handler.capture === capture) handler.fn.call(at,e);
      };
      try {
        for (const at of path.slice(1).reverse()) fire(at, true, 1);
        fire(this, true, 2); fire(this, false, 2);
        if (e.bubbles) for (const at of path.slice(1)) fire(at, false, 3);
        return !e.defaultPrevented;
      } finally { e.currentTarget = null; e.eventPhase = 0; currentEvent = outer; }
    }
  }
  class MutationObserver {
    constructor(fn) { this.fn = fn; this.records = []; }
    observe() { observers.add(this); }
    disconnect() { observers.delete(this); this.records = []; }
    takeRecords() { return this.records.splice(0); }
  }
  function mutate(target, addedNodes, removedNodes) {
    for (const obs of observers) {
      obs.records.push({type:'childList', target, addedNodes, removedNodes});
      queueMicrotask(() => { const list = obs.takeRecords(); if (list.length && observers.has(obs)) obs.fn(list); });
    }
  }
  const document = new Hub(), window = new Hub();
  class Element extends Hub {
    constructor(tag, attrs = {}) {
      super(); this.tagName = tag.toUpperCase(); this.attrs = attrs; this.children = []; this.parentElement = null;
      this.nodeType = 1; this.ownerDocument = document; this.textContent = '';
    }
    get id() { return this.getAttribute('id') || ''; }
    get type() { return this.getAttribute('type') || ''; }
    get parentNode() { return this.parentElement || this.eventParent || null; }
    get isConnected() { return document.documentElement.contains(this); }
    get form() { return this.hasAttribute('form') ? document.getElementById(this.getAttribute('form')) : this.closest('form'); }
    getAttribute(k) { return this.attrs[k] ?? null; }
    hasAttribute(k) { return Object.hasOwn(this.attrs, k); }
    matches(selectors) {
      return selectors.split(',').some(raw => {
        const s = raw.trim();
        if (s === '*') return true;
        if (s.startsWith('#')) return this.id === s.slice(1);
        if (s === ':disabled') return !!this.disabled;
        const m = /^([\w-]+)?(?:\[([\w-]+)(?:(\^?=)"([^"]*)")?\])?$/.exec(s);
        if (!m) throw Error('Unsupported synthetic selector: ' + s);
        return (!m[1] || this.tagName === m[1].toUpperCase()) && (!m[2] ||
          (this.hasAttribute(m[2]) && (!m[3] || (m[3] === '=' ? this.attrs[m[2]] === m[4] : this.attrs[m[2]].startsWith(m[4])))));
      });
    }
    closest(s) { for (let n = this; n; n = n.parentElement) if (n.matches(s)) return n; return null; }
    contains(other) { for (let n = other; n; n = n.parentElement) if (n === this) return true; return false; }
    querySelectorAll(s) { return this.children.flatMap(n => [...(n.matches(s) ? [n] : []), ...n.querySelectorAll(s)]); }
    querySelector(s) { return this.querySelectorAll(s)[0] || null; }
    append(n) { n.remove(); this.children.push(n); n.parentElement = this; mutate(this,[n],[]); return n; }
    remove() {
      const p = this.parentElement;
      if (p) { p.children.splice(p.children.indexOf(this),1); this.parentElement = null; mutate(p,[],[this]); }
    }
    getClientRects() { return [{}]; }
    getBoundingClientRect() { return {width:10,height:10,top:0,left:0,right:10,bottom:10}; }
    click() { this.dispatchEvent(new PageEvent('click',{bubbles:true,cancelable:true})); }
  }
  class HTMLInputElement extends Element {
    constructor(name) {
      super('input', {type:'file'}); this.name = name; this.accept = ''; this.writes = []; this.nativePickers = 0;
      this.inputEvents = 0; this.changeEvents = 0;
      this.addEventListener('input', () => this.inputEvents++);
      this.addEventListener('change', () => this.changeEvents++);
    }
    set files(v) { this.writes.push([...v]); this.onSetter?.(); }
    showPicker() { this.nativePickers++; }
  }
  const html = new Element('html'); document.documentElement = html; html.eventParent = document; document.eventParent = window;
  const body = document.body = html.append(new Element('body'));
  document.querySelectorAll = s => html.querySelectorAll(s);
  document.getElementById = id => html.querySelectorAll('[id]').find(n => n.id === id) || null;
  document.hasFocus = () => true; document.visibilityState = 'visible';
  body.append(new Element('article', {'data-message-author-role':'user','data-message-id':'fixture-turn'}));
  const form = body.append(new Element('form', {id:'composer-fixture'}));
  const editor = form.append(new Element('textarea')); editor.value = 'NEARPANE-TEST-' + b.session;
  const entry = form.append(new Element('button', {type:'button','aria-label':'Attach file','data-testid':'composer-plus'}));
  const own = new HTMLInputElement('own'), foreign = new HTMLInputElement('foreign');
  let clicks = 0; entry.addEventListener('click', () => clicks++);
  const native = {applicationID:'com.google.Chrome',sessionID:b.process,windowID:b.window,tabID:b.tab};
  class TestURL extends URL { static createObjectURL = undefined; }
  const context = vm.createContext({document, crypto, location:{href:b.url}, history:{}, URL:TestURL,
    get event() { return currentEvent; },
    getComputedStyle:() => ({}), MutationObserver, HTMLInputElement, File, Event:PageEvent, PointerEvent:PageEvent, MouseEvent:PageEvent, KeyboardEvent:PageEvent,
    Date:class extends Date { static now() { return clock; } }, performance:{timeOrigin:b.timeOrigin, now:() => {beforeWrite?.(); return clock - 101000;}},
    setTimeout:later, clearTimeout:id => timers.delete(id), queueMicrotask, atob,
    DataTransfer:class { files = []; items = {add:f => this.files.push(f)}; },
    addEventListener:window.addEventListener.bind(window), removeEventListener:window.removeEventListener.bind(window)});
  vm.runInContext('globalThis.top = globalThis.window = globalThis', context);
  vm.runInContext(baseline,context);
  assert.ok(context.observeTestDraft(b.url,editor.value,b,true));
  const program = vm.runInContext('(' + source + ')', context);
  async function run() {
    const target = program({action:'captureTarget'}, native);
    const operationID = crypto.randomUUID(), sha = crypto.createHash('sha256').update(Buffer.from(png,'base64')).digest('hex');
    assert.equal(sha,b.sha256);
    const identity = {operationID,assetID:b.assetID,attempt:1,assetSHA256:sha,target};
    const base = {target,identity,invocationID:crypto.randomUUID()};
    const invoke = (action, extra) => program({...base,action,...extra},native);
    assert.equal(invoke('begin',{uploadName:'riftlet-'+operationID+'.png',mediaType:'image/png',byteCount:Buffer.from(png,'base64').length}).nextChunk,0);
    assert.equal(invoke('chunk',{chunkIndex:0,chunkBase64:png}).nextChunk,1);
    let result, error;
    Promise.resolve(invoke('commit',{chunkIndex:1})).then(r => {result = r;}, e => {error = e;});
    for (let n=0; n<100 && !result && !error; n++) {
      await new Promise(resolve => setImmediate(resolve));
      if (result || error) break;
      const next = [...timers].sort((a,b) => a[1].at-b[1].at)[0];
      assert.ok(next, 'upstream discovery pending with no timer');
      timers.delete(next[0]); clock = Math.max(clock,next[1].at); next[1].fn();
    }
    if (error) throw error;
    assert.ok(result);
    // Settle page tasks past the locked program's three-second discovery window.
    // Count side effects after this point too, including any unintended deferred delivery.
    const quietUntil = clock + 3100;
    for (let n=0; n<100; n++) {
      await new Promise(resolve => setImmediate(resolve));
      const next = [...timers].sort((a,b) => a[1].at-b[1].at)[0];
      if (!next || next[1].at > quietUntil) break;
      timers.delete(next[0]); clock = Math.max(clock,next[1].at); next[1].fn();
    }
    assert.ok([...timers.values()].every(t => t.at > quietUntil), 'page work did not settle');
    clock = quietUntil;
    assert.throws(() => invoke('commit',{chunkIndex:1}),/COMMIT_REFUSED/);
    const observed = invoke('observe');
    assert.equal(observed.observation.state,result.observation.state);
    return result;
  }
  return {document,body,form,editor,entry,own,foreign,later,run,el:(tag,attrs) => new Element(tag,attrs),
    beforeSetterClock:fn => {beforeWrite = fn;},clicks:() => clicks,advance:ms => {clock += ms;}};
}
function counters(node) { return [node.writes.length,node.inputEvents,node.changeEvents]; }
function noInput(result) {
  assert.ok(result.observation.preInputRetirement);
  assert.equal(result.observation.preInputRetirement.inputCount,0);
  assert.equal(result.entryDiagnostics.setterEntered,false);
  assert.equal(result.entryDiagnostics.exceptionType,'none');
}
async function delivered(f) {
  const r = await f.run();
  assert.deepEqual(counters(f.own),[1,1,1]);
  assert.deepEqual(counters(f.foreign),[0,0,0]);
  assert.equal(r.observation.state,'inputTriggered'); // no START or completion fabricated
  const file = f.own.writes[0][0];
  assert.equal(crypto.createHash('sha256').update(Buffer.from(await file.arrayBuffer())).digest('hex'),b.sha256);
}
test('approved entry opens nothing; independent task invokes detached showPicker', async t => {
  const f = page(); let foreignInvocations = 0;
  f.later(() => {assert.equal(f.clicks(),1); foreignInvocations++; f.foreign.showPicker();},35);
  const r = await f.run();
  assert.equal(foreignInvocations,1);
  const [foreignSetterCalls, foreignInputCalls, foreignChangeCalls] = counters(f.foreign);
  t.diagnostic(JSON.stringify({entryClicks:f.clicks(),foreignInvocations,foreignSetterCalls,foreignInputCalls,foreignChangeCalls,state:r.observation.state}));
  assert.equal(foreignSetterCalls,0); assert.equal(foreignChangeCalls,0); assert.equal(foreignInputCalls,0);
  assert.equal(f.foreign.nativePickers,0); assert.deepEqual(counters(f.own),[0,0,0]); noInput(r);
});
test('direct file receiver owned by original form', async () => {
  const f = page(); f.form.append(f.own); await delivered(f); assert.equal(f.clicks(),0);
});
test('external direct field with explicit native form association', async () => {
  const f = page(); f.own.attrs.form = f.form.id; f.body.append(f.own); await delivered(f); assert.equal(f.clicks(),0);
});
test('IDREF alone cannot write a portalled field discovered on the direct path', async () => {
  const f = page(); f.foreign.attrs.id = 'page-field'; f.entry.attrs['aria-controls'] = 'page-field'; f.body.append(f.foreign);
  noInput(await f.run()); assert.deepEqual(counters(f.foreign),[0,0,0]);
});
test('detached picker synchronously invoked by the approved entry handler', async () => {
  const f = page(); f.entry.addEventListener('click', () => f.own.showPicker()); await delivered(f); assert.equal(f.clicks(),1);
});
test('repeated click and showPicker for the same authorized object deliver only once', async () => {
  const f = page(); f.entry.addEventListener('click', () => {f.own.click(); f.own.showPicker(); f.own.showPicker();}); await delivered(f);
});
for (const linked of [true,false]) test('menu action after entry activation, explicit popup link: '+linked, async () => {
  const f = page(); let menuClicks = 0;
  f.entry.addEventListener('click',() => {
    const menu = f.body.append(f.el('div',{role:'menu',id:'test-menu'}));
    f.entry.attrs['aria-expanded'] = 'true';
    if (linked) f.entry.attrs['aria-controls'] = menu.id;
    const item = menu.append(f.el('button',{type:'button',role:'menuitem','aria-label':'Upload from computer'}));
    item.addEventListener('click',() => {menuClicks++; f.own.showPicker();});
  });
  if (linked) { await delivered(f); assert.equal(menuClicks,1); }
  else { noInput(await f.run()); assert.equal(menuClicks,0); assert.deepEqual(counters(f.own),[0,0,0]); }
});
test('candidate moves between confirmation and the native setter', async () => {
  const f = page(); f.form.append(f.own); let moved = 0;
  f.beforeSetterClock(() => {moved++; f.body.append(f.own);});
  noInput(await f.run()); assert.equal(moved,1); assert.deepEqual(counters(f.own),[0,0,0]);
});
for (const [name, action] of Object.entries({
  'capture before deadline but candidate expires before confirmation':f => {f.own.showPicker(); f.advance(3001);},
  'captured connected node removed before confirmation':f => {f.form.append(f.own); f.own.showPicker(); f.own.remove();},
  'removing and reinserting the same candidate does not restore its proof':f => {
    f.form.append(f.own); f.own.showPicker(); f.own.remove(); f.form.append(f.own);
  },
  'captured candidate replaced, even with another owned input':f => {
    f.form.append(f.own); f.own.showPicker(); f.own.remove(); f.form.append(f.foreign); f.foreign.showPicker();
  },
  'microtask from approved click cannot authorize an orphan picker':f => queueMicrotask(() => f.foreign.showPicker()),
  'a separate nested event is not the approved event':f => {
    let calls = 0;
    f.body.addEventListener('click',e => { if (e.target === f.body) {calls++; f.foreign.showPicker();} });
    f.body.click(); assert.equal(calls,1);
  },
  'unlinked connected page input has no owner even on the opener stack':f => {
    f.body.append(f.foreign); f.foreign.showPicker();
  },
})) test(name, async () => {
  const f = page(); f.entry.addEventListener('click', () => action(f)); const r = await f.run();
  assert.equal(f.clicks(),1); assert.deepEqual(counters(f.foreign),[0,0,0]); assert.deepEqual(counters(f.own),[0,0,0]); noInput(r);
});
for (const [label, expected] of [['setter',[1,0,0]],['input',[1,1,0]]]) test('ownership lost during '+label+' stops remaining events and replay', async () => {
  const f = page(); f.form.append(f.own);
  const move = () => f.body.append(f.own);
  if (label === 'setter') f.own.onSetter = move; else f.own.addEventListener('input',move);
  const r = await f.run();
  assert.deepEqual(counters(f.own),expected); assert.deepEqual(counters(f.foreign),[0,0,0]);
  assert.equal(r.observation.state,'unknown'); assert.equal(r.observation.preInputRetirement,undefined);
  assert.equal(r.entryDiagnostics.cause,'deliveryUncertain');
});
