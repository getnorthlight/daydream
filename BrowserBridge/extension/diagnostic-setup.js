import {DiagnosticClient,canonical} from './diagnostic.js';
import {loadDiagnosticTrust} from './diagnostic-trust.js';
// Extension-owned setup controls only; no page messages, background or tab APIs.
const api=globalThis.browser??globalThis.chrome;
const browser=location.protocol==='safari-web-extension:'?'safari':'chrome';
const button=document.getElementById('diagnostic-run'),status=document.getElementById('diagnostic-status');
let current=null,generation=0;
button.onclick=async()=>{
  if(current)return;
  const epoch=++generation;
  button.disabled=true;
  try {
    const text=document.getElementById('diagnostic-ticket').value;
    if(text.length>4096)throw Error();
    const ticket=canonical(JSON.parse(text));
    const trust=await loadDiagnosticTrust({browser,extensionID:api.runtime.id});
    if(epoch!==generation)return;
    current=new DiagnosticClient({trust,runtimeID:api.runtime.id,
      exchange:frame=>api.runtime.sendNativeMessage('com.macmem.browser_diagnostic',frame)});
    await current.run(ticket);
    status.textContent='Connection acknowledged. Capture and physical validation remain unavailable.';
  } catch {status.textContent='Diagnostic unavailable, expired or disconnected. No capture was enabled.';}
  finally {current?.close();current=null;button.disabled=false;}
};
const cancel=()=>{generation++;current?.close();};
document.getElementById('diagnostic-cancel').onclick=cancel;
addEventListener('pagehide',cancel);
