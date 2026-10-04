#!/usr/bin/env python3
"""Execute the exact QA predicate helper against side-effect read-order witnesses."""
from pathlib import Path
import subprocess, tempfile, json, hashlib, sys
root=Path(__file__).resolve().parent.parent
source=(root/'Sources/MacMemApp/CaptureFixtureTrial.swift').read_text()
assert 'static let scopeFixture = CaptureFixtureKind.textEdit' in source
assert 'textEdit = "textedit"' in source
helper=source[source.index('struct CaptureSavePredicateDiagnostic {'):source.index('enum CaptureFixtureKind: String {')]
checks=r"""
var checks=0
func expect(_ value:Bool){checks+=1;precondition(value)}
for scope in [false,true] {
 for edit in [Optional<Bool>.none,false,true] {
  for file in [Optional<Bool>.none,false,true] {
   var observed=[String](), baseline=[String]()
   var d=CaptureSavePredicateDiagnostic()
   let actual=d.check(matches:{observed.append("scope");return scope},
     edited:{observed.append("edited");return edit},
     protectedExact:{observed.append("file");return file})
   let original:Bool = {
    baseline.append("scope");guard scope else{return false}
    baseline.append("edited");guard edit==false else{return false}
    baseline.append("file");return file==true
   }()
   expect(actual==original);expect(observed==baseline)
   expect(d.attempts==1);expect(d.scopeMatched==scope)
   expect(d.editedState == (scope ? (edit.map{$0 ? "true":"false"} ?? "unavailable"):"not-read"))
   expect(d.fileState == (scope && edit==false ? (file.map{$0 ? "exact":"mismatch"} ?? "unavailable"):"not-read"))
   for final in [false,true] {
    var dd=d;var reads=0
    expect(dd.finish(saved:actual,matches:{reads+=1;return final})==(actual && final))
    expect(reads==(actual ? 1:0))
    expect(dd.finalScopeState == (actual ? (final ? "matched":"refused"):"not-read"))
   }
  }
 }
}
var d=CaptureSavePredicateDiagnostic()
expect(!d.check(matches:{true},edited:{nil},protectedExact:{preconditionFailure("unavailable must skip file")}))
expect(d.editedUnavailableCount==1)
expect(!d.check(matches:{false},edited:{preconditionFailure("scope refusal must skip edited")},protectedExact:{preconditionFailure()}))
expect(d.editedState=="not-read" && d.fileState=="not-read" && d.attempts==2)
expect(d.check(matches:{true},edited:{false},protectedExact:{true}))
expect(d.fileExactCount==1 && d.editedUnavailableCount==1)
expect(d.metadata["additionalReads"] as? Bool == false)
expect(Set(d.metadata.keys)==Set(["phase","saveAttempts","currentScopeMatches","editedState","protectedFileState","finalScopeState","editedUnavailableCount","fileExactCount","additionalReads"]))
for scope in [false,true] {
 for exact in [Optional<Bool>.none,false,true] {
  var order=[String]()
  let value=CapturePersistedReopenPredicate.exact(matches:{order.append("scope");return scope},protectedExact:{order.append("file");return exact})
  expect(value==(scope && exact==true))
  expect(order==(scope ? ["scope","file"]:["scope"]))
 }
}
func rangeValue(_ location:Int,_ length:Int) -> CFTypeRef? {
 var range=CFRange(location:location,length:length)
 return AXValueCreate(.cfRange,&range)
}
expect(CaptureCaretRangePredicate.acceptsScope(rawFixture:"textedit",hasDocument:true))
expect(!CaptureCaretRangePredicate.acceptsScope(rawFixture:"textedit-workflow",hasDocument:true))
expect(!CaptureCaretRangePredicate.acceptsScope(rawFixture:"textedit",hasDocument:false))
expect(!CaptureCaretRangePredicate.acceptsScope(rawFixture:"native-claude",hasDocument:true))
for location in [-1,0,25,26,27] {
 for length in [-1,0,1] {
  let raw=rangeValue(location,length)
  expect(CaptureCaretRangePredicate.exact(status:.success,raw:raw,scopeHeld:true,timely:true,expected:26)==(location==26 && length==0))
 }
}
for error in [AXError.attributeUnsupported,AXError.cannotComplete,AXError.invalidUIElement,AXError.noValue] {
 expect(!CaptureCaretRangePredicate.exact(status:error,raw:rangeValue(26,0),scopeHeld:true,timely:true,expected:26))
}
expect(!CaptureCaretRangePredicate.exact(status:.success,raw:nil,scopeHeld:true,timely:true,expected:26))
expect(!CaptureCaretRangePredicate.exact(status:.success,raw:"not a range" as CFString,scopeHeld:true,timely:true,expected:26))
expect(!CaptureCaretRangePredicate.exact(status:.success,raw:rangeValue(26,0),scopeHeld:false,timely:true,expected:26))
expect(!CaptureCaretRangePredicate.exact(status:.success,raw:rangeValue(26,0),scopeHeld:true,timely:false,expected:26))
expect(!CaptureCaretRangePredicate.exact(status:.success,raw:rangeValue(26,0),scopeHeld:true,timely:true,expected:-1))
print("checks=\(checks) failures=0")
"""
out=Path(sys.argv[1]);out.mkdir(mode=0o700,exist_ok=False)
swift=out/'extracted.swift';swift.write_text('import Foundation\nimport ApplicationServices\n'+helper+checks)
binary=out/'checks';cmd=['swiftc',str(swift),'-o',str(binary)]
subprocess.run(cmd,check=True)
r=subprocess.run([str(binary)],check=True,capture_output=True,text=True)
(out/'result.log').write_text(r.stdout)
(out/'receipt.json').write_text(json.dumps({'source':str(root),'extractedSourceSHA':hashlib.sha256(swift.read_bytes()).hexdigest(),'binarySHA':hashlib.sha256(binary.read_bytes()).hexdigest(),'command':cmd,'result':r.stdout,'liveUI':False},indent=2)+'\n')
print(r.stdout)
