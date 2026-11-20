// Independent observers on intercepted draft pages owned by this run.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';

const fixtures = [
  {
    host: 'chatgpt.com', fresh: '/',
    editor: '<textarea id="prompt-textarea"></textarea>',
    account: '<button data-testid="profile-button">Account</button>',
    login: '<button data-testid="login-button">Log in</button>',
    turn: '<article data-message-author-role="user">Fixture turn</article>',
  },
  {
    host: 'claude.ai', fresh: '/new',
    editor: '<div class="ProseMirror" contenteditable="true"></div>',
    account: '<button data-testid="user-menu-button">Account</button>',
    login: '<a href="/login">Log in</a>',
    turn: '<article data-testid="user-message">Fixture turn</article>',
  },
  {
    host: 'gemini.google.com', fresh: '/app',
    editor: '<rich-textarea><div contenteditable="true"></div></rich-textarea>',
    account: '<a href="https://accounts.google.com/SignOutOptions">Account</a>',
    login: '<a href="https://accounts.google.com/ServiceLogin">Log in</a>',
    turn: '<user-query>Fixture turn</user-query>',
  },
  {
    host: 'chat.deepseek.com', fresh: '/',
    editor: '<textarea id="chat-input"></textarea>',
    account: '<button data-testid="user-menu">Account</button>',
    login: '<a href="/sign_in">Log in</a>',
    turn: '<article data-message-id="fixture">Fixture turn</article>',
  },
];
const scenarios = [
  'fresh', 'signed-out', 'foreign-picker', 'navigate', 'replace-input', 'multiple-dialogs', 'missing-editor',
  'existing-draft', 'history-present', 'tab-switch', 'delayed-preview', 'upload-canceled',
];

function monitor(scenario) {
  const counts = { setter: 0, input: 0, change: 0, foreignSetter: 0, send: 0, submit: 0, enter: 0, uploadCanceled: 0 };
  const form = document.querySelector('main form');
  const field = form.querySelector('input[type=file]');
  const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files');
  let preview;

  Object.defineProperty(HTMLInputElement.prototype, 'files', {
    ...descriptor,
    set(value) {
      counts[this === field ? 'setter' : 'foreignSetter']++;
      return descriptor.set.call(this, value);
    },
  });
  document.addEventListener('submit', event => {
    counts.submit++;
    event.preventDefault();
  }, true);
  document.addEventListener('click', event => {
    if (event.target.closest('button[type=submit]')) counts.send++;
  }, true);
  document.addEventListener('keydown', event => {
    if (event.key === 'Enter') counts.enter++;
  }, true);
  form.addEventListener('input', event => {
    if (event.target === field) counts.input++;
  });
  form.addEventListener('change', event => {
    if (event.target !== field) return;
    counts.change++;
    const file = field.files[0];
    if (scenario === 'upload-canceled') {
      // The fixture consumes the file but cancels its own pending upload before presenting any preview.
      counts.uploadCanceled++;
      return;
    }
    preview = (async () => {
      if (scenario === 'delayed-preview') await new Promise(resolve => setTimeout(resolve, 220));
      const tile = document.createElement('span');
      const image = document.createElement('img');
      tile.dataset.fileName = file.name;
      image.alt = file.name;
      image.src = URL.createObjectURL(file);
      tile.append(image);
      form.append(tile);
      await image.decode();
      const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
      return {
        hash: [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join(''),
        width: image.naturalWidth,
        height: image.naturalHeight,
        accessibleName: image.alt === file.name,
        visible: image.getClientRects().length > 0,
      };
    })();
  });
  globalThis.readQualified = async () => {
    if (!preview) return { counts, preview: null };
    const timeout = new Promise(resolve => setTimeout(() => resolve({ timedOut: true }), 1500));
    return { counts, preview: await Promise.race([preview, timeout]) };
  };
}

async function executeDriver({ exe, intentID, folder, browserID, host, pid, scenario, evalPage, restart }) {
  const proc = spawn(exe, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const closed = once(proc, 'exit');
  const timer = setTimeout(() => proc.kill('SIGKILL'), 12000);
  proc.stdin.on('error', () => {});
  proc.stdin.write(JSON.stringify({ intentID, folder, browserID, host, pid, restart }) + '\n');
  let result;
  let session;
  let tabID = '1';
  const actions = {};
  try {
    for await (const line of createInterface({ input: proc.stdout })) {
      const message = JSON.parse(line);
      if (message.session) {
        session = message.session;
        proc.stdin.write('ok\n');
        continue;
      }
      if (message.done) {
        result = message;
        continue;
      }
      const command = message.command;
      actions[command.action] = (actions[command.action] ?? 0) + 1;
      if (command.action === 'commit' && scenario === 'navigate') {
        await evalPage("history.pushState({}, '', '/wrong-fixture-page')");
      }
      if (command.action === 'commit' && scenario === 'replace-input') {
        await evalPage("(() => { const field = document.querySelector('main input[type=file]'); field.replaceWith(field.cloneNode(true)); })()");
      }
      if (command.action === 'commit' && scenario === 'tab-switch') tabID = '2';
      const native = { applicationID: browserID, sessionID: session, windowID: '1', tabID };
      let reply;
      try {
        const invocation = '(' + message.source + ')(' + JSON.stringify(command) + ',' + JSON.stringify(native) + ')';
        const value = await evalPage(invocation);
        reply = { result: typeof value === 'string' ? value : JSON.stringify(value) };
      } catch {
        reply = { refused: true };
      }
      proc.stdin.write(JSON.stringify(reply) + '\n');
    }
    const [code] = await closed;
    assert.equal(code, 0);
    assert.ok(result);
    return { result, actions };
  } finally {
    clearTimeout(timer);
    if (proc.exitCode === null && proc.signalCode === null) proc.kill('SIGKILL');
    await closed;
  }
}

export async function runColdRestart({ exe, run, browser, chromePID, navigate, evalPage, restart }) {
  const { stage, intentID } = restart;
  assert.match(intentID, /^[0-9a-f-]{36}$/);
  assert.ok(['original', 'successor'].includes(stage));
  const { host, fresh, editor, account } = fixtures[0];
  const browserID = browser === 'edge' ? 'com.microsoft.edgemac' : 'com.google.Chrome';
  let source = run;
  if (stage === 'successor') {
    assert.match(restart.from, /^local-browser-[A-Za-z0-9]+$/);
    source = path.join(path.dirname(run), restart.from);
    assert.equal(fs.realpathSync(source), source);
    assert.equal(fs.lstatSync(path.join(source, 'user-data'), { throwIfNoEntry: false }), undefined);
    const prior = JSON.parse(fs.readFileSync(path.join(source, 'receipt.json'), 'utf8'));
    assert.equal(prior.intentID, intentID);
    assert.equal(prior.browser, browser);
    assert.equal(prior.status, 'PASS_FIXTURE');
  }
  const folder = path.join(source, 'cold-restart');
  if (stage === 'original') fs.mkdirSync(folder, { mode: 0o700 });
  else assert.equal(fs.realpathSync(folder), folder);
  await navigate('https://' + host + fresh, '<main>' + account + '<form>' + editor +
    '<input type="file" accept="image/*"><button type="submit">Send</button></form></main>');
  await evalPage('(' + monitor.toString() + ')("fresh")');
  const record = { stage, intentID, browser, browserID, status: 'UNKNOWN', before: await evalPage('readQualified()') };
  try {
    const { result, actions } = await executeDriver({ exe, intentID, folder, browserID, host, pid: chromePID, evalPage, restart: stage });
    record.driver = result;
    record.pageCommands = actions;
    assert.deepEqual(actions, { pinTarget: 1, captureTarget: 1, validate: stage === 'original' ? 1 : 2 });
    assert.equal(result.intentID.toLowerCase(), intentID);
    record.status = 'PASS_FIXTURE';
  } catch (error) {
    record.status = 'FAIL_FIXTURE';
    record.issue = String(error.message).slice(0, 160);
  }
  record.after = await evalPage('readQualified()');
  for (const evidence of [record.before, record.after]) {
    if (evidence.preview !== null || Object.values(evidence.counts).some(count => count !== 0)) {
      record.status = 'FAIL_FIXTURE';
      record.issue = 'The independent document listener observed input or sending';
    }
  }
  return record;
}

function assertObserved(row, sha) {
  assert.equal(row.ordinaryWriterRefused, true);
  for (const key of ['send', 'submit', 'enter', 'foreignSetter']) assert.equal(row.counts[key], 0, key);
  const rendered = row.scenario === 'fresh' || row.scenario === 'delayed-preview';
  const canceled = row.scenario === 'upload-canceled';
  const received = rendered || canceled;
  for (const key of ['setter', 'input', 'change']) assert.equal(row.counts[key], Number(received), key);
  assert.equal(row.counts.uploadCanceled, Number(canceled));
  assert.equal(row.sourceSHA256, sha);
  if (received) {
    assert.equal(row.targetPinned, true);
    assert.equal(row.duplicateRefused, true);
    assert.equal(row.nonSyntheticRefused, true);
    assert.equal(row.exactReceipt, true);
    assert.equal(row.actions.commit, 1);
    if (rendered) {
      assert.equal(row.reportedOutcome, 'uploadStarted');
      assert.deepEqual(row.preview, { hash: sha, width: 2, height: 2, accessibleName: true, visible: true });
    } else {
      assert.ok(['inputTriggered', 'unknown'].includes(row.reportedOutcome), row.reportedOutcome);
      assert.equal(row.preview, null);
    }
  } else {
    assert.equal(row.adapterRefused, true);
    assert.equal(row.preview, null);
    if (!['navigate', 'replace-input', 'tab-switch'].includes(row.scenario)) assert.equal(row.actions.begin, undefined);
  }
}

export async function runQualifiedCases({ exe, run, browser, chromePID, navigate, evalPage, sha }) {
  const browserID = browser === 'edge' ? 'com.microsoft.edgemac' : 'com.google.Chrome';
  const rows = [];
  for (const { host, fresh, editor, account, login, turn } of fixtures) {
    for (const scenario of scenarios) {
      const folder = path.join(run, 'scoped-' + host + '-' + scenario);
      fs.mkdirSync(folder, { mode: 0o700 });
      const intentID = randomUUID();
      const started = performance.now();
      const url = 'https://' + host + fresh;
      const row = {
        intentID, host, scenario, browser, browserID, selectedURL: url, result: 'UNKNOWN', counts: null, preview: null,
        monotonicStartNanoseconds: process.hrtime.bigint().toString(),
      };
      try {
        const field = '<input type="file" accept="image/*">';
        const owned = scenario !== 'foreign-picker';
        const dialogs = '<div role="dialog">First fixture panel</div><div role="dialog">Second fixture panel</div>';
        const html = '<main>' + (scenario === 'signed-out' ? login : account) +
          (scenario === 'history-present' ? turn : '') + (scenario === 'multiple-dialogs' ? dialogs : '') +
          '<form>' + (scenario === 'missing-editor' ? '' : editor) +
          (owned ? field : '') + '<button type="submit" aria-label="Send">Send</button></form></main>' +
          (owned ? '' : '<aside>' + field + '</aside>');
        await navigate(url, html);
        if (scenario === 'existing-draft') {
          await evalPage("(() => { const editor = document.querySelector('form textarea, form [contenteditable]'); if (editor.isContentEditable) editor.textContent = 'Fixture draft'; else editor.value = 'Fixture draft'; })()");
        }
        await evalPage('(' + monitor.toString() + ')(' + JSON.stringify(scenario) + ')');
        const { result, actions } = await executeDriver({ exe, intentID, folder, browserID, host, pid: chromePID, scenario, evalPage });
        const observed = await evalPage('readQualified()');
        Object.assign(row, {
          actions, processSession: result.processSession, syntheticWindowID: '1', syntheticTabID: '1',
          targetPinned: result.targetPinned ?? false, adapterID: result.adapterID, operationID: result.operationID ?? null,
          documentID: result.documentID ?? null, composerID: result.composerID ?? null,
          draftGeneration: result.draftGeneration ?? null, clickBindingID: result.clickBindingID ?? null,
          assetID: result.assetID, sourceOrigin: 'synthetic', sourceByteCount: result.sourceByteCount,
          sourceSHA256: result.sha256, reportedOutcome: result.receipt ?? null,
          adapterRefused: result.refused ?? false, reportedError: result.errorType ?? null,
          exactReceipt: result.receiptMatches ?? null, duplicateRefused: result.duplicateRefused ?? null,
          nonSyntheticRefused: result.nonSyntheticRefused ?? null, ordinaryWriterRefused: result.ordinaryWriterRefused ?? null,
          ...observed,
        });
        assert.equal(result.intentID.toLowerCase(), intentID);
        assertObserved(row, sha);
        row.result = 'PASS_FIXTURE';
      } catch (error) {
        row.result = error.code === 'ERR_ASSERTION' ? 'FAIL_FIXTURE' : 'UNKNOWN';
        row.reason = String(error.message).slice(0, 300);
      }
      row.elapsedMilliseconds = Math.round(performance.now() - started);
      row.monotonicEndNanoseconds = process.hrtime.bigint().toString();
      fs.writeFileSync(path.join(folder, 'qualification.json'), JSON.stringify(row, null, 2), { flag: 'wx', mode: 0o600 });
      rows.push(row);
    }
  }
  return {
    scope: 'Synthetic media. The real Riftlet Swift adapter and page program share an isolated headless pipe with fixture window and tab IDs.',
    browser, liveAuth: null, liveAttemptCount: 0, rows,
  };
}
