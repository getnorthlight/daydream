import Foundation
@main struct KernelIdentityChecks {
 static func main() {
  var count=0
  func check(_ value:Bool,_ label:String){precondition(value,label);count+=1}
  final class App {
   var pid:Int32=7,terminated=false,bundle:String?="com.apple.MobileSMS",bundlePath:String?="/System/Applications/Messages.app",path:String?="/System/Applications/Messages.app/Contents/MacOS/Messages"
   var launchDate:Date?=nil
  }
  final class Fixture {
   var app:App?=App(),births:[Double?]=[1790025771.125661,1790025771.125661],signature=true,clock:UInt64=1,signatureAdvance:UInt64=0,birthSecondAdvance:UInt64=0,rewind=false
   var reads:[String]=[],issues:[MessagesKernelIdentityIssue]=[],birthIndex=0
   var access:MessagesKernelProcessIdentity<App>.Access {
    .init(now:{self.clock},birth:{_ in self.reads.append("birth");let i=self.birthIndex;self.birthIndex+=1;if i==1 {self.clock+=self.birthSecondAdvance};return self.births[min(i,self.births.count-1)]},application:{_ in self.reads.append("application");return self.app},currentPID:{self.reads.append("pid");return $0.pid},terminated:{self.reads.append("terminated");return $0.terminated},bundle:{self.reads.append("bundle");return $0.bundle},bundlePath:{self.reads.append("bundlePath");return $0.bundlePath},executablePath:{self.reads.append("path");return $0.path},signature:{_ in self.reads.append("signature");self.clock+=self.signatureAdvance;if self.rewind {self.clock=0};return self.signature})
   }
   func read(pid:Int32=7,held:MessagesKernelIdentity?=nil)->MessagesKernelIdentity? {
    try? MessagesKernelProcessIdentity<App>.read(pid:pid,held:held,deadline:100,access:access,observe:{self.issues.append($0)})
   }
  }
  for date:Date? in [nil,Date(timeIntervalSince1970:1)] {
   let f=Fixture();f.app!.launchDate=date;let id=f.read()
   check(id==MessagesKernelIdentity(pid:7,start:1790025771.125661),"positive precisekernel admits nil or present unrelated LaunchServices Date")
   check(f.reads==["birth","application","pid","terminated","bundle","bundlePath","path","signature","birth"],"full target metadata/signature kernelbracket; no Date access")
   check(f.issues.isEmpty,"no success diagnostic")
  }
  let first=Double(1790025771)+Double(125661)/1_000_000,second=Double(1790025771)+Double(125662)/1_000_000
  check(first != second,"productionformula distinguishes samesecond adjacent microseconds at actual epoch")
  check(MessagesKernelIdentity.precise(first)==first && MessagesKernelIdentity.precise(second)==second,"both exactpublic representations retained")
  check(!MessagesKernelIdentity(pid:7,start:first).matches(pid:7,start:second),"same PID+second differentmicrosecond is a new birth")
  for value:Double? in [nil,0,-1,Double.nan,Double.infinity,Double.greatestFiniteMagnitude,Double(1<<34)] {
   check(MessagesKernelIdentity.precise(value)==nil,"nil/nonpositive/nonfinite/coarsemicrosecond birth refuses")
   check(!MessagesKernelIdentity(pid:7,start:first).matches(pid:7,start:value),"unknown cannot match retained identity")
  }
  let expected=MessagesKernelIdentity(pid:7,start:first)
  let cases:[(MessagesKernelIdentityIssue,(Fixture)->Void)]=[
   (.kernelBirthUnavailable,{$0.births=[nil]}),(.kernelBirthUnusable,{$0.births=[Double.nan]}),(.kernelBirthUnusable,{$0.births=[0]}),(.kernelBirthUnusable,{$0.births=[Double(1<<34)]}),
   (.applicationUnavailable,{$0.app=nil}),(.applicationPIDMismatch,{$0.app!.pid=8}),(.terminated,{$0.app!.terminated=true}),
   (.bundleUnavailable,{$0.app!.bundle=nil}),(.bundleMismatch,{$0.app!.bundle="foreign"}),
   (.bundlePathUnavailable,{$0.app!.bundlePath=nil}),(.bundlePathMismatch,{$0.app!.bundlePath="/tmp/Messages.app"}),
   (.executablePathUnavailable,{$0.app!.path=nil}),(.executablePathMismatch,{$0.app!.path="/tmp/Messages"}),
   (.signatureUnverified,{$0.signature=false}),(.kernelBirthChanged,{$0.births=[first,second]}),(.kernelBirthChanged,{$0.births=[first,nil]}),
   (.deadline,{$0.clock=100}),(.deadline,{$0.signatureAdvance=100}),(.deadline,{$0.rewind=true}),(.deadline,{$0.birthSecondAdvance=100})]
  for (issue,mutate) in cases {
   let f=Fixture();mutate(f)
   check(f.read()==nil,"negative \(issue)");check(f.issues==[issue],"one exact refusal \(issue)")
   check(f.reads.count<=9,"bounded metadata callbacks")
  }
  for pid:Int32 in [-1,0] {
   let f=Fixture();check(f.read(pid:pid)==nil && f.issues==[.pidInvalid],"nonpositive PID rejects");check(f.reads.isEmpty,"no metadata for invalid PID")
  }
  for held in [MessagesKernelIdentity(pid:8,start:first),MessagesKernelIdentity(pid:7,start:second)] {
   let f=Fixture();check(f.read(held:held)==nil && f.issues==[.heldIdentityChanged],"retained PID/newbirth mismatch");check(f.reads==["birth"],"refuse PIDreuse before any application/ref metadata")
  }
  let good=Fixture();check(good.read(held:expected)==expected,"fresh repeated wholeidentity same kernelbirth succeeds")
  for (_,mutate) in cases {
   let f=Fixture();mutate(f);check(f.read(held:expected)==nil,"heldfullmetadata doesnotcache vendor/path/bundle/readiness")
  }
  let changing=Fixture();changing.births=[first,first,second,second]
  check(changing.read()==expected,"firstidentity passes")
  check(changing.read(held:expected)==nil && changing.issues==[.heldIdentityChanged],"next wholeidentity refuses reuse, never accepts cached firstsuccess")
  for valid in [true,false] {
   var posted=0
   let f=Fixture();let scope:()->Bool={valid}
   do {try MessagesOwnedComposerContract.postControl(ready:{f.read(held:expected)==expected},requiredScope:{scope() && expected.matches(pid:7,start:valid ? first:second)},post:{posted+=1})}catch{}
   check(posted==(valid ? 1:0),"post only after both actualwholeidentity+scope+finalfreshbirth")
  }
  for current:Double? in [nil,second,0,Double.nan] {
   var posted=0
   let f=Fixture()
   do {try MessagesOwnedComposerContract.postControl(ready:{f.read(held:expected)==expected},requiredScope:{expected.matches(pid:7,start:current)},post:{posted+=1})}catch{}
   check(posted==0,"last birth unavailable/changed/unusable cannot post after valid readiness")
  }
  let signatureChanged=Fixture();signatureChanged.signature=false;var posted=0
  do {try MessagesOwnedComposerContract.postControl(ready:{signatureChanged.read(held:expected)==expected},requiredScope:{true},post:{posted+=1})}catch{}
  check(posted==0,"forgedsign cannotpost despite safeexistingref scope")
  for (scopeTime,birthTime,allowed) in [(UInt64(0),UInt64(100_000_001),false),(60_000_000,40_000_001,false),(60_000_000,40_000_000,true),(0,0,true)] {
   var t:UInt64=1,posts=0,order:[String]=[]
   do {try MessagesOwnedComposerContract.postControl(ready:{true},requiredScope:{
    MessagesKernelControlScope.read(now:{t},scope:{order.append("scope");t+=scopeTime;return true},birth:{order.append("birth");t+=birthTime;return true},secure:{order.append("secure");return false})
   },post:{posts+=1})}catch{}
   check((posts==1)==allowed,"whole finalscope+kernel elapsed cap, exactboundary included")
   check(order==["scope","birth","secure"],"no extra scope/read after finalkernel")
  }
  var backwards:UInt64=10
  check(!MessagesKernelControlScope.read(now:{backwards},scope:{backwards=0;return true},birth:{true},secure:{false}),"finalclockrewind refuses")
  for failure in 0...2 {
   var callbacks:[String]=[]
   let allowed=MessagesKernelControlScope.read(now:{1},scope:{callbacks.append("scope");return failure != 0},birth:{callbacks.append("birth");return failure != 1},secure:{callbacks.append("secure");return failure == 2})
   check(!allowed,"scope/birth/secure refusal preserves no-post")
   check(callbacks.count==failure+1,"failedfinalpredicate doesnotcontinue callbacks")
  }
  print("\(count) kernelidentity/ref/post controls passed; synthetic no AppKit/AX/input.")
 }
}
