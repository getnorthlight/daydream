import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { ChromeBridge } from '../extension/bridge.js';
import { join } from 'node:path';
// Explicit isolated build path for source QA; never an installed helper lookup.
const binaryDirectory=process.argv[2] ?? '.build/debug';

const frame=value=>{const body=Buffer.from(JSON.stringify(value)),head=Buffer.alloc(4);head.writeUInt32LE(body.length);return Buffer.concat([head,body]);};
const unpack=buffer=>{assert.ok(buffer.length>=4);const length=buffer.readUInt32LE();assert.ok(length<=4096&&buffer.length===length+4);return JSON.parse(buffer.subarray(4).toString());};
const id='a'.repeat(32),doc='11111111-1111-4111-8111-111111111111',focus='22222222-2222-4222-8222-222222222222';
const event=()=>({listeners:[],addListener(fn){this.listeners.push(fn)},fire(value){for(const f of this.listeners)f(value)}});
const child=spawn(join(binaryDirectory,'BrowserBridgeChecks'),['--wire-fixture'],{stdio:['pipe','pipe','pipe']});
const port={onMessage:event(),onDisconnect:event(),postMessage:value=>child.stdin.write(frame(value)),disconnect:()=>child.stdin.end()};
let buffer=Buffer.alloc(0),reply=null;
child.stdout.on('data',data=>{buffer=Buffer.concat([buffer,data]);while(buffer.length>=4){const size=buffer.readUInt32LE();assert.ok(size<=4096);if(buffer.length<size+4)break;
 const value=unpack(buffer.subarray(0,size+4));buffer=buffer.subarray(size+4);
 if(value.kind==='probe')port.onMessage.fire(value);else reply=value;
}});
const api={runtime:{id,connectNative:()=>port},windows:{getLastFocused:async()=>({id:3,incognito:false,focused:true})},
 tabs:{query:async()=>[{id:9,windowId:3,incognito:false,active:true,status:'complete',url:'https://example.test/article'}]},
 permissions:{contains:async()=>true},webNavigation:{getAllFrames:async()=>[{frameId:0,parentFrameId:-1,documentId:doc,documentLifecycle:'active',url:'https://example.test/article'}]},
 scripting:{executeScript:async()=>[{frameId:0,documentId:doc,result:{safety:'noneditable',role:'button',focusID:focus,focusGeneration:1}}]}};
new ChromeBridge(api).connect();
const timer=setTimeout(()=>child.kill(),3000);let stderr='';child.stderr.on('data',d=>{stderr+=d.toString()});
const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',resolve)});clearTimeout(timer);
assert.equal(code,0);assert.equal(stderr,'');assert.deepEqual(reply,{accepted:true,kind:'browser.observed',textEnabled:false});
// The production helper has no synthetic-mode flag and cannot enable capture.
const host=spawnSync(join(binaryDirectory,'BrowserBridgeHost'),['chrome-extension://'+id+'/'],{input:frame({version:1,kind:'hello',extensionID:id,textEnabled:false}),timeout:3000});
assert.equal(host.status,0);assert.equal(host.stderr.length,0);assert.deepEqual(unpack(host.stdout),{version:1,kind:'unavailable',reason:'native_app_not_integrated',textEnabled:false});
const huge=Buffer.alloc(4);huge.writeUInt32LE(4097);
const malformed=spawnSync(join(binaryDirectory,'BrowserBridgeHost'),[],{input:huge,timeout:3000});assert.equal(malformed.status,1);assert.equal(malformed.stdout.length,0);assert.equal(malformed.stderr.length,0);
console.log('Native wire passes: extension probe -> real Swift decoder/receiver, strict bounded framing, and production host stays OFF. Browser APIs/native identities are synthetic.');
