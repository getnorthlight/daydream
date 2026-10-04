import { AuthenticatedSafariBridge } from './safari.js';
import { safariNativeAPI } from './safari-native-port.js';
import { loadLocalTrust } from './local-trust.js';
// Packaging/setup supplies reviewed trust. No credentials or automatic grants.
// Deliberately inert until that setup exists; never enroll from native messages.
const bridge=new AuthenticatedSafariBridge(safariNativeAPI(browser),null);
async function connectReviewed(){
  try{bridge.trust=await loadLocalTrust({browser:'safari',extensionID:browser.runtime.id});bridge.connect();}
  catch{bridge.disconnect('trusted_enrollment_missing');}
}
browser.action.onClicked.addListener(connectReviewed);
browser.action.onClicked.addListener(async()=>{try{if(!await loadLocalTrust({browser:'safari',extensionID:browser.runtime.id}))await browser.runtime.openOptionsPage();}catch{}});
browser.runtime.onStartup?.addListener(connectReviewed);
