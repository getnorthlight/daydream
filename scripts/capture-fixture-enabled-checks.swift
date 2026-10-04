import Foundation
import ApplicationServices
import Darwin
@main enum EnabledChecks {
    static func main() {
        var checks=0
        func expect(_ value:Bool,_ label:String) {checks+=1;if !value {print("FAIL "+label);exit(1)}}
        var reads=0
        func check(_ status:AXError,_ raw:CFTypeRef?=nil,_ timely:Bool=true,_ textEdit:Bool=true,_ editable:Bool?=true)->Bool {
            CaptureFixtureMetadata.enabled(status:status,raw:raw,withinDeadline:timely,textEdit:textEdit) {reads+=1;return editable}
        }
        expect(check(.attributeUnsupported),"owned TextEdit unsupported + positive editability")
        expect(reads==1,"only positive fallback reads metadata")
        reads=0
        expect(!check(.success,kCFBooleanFalse),"explicit disabled never fallback")
        expect(!check(.success,"true" as CFString),"malformed enabled never fallback")
        expect(!check(.success,nil),"missing enabled never fallback")
        expect(!check(.attributeUnsupported,nil,false),"late unsupported never fallback")
        expect(!check(.cannotComplete),"transport failure never fallback")
        expect(!check(.noValue),"no-value never fallback")
        expect(!check(.attributeUnsupported,kCFBooleanTrue),"unsupported with malformed raw never fallback")
        expect(!check(.attributeUnsupported,nil,true,false),"Claude unsupported remains refused")
        expect(reads==0,"all nonfallback refusals make zero editability reads")
        expect(!check(.attributeUnsupported,nil,true,true,false),"unsupported + uneditable refuses")
        expect(!check(.attributeUnsupported,nil,true,true,nil),"unsupported + metadata timeout refuses")
        expect(check(.success,kCFBooleanTrue,true,false),"Claude enabled stays accepted")
        expect(check(.success,kCFBooleanTrue),"TextEdit explicit enabled stays accepted")
        expect(!check(.success,kCFBooleanTrue,false),"late enabled refuses")
        print("enabled_metadata_checks=\(checks) failures=0 no_input=true no_text_acquisition=true")
    }
}
