import Foundation
import Darwin
var passed=0,failed=0
func check(_ yes:Bool,_ label:String){if yes{passed+=1}else{failed+=1;print("FAIL "+label)}}
func refused(_ label:String,_ fn:()throws->Void){do{try fn();check(false,label)}catch{check(true,label)}}
let root=URL(fileURLWithPath:"/private/tmp/daydream-capture-fixture-"+UUID().uuidString.lowercased(),isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? FileManager.default.removeItem(at:root)}
let file=root.appendingPathComponent("owned.txt")
func make(_ bytes:Data,_ mode:Int=0o600)throws{try bytes.write(to:file);try FileManager.default.setAttributes([.posixPermissions:mode],ofItemAtPath:file.path)}
try make(Data("I started a chess club note".utf8))
check(try NativeLifecycleFiles.read("owned.txt",root:root)==Data("I started a chess club note".utf8),"literal saved bytes")
refused("path traversal"){_=try NativeLifecycleFiles.read("../owned.txt",root:root)}
refused("NUL name"){_=try NativeLifecycleFiles.read("a\0b",root:root)}
refused("empty name"){_=try NativeLifecycleFiles.read("",root:root)}
refused("wrong root"){_=try NativeLifecycleFiles.read("owned.txt",root:root.deletingLastPathComponent())}
refused("bounded bytes"){_=try NativeLifecycleFiles.read("owned.txt",root:root,maximum:1)}
refused("invalid bound"){_=try NativeLifecycleFiles.read("owned.txt",root:root,maximum:65537)}
try make(Data("known".utf8),0o644)
refused("world-readable"){_=try NativeLifecycleFiles.read("owned.txt",root:root)}
try make(Data("known".utf8))
let link=root.appendingPathComponent("linked.txt")
check(Darwin.link(file.path,link.path)==0,"hardlink prepared")
refused("hardlink"){_=try NativeLifecycleFiles.read("owned.txt",root:root)}
try FileManager.default.removeItem(at:link)
let symlink=root.appendingPathComponent("symlink.txt")
try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:file)
refused("symlink"){_=try NativeLifecycleFiles.read("symlink.txt",root:root)}
let directory=root.appendingPathComponent("directory")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
refused("directory not data"){_=try NativeLifecycleFiles.read("directory",root:root)}
try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
refused("public root"){_=try NativeLifecycleFiles.read("owned.txt",root:root)}
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
let alias=URL(fileURLWithPath:"/private/tmp/daydream-capture-fixture-"+UUID().uuidString.lowercased(),isDirectory:true)
try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
defer{try? FileManager.default.removeItem(at:alias)}
refused("symlink root"){_=try NativeLifecycleFiles.read("owned.txt",root:alias)}
try make(Data())
check(try NativeLifecycleFiles.read("owned.txt",root:root).isEmpty,"empty bounded file")
check(NativeLifecycleContract.texts.map(\.count)==[26,22,27],"closed story counts")
check(NativeLifecycleContract.expectedDocument(0,final:false)==NativeLifecycleContract.texts[0],"prefix before close")
check(NativeLifecycleContract.expectedDocument(0,final:true)==NativeLifecycleContract.texts[0]+NativeLifecycleContract.texts[2],"resumed whole document")
check(NativeLifecycleContract.expectedDocument(1,final:true)==NativeLifecycleContract.texts[1],"B separate")
print("PASS \(passed) FAIL \(failed)")
if failed>0{exit(1)}
