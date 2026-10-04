import { AuthenticatedChromeBridge } from './authenticated.js';
import { loadLocalTrust } from './local-trust.js';
// No implicit enrollment, test keys, first-contact pin or unsigned fallback.
// App integration must supply reviewed local trust before connecting. With no
// enrollment this is unavailable BEFORE opening a port or reading any context.
const bridge = new AuthenticatedChromeBridge(chrome, null);
async function connectReviewed(){
  try{bridge.trust=await loadLocalTrust({browser:'chrome',extensionID:chrome.runtime.id});bridge.connect();}
  catch{bridge.disconnect('trusted_enrollment_missing');}
}
chrome.action.onClicked.addListener(connectReviewed);
// Setup opens only on an explicit extension-action click, never on startup.
chrome.action.onClicked.addListener(async()=>{try{if(!await loadLocalTrust({browser:'chrome',extensionID:chrome.runtime.id}))await chrome.runtime.openOptionsPage();}catch{}});
// Reconnect only an already enrolled extension after browser/worker startup.
// Native master-recording and validation gates still precede every observation.
chrome.runtime.onStartup?.addListener(connectReviewed);
// No first-use trust, retries, alarms, content scripts, external messages,
// externally_connectable, postMessage forwarding, or key/input listeners.
