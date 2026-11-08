// Called only for a separately authorized, already-open test conversation. Read-only page observation.
function observeTestDraft(expectedURL, marker) {
  if (location.href !== expectedURL) return null;
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
  return {timeOrigin: performance.timeOrigin, ids, previews: previews.length,
    busy: [...composer.querySelectorAll('[role="progressbar"],progress,[aria-busy="true"],[role="alert"]')].some(visible)};
}
