import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { openKeyStore } from '../extension/key-store.js';
import { prepareLocalRegistration,approveLocalAppPin,loadLocalTrust } from '../extension/local-trust.js';
import { safariNativeAPI } from '../extension/safari-native-port.js';

// Transaction-level IndexedDB fixture, not a real browser's persistence engine.
function database(){
  const rows=new Map();let tail=Promise.resolve(),abortNext=false,opens=0;
  const db={objectStoreNames:{contains:()=>true},close(){},transaction(name,mode){
    assert.equal(name,'keys');const tx={},requests=[],pending=[];
    tx.objectStore=()=>({get(id){const request={};requests.push(()=>{request.result=rows.get(id);request.onsuccess?.();});return request;},add(value,id){pending.push([id,value]);}});
    tail=tail.then(()=>new Promise(resolve=>setTimeout(()=>{
      for(const f of requests)f();
      if(abortNext){abortNext=false;tx.onabort?.();}
      else{for(const [id,value] of pending){assert(!rows.has(id));rows.set(id,structuredClone(value));}tx.oncomplete?.();}
      resolve();
    },0)));return tx;
  }};
  return {rows,abort(){abortNext=true;},api:{open(){opens++;const request={};setTimeout(()=>{request.result=db;request.onsuccess();},0);return request;}},get opens(){return opens;}};
}
test('durable storage adapter waits for transactions, reuses keys on reopen and concurrent setup',async()=>{
  const d=database(),store=await openKeyStore({indexedDB:d.api,origin:'chrome-extension://'+'a'.repeat(32)});
  const cfg={browser:'chrome',extensionID:'a'.repeat(32),approvedSetup:true,store,cryptoAPI:webcrypto};
  const [one,two]=await Promise.all([prepareLocalRegistration(cfg),prepareLocalRegistration(cfg)]);
  assert.equal(one.fingerprint,two.fingerprint);store.close();
  const reopened=await openKeyStore({indexedDB:d.api,origin:'chrome-extension://'+'a'.repeat(32)});
  const again=await prepareLocalRegistration({...cfg,store:reopened});assert.equal(one.fingerprint,again.fingerprint);
  assert.equal(d.rows.get('chrome:'+cfg.extensionID).privateKey.extractable,false);assert.equal(d.opens,2);
  d.abort();await assert.rejects(reopened.putIfAbsent('not-committed',{x:1}));assert(!d.rows.has('not-committed'));
});
test('setup and app pin approval required; changed key denied; runtime loads reviewed trust only',async()=>{
  const d=database(),store=await openKeyStore({indexedDB:d.api,origin:'safari-web-extension://fixture'});
  const cfg={browser:'safari',extensionID:'com.daydream.fixture',store,cryptoAPI:webcrypto};
  assert.equal(await loadLocalTrust(cfg),null);await assert.rejects(prepareLocalRegistration({...cfg,approvedSetup:false}));assert.equal(d.rows.size,0);
  await prepareLocalRegistration({...cfg,approvedSetup:true});
  const app=await webcrypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const publicKey=await webcrypto.subtle.exportKey('raw',app.publicKey),fingerprint=Buffer.from(await webcrypto.subtle.digest('SHA-256',publicKey)).toString('hex');
  await assert.rejects(approveLocalAppPin({...cfg,publicKey,displayedFingerprint:fingerprint,approved:false}));
  await approveLocalAppPin({...cfg,publicKey,displayedFingerprint:fingerprint,approved:true});
  const trusted=await loadLocalTrust(cfg);assert.equal(trusted.extensionPrivateKey.extractable,false);assert.equal(trusted.browser,'safari');
  const changed=await webcrypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const next=await webcrypto.subtle.exportKey('raw',changed.publicKey),hash=Buffer.from(await webcrypto.subtle.digest('SHA-256',next)).toString('hex');
  await assert.rejects(approveLocalAppPin({...cfg,publicKey:next,displayedFingerprint:hash,approved:true}));
  await assert.rejects(openKeyStore({indexedDB:d.api,origin:'https://example.test'}));
});
test('Safari native request adapter relays replies and discards disconnected late replies',async()=>{
  let resolve;const api=safariNativeAPI({runtime:{sendNativeMessage:()=>new Promise(r=>{resolve=r;})}}),received=[];
  const port=api.runtime.connectNative('fixture');port.onMessage.addListener(x=>received.push(x));
  port.postMessage({fixture:1});resolve({reply:1});await new Promise(r=>setTimeout(r,0));assert.deepEqual(received,[{reply:1}]);
  port.postMessage({fixture:2});port.disconnect();resolve({reply:2});await new Promise(r=>setTimeout(r,0));assert.equal(received.length,1);
});
