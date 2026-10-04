import assert from 'node:assert/strict';
import { test } from 'node:test';
import { webcrypto } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fixture } from './extension-checks.mjs';
import { AuthenticatedChromeBridge, signedBytes } from '../extension/authenticated.js';
import { AuthenticatedSafariBridge } from '../extension/safari.js';
import { prepareRegistration } from '../extension/enrollment.js';

const crypto = webcrypto, extensionID = 'a'.repeat(32), sessionID = 'c'.repeat(32);
const keypair = () => crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
async function setup(browser='chrome') {
  const f=fixture();f.bridge.disconnect();f.messages.length=0;
  const event=()=>({listeners:new Set(),addListener(fn){this.listeners.add(fn)},removeListener(fn){this.listeners.delete(fn)},fire(){for(const fn of [...this.listeners])fn()}});
  for(const name of ['onBeforeNavigate','onCommitted','onHistoryStateUpdated','onReferenceFragmentUpdated','onErrorOccurred'])f.api.webNavigation[name]=event();
  for(const name of ['onActivated','onUpdated','onRemoved'])f.api.tabs[name]=event();
  for(const name of ['onFocusChanged','onRemoved'])f.api.windows[name]=event();
  f.api.permissions.onRemoved=event();
  const id=browser==='chrome'?extensionID:'com.daydream.browser.fixture';f.api.runtime.id=id;
  const extension=await keypair(), app=await keypair();
  const Adapter=browser==='safari'?AuthenticatedSafariBridge:AuthenticatedChromeBridge;
  const bridge=new Adapter(f.api,{extensionID:id,browser,extensionPrivateKey:extension.privateKey,appPublicKey:app.publicKey},()=>1000,crypto);
  bridge.connect();
  return {...f,secure:bridge,extension,app};
}
async function request(f,changes={},key=f.app.privateKey,payloadChanges={}) {
  const payload={version:1,kind:'probe',nonce:'d'.repeat(32),policyRevision:1,allowedOrigins:['https://example.test'],textEnabled:false,...payloadChanges};
  const frame={version:3,browser:f.secure.browser,extensionID:f.api.runtime.id,clientNonce:f.secure.clientNonce,sessionID,sequence:1,payload:Buffer.from(JSON.stringify(payload)).toString('base64'),...changes};
  frame.signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,signedBytes(frame,'app-to-extension'))).toString('base64');
  return frame;
}
test('signed request required before Chrome metadata; signed result contains browser identities only',async()=>{
  const f=await setup();assert.equal(f.counts().tabReads,0);
  await f.secure.receive(await request(f));const frame=f.messages.at(-1);
  assert.equal(frame.version,3);
  assert(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},f.extension.publicKey,Buffer.from(frame.signature,'base64'),signedBytes(frame,'extension-to-app')));
  const result=JSON.parse(Buffer.from(frame.payload,'base64'));
  assert.equal(result.kind,'observation');assert.equal(result.textEnabled,false);
  assert.equal(result.tabID,9);assert.equal(result.origin,'https://example.test');assert.equal(f.counts().valueReads,0);
  assert(!JSON.stringify(result).includes('nativeWindow'));
});
test('signed production diagnostic acknowledges without any browser context or DOM read',async()=>{
  for(const browser of ['chrome','safari']){
    const f=await setup(browser);f.set({mode:true});
    const payload={kind:'diagnostic',nonce:'11111111-1111-4111-8111-111111111111',deployment:'d'.repeat(64),issuedAt:1800000000};
    const q=await request(f,{payload:Buffer.from(JSON.stringify(payload)).toString('base64')});
    await f.secure.receive(q);
    const a=f.messages.at(-1),body=JSON.parse(Buffer.from(a.payload,'base64'));
    assert.equal(body.kind,'diagnostic_ack');assert.equal(body.contentRead,false);assert.equal(body.runtimeID,f.api.runtime.id);
    assert.equal(f.counts().tabReads,0);assert.equal(f.counts().scripts,0);assert.equal(f.counts().valueReads,0);
    await f.secure.receive(q);assert.equal(f.secure.port,null,'diagnostic replay denied');
  }
});
test('untrusted app, changed extension/client/session, unsigned, oversized, extra fields: zero acquisition',async()=>{
  for(const scenario of ['wrong-key','extension','client','unsigned','oversized','extra']) {
    const f=await setup();let r=await request(f);
    if(scenario==='wrong-key')r=await request(f,{},(await keypair()).privateKey);
    if(scenario==='extension')r=await request(f,{extensionID:'e'.repeat(32)});
    if(scenario==='client')r=await request(f,{clientNonce:'f'.repeat(32)});
    if(scenario==='unsigned')delete r.signature;
    if(scenario==='oversized')r.payload='A'.repeat(5000);
    if(scenario==='extra')r.text='forged';
    await f.secure.receive(r);assert.equal(f.counts().tabReads,0,scenario);assert.equal(f.counts().scripts,0,scenario);
    assert.equal(f.secure.port,null,scenario);
  }
});
test('private/mixed/unknown, sensitive, frames, no permission stay denied through signed path',async()=>{
  for(const changes of [{mode:true},{mode:undefined},{tabPrivate:true},{permission:false},{frames:2},{url:'https://example.test/login'}]) {
    const f=await setup();f.set(changes);await f.secure.receive(await request(f));
    const frame=f.messages.at(-1), result=JSON.parse(Buffer.from(frame.payload,'base64'));
    assert.equal(result.kind,'unavailable');assert.equal(f.counts().scripts,0);assert.equal(f.counts().valueReads,0);
  }
  for(const autocomplete of ['one-time-code','cc-number','username','current-password']) {
    const f=await setup(),node=f.element('INPUT',{autocomplete});f.set({focus:node,controls:[node]});
    await f.secure.receive(await request(f));assert.equal(JSON.parse(Buffer.from(f.messages.at(-1).payload,'base64')).kind,'unavailable');
    assert.equal(f.counts().valueReads,0);
  }
});
test('replay and restart nonce rejected; no trust or receiver never acquires',async()=>{
  const f=await setup(),r=await request(f);await f.secure.receive(r);const reads=f.counts().scripts;
  await f.secure.receive(r);assert.equal(f.counts().scripts,reads);assert.equal(f.secure.port,null);
  f.secure.connect();await f.secure.receive(r);assert.equal(f.counts().scripts,reads);assert.equal(f.secure.port,null);
  const noTrust=new AuthenticatedChromeBridge(f.api,null,()=>0,crypto);noTrust.connect();
  assert.equal(noTrust.status,'trusted_enrollment_missing');
  f.api.runtime.connectNative=()=>{throw Error('no receiver')};f.secure.connect();assert.equal(f.secure.status,'native_unavailable');
});
test('navigation/focus invalidation and disconnect during async collection produce no signed observation',async()=>{
  for(const action of ['invalidate','disconnect']) {
    const f=await setup();const original=f.api.scripting.executeScript;
    f.api.scripting.executeScript=async args=>{const result=await original(args);f.secure[action]();return result};
    await f.secure.receive(await request(f));
    assert.equal(f.messages.filter(m=>m.signature).length,0);assert.equal(f.counts().valueReads,0);
  }
});
test('browser lifecycle installed on connect, removed on disconnect, permission removal stops acquisition',async()=>{
  const f=await setup(),before=f.secure.collector.epoch;
  f.api.webNavigation.onCommitted.fire();assert.equal(f.secure.collector.epoch,before+1);
  f.api.windows.onFocusChanged.fire();assert.equal(f.secure.collector.epoch,before+2);
  f.api.permissions.onRemoved.fire();assert.equal(f.secure.port,null);
  assert.equal(f.api.webNavigation.onCommitted.listeners.size,0);
  await f.secure.receive(await request(f));assert.equal(f.counts().tabReads,0);
});
test('production entry cannot use unsigned collector or enroll from messages',()=>{
  const source=readFileSync(new URL('../extension/background.js',import.meta.url),'utf8');
  assert(source.includes('new AuthenticatedChromeBridge(chrome, null)'));
  assert(!source.includes('new ChromeBridge('));
  const implementation=readFileSync(new URL('../extension/authenticated.js',import.meta.url),'utf8');
  assert(!/runtime\.onMessage|onMessageExternal|permissions\.request|generateKey|fetch\(/.test(implementation));
});
test('Safari shares browser-issued document proof; missing document/private/background/key fields deny',async()=>{
  const safe=await setup('safari');await safe.secure.receive(await request(safe));
  assert.equal(JSON.parse(Buffer.from(safe.messages.at(-1).payload,'base64')).kind,'observation');
  for(const change of [{doc:''},{mode:true},{tabPrivate:true},{active:false},{frames:2}]) {
    const f=await setup('safari');f.set(change);await f.secure.receive(await request(f));
    assert.equal(JSON.parse(Buffer.from(f.messages.at(-1).payload,'base64')).kind,'unavailable');
    assert.equal(f.counts().scripts,0);assert.equal(f.counts().valueReads,0);
  }
  const wrong=await setup('safari');await wrong.secure.receive(await request(wrong,{browser:'chrome'}));
  assert.equal(wrong.counts().tabReads,0);
  for(const name of ['api_key','access-token','credential','password']) {
    const f=await setup('safari'),node=f.element('INPUT',{name});f.set({controls:[node]});
    await f.secure.receive(await request(f));assert.equal(JSON.parse(Buffer.from(f.messages.at(-1).payload,'base64')).kind,'unavailable');
    assert.equal(f.counts().valueReads,0);
  }
});
test('ordinary document focus is explicit BODY identity, never an arbitrary claimed role',async()=>{
  for(const browser of ['chrome','safari']) {
    const f=await setup(browser),body=f.element('BODY');Object.defineProperty(f.document,'body',{value:body});f.set({focus:body});
    await f.secure.receive(await request(f));const result=JSON.parse(Buffer.from(f.messages.at(-1).payload,'base64'));
    assert.equal(result.role,'document');assert.equal(result.safety,'noneditable');assert.equal(f.counts().valueReads,0);
  }
});
test('ordinary metadata needs signed mode and retains exclusions before DOM for both browsers',async()=>{
  for(const browser of ['chrome','safari'])for(const [url,denied] of [['https://ordinary.test/article',false],['https://excluded.test/article',true],['https://chase.com/',true],['https://ordinary.test/?api_key=dummy',true]]) {
    const f=await setup(browser);f.set({url});
    await f.secure.receive(await request(f,{},f.app.privateKey,{allowedOrigins:[],ordinaryMetadata:true,excludedDomains:['excluded.test']}));
    const e=JSON.parse(Buffer.from(f.messages.at(-1).payload,'base64'));
    assert.equal(e.kind,denied?'unavailable':'observation');if(denied)assert.equal(f.counts().scripts,0);
    else assert.equal(e.origin,'https://ordinary.test');assert.equal(f.counts().valueReads,0);
  }
});
test('Safari navigation race, disconnect, forgery and replay never produce reusable metadata',async()=>{
  for(const action of ['invalidate','disconnect']) {
    const f=await setup('safari'),read=f.api.scripting.executeScript;
    f.api.scripting.executeScript=async arg=>{const value=await read(arg);f.secure[action]();return value};
    await f.secure.receive(await request(f));assert.equal(f.messages.filter(m=>m.signature).length,0);
  }
  const forged=await setup('safari');await forged.secure.receive(await request(forged,{},(await keypair()).privateKey));assert.equal(forged.counts().tabReads,0);
  const replay=await setup('safari'),r=await request(replay);await replay.secure.receive(r);const reads=replay.counts().scripts;
  await replay.secure.receive(r);assert.equal(replay.counts().scripts,reads);assert.equal(replay.secure.port,null);
});
test('enrollment requires setup approval, reuses nonextractable key and binds app fingerprint',async()=>{
  for(const browser of ['chrome','safari']) {
    const records=new Map(),store={get:async id=>records.get(id),putIfAbsent:async(id,row)=>{if(!records.has(id))records.set(id,row);return records.get(id)}};
    const config={store,browser,extensionID:browser==='chrome'?extensionID:'com.daydream.browser.fixture',cryptoAPI:crypto};
    await assert.rejects(prepareRegistration({...config,approvedSetup:false}));assert.equal(records.size,0);
    const first=await prepareRegistration({...config,approvedSetup:true}),again=await prepareRegistration({...config,approvedSetup:true});
    assert.equal(first.fingerprint,again.fingerprint);assert.equal(records.size,1);
    const row=[...records.values()][0];await assert.rejects(crypto.subtle.exportKey('pkcs8',row.privateKey));
    const nonce='11111111-1111-4111-8111-111111111111',appFingerprint='a'.repeat(64);
    await assert.rejects(first.prove({nonce,appFingerprint,displayedAppFingerprint:'b'.repeat(64)}));
    const signature=await first.prove({nonce,appFingerprint,displayedAppFingerprint:appFingerprint});
    const text=`daydream-browser-enrollment-v1\n${browser}\n${config.extensionID}\n${nonce}\n${first.fingerprint}\n${appFingerprint}`;
    assert(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},row.publicKey,signature,new TextEncoder().encode(text)));
  }
});
for(const browser of ['chrome','safari'])test(`${browser} actual native frames: Swift signed request -> JS collection/signature -> Swift acceptance and replay deny`,async()=>{
  const binary=process.argv[2];assert(binary,'pass isolated BrowserMetadataChecks path');
  const f=await setup(browser),child=spawn(binary,['--synthetic-wire'],{stdio:['pipe','pipe','pipe']});
  const exited=new Promise(resolve=>child.on('exit',code=>resolve(code)));
  let buffer=Buffer.alloc(0),error='',waiting=[];const frames=[];
  let failed;
  const fail=e=>{failed=e;for(const waiter of waiting.splice(0))waiter.reject(e)};
  child.on('error',fail);child.on('exit',code=>{if(code!==0)fail(Error(`fixture exited ${code}`))});
  child.stderr.on('data',b=>{error+=b});
  child.stdout.on('data',chunk=>{buffer=Buffer.concat([buffer,chunk]);while(buffer.length>=4){const size=buffer.readUInt32LE();assert(size<=4096);if(buffer.length<4+size)break;
    const value=JSON.parse(buffer.subarray(4,4+size));buffer=buffer.subarray(4+size);if(waiting.length)waiting.shift().resolve(value);else frames.push(value);}});
  const next=()=>failed?Promise.reject(failed):frames.length?Promise.resolve(frames.shift()):new Promise((resolve,reject)=>waiting.push({resolve,reject}));
  const send=value=>{const data=Buffer.from(JSON.stringify(value)),header=Buffer.alloc(4);header.writeUInt32LE(data.length);child.stdin.write(Buffer.concat([header,data]));};
  const deadline=setTimeout(()=>{fail(Error('fixture deadline'));child.kill('SIGTERM')},10000);
  try {
    send({browser,extensionID:f.api.runtime.id,extensionPublicKey:Buffer.from(await crypto.subtle.exportKey('raw',f.extension.publicKey)).toString('base64'),clientNonce:f.secure.clientNonce});
    const setup=await next();
    f.secure.trust.appPublicKey=await crypto.subtle.importKey('raw',Buffer.from(setup.appPublicKey,'base64'),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
    await f.secure.receive(await next());send(f.messages.at(-1));
    assert.deepEqual(await next(),{accepted:true,replayDenied:true,kind:'browser.extension_observed',textEnabled:false});
    assert.equal(await exited,0,error);assert.equal(f.counts().valueReads,0);
  } finally {clearTimeout(deadline);child.stdin.end();}
});
