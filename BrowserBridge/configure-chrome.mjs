// Prepare files inside an existing staged delivery only. This NEVER writes a
// Chrome NativeMessagingHosts directory or loads/enables an extension.
import {writeFile,stat} from 'node:fs/promises';
import {join} from 'node:path';
const args=process.argv.slice(2),get=name=>{const at=args.indexOf(name);return at<0?null:args[at+1];};
const delivery=get('--delivery'),directory=get('--setup-directory'),service=get('--service'),deployment=get('--deployment'),id=get('--extension-id'),installed=get('--installed-launcher');
if(!delivery?.startsWith('/')||!directory?.startsWith('/')||!installed?.startsWith('/')||!/^[a-p]{32}$/.test(id??'')||!/^[a-f0-9]{64}$/.test(deployment??'')||!/^[A-Za-z0-9][A-Za-z0-9.-]{3,199}$/.test(service??''))throw Error('Exact delivery/setup/installed paths, service, deployment SHA256 and Chrome runtime ID required');
if(!(await stat(join(delivery,'BrowserBridgeHost'))).isFile())throw Error('staged_host_missing');
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
const launcher='#!/bin/sh\nset -eu\nbrowser_host_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$browser_host_root/BrowserBridgeHost" --reviewed-directory '+quote(directory)+' --keychain-service '+quote(service)+' --deployment '+quote(deployment)+' "$@"\n';
await writeFile(join(delivery,'browser-host'),launcher,{flag:'wx',mode:0o700});
await writeFile(join(delivery,'com.macmem.browser_bridge.json'),JSON.stringify({name:'com.macmem.browser_bridge',description:'Daydream reviewed browser metadata',path:installed,type:'stdio',allowed_origins:[`chrome-extension://${id}/`]},null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({prepared:delivery,installed:false,extensionID:id,validationRequired:true}));
