// Existing database only. No upgrade, put, add, enrollment or key generation.
export async function loadDiagnosticTrust({browser,extensionID,indexedDB=globalThis.indexedDB,origin=globalThis.location?.origin}) {
  if(!/^(chrome-extension|safari-web-extension):\/\/[^/]+$/.test(origin??'')||!indexedDB)throw Error('diagnostic_enrollment_missing');
  const db=await new Promise((resolve,reject)=>{
    const r=indexedDB.open('daydream-browser-keys');
    r.onupgradeneeded=()=>{r.transaction.abort();};
    r.onsuccess=()=>resolve(r.result);
    r.onerror=r.onblocked=()=>reject(Error('diagnostic_enrollment_missing'));
  });
  try {
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction('keys','readonly'),store=tx.objectStore('keys'),id=browser+':'+extensionID;
      let held,pin;
      store.get(id).onsuccess=e=>{held=e.target.result;};
      store.get('app:'+id).onsuccess=e=>{pin=e.target.result;};
      tx.onerror=tx.onabort=()=>reject(Error('diagnostic_enrollment_missing'));
      tx.oncomplete=()=>{
        if(!held||!pin||held.browser!==browser||held.extensionID!==extensionID||
            !/^[a-f0-9]{64}$/.test(held.fingerprint)||!/^[a-f0-9]{64}$/.test(pin.fingerprint))return reject(Error('diagnostic_enrollment_missing'));
        resolve({browser,extensionID,extensionFingerprint:held.fingerprint,appFingerprint:pin.fingerprint,
          extensionPrivateKey:held.privateKey,appPublicKey:pin.key});
      };
    });
  } finally {db.close();}
}
