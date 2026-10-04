#!/usr/bin/env python3
"""Execute product QA-only buffer and observer with pure read simulation; no OS/file reads during callbacks."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
sender=(root/'Sources/MacMemApp/ChromeEventSender.swift').read_text()
block=sender.split('    #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING',1)[1].split('    #endif',1)[0]
assert 'CaptureFixtureTrial' not in block and '.emit(' not in block and 'NSAppleEventDescriptor' not in block
for file in ['CaptureChromeFrontInspection.swift','CaptureBrowserFixtureTrial.swift']:
    source=(root/'Sources/MacMemApp'/file).read_text()
    assert 'observeQA { transportOutcomes.record($0) }' in source
    defer=source.split('        defer {\n            ChromeEventSender.observeQA(nil)',1)[1].split('\n        }',1)[0]
    assert 'transportOutcomes.drain()' in defer
    assert 'emit(' in defer
swift='''import Foundation
enum Sender {
''' + block + '''
}
var checks=0
func check(_ b:Bool,_ s:String) {guard b else {print("FAIL "+s);exit(1)};checks+=1;print("PASS "+s)}
var emitted:[Sender.QAOutcome]=[], reading=false
let buffer=Sender.QAOutcomeBuffer()
func route(throwAfterRead:Bool) throws {
 Sender.observeQA {buffer.record($0)}
 defer {
  Sender.observeQA(nil)
  for outcome in buffer.drain() {precondition(!reading);emitted.append(outcome)}
 }
 reading=true
 for _ in 0..<1025 {Sender.noteQA(.resultPresent)}
 check(emitted.isEmpty,"measured witness emits no receipt/fileIO callback while reading")
 reading=false
 if throwAfterRead {throw NSError(domain:"fixture",code:1)}
}
try route(throwAfterRead:false)
check(emitted.count==1025 && emitted.last == .bufferTruncated,"1024 bounded events plus fixed truncation marker outside read")
Sender.noteQA(.transportTimeout)
check(emitted.count==1025 && buffer.drain().isEmpty,"observer cleared and buffer drained on success")
emitted=[]
do {try route(throwAfterRead:true)}catch {}
check(emitted.count==1025 && emitted.last == .bufferTruncated,"throw path flushes only after measured read exits")
Sender.noteQA(.transportTimeout)
check(emitted.count==1025 && buffer.drain().isEmpty,"defer clears observer even when route throws")
print("PASS "+String(checks)+" outcome buffer checks; no OS/UI/store calls")
'''
with tempfile.TemporaryDirectory(prefix='dd-qa-buffer-') as tmp:
    p=Path(tmp);(p/'main.swift').write_text(swift)
    subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
    subprocess.run([str(p/'checks')],check=True)
