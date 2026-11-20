// Isolated documents served by Fetch.fulfillRequest. No real account or remote service.
import assert from 'node:assert/strict';

const fixtures = [
  {host:'chatgpt.com', blank:'/', editor:'<textarea id="prompt-textarea"></textarea>',
    account:'<button data-testid="profile-button">Account</button>', login:'<button data-testid="login-button">Log in</button>',
    turn:'<article data-message-author-role="user">Fixture</article>'},
  {host:'claude.ai', blank:'/new', editor:'<div class="ProseMirror" contenteditable="true"></div>',
    account:'<button data-testid="user-menu-button">Account</button>', login:'<a href="/login">Log in</a>',
    turn:'<article data-testid="user-message">Fixture</article>'},
  {host:'gemini.google.com', blank:'/app', editor:'<rich-textarea><div contenteditable="true"></div></rich-textarea>',
    account:'<a href="https://accounts.google.com/SignOutOptions">Account</a>',
    login:'<a href="https://accounts.google.com/ServiceLogin">Log in</a>', turn:'<user-query>Fixture</user-query>'},
  {host:'chat.deepseek.com', blank:'/', editor:'<textarea id="chat-input"></textarea>',
    account:'<button data-testid="user-menu">Account</button>', login:'<a href="/sign_in">Log in</a>',
    turn:'<article data-message-id="fixture">Fixture</article>'}
];

export async function runCapabilityCases({guard, navigate, evalPage}) {
  const cases=[];
  for (const profile of fixtures) {
    for (const state of ['fresh','signedOut','existing','ambiguous']) {
      const controls = state==='signedOut' ? profile.login : profile.account+(state==='ambiguous'?profile.login:'');
      const form = '<form>'+profile.editor+'<input type="file" accept="image/*"><button type="submit">Send</button></form>';
      const html = '<main>'+controls+(state==='existing'?profile.turn:'')+(state==='signedOut'?'':form)+'</main>';
      await navigate('https://'+profile.host+profile.blank,html);
      await evalPage(`(() => {
        globalThis.events={change:0,click:0,submit:0,input:0};
        for (const type of Object.keys(events)) document.addEventListener(type,e=>{events[type]++;e.preventDefault()},true);
        globalThis.before=document.documentElement.outerHTML;
      })()`);
      const probe = host => '('+guard+')(null,'+JSON.stringify({action:'inspectCapabilities',host})+')';
      const found=JSON.parse(await evalPage(probe(profile.host)));
      assert.equal(found.service,profile.host);
      assert.equal(found.authenticated,state==='ambiguous'?null:state!=='signedOut');
      assert.equal(found.blankEditorAtFreshRoute,state==='signedOut'?null:state!=='existing');
      assert.equal(found.uniqueEditor,state!=='signedOut');
      assert.equal(found.ownedFileControl,state==='signedOut'?null:true);
      for(const key of ['pickerAccepted','attachmentRendered','uploadComplete','sendEvents']) assert.equal(found[key],null);
      await assert.rejects(evalPage(probe(profile.host==='claude.ai'?'chatgpt.com':'claude.ai')));
      const independent=await evalPage('({events,unchanged:before===document.documentElement.outerHTML})');
      assert.deepEqual(independent,{events:{change:0,click:0,submit:0,input:0},unchanged:true});
      cases.push({service:profile.host,state,observed:found,independent});
    }
  }
  return {scope:'Synthetic origin-specific read-only DOM capabilities. No live browser authorization or upload.',cases};
}
