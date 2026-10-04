import Foundation
import ApplicationServices
import PrivacyPolicy
import Darwin
@main enum WorkflowChecks {
 static func main() throws {
  var count=0;var roots=[URL]()
  defer {for root in roots {try? FileManager.default.removeItem(at:root)}}
  func expect(_ value:Bool,_ label:String) {count+=1;if !value {print("FAIL "+label);exit(1)}}
  func rejects(_ body:() throws -> Void)->Bool {do {try body();return false}catch{return true}}
  func make() throws -> URL {
   let root=URL(fileURLWithPath:"/private/tmp/daydream-capture-fixture-workflow-checks-"+UUID().uuidString,isDirectory:true)
   try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);roots.append(root)
   let marker=root.appendingPathComponent("OWNED-FIXTURE");try Data(CaptureFixtureKind.textEditWorkflow.declaration.utf8).write(to:marker)
   try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:marker.path)
   for name in CaptureWorkflowContract.names(root) {let file=root.appendingPathComponent(name);try Data().write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
   return root
  }
  expect(CaptureWorkflowContract.retryableScopeCode("focusDocument"),"document settling may retry metadata")
  expect(CaptureWorkflowContract.retryableScopeCode("focusField"),"field settling may retry metadata")
  expect(!CaptureWorkflowContract.retryableScopeCode("secureInput"),"secure input refuses immediately")
  expect(!CaptureWorkflowContract.retryableScopeCode("permissionAX"),"AX permission loss refuses immediately")
  expect(!CaptureWorkflowContract.retryableScopeCode("permissionListen"),"listen permission loss refuses immediately")
  expect(!CaptureWorkflowContract.retryableScopeCode("pidMatch"),"unexpected process refuses immediately")
  expect(CaptureWorkflowContract.scopeFixture == .textEdit,"workflow scopes use ordinary TextEdit enabled fallback")
  expect(CaptureFixtureMetadata.enabled(status:.attributeUnsupported,raw:nil,withinDeadline:true,textEdit:CaptureWorkflowContract.scopeFixture == .textEdit,editable:{true}),"workflow unsupported enabled + editable accepted")
  expect(!CaptureFixtureMetadata.enabled(status:.success,raw:kCFBooleanFalse,withinDeadline:true,textEdit:true,editable:{true}),"disabled workflow field refused")
  expect(!CaptureFixtureMetadata.enabled(status:.success,raw:"true" as CFString,withinDeadline:true,textEdit:true,editable:{true}),"malformed workflow enabled refused")
  expect(!CaptureFixtureMetadata.enabled(status:.attributeUnsupported,raw:nil,withinDeadline:false,textEdit:true,editable:{true}),"late workflow enabled refused")
  expect(!CaptureFixtureMetadata.enabled(status:.attributeUnsupported,raw:nil,withinDeadline:true,textEdit:false,editable:{true}),"Claude unsupported enabled stays refused")
  expect(CaptureWorkflowContract.fixedUSKeyboard(inputID:"com.apple.keylayout.US",layoutID:"com.apple.keylayout.US",flags:[]),"literal US layout accepted")
  expect(!CaptureWorkflowContract.fixedUSKeyboard(inputID:"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",layoutID:"com.apple.keylayout.US",flags:[]),"IME over US layout refused")
  expect(!CaptureWorkflowContract.fixedUSKeyboard(inputID:"com.apple.keylayout.French",layoutID:"com.apple.keylayout.French",flags:[]),"non US key mapping refused")
  expect(!CaptureWorkflowContract.fixedUSKeyboard(inputID:"com.apple.keylayout.US",layoutID:"com.apple.keylayout.US",flags:.maskAlphaShift),"caps lock refuses literal input")
  expect(!CaptureWorkflowContract.fixedUSKeyboard(inputID:"com.apple.keylayout.US",layoutID:"com.apple.keylayout.US",flags:.maskCommand),"held command refuses literal input")
  expect(CaptureWorkflowContract.Scenario(rawValue:"arbitrary user text") == nil,"arbitrary scenario refused")
  let manifestURL=URL(fileURLWithPath:CommandLine.arguments[1])
  let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
  let cases=manifest["cases"] as! [[String:Any]]
  expect(cases.count==CaptureWorkflowContract.Scenario.allCases.count,"manifest enumerates only compiled cases")
  for scenario in CaptureWorkflowContract.Scenario.allCases {
   let record=cases.first {$0["caseID"] as? String == scenario.rawValue}!
   expect(record["fixedTextPerVisit"] as? [String] == scenario.texts,"actual compiled story matches external oracle")
   expect(record["expectedPostedPerVisit"] as? [Int] == scenario.operations.map(\.count),"actual OS operation counts match oracle")
   var assembled=["","",""]
   for (index,operations) in scenario.operations.enumerated() {
    for operation in operations {switch operation {case .character(let c):assembled[index].append(c);case .backspace:if !assembled[index].isEmpty {assembled[index].removeLast()}}}
   }
   expect(assembled == scenario.texts,"correction produces expected full story")
   expect((record["expectedTextByContext"] as? [String:String]) == ["A":scenario.alpha,"B":scenario.texts[1]],"complete A and separate B exact oracle")
  }
  expect(CaptureWorkflowContract.Scenario.correctedMorning.operations[0].suffix(2) == [.character("x"),.backspace],"actual correction is glyph then Backspace")
  expect(CaptureWorkflowContract.Scenario.morning.alpha.contains("chess club") && CaptureWorkflowContract.Scenario.morning.alpha.contains("vote and support"),"meaningful subject retained across interrupted source")
  let exactShape=CaptureWorkflowContract.shape("alpha draft starts and finishes here",expectedPrefix:"alpha draft starts")
  expect(exactShape.prefixCaseExact && !exactShape.prefixCaseOnly && exactShape.expectedPrefixOccurrences==1,"exact source shape")
  expect(exactShape.characters==36 && exactShape.utf8Bytes==36,"exact source counts")
  let casedShape=CaptureWorkflowContract.shape("Alpha draft starts",expectedPrefix:"alpha draft starts")
  expect(casedShape.prefixCaseOnly && !casedShape.prefixCaseExact,"case-only difference identified without changing oracle")
  let duplicatedShape=CaptureWorkflowContract.shape("alpha draft startsalpha draft starts",expectedPrefix:"alpha draft starts")
  expect(duplicatedShape.expectedPrefixOccurrences==2 && duplicatedShape.metadata["duplicateExpectedPrefix"] as? Bool == true,"duplicate snapshot identified")
  let outerShape=CaptureWorkflowContract.shape(" about the vote and support ",expectedPrefix:" about")
  expect(outerShape.leadingASCIISpace && outerShape.trailingASCIISpace,"literal outer ASCII-space shape")
  let unicodeShape=CaptureWorkflowContract.shape("\u{00A0}about\u{00A0}",expectedPrefix:"about")
  expect(!unicodeShape.leadingASCIISpace && !unicodeShape.trailingASCIISpace && unicodeShape.utf8Bytes>unicodeShape.characters,"Unicode whitespace not mislabeled ASCII")
  let absentShape=CaptureWorkflowContract.shape("other fictional text",expectedPrefix:"alpha draft starts")
  expect(!absentShape.prefixCaseExact && !absentShape.prefixCaseOnly && absentShape.expectedPrefixOccurrences==0,"other content not labeled capitalization")
  let emptyShape=CaptureWorkflowContract.shape("",expectedPrefix:"alpha")
  expect(emptyShape.characters==0 && emptyShape.expectedPrefixOccurrences==0,"empty captured shape explicit")
  expect(CaptureWorkflowContract.shape("alpha",expectedPrefix:"").expectedPrefixOccurrences==0,"empty expected prefix does not manufacture duplicates")
  let allowedShapeKeys:Set<String>=["characters","utf8Bytes","leadingASCIISpace","trailingASCIISpace","prefixCaseExact","prefixCaseOnly","expectedPrefixOccurrences","duplicateExpectedPrefix"]
  expect(Set(exactShape.metadata.keys)==allowedShapeKeys && exactShape.metadata.values.allSatisfy {$0 is Int || $0 is Bool},"diagnostic emits fixed numeric/Boolean fields only")
  let root=try make()
  expect(try CaptureFixtureTrial.checkedRoot(root.path,fixture:.textEditWorkflow)==root,"exact fresh pair accepted")
  expect(CaptureWorkflowContract.names(root).count==2 && Set(CaptureWorkflowContract.names(root)).count==2,"two distinct owned names")
  expect(CaptureWorkflowContract.documents==[0,1,0],"actual visit sequence A B A")
  expect(CaptureWorkflowContract.texts.count==3 && CaptureWorkflowContract.texts.allSatisfy {!$0.contains("\\n") && !$0.contains("\\r")},"fixed unsent texts no Return")
  expect(CaptureWorkflowContract.alpha==CaptureWorkflowContract.texts[0]+CaptureWorkflowContract.texts[2],"expected alpha resumes full draft")
  let nonempty=try make();try Data("fictional unsent text".utf8).write(to:nonempty.appendingPathComponent(CaptureWorkflowContract.names(nonempty)[1]))
  expect(rejects {_ = try CaptureFixtureTrial.checkedRoot(nonempty.path,fixture:.textEditWorkflow)},"existing B draft refused")
  let missing=try make();try FileManager.default.removeItem(at:missing.appendingPathComponent(CaptureWorkflowContract.names(missing)[0]))
  expect(rejects {_ = try CaptureFixtureTrial.checkedRoot(missing.path,fixture:.textEditWorkflow)},"missing A refused")
  let extra=try make();try Data().write(to:extra.appendingPathComponent("user-document.txt"))
  expect(rejects {_ = try CaptureFixtureTrial.checkedRoot(extra.path,fixture:.textEditWorkflow)},"third document refused")
  let replay=try make();try Data().write(to:replay.appendingPathComponent("capture-fixture-receipt.jsonl"))
  expect(rejects {_ = try CaptureFixtureTrial.checkedRoot(replay.path,fixture:.textEditWorkflow)},"receipt no replay")
  let linked=try make(),source=linked.appendingPathComponent(CaptureWorkflowContract.names(linked)[0]),target=linked.appendingPathComponent(CaptureWorkflowContract.names(linked)[1])
  try FileManager.default.removeItem(at:target);try FileManager.default.createSymbolicLink(at:target,withDestinationURL:source)
  expect(rejects {_ = try CaptureFixtureTrial.checkedRoot(linked.path,fixture:.textEditWorkflow)},"symlink B refused")
  let publicFile=try make();try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:publicFile.appendingPathComponent(CaptureWorkflowContract.names(publicFile)[1]).path)
  expect(rejects {_ = try CaptureFixtureTrial.checkedRoot(publicFile.path,fixture:.textEditWorkflow)},"nonprivate B refused")
  let a:Set<String>=["a-first","a-resume"],b:Set<String>=["b"]
  let good=CaptureWorkflowContract.grouping(actionIDs:[a,b],moments:[a,b])
  expect(good.alphaConnected && good.betaSeparate,"actual A actions connected with B separate")
  let fragmented=CaptureWorkflowContract.grouping(actionIDs:[a,b],moments:[["a-first"],["a-resume"],b])
  expect(!fragmented.alphaConnected && fragmented.betaSeparate,"real A fragmentation detected")
  let crossed=CaptureWorkflowContract.grouping(actionIDs:[a,b],moments:[a.union(b)])
  expect(crossed.alphaConnected && !crossed.betaSeparate,"A B overmerge detected")
  let overlap=CaptureWorkflowContract.grouping(actionIDs:[a,a],moments:[a])
  expect(!overlap.alphaConnected && !overlap.betaSeparate,"ambiguous source attribution refused")
  let absent=CaptureWorkflowContract.grouping(actionIDs:[[],b],moments:[b])
  expect(!absent.alphaConnected,"missing A never connected")
  var proof=FocusProof();proof.bundle="com.apple.TextEdit";proof.surface = .native
  expect(CaptureFixtureKind.textEditWorkflow.accepts(proof),"workflow retains native TextEdit surface")
  proof.surface = .embeddedWeb;expect(!CaptureFixtureKind.textEditWorkflow.accepts(proof),"workflow rejects embedded web")
  print("workflow_contract_checks=\(count) failures=0 no_input=true no_user_history=true")
 }
}
