// Safari's native request handler is a request/response boundary. Adapt it to
// the shared signed collector without inventing a persistent native port.
export function safariNativeAPI(api){
  const runtime=Object.create(api.runtime);
  runtime.connectNative=host=>{
    const messages=new Set(),disconnects=new Set();let open=true,busy=false;
    const port={onMessage:{addListener:f=>messages.add(f)},onDisconnect:{addListener:f=>disconnects.add(f)},
      disconnect(){if(!open)return;open=false;for(const f of disconnects)f();},
      postMessage(value){
        if(!open||busy){port.disconnect();return;}busy=true;
        let timer;
        Promise.race([api.runtime.sendNativeMessage(host,value),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('native_deadline')),2500);})])
          .then(reply=>{busy=false;if(open)for(const f of messages)f(reply);})
          .catch(()=>port.disconnect()).finally(()=>clearTimeout(timer));
      }};
    return port;
  };
  return {...api,runtime};
}
