import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source=readFileSync(new URL('../../Sources/MacMemApp/AccessibilitySnapshot.swift',import.meta.url),'utf8');
test('production snapshot rejects browsers before AX or AppleEvents metadata',()=>{
  const snapshot=source.split('static func snapshot(')[1];
  assert.ok(snapshot.indexOf('CaptureSession.excludedBrowsers.contains(bundle)')<snapshot.indexOf('AXUIElementCreateApplication(pid)'));
  assert.match(snapshot,/Browser windows aren't read here\. What's on web pages and what you type in browsers is never saved\./);
  assert.ok(!source.includes('ChromeModeReader.read('));
  // Chrome page history has its own Apple Events path; the AX snapshot never reaches it.
  for(const denied of ['ChromeEventSender','ChromePageRecorder','ChromePageProbe']) assert.ok(!source.includes(denied),denied);
});
test('no native window mapping by title, first-window selection, or global scan',()=>{
  assert.ok(!source.includes('CGWindowListCopyWindowInfo'));
  assert.ok(!source.includes('kCGWindowName'));
  assert.match(source,/windowID: nil/);
});
test('typed native OS reader uses exact AX owner and equality with per-object timeout',()=>{
  const native=source.split('static func typingProof(')[1].split('private static func directKeyboardInput')[0];
  for(const expected of ['Thread.isMainThread','AXUIElementGetPid','CFEqual','process.launchDate','trustedNativeProcess','AXUIElementSetMessagingTimeout(node,0.025)']) assert.ok(native.includes(expected),expected);
  for(const denied of ['CFHash','kAXValueAttribute','kAXTitleAttribute','kAXSelectedTextAttribute','ChromeModeReader']) assert.ok(!native.includes(denied),denied);
});
test('host cannot manufacture integration or native witness from launch arguments',()=>{
  const host=readFileSync(new URL('../Sources/BrowserBridgeHost/main.swift',import.meta.url),'utf8');
  assert.match(host,/native_app_not_integrated/);
  assert.ok(!host.includes('NativeWitness('));
  assert.ok(!host.includes('verifiedLaunchIdentity:true'));
});
