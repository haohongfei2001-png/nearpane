// Installed only in the explicit acceptance composition of the locked Riftlet page program.
function nearpaneBoundDraft(b, command, native, handoff) {
  const reject = () => { throw Error('TARGET_INVALID'); };
  if (Date.now() / 1000 > b.expiresAt || location.href !== b.url ||
      performance.timeOrigin !== b.timeOrigin || document.visibilityState !== 'visible' ||
      !document.hasFocus() || native.applicationID !== 'com.google.Chrome' ||
      native.sessionID !== b.process || native.windowID !== b.window || native.tabID !== b.tab) reject();
  const editors = [...document.querySelectorAll('[contenteditable="true"],textarea')]
    .filter(e => e.getClientRects().length && (e.value || e.innerText || '').trim() === 'NEARPANE-TEST-' + b.session);
  // Only the original editor has the listener installed at browser-before. A cloned node,
  // a replacement form, a hidden tab or a new Document cannot answer this challenge.
  if (editors.length !== 1 || editors[0].dispatchEvent(new Event('nearpane-test-' + b.nonce,
      {cancelable: true, bubbles: false}))) reject();
  if (command.identity && (command.identity.assetID.toLowerCase() !== b.assetID ||
      command.identity.assetSHA256 !== b.sha256 || command.identity.attempt !== 1)) reject();
  if (handoff && (!command.identity || command.action !== 'commit')) reject();
}
