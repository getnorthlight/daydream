import Foundation
import Darwin
@main enum FileChecks {
 @MainActor static func main() throws {
  var count=0
  func check(_ n:String,_ v:Bool){count+=1;if !v{fatalError(n)}}
  func denies(_ n:String,_ f:()throws->Void){do{try f();check(n,false)}catch{check(n,true)}}
  func make(_ action:NotesActivationContract.Action = .activate)throws->NotesActivationContract.Configuration {
    let root=NotesActivationContract.prefix+UUID().uuidString
    guard mkdir(root,0o700)==0 else{fatalError("mkdir")}
    let c=NotesActivationContract.Configuration(root:root,pid:99,start:1,seconds:5,action:action)
    let u=URL(fileURLWithPath:root).appendingPathComponent("OWNED-FIXTURE")
    try Data(c.declaration.utf8).write(to:u);guard chmod(u.path,0o600)==0 else{fatalError("chmod")};return c
  }
  let c=try make(),r=try Files.root(c);check("actual-private-root",r.path==c.root)
  let n=try make(.newNote);check("actual-new-declaration",try Files.root(n).path==n.root)
  let wrong=NotesActivationContract.Configuration(root:c.root,pid:99,start:1,seconds:5,action:.newNote);denies("action-bound-marker"){_=try Files.root(wrong)}
  let extra=try make();try Data().write(to:URL(fileURLWithPath:extra.root).appendingPathComponent("unknown"));denies("nonfresh-home"){_=try Files.root(extra)}
  let mode=try make();chmod(mode.root,0o755);denies("public-root"){_=try Files.root(mode)}
  let m=try make();chmod(m.root+"/OWNED-FIXTURE",0o644);denies("public-declaration"){_=try Files.root(m)}
  let noncanonical=NotesActivationContract.Configuration(root:c.root+"/.",pid:99,start:1,seconds:5,action:.activate);denies("noncanonical-root"){_=try Files.root(noncanonical)}
  let alias=NotesActivationContract.prefix+UUID().uuidString;guard symlink(c.root,alias)==0 else{fatalError("symlink")};let a=NotesActivationContract.Configuration(root:alias,pid:99,start:1,seconds:5,action:.activate);denies("symlink-root"){_=try Files.root(a)}
  let h=try make();guard link(h.root+"/OWNED-FIXTURE",h.root+"/hard")==0 else{fatalError("hardlink")};denies("multiply-linked-declaration"){_=try CaptureNotesMetadataInspector.file(URL(fileURLWithPath:h.root+"/OWNED-FIXTURE"),maximum:128)}
  let file=r.appendingPathComponent("OWNED-FIXTURE")
  denies("oversize"){_=try CaptureNotesMetadataInspector.file(file,maximum:1)}
  denies("directory-file"){_=try CaptureNotesMetadataInspector.file(r,maximum:128)}
  denies("missing-file"){_=try CaptureNotesMetadataInspector.file(r.appendingPathComponent("missing"),maximum:128)}
  let sym=r.appendingPathComponent("sym");guard symlink(file.path,sym.path)==0 else{fatalError("file-symlink")};denies("symlink-file"){_=try CaptureNotesMetadataInspector.file(sym,maximum:128)}
  print("PASS \(count) actual Notes preparation filesystem controls; task-owned scratch retained; no Notes/AppKit/GUI")
 }
}
