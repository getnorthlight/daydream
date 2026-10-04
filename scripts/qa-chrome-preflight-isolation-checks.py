#!/usr/bin/env python3
"""Execute verbatim QA proof wrapper against clock-free owned-scope adversaries. No OS/UI/store calls."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root/'Sources/MacMemApp/CaptureBrowserFixtureTrial.swift').read_text()
def method(text, marker):
    start=text.index(marker); brace=text.index('{',start); end=brace+1; depth=1
    while depth:
        depth += (text[end]=='{')-(text[end]=='}'); end+=1
    return text[start:end]
proof = method(source, '    func verifiedProductionField()')
ready = method(source, '    private func preflightReady()')
assert 'matches()' not in ready and '.reply(' not in ready and 'metadataSession' not in ready
assert 'preflightDiagnostic:mode == "preflight"' in source
assert 'if mode == "preflight"' in source and source.index('if mode == "preflight" {\n            emit(') < source.index('let home = try CaptureFixtureTrial.newHome(root)')
witness = (root/'Sources/MacMemApp/ChromeTypingWitness.swift').read_text()
assert 'formSearchRecoveryEnabled: Bool = true' in witness  # fix/chrome-large-pages: production default ON
sender = (root/'Sources/MacMemApp/ChromeEventSender.swift').read_text()
assert sender.count('.sendEvent(')==1
assert 'noConsentPrompt' in sender and 'error as NSError).code' in sender
assert 'localizedDescription' not in sender and 'error.userInfo' not in sender
swift='''import Foundation
struct Proof { var windowID="w"; var tabID="t"; var origin="https://www.google.com"; var sendField="search" }
enum Denial { case changed, disabled, field }
struct BrowserTypingJoinResult {
 var proof:Proof?; var denial:Denial?
 static func denied(_ d:Denial)->Self {Self(proof:nil,denial:d)}
}
enum ChromeJoinDesign { static let current=0 }
struct BrowserTypingBlockList {static let pinned:[String]=[]}
enum SendRules {static func surface(bundle:String,host:String?,field:String)->String {"search"}}
struct Scenario {func allows(origin:String,documentURL:String,surface:String,field:String)->Bool {false}}
final class ChromeTypingWitness {
 static var calls=0, checks=0, admit=true
 init(design:Int) {}
 func read(pid:Int,enabled:()->Bool,blockList:BrowserTypingBlockList,alwaysBlocked:[String])->BrowserTypingJoinResult {
  Self.calls+=1
  for _ in 0..<6 {Self.checks+=1; if !enabled() {return .denied(.disabled)}}
  return Self.admit ? .init(proof:Proof(),denial:nil) : .denied(.field)
 }
}
final class Scope {
 let pid=42,windowID="w",tabID="t",origin="https://www.google.com",documentURL="https://www.google.com/search?q=fake"
 var scenario:Scenario?=nil
 var preflightDiagnostic:Bool, ready=true, scopeResults:[Bool], scopeChecks=0, readyChecks=0
 init(preflight:Bool,scopeResults:[Bool]=[]) {preflightDiagnostic=preflight; self.scopeResults=scopeResults}
 func matches()->Bool {scopeChecks+=1; return scopeResults.isEmpty ? true : scopeResults.removeFirst()}
 private func preflightReady()->Bool {readyChecks+=1; return ready}
''' + proof + '''
}
var checks=0
func check(_ ok:Bool,_ label:String) {guard ok else {print("FAIL "+label);exit(1)};checks+=1;print("PASS "+label)}
let pre=Scope(preflight:true)
check(pre.verifiedProductionField().proof != nil,"preflight admits only through real wrapper")
check(pre.scopeChecks==2 && pre.readyChecks==6,"preflight exact owned scope before and after; no QA AE injected by enabled callbacks")
let capture=Scope(preflight:false)
check(capture.verifiedProductionField().proof != nil && capture.scopeChecks==8 && capture.readyChecks==0,"capture retains original exact scope checks inside every witness callback")
let before=Scope(preflight:true,scopeResults:[false]);let beforeCalls=ChromeTypingWitness.calls
check(before.verifiedProductionField().denial == .changed && ChromeTypingWitness.calls==beforeCalls,"stale tab/window/document refused before production read")
let after=Scope(preflight:true,scopeResults:[true,false])
check(after.verifiedProductionField().denial == .changed && after.scopeChecks==2,"scope loss after successful witness prevents proof admission")
let readiness=Scope(preflight:true);readiness.ready=false
check(readiness.verifiedProductionField().denial == .disabled,"cheap front/privacy/permission guard refusal denies production witness")
let captureLoss=Scope(preflight:false,scopeResults:[true,false])
check(captureLoss.verifiedProductionField().denial == .disabled && captureLoss.readyChecks==0,"capture scope loss during callback still refuses")
ChromeTypingWitness.admit=false
let denied=Scope(preflight:true)
check(denied.verifiedProductionField().denial == .field,"production field refusal unchanged; no candidate recovery admission")
check(denied.scopeChecks==2,"denied preflight also rechecks exact owned scope before exposing refusal")
let movedDenied=Scope(preflight:true,scopeResults:[true,false])
check(movedDenied.verifiedProductionField().denial == .changed,"scope loss masks detailed product refusal after preflight")
print("PASS "+String(checks)+" executed QA wrapper isolation checks; no OS/UI/store calls")
'''
with tempfile.TemporaryDirectory(prefix='dd-qa-preflight-') as tmp:
    p=Path(tmp);(p/'main.swift').write_text(swift)
    subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
    subprocess.run([str(p/'checks')],check=True)
