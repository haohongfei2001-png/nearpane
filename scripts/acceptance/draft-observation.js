// Only browser-before arms a document-local listener in the explicitly authorized disposable editor.
function observeTestDraft(expectedURL, marker, nonce, arm) {
  if (location.href !== expectedURL || document.visibilityState !== 'visible' || !document.hasFocus()) return null;
  const editors = [...document.querySelectorAll('[contenteditable="true"],textarea')]
    .filter(e => e.getClientRects().length && (e.value || e.innerText || '').trim() === marker);
  if (editors.length !== 1) return null;
  const composer = editors[0].closest('form,[data-testid="composer"],[data-composer-placement]');
  if (!composer) return null;
  const turns = [...document.querySelectorAll('[data-message-author-role="user"]')];
  const ids = turns.map(node => (node.closest('[data-message-id]') || node.querySelector('[data-message-id]'))?.getAttribute('data-message-id'));
  if (!ids.length || ids.some(id => !id) || new Set(ids).size !== ids.length) return null;
  const visible = e => e.getClientRects().length > 0;
  const previews = [...composer.querySelectorAll('[data-file-name], img[src^="blob:"], img[src^="data:image/"]')]
    .filter(visible)
    .filter(e => !e.parentElement.closest('[data-file-name]'));
  const editor = editors[0], eventType = 'nearpane-test-' + nonce;
  if (arm) {
    if (previews.length || !/^[a-f0-9-]{36}$/.test(nonce)) return null;
    const root = document.documentElement, entry = globalThis.navigation?.currentEntry?.key;
    let live = true;
    const invalidate = () => { live = false; };
    document.addEventListener('visibilitychange', () => { if (document.hidden) invalidate(); });
    for (const type of ['pagehide','popstate','blur']) window.addEventListener(type, invalidate);
    globalThis.navigation?.addEventListener('currententrychange', invalidate);
    editor.addEventListener(eventType, event => {
      if (live && document.documentElement === root && editor.isConnected && composer.isConnected &&
          composer === editor.closest('form,[data-testid="composer"],[data-composer-placement]') &&
          location.href === expectedURL && entry === globalThis.navigation?.currentEntry?.key &&
          (editor.value || editor.innerText || '').trim() === marker) event.preventDefault();
    });
  }
  if (editor.dispatchEvent(new Event(eventType, {cancelable:true}))) return null;
  // Persist only the operation-generated upload basename. Unknown cards remain unproved.
  const previewNames = previews.map(node => {
    const names = [node, ...node.querySelectorAll('[data-file-name],img[alt],[title]')]
      .flatMap(n => ['data-file-name','alt','title','aria-label'].map(k => n.getAttribute(k)))
      .filter(x => typeof x === 'string' && /^riftlet-[0-9a-f-]{36}\.(png|jpg)$/i.test(x));
    const unique = [...new Set(names.map(x => x.toLowerCase()))];
    return unique.length === 1 ? unique[0] : null;
  });
  return {previewNames, timeOrigin: performance.timeOrigin, ids, previews: previews.length,
    busy: [...composer.querySelectorAll('[role="progressbar"],progress,[aria-busy="true"],[role="alert"]')].some(visible)};
}
