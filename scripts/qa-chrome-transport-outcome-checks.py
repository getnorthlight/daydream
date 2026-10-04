#!/usr/bin/env python3
"""Execute verbatim sole-sender body with fake descriptors and clock; never sends an OS event."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
text=(root/'Sources/MacMemApp/ChromeEventSender.swift').read_text()
start=text.index('    static func send(');brace=text.index('{',start);end=brace+1;depth=1
while depth:
    depth+=(text[end]=='{')-(text[end]=='}');end+=1
send=text[start:end].replace('NSAppleEventDescriptor','Descriptor').replace('deadline:Date','deadline:FakeDate')
swift='''import Foundation
let errAETimeout:Int32 = -1712
enum Clock {static var now:Double=0}
struct FakeDate {let at:Double;var timeIntervalSinceNow:Double {at-Clock.now}}
enum ChromeAppleEvents {
 static let everyWindowDefault:Set<String>=[],eventClass="core",eventID="getd"
 static var auditAllowed=true
 static func audit(_ d:Descriptor,everyWindow:Set<String>)->Bool {auditAllowed}
}
final class Descriptor {
 enum Option:Hashable {case waitForReply,neverInteract,dontRecord,noConsentPrompt}
 static var sends=0,throwCode:Int?=nil,replyError:Int32=0,missing=false,advance:Double=0
 var int32Value:Int32=0
 init() {}
 init(eventClass:UInt32,eventID:UInt32,targetDescriptor:Descriptor,returnID:Int,transactionID:Int) {}
 func setParam(_ d:Descriptor,forKeyword:UInt32) {}
 func sendEvent(options:Set<Option>,timeout:Double)throws->Descriptor {
  precondition(options == [.waitForReply,.neverInteract,.dontRecord,.noConsentPrompt]);precondition(timeout>0 && timeout<=0.02)
  Self.sends+=1;Clock.now+=Self.advance
  if let code=Self.throwCode {throw NSError(domain:NSOSStatusErrorDomain,code:code)}
  return Descriptor()
 }
 func paramDescriptor(forKeyword:UInt32)->Descriptor? {
  if forKeyword==1 {let d=Descriptor();d.int32Value=Self.replyError;return d}
  return Self.missing ? nil : Descriptor()
 }
}
enum Sender {
 enum QAOutcome:String {case budgetExpired,transportTimeout,transportFailed,replyFailed,lateReply,missingResult,resultPresent,decodeFailed}
 static var enabled=true,outcomes:[QAOutcome]=[]
 static let noConsentPrompt=Descriptor.Option.noConsentPrompt
 static func code(_ s:String)->UInt32 {s=="errn" ? 1 : 0}
 static func noteQA(_ o:QAOutcome) {outcomes.append(o)}
''' + send + '''
}
var checks=0
func check(_ b:Bool,_ s:String) {guard b else {print("FAIL "+s);exit(1)};checks+=1;print("PASS "+s)}
func reset() {Clock.now=0;Descriptor.sends=0;Descriptor.throwCode=nil;Descriptor.replyError=0;Descriptor.missing=false;Descriptor.advance=0;Sender.enabled=true;Sender.outcomes=[];ChromeAppleEvents.auditAllowed=true}
func call(deadline:Double=10,specifier:Descriptor?=Descriptor())->Descriptor? {Sender.send(specifier,to:Descriptor(),deadline:FakeDate(at:deadline),eventTimeout:0.02)}
reset();check(call() != nil && Descriptor.sends==1 && Sender.outcomes == [.resultPresent],"ordinary success sends once and reports only result-present")
reset();Sender.enabled=false;check(call()==nil && Descriptor.sends==0,"release disabled still sends nothing")
reset();ChromeAppleEvents.auditAllowed=false;check(call()==nil && Descriptor.sends==0,"specifier audit refusal still sends nothing")
reset();check(call(specifier:nil)==nil && Descriptor.sends==0,"nil specifier still sends nothing")
reset();check(call(deadline:0)==nil && Descriptor.sends==0 && Sender.outcomes == [.budgetExpired],"expired budget reports before any event")
reset();Descriptor.throwCode=Int(errAETimeout);check(call()==nil && Descriptor.sends==1 && Sender.outcomes == [.transportTimeout],"timeout distinct from replied mode with one send")
reset();Descriptor.throwCode = -1743;check(call()==nil && Descriptor.sends==1 && Sender.outcomes == [.transportFailed],"other transport error returns nil without status text")
reset();Descriptor.replyError = -1712;check(call()==nil && Descriptor.sends==1 && Sender.outcomes == [.replyFailed],"reply error still nil and separate from send exception")
reset();Descriptor.advance=2;check(call(deadline:1)==nil && Descriptor.sends==1 && Sender.outcomes == [.lateReply],"reply exceeding total budget never admitted")
reset();Descriptor.missing=true;check(call()==nil && Descriptor.sends==1 && Sender.outcomes == [.missingResult],"missing direct result never admitted")
print("PASS "+String(checks)+" executed transport outcome checks; no OS event calls")
'''
with tempfile.TemporaryDirectory(prefix='dd-qa-transport-') as tmp:
    p=Path(tmp);(p/'main.swift').write_text(swift)
    subprocess.run(['swiftc','-D','DAYDREAM_QA_HARNESS','-D','DAYDREAM_OWNER_TYPING',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
    subprocess.run([str(p/'checks')],check=True)
