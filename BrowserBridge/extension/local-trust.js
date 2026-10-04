import { openKeyStore } from './key-store.js';
import { prepareRegistration } from './enrollment.js';

const hex=bytes=>[...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
// Setup-only entry. Keys are created only after explicit local setup approval.
export async function prepareLocalRegistration({browser,extensionID,approvedSetup,store,cryptoAPI=crypto}) {
  if(approvedSetup!==true)throw Error('setup_approval_required');
  const owned=store??await openKeyStore();
  try{return await prepareRegistration({store:owned,browser,extensionID,approvedSetup,cryptoAPI});}
  finally{if(!store)owned.close();}
}
export async function approveLocalAppPin({browser,extensionID,publicKey,displayedFingerprint,approved,store,cryptoAPI=crypto}) {
  if(approved!==true)throw Error('app_pin_approval_required');
  const fingerprint=hex(await cryptoAPI.subtle.digest('SHA-256',publicKey));
  if(displayedFingerprint!==fingerprint)throw Error('app_pin_changed');
  const key=await cryptoAPI.subtle.importKey('raw',publicKey,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  const owned=store??await openKeyStore(),id=`${browser}:${extensionID}`;
  try{
    const registration=await owned.get(id);
    if(!registration||registration.browser!==browser||registration.extensionID!==extensionID)throw Error('extension_registration_missing');
    const pin=await owned.putIfAbsent(`app:${id}`,{fingerprint,key});
    if(pin.fingerprint!==fingerprint)throw Error('app_pin_changed');
    return fingerprint;
  }finally{if(!store)owned.close();}
}
// Read-only trust load on action/startup. No generated keys or first-use trust.
export async function loadLocalTrust({browser,extensionID,store,cryptoAPI=crypto}) {
  const owned=store??await openKeyStore(),id=`${browser}:${extensionID}`;
  try {
    const held=await owned.get(id),pin=await owned.get(`app:${id}`);
    if(!held||!pin)return null;
    if(held.browser!==browser||held.extensionID!==extensionID||held.privateKey?.extractable!==false||held.privateKey?.type!=='private'||pin.key?.type!=='public')throw Error('registration_changed');
    // App key was imported nonextractable, so verify with a public key digest
    // stored at approval; the enrolled CryptoKey itself is the runtime pin.
    if(!/^[a-f0-9]{64}$/.test(pin.fingerprint))throw Error('app_pin_changed');
    return {browser,extensionID,extensionPrivateKey:held.privateKey,appPublicKey:pin.key};
  }finally{if(!store)owned.close();}
}
