// Installed only in the explicit acceptance composition of the locked Riftlet page program.
function nearpaneBoundDraft(b, command, native, handoff, parts, deadline, conflicts) {
  const reject = () => { throw Error('TARGET_INVALID'); };
  const surface = 'form,[data-testid="composer"],[data-composer-placement]';
  function checkDraft() {
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
    if (control === entry) return true;
    return entryDispatched && control === action && here(popup) && popup.contains(control) &&
      roots(entry,['aria-controls','aria-owns','popovertarget']).includes(popup);
  }
  function validInput(input) {
    return input?.ownerDocument === document && !removed.has(input) && input.type === 'file' &&
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
