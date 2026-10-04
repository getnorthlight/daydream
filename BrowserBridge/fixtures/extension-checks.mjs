import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { ChromeBridge } from '../extension/bridge.js';
import { inspectFocus } from '../extension/focus.js';

const extensionID='a'.repeat(32), documentID='11111111-1111-4111-8111-111111111111';
const event=()=>({listeners:[],addListener(fn){this.listeners.push(fn)},fire(...args){for(const f of this.listeners)f(...args)}});
const nonce=n=>n.toString(16).padStart(32,'0');
export function fixture() {
  let now=0, privateWindow=false, permission=true, secure=false, tabPrivate=false, active=true, frameCount=1;
  let url='https://example.test/article', doc=documentID, focus=null, scripts=0, tabReads=0, valueReads=0;
  const element=(tag='BUTTON',attrs={})=>({tagName:tag,shadowRoot:null,isContentEditable:false,
    getAttribute(name){return attrs[name]??null},hasAttribute(name){return name in attrs},
    get value(){valueReads++;throw Error('value must not be read')},get innerText(){valueReads++;throw Error('text must not be read')}});
  focus=element();let controls=[];const listeners={};
  const document={hasFocus:()=>active,visibilityState:'visible',get activeElement(){return focus},
    querySelectorAll:()=>controls,addEventListener:(name,fn)=>{listeners[name]=fn},
    get title(){valueReads++;throw Error('title must not be read')},get body(){valueReads++;throw Error('body must not be read')}};
  const world=vm.createContext({document,crypto:webcrypto});
  const messages=[],port={onMessage:event(),onDisconnect:event(),postMessage:m=>messages.push(m),disconnect(){this.onDisconnect.fire()}};
  const api={runtime:{id:extensionID,connectNative:()=>port},
    windows:{getLastFocused:async()=>({id:3,incognito:privateWindow,focused:active})},
    tabs:{query:async()=>{tabReads++;return[{id:9,windowId:3,active:true,incognito:tabPrivate,status:'complete',url}]}},
    permissions:{contains:async()=>permission},
    webNavigation:{getAllFrames:async()=>Array.from({length:frameCount},(_,i)=>({frameId:i,parentFrameId:i===0?-1:0,documentId:doc,documentLifecycle:'active',url,errorOccurred:false}))},
    scripting:{executeScript:async({world:kind,target,func})=>{
      scripts++;assert.equal(kind,'ISOLATED');assert.deepEqual(target.documentIds,[doc]);
      return[{frameId:0,documentId:doc,result:vm.runInContext('('+func.toString()+')()',world)}];
    }}};
  const bridge=new ChromeBridge(api,()=>now);bridge.connect();
  const request=n=>({version:1,kind:'probe',nonce:nonce(n),policyRevision:1,allowedOrigins:['https://example.test'],textEnabled:false});
  const probe=async(n=1)=>{now+=200;await bridge.probe(request(n));return messages.at(-1)};
  return {api,bridge,port,messages,probe,request,document,element,listeners,
    set:(changes)=>{if('mode'in changes)privateWindow=changes.mode;if('permission'in changes)permission=changes.permission;
      if('tabPrivate'in changes)tabPrivate=changes.tabPrivate;if('active'in changes)active=changes.active;
      if('url'in changes)url=changes.url;if('doc'in changes)doc=changes.doc;if('frames'in changes)frameCount=changes.frames;
      if('focus'in changes)focus=changes.focus;if('controls'in changes)controls=changes.controls;},
    counts:()=>({scripts,tabReads,valueReads}),advance:n=>{now+=n},world};
}
test('normal Chrome proof: stable window/tab/document/focus; origin only; zero text reads',async()=>{
  const f=fixture(),r=await f.probe();assert.equal(r.kind,'observation');assert.equal(r.windowMode,'normal');
  assert.equal(r.tabMode,'normal');assert.equal(r.frameID,0);assert.equal(r.documentID,documentID);
  assert.equal(r.origin,'https://example.test');assert.equal(r.role,'button');assert.equal(r.textEnabled,false);
  assert.equal('text'in r,false);assert.equal('url'in r,false);assert.equal('title'in r,false);assert.equal(f.counts().valueReads,0);
});
test('private/unknown window denies before tab metadata; mixed normal-window/private-tab denies before DOM',async()=>{
  for(const mode of [true,undefined,null]){const f=fixture();f.set({mode});assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().tabReads,0);}
  const f=fixture();f.set({tabPrivate:true});assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().scripts,0);
});
test('password, OTP, card, username/login, unknown input: no candidate getters',async()=>{
  for(const attrs of [{type:'password'},{autocomplete:'one-time-code'},{autocomplete:'cc-number'},{autocomplete:'current-password'},{autocomplete:'username'},{}]){
    const f=fixture(),node=f.element('INPUT',attrs);f.set({focus:node,controls:[node]});
    assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().valueReads,0);
  }
  const f=fixture();f.set({controls:[f.element('INPUT',{type:'password'})]});assert.equal((await f.probe()).kind,'unavailable');
});
test('unknown, editable, open/closed shadow, iframe, missing document deny',async()=>{
  for(const tag of ['BODY','DIV','CUSTOM-EDITOR','TEXTAREA','IFRAME']){const f=fixture();f.set({focus:f.element(tag)});assert.equal((await f.probe()).kind,'unavailable');}
  const a=fixture(),node=a.element();node.shadowRoot={};a.set({focus:node});assert.equal((await a.probe()).kind,'unavailable');
  for(const frames of [0,2]){const f=fixture();f.set({frames});assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().scripts,0);}
  const f=fixture();f.set({doc:''});assert.equal((await f.probe()).kind,'unavailable');
});
test('queries/fragments/credentials/high-risk routes/ungranted origins never reach DOM',async()=>{
  for(const url of ['https://example.test/?q=private','https://example.test/#secret','https://user:secret@example.test/','https://example.test/login','https://example.test/%70ayment','https://other.test/','file:///private','chrome://settings']){
    const f=fixture();f.set({url});assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().scripts,0);
    assert.equal(JSON.stringify(f.messages).includes('private'),false);
  }
});
test('no permission, inactive browser, native receiver missing, forged extension id',async()=>{
  for(const change of [{permission:false},{active:false}]){const f=fixture();f.set(change);assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().scripts,0);}
  const f=fixture();f.bridge.disconnect();f.api.runtime.connectNative=()=>{throw Error('missing host')};f.bridge.connect();assert.equal(f.bridge.status,'native_unavailable');
  f.api.runtime.id='page-script';f.bridge.connect();assert.equal(f.bridge.status,'invalid_extension');
});
test('navigation, redirect and focus races invalidate; focus away/back cannot reuse sample',async()=>{
  for(const change of ['navigation','url','focus','focusBack']){
    const f=fixture(),original=f.api.scripting.executeScript;let calls=0;
    f.api.scripting.executeScript=async arg=>{const r=await original(arg);if(++calls===1){
      if(change==='navigation')f.bridge.invalidate();if(change==='url')f.set({url:'https://example.test/redirected'});
      if(change==='focus')f.set({focus:f.element('A',{href:'/safe'})});
      if(change==='focusBack'){f.listeners.focusout();f.listeners.focusin();}
    }return r};
    assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.counts().valueReads,0);
  }
});
test('spoofed scripting result document, replay, unbounded and text-enabled requests denied',async()=>{
  const f=fixture();f.api.scripting.executeScript=async()=>[{frameId:1,documentId:'wrong',result:{safety:'noneditable',role:'button'}}];assert.equal((await f.probe()).kind,'unavailable');
  const a=fixture();await a.probe(1);a.advance(200);await a.bridge.probe(a.request(1));assert.equal(a.bridge.status,'invalid_native_policy');
  for(const mutation of [{textEnabled:true},{allowedOrigins:Array(33).fill('https://example.test')},{nonce:'forged'}]){
    const b=fixture();b.advance(200);await b.bridge.probe({...b.request(1),...mutation});assert.equal(b.bridge.status,'invalid_native_policy');assert.equal(b.counts().scripts,0);
  }
});
test('disconnect/reconnect discard in-flight result, new worker has no grant',async()=>{
  const f=fixture();let finish;f.api.windows.getLastFocused=()=>new Promise(resolve=>{finish=resolve});
  const p=f.probe();f.bridge.disconnect();finish({id:3,incognito:false,focused:true});await p;
  assert.equal(f.messages.filter(x=>x.kind==='observation').length,0);f.bridge.connect();assert.equal(f.bridge.status,'awaiting_native_policy');
  const b=new ChromeBridge(f.api);assert.equal(b.port,null);assert.equal(b.status,'disconnected');
});
test('hung API emits bounded failure and releases busy; stale sampling rejected',async()=>{
  const f=fixture();f.api.windows.getLastFocused=()=>new Promise(()=>{});
  assert.equal((await f.probe()).kind,'unavailable');assert.equal(f.bridge.busy,false);
  const a=fixture(),original=a.api.scripting.executeScript;
  a.api.scripting.executeScript=async arg=>{a.advance(600);return original(arg)};assert.equal((await a.probe()).kind,'unavailable');
});
test('manifest/background offer no page ingress, keylogger or automatic grants/connect',()=>{
  const manifest=JSON.parse(readFileSync(new URL('../extension/manifest.json',import.meta.url)));
  assert.equal(manifest.incognito,'not_allowed');assert.equal(manifest.content_scripts,undefined);
  assert.equal(manifest.externally_connectable,undefined);assert.equal(manifest.host_permissions,undefined);
  const source=['background.js','bridge.js','focus.js'].map(file=>readFileSync(new URL('../extension/'+file,import.meta.url),'utf8')).join('\n');
  assert.ok(!/onMessageExternal|runtime\.onMessage|permissions\.request|window\.addEventListener|\b(?:active|field|document)\.value\b|\.innerText\b|\.textContent\b|\.title\b/.test(source));
  assert.ok(!/addEventListener\(['"](?:keydown|keyup|keypress|input|beforeinput|submit|message)/.test(source));
  const host=JSON.parse(readFileSync(new URL('../native-host.template.json',import.meta.url)));assert.deepEqual(host.allowed_origins,[]);
});
