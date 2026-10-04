import Foundation
var n=0
func check(_ b:Bool,_ why:String) { guard b else { fatalError(why) }; n+=1 }
let good=["--fixture":"chrome","--mode":"site-capture","--scenario":"x-post-draft-v1","--work-root":"/private/tmp/daydream-capture-fixture-qa","--expected-pid":"123","--input":"fixed-marker"]
check(ChromeComposerCaptureRequest.parse(good) != nil,"closed request")
for key in good.keys { var bad=good;bad.removeValue(forKey:key);check(ChromeComposerCaptureRequest.parse(bad)==nil,"missing required") }
for (key,value) in [("--scenario","other-site"),("--input","operator"),("--expected-pid","0"),("--seconds","nan"),("--seconds","46"),("--window-id","123"),("--origin","https://x.com"),("--arbitrary-text","private")]{var bad=good;bad[key]=value;check(ChromeComposerCaptureRequest.parse(bad)==nil,"closed options")}
check(ChromeComposerCaptureRequest.eligible(scenario:"x-search-v1",role:"AXComboBox",subrole:"",labels:["search"]),"actual search label")
check(!ChromeComposerCaptureRequest.eligible(scenario:"x-search-v1",role:"AXComboBox",subrole:"",labels:["address bar"]),"not omnibox")
check(!ChromeComposerCaptureRequest.eligible(scenario:"x-search-v1",role:"AXTextArea",subrole:"",labels:["search"]),"not composer")
check(!ChromeComposerCaptureRequest.eligible(scenario:"x-post-draft-v1",role:"AXTextArea",subrole:"AXSecureTextField",labels:[]),"secure refuses")
check(!ChromeComposerCaptureRequest.eligible(scenario:"x-post-draft-v1",role:"AXTextField",subrole:"",labels:[]),"single line not post")
check(ChromeComposerCaptureRequest.eligible(scenario:"chatgpt-prompt-draft-v1",role:"AXTextArea",subrole:"",labels:[]),"prompt role only candidate")
check(!ChromeComposerCaptureRequest.eligible(scenario:"other",role:"AXTextArea",subrole:"",labels:[]),"unknown site")
check(ChromeComposerCaptureRequest.destination("chatgpt-prompt-draft-v1")=="chatgpt-new-prompt","closed destination")
check(ChromeComposerCaptureRequest.bootstrapCaptureSupported("x-search-v1"),"search auto case")
check(!ChromeComposerCaptureRequest.bootstrapCaptureSupported("x-post-draft-v1"),"post whole ownership unproved")
check(!ChromeComposerCaptureRequest.bootstrapCaptureSupported("chatgpt-prompt-draft-v1"),"prompt whole ownership unproved")
check(ChromeComposerCaptureRequest.knownLeafWithoutChildren(role:"AXButton",supported:["AXRole"]),"explicit known leaf")
check(!ChromeComposerCaptureRequest.knownLeafWithoutChildren(role:"AXGroup",supported:["AXRole"]),"opaque group refuses")
check(!ChromeComposerCaptureRequest.knownLeafWithoutChildren(role:"AXWebArea",supported:["AXRole"]),"opaque page refuses")
check(!ChromeComposerCaptureRequest.knownLeafWithoutChildren(role:"AXButton",supported:["AXRole","AXChildren"]),"advertised children may not be skipped")
check(!ChromeComposerCaptureRequest.knownLeafWithoutChildren(role:"AXButton",supported:[]),"missing supportedrole refuses")
print("chrome composer bootstrap controls PASS \(n); no UI or input")
