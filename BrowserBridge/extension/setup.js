import {prepareLocalRegistration,approveLocalAppPin} from './local-trust.js';
const api=globalThis.browser??globalThis.chrome;
const browser=location.protocol==='safari-web-extension:'?'safari':'chrome',extensionID=api.runtime.id;
const get=id=>document.getElementById(id),b64=value=>btoa(String.fromCharCode(...new Uint8Array(value)));
let registration=null,review=null;
const status=text=>{get('status').textContent=text;};
get('prepare').onclick=async()=>{
  try{
    registration=await prepareLocalRegistration({browser,extensionID,approvedSetup:true});
    get('registration').value=JSON.stringify({browser,extensionID,publicKey:b64(registration.publicKey),fingerprint:registration.fingerprint});
    status('Public registration ready. Native review is still required.');
  }catch{status('Extension key storage unavailable. Nothing enrolled.');}
};
get('challenge').oninput=()=>{review=null;get('approve').disabled=true;get('fingerprint').textContent='';};
get('inspect').onclick=async()=>{
  review=null;get('approve').disabled=true;
  try{
    if(!registration||get('challenge').value.length>4096)throw Error();
    const value=JSON.parse(get('challenge').value);
    if(value.browser!==browser||value.extensionID!==extensionID||value.fingerprint!==registration.fingerprint||typeof value.appPublicKey!=='string')throw Error();
    const raw=Uint8Array.from(atob(value.appPublicKey),c=>c.charCodeAt(0));
    const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',raw))].map(x=>x.toString(16).padStart(2,'0')).join('');
    if(hash!==value.appFingerprint)throw Error();
    review={...value,raw};get('fingerprint').textContent=hash;get('approve').disabled=false;
  }catch{status('Challenge does not match this browser registration.');}
};
get('approve').onclick=async()=>{
  const held=review;review=null;get('approve').disabled=true;
  try{
    if(!held||!registration)throw Error();
    await approveLocalAppPin({browser,extensionID,publicKey:held.raw,displayedFingerprint:held.appFingerprint,approved:true});
    const signature=await registration.prove({nonce:held.nonce,appFingerprint:held.appFingerprint,displayedAppFingerprint:held.appFingerprint});
    get('proof').value=JSON.stringify({nonce:held.nonce,fingerprint:registration.fingerprint,appFingerprint:held.appFingerprint,signature:b64(signature)});
    status('Proof ready. Finish native approval; this has not enabled capture.');
  }catch{status('Approval failed or app pin changed. Existing keys were preserved.');}
};
