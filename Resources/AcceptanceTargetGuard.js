// Shared receiver/side-effect guard for the locked Riftlet page program.
function nearpaneBoundDraft(b, command, native, handoff, parts, deadline, conflicts) {
  const reject = () => { throw Error('TARGET_INVALID'); };
  const surface = 'form,[data-testid="composer"],[data-composer-placement]';
  const product = b?.mode === 'product';
  const currentKey = 'data-nearpane-selected-image-v1';
  const productKey = product ? 'data-nearpane-image-' + b.nonce : '';
  function visibleModal() {
    return [...document.querySelectorAll('dialog[open],[aria-modal="true"],[role="dialog"],[role="alertdialog"]')]
      .some(node => !node.closest('[hidden],[inert],[aria-hidden="true"]') && node.getClientRects().length &&
        getComputedStyle(node).visibility !== 'hidden');
  }
  function foreignEditingFocus(editor) {
    const active = document.activeElement;
    if (!active || active === editor || editor.contains(active)) return false;
    return active.tagName === 'IFRAME' || !!active.shadowRoot || active.isContentEditable ||
      active.matches('textarea,[role="textbox"],[role="searchbox"],input:not([type]),input[type="text" i],input[type="search" i],input[type="email" i],input[type="password" i]');
  }
  function productEditor() {
    if (globalThis.top !== globalThis || location.origin !== 'https://chatgpt.com' ||
        !/^\/(?:c\/[A-Za-z0-9-]+\/?)?$/.test(location.pathname) ||
        document.visibilityState !== 'visible' || !document.hasFocus()) reject();
    const editors = document.querySelectorAll('[id="prompt-textarea"]');
    if (editors.length !== 1) reject();
    const editor = editors[0], form = editor.closest(surface);
    if (!(editor.isContentEditable || editor.tagName === 'TEXTAREA') || editor.disabled || editor.readOnly ||
        !editor.getClientRects().length || editor.closest('aside,nav,header,article,[role="dialog"],[role="search"],[data-message-author-role],[inert],[aria-hidden="true"]') ||
        !form || form === document.body || form === document.documentElement) reject();
    if (visibleModal() || foreignEditingFocus(editor)) reject();
    // A still-mounted editing host can sit underneath a sheet without ARIA.
    const rect = editor.getBoundingClientRect();
    const x = (Math.max(0, rect.left) + Math.min(innerWidth, rect.right)) / 2;
    const y = (Math.max(0, rect.top) + Math.min(innerHeight, rect.bottom)) / 2;
    if (!editor.contains(document.elementFromPoint(x,y))) reject();
    return {editor, form};
  }
  function productChallenge() {
    return ['nearpane-product',b.nonce,b.process,b.window,b.tab,b.assetID,b.sha256,b.boundAt,b.expiresAt].join('|');
  }
  if (product && command.action === 'armProductDraft') {
    const {editor,form} = productEditor(), root = document.documentElement, href = location.href;
    const navigation = globalThis.navigation, key = navigation?.currentEntry?.key;
    if (!key || Date.now()/1000 > b.expiresAt) reject();
    const scope = new AbortController(), options = {signal:scope.signal}, eventType = productChallenge();
    const attr = JSON.stringify({...b,timeOrigin:performance.timeOrigin});
    let observer, timeout;
    const retire = () => {
      scope.abort(); observer?.disconnect(); clearTimeout(timeout);
      if (root.getAttribute(productKey) === attr) root.removeAttribute(productKey);
      if (root.getAttribute(currentKey) === b.nonce) root.removeAttribute(currentKey);
    };
    const removed = records => records.some(record => [...record.removedNodes].some(node =>
      node === root || node.contains(editor) || node.contains(form)));
    observer = new MutationObserver(records => { if (removed(records)) retire(); });
    observer.observe(document,{subtree:true,childList:true});
    document.addEventListener('focusin', () => { if (foreignEditingFocus(editor)) retire(); },{capture:true,...options});
    document.addEventListener('visibilitychange', () => { if (document.hidden) retire(); },options);
    for (const event of ['pagehide','popstate','blur','hashchange']) window.addEventListener(event,retire,options);
    navigation.addEventListener('currententrychange',retire,options);
    editor.addEventListener(eventType,event => {
      if (removed(observer.takeRecords())) { retire(); return; }
      if (Date.now()/1000 <= b.expiresAt && document.documentElement === root && root.getAttribute(productKey) === attr &&
          event.target === editor && editor.isConnected && editor.closest(surface) === form &&
          form.isConnected && navigation.currentEntry?.key === key && location.href === href) event.preventDefault();
    },options);
    root.setAttribute(productKey,attr);
    root.setAttribute(currentKey,b.nonce);
    timeout = setTimeout(retire,Math.max(0,b.expiresAt*1000-Date.now()));
    return JSON.stringify({timeOrigin:performance.timeOrigin});
  }
  function checkDraft() {
    if (product) {
      const {editor,form} = productEditor();
      if (Date.now()/1000 > b.expiresAt || performance.timeOrigin !== b.timeOrigin ||
          native.applicationID !== 'com.google.Chrome' || native.sessionID !== b.process ||
          native.windowID !== b.window || native.tabID !== b.tab ||
          (command.target && command.target.clickBindingID !== b.nonce.toUpperCase()) ||
          (command.identity && (command.identity.assetID.toLowerCase() !== b.assetID ||
            command.identity.assetSHA256 !== b.sha256 || !Number.isSafeInteger(command.identity.attempt) || command.identity.attempt < 1)) ||
          (parts && (parts.editor !== editor || parts.form !== form)) ||
          (handoff && (!parts || !command.identity || command.action !== 'commit')) ||
          editor.dispatchEvent(new Event(productChallenge(), {cancelable:true}))) reject();
      return;
    }
    if (Date.now() / 1000 > b.expiresAt || location.href !== b.url ||
        performance.timeOrigin !== b.timeOrigin || document.visibilityState !== 'visible' ||
        !document.hasFocus() || native.applicationID !== 'com.google.Chrome' ||
        native.sessionID !== b.process || native.windowID !== b.window || native.tabID !== b.tab) reject();
    const editors = [...document.querySelectorAll('[contenteditable="true"],textarea')]
      .filter(e => e.getClientRects().length && (e.value || e.innerText || '').trim() === 'NEARPANE-TEST-' + b.session);
    const challenge = ['nearpane-test',b.session,b.nonce,b.process,b.window,b.tab,b.assetID,b.sha256,b.boundAt,b.expiresAt].join('|');
    if (editors.length !== 1 || (parts && (parts.editor !== editors[0] || parts.form !== editors[0].closest(surface))) ||
        editors[0].dispatchEvent(new Event(challenge, {cancelable:true, bubbles:false}))) reject();
    if (command.identity && (command.identity.assetID.toLowerCase() !== b.assetID ||
        command.identity.assetSHA256 !== b.sha256 || command.identity.attempt !== 1)) reject();
    if (handoff && (!parts || !command.identity || command.action !== 'commit')) reject();
  }
  checkDraft();
  if (!handoff) return;

  // This capability lives in one commit's closure. It cannot be read from the document registry or reused by observe.
  const {editor, form} = parts, removed = new WeakSet();
  let observer, entry, entryDispatched = false, activeEvent, action, popup, candidate, denied = false;
  const deny = () => { denied = true; return false; };
  function noteRemovals(records) {
    for (const record of records) for (const node of record.removedNodes) {
      removed.add(node);
      // A detached and reinserted subtree must not resurrect its input or its opener.
      if ([form,editor,entry,popup,action,candidate?.input].some(el => el && node.contains(el))) deny();
    }
  }
  function current() {
    try { checkDraft(); } catch { return deny(); }
    noteRemovals(observer.takeRecords());
    if (form === document.body || form === document.documentElement ||
        [...form.querySelectorAll('[contenteditable="true"],textarea')].some(el => el !== editor &&
          el.getClientRects().length && el.closest(surface) === form && !el.contains(editor) && !editor.contains(el))) return deny();
    return !denied && !removed.has(editor) && !removed.has(form) && (!deadline() || Date.now() < deadline());
  }
  const here = el => el?.ownerDocument === document && el.isConnected && !removed.has(el);
  const sameForm = el => (!el.hasAttribute('form') && !el.form) || (!!el.form && el.form === editor.closest('form'));
  function compatible(el) {
    const owner = el.closest(surface);
    return sameForm(el) && (!owner || owner === form || owner === editor.closest('form'));
  }
  function local(el) {
    if (!here(el) || !sameForm(el)) return false;
    return (form.contains(el) && el.closest(surface) === form) ||
      (form.tagName === 'FORM' && el.form === form && !el.closest(surface));
  }
  function roots(control, keys) {
    // IDREFs must resolve uniquely to actual nodes; proximity and the popup's name do not establish an owner.
    const ids = keys.flatMap(k => (control.getAttribute(k) || '').split(/\s+/)).filter(Boolean);
    return ids.flatMap(id => {
      const matches = [...document.querySelectorAll('[id]')].filter(n => n.id === id);
      return matches.length === 1 ? matches : [];
    });
  }
  function approved(control) {
    if (!entry || !local(entry) || !here(control) || !compatible(control)) return false;
    if (product && (control.type === 'submit' || control.type === 'reset' ||
        control.matches('[data-testid="send-button"],[data-testid="stop-button"]'))) return false;
    if (control === entry) return true;
    return entryDispatched && control === action && here(popup) && popup.contains(control) &&
      roots(entry,['aria-controls','aria-owns','popovertarget']).includes(popup);
  }
  function validInput(input) {
    return input?.ownerDocument === document && (!product || input.isConnected) && !removed.has(input) && input.type === 'file' &&
      !input.hasAttribute('capture') && compatible(input) && !conflicts(input, n => n === entry || n === action);
  }
  function pickerRelation(input, control) {
    if (!input.isConnected) return !input.parentNode && !input.form;
    return local(input) || control.control === input || roots(control,['for','aria-controls','aria-owns']).includes(input);
  }
  function matches(input) {
    if (!current() || !candidate || input !== candidate.input || !validInput(input) ||
        input.isConnected !== candidate.connected || input.parentNode !== candidate.parent ||
        input.form !== candidate.form) return false;
    return candidate.control ? approved(candidate.control) && pickerRelation(input,candidate.control) : local(input);
  }
  function pin(input, control) {
    candidate = {input, control, connected:input.isConnected, parent:input.parentNode, form:input.form};
  }
  return {
    monitor(work) {
      observer = new MutationObserver(noteRemovals);
      observer.observe(document.documentElement,{subtree:true,childList:true});
      try {
        const result = work();
        if (result && typeof result.then === 'function') return result.finally(() => observer.disconnect());
        observer.disconnect(); return result;
      } catch (error) { observer.disconnect(); throw error; }
    },
    bind(entries) {
      const owned = entries.filter(local);
      entry = owned.length === 1 ? owned[0] : null;
      return entry ? [entry] : [];
    },
    entries(available) { return entry && local(entry) && available.includes(entry) ? [entry] : []; },
    activate(control) {
      if (!current() || !entry || !local(entry) || !here(control)) return deny();
      if (control !== entry && !action) {
        const found = roots(entry,['aria-controls','aria-owns','popovertarget'])
          .filter(root => here(root) && root !== document.body && !root.contains(editor) && root.contains(control));
        if (found.length === 1) { action = control; popup = found[0]; }
      }
      return approved(control) || deny();
    },
    fire(control, callback) {
      if (!current() || !approved(control)) reject();
      // Only while the original dispatch is actually running a listener on the admitted control.
      // The timer, microtask, delegated ancestor and neighbouring event paths confer no authority.
      const track = e => {
        if (e.target === control) { activeEvent = e; if (control === entry) entryDispatched = true; }
      };
      const types = ['pointerdown','mousedown','pointerup','mouseup','click'];
      for (const type of types) document.addEventListener(type,track,true);
      try { return callback(control); }
      finally { activeEvent = null; for (const type of types) document.removeEventListener(type,track,true); }
    },
    capture(input) {
      const control = activeEvent?.target;
      if (!current() || !control || window.event !== activeEvent || activeEvent.currentTarget !== control || activeEvent.eventPhase !== Event.AT_TARGET ||
          !approved(control) || !validInput(input) || !pickerRelation(input,control)) return deny();
      if (!candidate) pin(input,control);
      return candidate.control === control && matches(input) || deny();
    },
    choose(input, invoked) {
      if (!current() || !validInput(input)) return deny();
      if (!candidate && !invoked && local(input)) pin(input,null);
      return matches(input) || deny();
    },
    ready: matches,
    require(input) { if (!matches(input)) reject(); },
    refuse: deny,
    get denied() { return denied; }
  };
}
