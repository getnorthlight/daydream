import assert from 'node:assert/strict';
import {webcrypto as crypto} from 'node:crypto';
import {spawn} from 'node:child_process';
import {mkdtemp,readdir,readFile} from 'node:fs/promises';
import {createInterface} from 'node:readline';
import {once} from 'node:events';
import vm from 'node:vm';
import {DiagnosticClient,canonical,sign,signedBytes} from '../extension/diagnostic.js';
const binary=process.argv[2];
const host=process.argv[3];assert(binary&&host,'pass isolated DiagnosticChecks and BrowserBridgeDiagnosticHost');
const mode=process.argv[4]??'normal';
let reads=0;for(const name of ['chrome','browser','document'])Object.defineProperty(globalThis,name,{get(){reads++;throw Error('forbidden acquisition');}});
for(const browser of ['chrome','safari']){
 const directory=await mkdtemp('/private/tmp/diag-livewire-');
 const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
 const child=spawn(binary,['--serve',directory,browser]); const exited=once(child,'exit');
 let err='';child.stderr.on('data',b=>err+=b);child.stdin.on('error',()=>{});
 const lines=createInterface({input:child.stdout}),queue=[],waiters=[];
 lines.on('line',l=>{const value=JSON.parse(l);if(waiters.length)waiters.shift()(value);else queue.push(value);});
 const next=()=>queue.length?Promise.resolve(queue.shift()):new Promise(resolve=>waiters.push(resolve));
 child.stdin.write(Buffer.from(await crypto.subtle.exportKey('raw',keys.publicKey)).toString('base64')+'\n');
 let exitedAlready=false;child.on('exit',()=>exitedAlready=true);
 const timer=setTimeout(()=>child.stdin.write('cancel\n'),12000);
 try{
  const first=await Promise.race([next(),exited.then(()=>{throw Error(err||'fixture stopped');})]);
  const trust={browser,extensionID:first.extensionID,extensionPrivateKey:keys.privateKey,
   appPublicKey:await crypto.subtle.importKey('raw',Buffer.from(first.appPublicKey,'base64'),{name:'ECDSA',namedCurve:'P-256'},false,['verify']),
   appFingerprint:first.ticket.binding.appFingerprint,extensionFingerprint:first.ticket.binding.extensionFingerprint};
  let exchanges=0;
  const exchange=async envelope=>{
   exchanges++;
   const args=browser==='chrome'?['--setup-directory',directory,'--diagnostic-directory',directory,'--extension-id',first.extensionID,
    '--deployment',first.deployment,'--app-public-key',first.appPublicKey,'chrome-extension://'+first.extensionID+'/']:
    ['--exchange',directory,browser,first.deployment,'reserved',first.appPublicKey];
   const cp=spawn(browser==='chrome'?host:binary,args);const done=once(cp,'exit');let output=Buffer.alloc(0),error='';
   cp.stdout.on('data',b=>output=Buffer.concat([output,b]));cp.stderr.on('data',b=>error+=b);cp.stdin.on('error',()=>{});
   const body=Buffer.from(canonical(envelope)),head=Buffer.alloc(4);head.writeUInt32LE(body.length);cp.stdin.end(Buffer.concat([head,body]));
   const [status]=await done;assert.equal(status,0,error);assert.equal(output.readUInt32LE(),output.length-4);
   return JSON.parse(output.subarray(4));
  };
  
  if(mode==='replay') {
   const hello=await sign({...first.ticket,kind:'hello',clientNonce:'b'.repeat(32)},keys.privateKey,crypto);
   await exchange({diagnostic:hello});await assert.rejects(exchange({diagnostic:hello}));
   assert.equal((await next()).status,'rejected');
   console.log(JSON.stringify({browser,mode,status:'PASS',acquisitionReads:reads}));
   continue;
  }
  if(mode==='disconnect') {
   let client;
   client=new DiagnosticClient({trust,runtimeID:first.extensionID,cryptoAPI:crypto,
    exchange:async envelope=>{const reply=await exchange(envelope);client.close();return reply;}});
   await assert.rejects(client.run(canonical(first.ticket)));assert.equal(exchanges,1);
   const at=Date.now();child.stdin.write('cancel\n');await exited;
   assert(Date.now()-at<1500,'cancel must not wait for the 30-second attempt deadline');
   console.log(JSON.stringify({browser,mode,status:'PASS',acquisitionReads:reads}));
   continue;
  }
  const snapshot=new Map();
  for(const name of await readdir(directory))if(name.endsWith('.json'))snapshot.set(name,await readFile(directory+'/'+name,'utf8'));
  let negatives=0;
  const hello=()=>sign({...first.ticket,kind:'hello',clientNonce:'b'.repeat(32)},keys.privateKey,crypto);
  for(const kind of ['Probe','probe','metadata_hello','observation','policy']){
   const bad={...await hello(),kind};
   bad.signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},keys.privateKey,signedBytes(bad))).toString('base64');
   await assert.rejects(exchange({diagnostic:bad}));negatives++;
  }
  for(const field of ['text','url','tabID','integrationValidated','physicalDeviceValidated']){
   await assert.rejects(exchange({diagnostic:{...await hello(),[field]:true}}));negatives++;
  }
  const wrong=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
  await assert.rejects(exchange({diagnostic:await sign({...await hello()},wrong.privateKey,crypto)}));negatives++;
  for(const field of ['browser','extensionID','appFingerprint','extensionFingerprint','deployment','configuration']){
   const binding={...first.ticket.binding,[field]:field==='browser'?(browser==='chrome'?'safari':'chrome'):field==='extensionID'?'b'.repeat(32):'f'.repeat(64)};
   if(field==='browser'&&binding.browser==='chrome')binding.extensionID='a'.repeat(32);
   await assert.rejects(exchange({diagnostic:await sign({...await hello(),binding},keys.privateKey,crypto)}));negatives++;
  }
  await assert.rejects(exchange({diagnostic:await sign({...await hello(),expiresAt:Date.now()-1},keys.privateKey,crypto)}));negatives++;
  await assert.rejects(exchange({diagnostic:await hello(),unknown:true}));negatives++;
  await assert.rejects(exchange({diagnostic:{...await hello(),oversized:'x'.repeat(4097)}}));negatives++;
  const baseline=exchanges;
  const client=new DiagnosticClient({trust,runtimeID:first.extensionID,exchange,cryptoAPI:crypto});
  const result=await client.run(canonical(first.ticket));assert.equal(result.status,'acknowledged');
  assert.equal((await next()).status,'acknowledged');assert.equal(exchanges-baseline,2);assert.equal(reads,0);
  assert(!(await readdir(directory)).some(n=>n.includes('validation')));
  await assert.rejects(client.run(canonical(first.ticket)));
  for(const [name,raw] of snapshot)assert.equal(await readFile(directory+'/'+name,'utf8'),raw);
  console.log(JSON.stringify({browser,status:'PASS',transport:'JS/native framing/Unix socket/Swift signatures',exchanges,negativeCases:negatives,acquisitionReads:reads,validationFiles:0,directory}));
 }finally{
  clearTimeout(timer);if(!exitedAlready)child.stdin.write('cancel\n');await exited;lines.close();
 }
}
// Only a synthetic extension setup document, not any browser page.
const setupSource=(await readFile(new URL('../extension/diagnostic-setup.js',import.meta.url),'utf8')).replace(/^import .*;$/gm,'');
for(const action of ['cancel','pagehide']) {
 let resolveTrust,clients=0;
 const waiting=new Promise(resolve=>resolveTrust=resolve);
 const elements=new Map(),listeners=new Map();
 const element=id=>{if(!elements.has(id))elements.set(id,{value:'{}',disabled:false});return elements.get(id);};
 const context={globalThis:{chrome:{runtime:{id:'a'.repeat(32)}}},location:{protocol:'chrome-extension:'},
  document:{getElementById:element},addEventListener:(name,fn)=>listeners.set(name,fn),
  canonical,loadDiagnosticTrust:()=>waiting,
  DiagnosticClient:class {constructor(){clients++;}async run(){}close(){}}};
 vm.runInNewContext(setupSource,context);
 const pending=element('diagnostic-run').onclick();
 if(action==='cancel')element('diagnostic-cancel').onclick();else listeners.get('pagehide')();
 resolveTrust({});await pending;assert.equal(clients,0);
}
console.log(JSON.stringify({setupCancelDuringTrustLoad:'PASS',cases:2}));
