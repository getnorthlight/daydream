import Foundation
@main enum Checks {
 static func main() throws {
  var count=0
  func check(_ b:Bool,_ name:String) {count+=1;if !b {fatalError(name)}}
  let root=NotesActivationContract.prefix+"01234567-89AB-CDEF-0123-456789ABCDEF"
  let a=["qa",NotesActivationContract.flag,"--work-root",root,"--expected-pid","99","--expected-start","123.25","--seconds","5","--action","activate"]
  check(try NotesActivationContract.Configuration.parse(a).action == .activate,"activate")
  var n=a;n[11]="new-note";check(try NotesActivationContract.Configuration.parse(n).declaration=="notes-activation-fixed-command-v1|new-note\n","new declaration")
  let changes=[(1,"--capture-fixture-trial"),(3,"/tmp/other"),(3,root.lowercased()),(5,"0"),(5,"-1"),(7,"nan"),(7,"infinity"),(7,"0"),(9,"1"),(9,"11"),(11,"typing"),(10,"--input"),(6,"--expected-pid")]
  for(i,v) in changes {var b=a;b[i]=v;check((try? NotesActivationContract.Configuration.parse(b))==nil,"reject argument \(i) \(v)")}
  check((try? NotesActivationContract.Configuration.parse(a+["--input","fixed-marker"]))==nil,"reject extra input")
  for pid in [Int32(0),Int32(98)] {check(!NotesActivationContract.foreground(expected:99,actual:pid),"foreign foreground")}
  check(!NotesActivationContract.foreground(expected:99,actual:nil),"missing foreground")
  check(NotesActivationContract.foreground(expected:99,actual:99),"same foreground")
  func identity(_ path:String?=NotesActivationContract.executablePath,_ bundle:String?=NotesActivationContract.bundle,_ pid:Int32=99,_ birth:Double?=123.25)->Bool {NotesActivationContract.identity(pid:99,start:123.25,path:path,bundle:bundle,currentPID:pid,currentStart:birth)}
  check(identity(),"exact identity")
  check(!identity("/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"),"foreign path")
  check(!identity(nil),"missing path")
  check(!identity(NotesActivationContract.executablePath,"com.apple.TextEdit"),"foreign bundle")
  check(!identity(NotesActivationContract.executablePath,NotesActivationContract.bundle,98),"foreign pid")
  check(!identity(NotesActivationContract.executablePath,NotesActivationContract.bundle,99,123.26),"reused pid")
  check(!identity(NotesActivationContract.executablePath,NotesActivationContract.bundle,99,nil),"unknown birth")
  check(NotesActivationContract.staticFile(role:"AXMenuBarItem",title:"File",position:2),"fixed File")
  check(!NotesActivationContract.staticFile(role:"AXMenuBarItem",title:"Private title",position:2),"unknown File label")
  check(!NotesActivationContract.staticFile(role:"AXMenuItem",title:"File",position:2),"wrong File role")
  check(!NotesActivationContract.staticFile(role:"AXMenuBarItem",title:"File",position:1),"wrong File index")
  check(NotesActivationContract.command(character:"n",modifiers:0),"default Command")
  for m in [1,2,4,8,16,-1] {check(!NotesActivationContract.command(character:"n",modifiers:m),"reject modifiers")}
  check(!NotesActivationContract.command(character:nil,modifiers:0),"missing char")
  check(!NotesActivationContract.command(character:"N",modifiers:0),"wrong char")
  check(!NotesActivationContract.command(character:"n",modifiers:nil),"missing modifiers")
  check((try? NotesActivationContract.unique([]))==nil,"missing command")
  check((try? NotesActivationContract.unique([1,2]))==nil,"ambiguous command")
  check(try NotesActivationContract.unique([4])==4,"unique command")
  func command(_ title:String?="New Note",_ role:String?="AXMenuItem",_ enabled:Bool=true,_ press:Bool=true)->Bool {NotesActivationContract.staticNew(role:role,title:title,character:"n",modifiers:0,enabled:enabled,press:press)}
  check(command(),"fixed New")
  check(!command("Previous draft"),"unknown candidate label")
  check(!command(nil),"missing candidate label")
  check(!command("New Note","AXTextArea"),"editor is not command")
  check(!command("New Note","AXMenuItem",false),"disabled")
  check(!command("New Note","AXMenuItem",true,false),"no press")
  let d=NotesActivationContract.Deadline(began:100,limit:10)
  check(d.accepts(110),"deadline boundary")
  check(!d.accepts(111),"expired")
  check(!d.accepts(99),"backwards clock")
  check(NotesActivationContract.focused(expected:99,workspace:99,system:99),"both fresh focus")
  check(!NotesActivationContract.focused(expected:99,workspace:99,system:98),"cached workspace mismatch live focus")
  check(!NotesActivationContract.focused(expected:99,workspace:98,system:99),"workspace mismatch")
  check(!NotesActivationContract.focused(expected:99,workspace:99,system:nil),"unknown live focus")
  check(NotesActivationContract.candidatePosition(0),"fixed new index")
  check(!NotesActivationContract.candidatePosition(1),"dynamic command elsewhere")
  check(NotesActivationContract.references([1,2,3,4],[1,2,3,4],equal:==),"retained references")
  for i in 0..<4 {var b=[1,2,3,4];b[i]=9;check(!NotesActivationContract.references([1,2,3,4],b,equal:==),"changed reference")}
  check(!NotesActivationContract.references([1,2,3,4],[],equal:==),"missing reference")
  print("PASS \(count) Notes activation contracts; no AppKit/UI/permission/input/store/model")
 }
}
