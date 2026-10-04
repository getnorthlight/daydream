// Invoked only by the extension's reviewed setup UI. No automatic enrollment,
// context query, native permission request or private-key export.
export async function prepareRegistration({store, browser, extensionID, approvedSetup, cryptoAPI=crypto}) {
  if (approvedSetup!==true || !['chrome','safari'].includes(browser)) throw Error('setup_approval_required');
  const valid=browser==='chrome'?/^[a-p]{32}$/:/^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$/;
  if(!valid.test(extensionID))throw Error('invalid_extension');
  const id=`${browser}:${extensionID}`;
  let held=await store.get(id);
  if(!held){
    const keys=await cryptoAPI.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
    held={browser,extensionID,privateKey:keys.privateKey,publicKey:keys.publicKey};
    // Store must implement atomic put-if-absent. A retry/concurrent setup must
    // return the existing key, never silently replace it.
    held=await store.putIfAbsent(id,held);
  }
  if(held.browser!==browser||held.extensionID!==extensionID||held.privateKey?.extractable!==false||held.privateKey.type!=='private')throw Error('registration_changed');
  const publicKey=new Uint8Array(await cryptoAPI.subtle.exportKey('raw',held.publicKey));
  const prefix=new TextEncoder().encode(`${browser}\n${extensionID}\n`),bytes=new Uint8Array(prefix.length+publicKey.length);
  bytes.set(prefix);bytes.set(publicKey,prefix.length);
  const fingerprint=[...new Uint8Array(await cryptoAPI.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
  return {browser,extensionID,publicKey,fingerprint,
    async prove({nonce,appFingerprint,displayedAppFingerprint}){
      if(!/^[a-f0-9-]{36}$/.test(nonce)||!/^[a-f0-9]{64}$/.test(appFingerprint)||displayedAppFingerprint!==appFingerprint)throw Error('app_pin_not_approved');
      const text=`daydream-browser-enrollment-v1\n${browser}\n${extensionID}\n${nonce}\n${fingerprint}\n${appFingerprint}`;
      return new Uint8Array(await cryptoAPI.subtle.sign({name:'ECDSA',hash:'SHA-256'},held.privateKey,new TextEncoder().encode(text)));
    }};
}
