// Explicit staging only. Does not register hosts, install extensions, sign with
// a user certificate, select a real extension ID, enroll keys or start capture.
import {mkdir,copyFile,readdir,readFile,writeFile,chmod} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const args=process.argv.slice(2),get=name=>{const at=args.indexOf(name);return at<0?null:args[at+1];};
const out=get('--out'),bin=get('--binaries'),safari=get('--safari-executable');
if(!out?.startsWith('/')||!bin?.startsWith('/')||!safari?.startsWith('/'))throw Error('Explicit absolute --out, --binaries and --safari-executable required');
const source=dirname(fileURLToPath(import.meta.url));
await mkdir(out,{mode:0o700}); // must be new; never overwrite a delivery
for(const name of ['BrowserBridgeHost','BrowserBridgeSetup']){await copyFile(join(bin,name),join(out,name));await chmod(join(out,name),0o700);}
await copyFile(join(source,'configure-chrome.mjs'),join(out,'configure-chrome.mjs'));
async function extension(destination,manifest){
  await mkdir(destination,{recursive:true,mode:0o700});
  for(const name of await readdir(join(source,'extension'))){if(/\.(js|html)$/.test(name))await copyFile(join(source,'extension',name),join(destination,name));}
  await copyFile(manifest,join(destination,'manifest.json'));
}
await extension(join(out,'Chrome'),join(source,'extension/manifest.json'));
const contents=join(out,'DaydreamBrowser.appex/Contents');
await mkdir(join(contents,'MacOS'),{recursive:true,mode:0o700});
await copyFile(safari,join(contents,'MacOS/DaydreamBrowser'));await chmod(join(contents,'MacOS/DaydreamBrowser'),0o700);
await extension(join(contents,'Resources'),join(source,'safari/manifest.json'));
let info=await readFile(join(source,'safari/Info.plist'),'utf8');
info=info.replace('<key>CFBundleName</key>','<key>CFBundleExecutable</key><string>DaydreamBrowser</string><key>CFBundleName</key>');
await writeFile(join(contents,'Info.plist'),info,{mode:0o600});
await writeFile(join(out,'README.txt'),'Uninstalled build artifacts. Safari has unresolved signing, bundle and reviewed configuration inputs. Chrome requires exact runtime ID and reviewed native host registration. Use BrowserBridgeSetup --help for interactive public-key enrollment. No validation receipt was produced.\n',{mode:0o600});
const receipts={};
async function hash(path){for(const entry of await readdir(path,{withFileTypes:true})){const full=join(path,entry.name);if(entry.isDirectory())await hash(full);else receipts[full.slice(out.length+1)]=createHash('sha256').update(await readFile(full)).digest('hex');}}
await hash(out);await writeFile(join(out,'SHA256.json'),JSON.stringify(receipts,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({staged:resolve(out),installed:false,paired:false,validated:false,files:Object.keys(receipts).length}));
