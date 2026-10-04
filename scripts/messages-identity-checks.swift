import Foundation
@main struct IdentityChecks {
 static func main() {
  var count=0
  func check(_ value:Bool,_ label:String){precondition(value,label);count+=1}
  final class App {let bundle:String?,birth:Date?;init(_ bundle:String?,_ birth:Date?){self.bundle=bundle;self.birth=birth}}
  let expected="com.apple.MobileSMS",birth=Date(timeIntervalSince1970:1)
  let cases:[App?]=[nil,App(nil,nil),App("foreign",nil),App(expected,nil),App(expected,birth)]
  let labels:[MessagesIdentityIssue?]=[.applicationUnavailable,.bundleUnavailable,.bundleMismatch,.launchDateUnavailable,nil]
  for (index,app) in cases.enumerated() {
   var baseline:[String]=[],actual:[String]=[],diagnostics:[MessagesIdentityDiagnostic]=[]
   func legacy()->Bool {
    baseline.append("application");guard let app else{return false}
    baseline.append("bundle");guard app.bundle==expected else{return false}
    baseline.append("launch");guard app.birth != nil else{return false};return true
   }
   let access=MessagesProcessIdentity<App,Date>.Access(application:{_ in actual.append("application");return app},bundle:{actual.append("bundle");return $0.bundle},launch:{actual.append("launch");return $0.birth})
   let old=legacy(),new=(try? MessagesProcessIdentity<App,Date>.read(pid:7,expectedBundle:expected,access:access,observe:{diagnostics.append($0)}))
   check(old==(new != nil),"unchanged admission \(index)")
   check(baseline==actual,"exact original metadata read order/short circuit \(index)")
   check(diagnostics.first?.issue==labels[index],"precise fixed cause \(index)")
   check(diagnostics.count==(old ? 0:1),"one failure observation; no success extra reads")
   if let d=diagnostics.first {
    check(d.pidPositive,"known positive PID flag")
    check(d.applicationAvailable==(index>0),"application evaluated state")
    check(d.bundleRead==(index>0),"bundle read only after app")
    check(d.bundleAvailable==(index>1),"bundle presence known")
    check(d.bundleMatches==(index>2),"bundle exact equality")
    check(d.launchDateRead==(index>2),"launch only after positive bundle")
   } else {check(new!.1==birth,"same admitted launch identity returned")}
  }
  for pid:Int32 in [-1,0,7] {
   var seen:[MessagesIdentityDiagnostic]=[]
   let access=MessagesProcessIdentity<App,Date>.Access(application:{_ in nil},bundle:{_ in preconditionFailure("unread bundle")},launch:{_ in preconditionFailure("unread launch")})
   check((try? MessagesProcessIdentity<App,Date>.read(pid:pid,expectedBundle:expected,access:access,observe:{seen.append($0)}))==nil,"missing app rejects any pid without new admission rule")
   check(seen[0].pidPositive==(pid>0),"pid positivity is an observation")
  }
  print("\(count) Messages constructor identity/parity controls passed; no AppKit/AX/UI/input.")
 }
}
