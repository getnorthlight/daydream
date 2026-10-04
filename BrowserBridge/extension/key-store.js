// IndexedDB belongs to this extension origin. Structured cloning preserves the
// nonextractable CryptoKey; JSON/localStorage/private-key export are not used.
export async function openKeyStore({indexedDB=globalThis.indexedDB,origin=globalThis.location?.origin}={}) {
  if(!/^(chrome-extension|safari-web-extension):\/\/[^/]+$/.test(origin??'') || !indexedDB)throw Error('extension_storage_unavailable');
  const db=await new Promise((resolve,reject)=>{
    const request=indexedDB.open('daydream-browser-keys',1);
    request.onupgradeneeded=()=>{if(!request.result.objectStoreNames.contains('keys'))request.result.createObjectStore('keys');};
    request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(Error('key_store_unavailable'));
    request.onblocked=()=>reject(Error('key_store_blocked'));
  });
  db.onversionchange=()=>db.close();
  function transact(id,candidate,write){
    return new Promise((resolve,reject)=>{
      const tx=db.transaction('keys',write?'readwrite':'readonly'),store=tx.objectStore('keys');let value;
      tx.oncomplete=()=>resolve(value);tx.onabort=tx.onerror=()=>reject(Error('key_store_transaction_failed'));
      const read=store.get(id);
      read.onsuccess=()=>{value=read.result;if(write && value===undefined){value=candidate;store.add(candidate,id);}};
      // Resolve only after durable transaction completion, never get/add success.
    });
  }
  return {get:id=>transact(id,undefined,false),putIfAbsent:(id,value)=>transact(id,value,true),close:()=>db.close()};
}
