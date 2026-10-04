// Independent diagnostic protocol. No capture, browser API, storage or page imports.
export const DOMAIN='daydream-browser-diagnostic-v1';
const encoder=new TextEncoder();
export function canonical(value) {
  if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
  if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
  return JSON.stringify(value);
}
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join(',')===keys.sort().join(',');
const token=s=>typeof s==='string'&&/^[a-f0-9]{32}$/.test(s),hash=s=>typeof s==='string'&&/^[a-f0-9]{64}$/.test(s);
const b64=b=>btoa(String.fromCharCode(...new Uint8Array(b)));
const unb64=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
const bindingKeys=['browser','extensionID','appFingerprint','extensionFingerprint','deployment','configuration'];
export function decode(raw) {
  const text=typeof raw==='string'?raw:canonical(raw);
  if(typeof text!=='string'||encoder.encode(text).length>4096)throw Error('diagnostic_invalid');
  const f=JSON.parse(text);
  if(!exact(f,['protocol','kind','binding','attemptID','clientNonce','expiresAt','signature'])||
      !exact(f.binding,bindingKeys)||canonical(f)!==text||f.protocol!==DOMAIN||
      !['ticket','hello','challenge','ack','receipt'].includes(f.kind)||
      !['chrome','safari'].includes(f.binding.browser)||
      typeof f.binding.extensionID!=='string'||
      !(f.binding.browser==='chrome'?/^[a-p]{32}$/:/^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$/).test(f.binding.extensionID)||
      !['appFingerprint','extensionFingerprint','deployment','configuration'].every(k=>hash(f.binding[k]))||
      !token(f.attemptID)||!token(f.clientNonce)||!Number.isSafeInteger(f.expiresAt)||f.expiresAt<=0||
      typeof f.signature!=='string'||unb64(f.signature).length!==64||b64(unb64(f.signature))!==f.signature)throw Error('diagnostic_invalid');
  return f;
}
export function signedBytes(f) {
  const b=f.binding;
  return encoder.encode([DOMAIN,f.kind,b.browser,b.extensionID,b.appFingerprint,b.extensionFingerprint,
    b.deployment,b.configuration,f.attemptID,f.clientNonce,String(f.expiresAt)].join('\n'));
}
export async function sign(f,key,cryptoAPI=crypto) {
  const result={...f,signature:b64(await cryptoAPI.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,signedBytes(f)))};
  return decode(canonical(result));
}
export async function verify(f,key,now,cryptoAPI=crypto) {
  if(f.expiresAt<=now||f.expiresAt-now>30000||
    !await cryptoAPI.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,unb64(f.signature),signedBytes(f)))throw Error('diagnostic_authentication_failed');
}
export class DiagnosticClient {
  constructor({trust,runtimeID,exchange,cryptoAPI=crypto,now=()=>Date.now(),monotonic=()=>performance.now()}) {
    this.trust=trust;this.runtimeID=runtimeID;this.exchange=exchange;this.crypto=cryptoAPI;
    this.now=now;this.monotonic=monotonic;this.used=false;this.closed=false;this.cancelWait=null;
  }
  close(){this.closed=true;this.cancelWait?.();this.cancelWait=null;}
  async run(rawTicket) {
    if(this.used||this.closed)throw Error('diagnostic_closed');
    this.used=true;
    const started=this.monotonic(),t=this.trust;
    const valid=()=>{if(this.closed||this.monotonic()-started>=30000)throw Error('diagnostic_closed');};
    let timer;
    const cancelled=new Promise((_,reject)=>{
      this.cancelWait=()=>reject(Error('diagnostic_closed'));
      timer=setTimeout(()=>this.close(),30000);
    });
    const step=async promise=>{const value=await Promise.race([promise,cancelled]);valid();return value;};
    try {
      if(!t||t.extensionID!==this.runtimeID||t.extensionPrivateKey?.extractable!==false||
          t.extensionPrivateKey?.type!=='private'||t.appPublicKey?.type!=='public'||
          t.extensionPrivateKey.algorithm?.namedCurve!=='P-256'||t.appPublicKey.algorithm?.namedCurve!=='P-256')throw Error('diagnostic_enrollment_missing');
      const ticket=decode(rawTicket),b=ticket.binding;
      if(ticket.kind!=='ticket'||ticket.clientNonce!=='0'.repeat(32)||
          b.browser!==t.browser||b.extensionID!==this.runtimeID||b.appFingerprint!==t.appFingerprint||
          b.extensionFingerprint!==t.extensionFingerprint)throw Error('diagnostic_binding_changed');
      await step(verify(ticket,t.appPublicKey,this.now(),this.crypto));
      const nonce=this.crypto.randomUUID().replaceAll('-','').toLowerCase();
      let frame=await step(sign({...ticket,kind:'hello',clientNonce:nonce},t.extensionPrivateKey,this.crypto));
      for(const expected of ['challenge','receipt']) {
        const envelope=await step(this.exchange({diagnostic:frame}));
        if(!exact(envelope,['diagnostic']))throw Error('diagnostic_invalid');
        const reply=decode(canonical(envelope.diagnostic));
        if(reply.kind!==expected||canonical(reply.binding)!==canonical(ticket.binding)||
            reply.attemptID!==ticket.attemptID||reply.clientNonce!==nonce||reply.expiresAt!==ticket.expiresAt)throw Error('diagnostic_binding_changed');
        await step(verify(reply,t.appPublicKey,this.now(),this.crypto));
        if(reply.expiresAt<=this.now())throw Error('diagnostic_expired');
        if(expected==='challenge')frame=await step(sign({...reply,kind:'ack'},t.extensionPrivateKey,this.crypto));
      }
      return Object.freeze({status:'acknowledged',attemptID:ticket.attemptID,binding:Object.freeze({...b})});
    } finally {clearTimeout(timer);this.cancelWait=null;this.closed=true;}
  }
}
