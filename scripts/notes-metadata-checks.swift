import Foundation
@main enum Checks {
 static func main() throws {
  var checks=0
  func check(_ name:String,_ value:Bool) {checks+=1;guard value else {fatalError(name)}}
  func refuses(_ name:String,_ body:()throws->Void) {do{try body();check(name,false)}catch{check(name,true)}}
  typealias C=NotesMetadataContract
  let nonce="3A96B842-06D3-4473-9DD7-7C9F5EFD0C94",root=C.prefix+nonce
  let valid=["app",C.flag,"--work-root",root,"--expected-pid","8","--seconds","30","--phase","empty"]
  let c=try C.Configuration.parse(valid);check("empty-route",c.phase == .empty)
  var args=valid;args[9]="uuid-first-line";check("first-line-route",try C.Configuration.parse(args).phase == .firstLine)
  for key in ["--input","--mode","--fixture","--store","--bundle"] {var a=valid;a[2]=key;refuses("reject-arbitrary-"+key){_=try C.Configuration.parse(a)}}
  refuses("duplicate-flag"){_=try C.Configuration.parse(valid+[C.flag])}
  var a=valid;a[4]="--work-root";refuses("duplicate-option"){_=try C.Configuration.parse(a)}
  for value in ["0","-1","999999999999"] {var a=valid;a[5]=value;refuses("invalid-pid"){_=try C.Configuration.parse(a)}}
  for value in ["nan","inf","29","91","-30"] {var a=valid;a[7]=value;refuses("invalid-duration"){_=try C.Configuration.parse(a)}}
  for value in ["/Users/test/Library/Notes",C.prefix+"../legacy",C.prefix+nonce.lowercased(),root+"/sub"] {var a=valid;a[3]=value;refuses("unsafe-root"){_=try C.Configuration.parse(a)}}
  let frame=C.Frame(x:10,y:20,width:100,height:200),new=C.Window(id:3,frame:frame)
  check("unique-new-window",try C.ownedWindow(frame,windows:[new],baseline:[1,2])==3)
  refuses("foreign-existing-window"){_=try C.ownedWindow(frame,windows:[new],baseline:[3])}
  refuses("multiple-overlapping-windows"){_=try C.ownedWindow(frame,windows:[new,.init(id:4,frame:frame)],baseline:[])}
  refuses("missing-owned-window"){_=try C.ownedWindow(frame,windows:[],baseline:[])}
  refuses("invalid-bounds"){_=try C.ownedWindow(.init(x:.nan,y:0,width:1,height:1),windows:[new],baseline:[])}
  refuses("foreign-focused-bounds"){_=try C.ownedWindow(.init(x:99,y:20,width:100,height:200),windows:[new],baseline:[])}
  check("fresh-ticket",C.freshTicket(modified:11,now:12,armed:10))
  check("old-ticket",!C.freshTicket(modified:9,now:12,armed:10))
  check("expired-ticket",!C.freshTicket(modified:11,now:14,armed:10))
  check("future-ticket",!C.freshTicket(modified:13,now:12,armed:10))
  check("NaN-ticket",!C.freshTicket(modified:.nan,now:12,armed:10))
  let budget=C.Budget(began:10,limit:100)
  check("budget-positive",budget.accepts(110));check("deadline",!budget.accepts(111));check("backward-clock",!budget.accepts(9))
  check("note-editor-role",C.editorRole("AXTextArea"))
  check("empty-search-field-refused",!C.editorRole("AXTextField"))
  check("missing-role-refused",!C.editorRole(nil))
  check("foreign-role-refused",!C.editorRole("AXWebArea"))
  check("empty-char-count",C.characters(0,phase:.empty,title:c.title))
  check("unknown-char-count",!C.characters(nil,phase:.empty,title:c.title))
  check("nonempty-refuses-empty",!C.characters(1,phase:.empty,title:c.title))
  check("own-line-character-count",C.characters(c.title.utf16.count,phase:.firstLine,title:c.title))
  check("wrong-line-count",!C.characters(0,phase:.firstLine,title:c.title))
  let missing:[C.Attribute]=[.unsupported,.absent,.text("widget"),.absent]
  check("missing-document-is-diagnostic-only",C.stable(missing,missing) && !missing[0].uri && !missing[1].uri)
  let observed:[C.Attribute]=[.text("opaque-note://instance/own"),.absent,.text("widget"),.absent]
  check("same-owned-metadata",C.stable(observed,observed))
  check("document-changed-refuses",!C.stable(observed,[.text("opaque-note://instance/other"),.absent,.text("widget"),.absent]))
  for error in [C.Attribute.transport,.wrongType,.oversized] {let row:[C.Attribute]=[error,.absent,.absent,.absent];check("typed-error-refuses",!C.stable(row,row))}
  check("malformed-uri",!C.Attribute.text("not a URI").uri)
  check("URI-syntax-not-identity",C.Attribute.text("notes://generic").uri)
  check("exact-retained-reference",C.referencesHeld(window:"w",editor:"e",currentWindow:"w",currentEditor:"e",equal:==))
  check("foreign-window-closure",!C.referencesHeld(window:"w",editor:"e",currentWindow:"other",currentEditor:"e",equal:==))
  check("foreign-editor-closure",!C.referencesHeld(window:"w",editor:"e",currentWindow:"w",currentEditor:"other",equal:==))
  print("notes_metadata_controls PASS \(checks) no_GUI_or_model_or_input=true")
 }
}
