// The Chrome page history release switch (ReleaseFeatures.chromePageHistory), end to end.
// scripts/honesty-switch-off-checks.sh compiles this file twice with the capture sources
// (EventCapture, Coordinator, ChromePageRecorder, ChromeEventSender, ...):
//   - against a copy of the tree with the switch set to false: Chrome page history must be gone;
//   - against the normal build (switch on) as a control: the same fakes do see the page reads,
//     so a zero count in the switch-off build means something.
// A fake ChromePageEnvironment stands in for every Chrome call; the live one is never used.
// ChromeEventSender itself is called only in the switch-off build, where every entry point
// must return before building an event or asking macOS (the pid is never a real process).
// No capture tap, permission request, app launch, signing or Apple Event.
import AppKit
import Foundation
import ApplicationServices
import HistoryCore
import MemoryCore
import MemoryUI
import PrivacyPolicy

@main struct HonestySwitchChecks {
    static var passed=0
    static func check(_ condition:Bool,_ name:String) {
        guard condition else {
            fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); exit(1)
        }
        passed+=1; print("PASS: "+name); fflush(stdout)
    }
    static func main() throws {
        setbuf(stdout,nil)
        let off = !ReleaseFeatures.chromePageHistory
        let expectOff = CommandLine.arguments.contains("--expect-off")
        check(off == expectOff, "switch: this build has Chrome page history \(off ? "off" : "on"), as the script expects")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("honesty-switch-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}

        // 1. Settings: a saved "on" does not count in a release without page history.
        var saved=PrivacySettings(); saved.browserPages=true; saved.browserPagesConsentVersion=1
        check(saved.browserPagesOn == !off, "settings: a saved Web pages in Chrome choice is \(off ? "ignored" : "honoured")")
        let decoded=try JSONDecoder().decode(PrivacySettings.self, from:JSONEncoder().encode(saved))
        check(decoded.browserPages && decoded.browserPagesOn == !off, "settings: the saved choice is kept on disk and counts only when the release has page history")

        // 2. Intake: a Chrome page row is refused before it reaches the store.
        let now=Date()
        var proof=BrowserVerification(mode:"normal",windowID:"1",tabID:"2",focusedRole:"",checkedAt:isoPrecise(now),provider:BrowserSafety.pageProvider)
        proof.policyRevision="policy-fixture"
        let page=Evidence(id:"page",at:isoPrecise(now),kind:"window.changed",app:"Google Chrome",bundle:"com.google.Chrome",title:"Fabricated plan",url:"https://example.org",browserVerification:proof)
        if off {
            check(!CaptureSession.accepts(page,focusedFieldKnown:true,settings:saved,now:now), "intake: a Chrome page row is refused with the switch off, even with the saved choice on")
        }

        // 3. The recorder, through the real EventCapture and Coordinator, with a fake environment.
        let store=try MemoryStore(home:root.appendingPathComponent("pages"),writable:true,automaticallySyncSearch:false)
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        let chrome:pid_t=99_999 // above macOS's highest pid: never a real process
        var verifies=0,permissions=0,sessions=0,requests=0
        var timers:[(at:Date,work:()->Void)]=[]
        let environment=ChromePageEnvironment(
            frontmost:{(chrome,"com.google.Chrome","99999:1:com.google.Chrome","Google Chrome")},instances:{1},secureInput:{false},
            verify:{_,_ in verifies+=1;return true},
            permission:{_ in permissions+=1;return noErr},
            transport:{_ in
                sessions+=1
                return {request in
                    requests+=1
                    switch request {
                    case .windowIDs:return .ids(["w1"])
                    case .mode:return .text("normal")
                    case .activeTabID:return .text("t1")
                    case .tabURL:return .text("https://example.org/plan")
                    case .tabTitle:return .text("Fabricated plan")
                    }
                }
            },
            background:{$0()},main:{$0()},
            schedule:{delay,work in timers.append((Date().addingTimeInterval(delay),work))},
            now:{Date()},idleSeconds:{0})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:EventCapture.TypingEnvironment(proof:{_,_ in nil},schedule:{_,_ in}),pageEnvironment:environment)
        var p=try store.policy(); p.browserPages=true; p.browserPagesConsentVersion=1; try store.updatePolicy(p)
        try coordinator.start()
        capture.switchFrontmost(pid:chrome,bundle:"com.google.Chrome") {_,_ in}
        for _ in 0..<12 {capture.pages.tick()}
        capture.handleAX(kAXTitleChangedNotification as String)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        Thread.sleep(forTimeInterval:1.3)
        while let i=timers.indices.filter({timers[$0].at<=Date()}).first {timers.remove(at:i).work()}
        let rows=try store.actions(limit:50).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome"}
        if off {
            check(capture.pages.probes == 0 && verifies == 0 && permissions == 0 && sessions == 0 && requests == 0 && rows.isEmpty,
                  "recorder: switch off with the saved choice on: no read, no signature, Automation or Apple Event call, no row")
            check(!capture.pages.pathActive("com.google.Chrome"), "recorder: the Chrome page path is never active")
        } else {
            check(capture.pages.probes > 0 && permissions > 0 && sessions > 0 && requests > 0 && !rows.isEmpty,
                  "control: with the switch on the same fakes see the reads and a row is saved (the zero counts above are meaningful)")
        }
        coordinator.stop()

        // 4. The one Apple Event sender refuses everything when the switch is off.
        if off {
            check(kill(chrome,0) == -1 && errno == ESRCH, "sender: the fixture pid is not a running process")
            let dead=NSAppleEventDescriptor(processIdentifier:chrome)
            check(ChromeEventSender.permissionStatus(pid:chrome) == ChromeEventSender.switchedOff && ChromeEventSender.switchedOff == OSStatus(errAEEventNotPermitted),
                  "sender: the Automation status is 'not permitted' without asking macOS")
            check(ChromeEventSender.askForChromeAccess(pid:chrome) == ChromeEventSender.switchedOff, "sender: Allow never shows the macOS prompt")
            check(!ChromeEventSender.permission(pid:chrome), "sender: Chrome access reads as not allowed")
            check(ChromeEventSender.pageTransport(pid:chrome)(.windowIDs) == nil, "sender: a page read returns nothing")
            check(ChromeEventSender.send(ChromePageRequest.windowIDs.specifier,to:dead,deadline:Date().addingTimeInterval(1),eventTimeout:0.1) == nil,
                  "sender: send returns nothing")
            check(!ChromeEventSender.signatureValid(pid:getpid()), "sender: no signature check runs")
        }

        // 5. What people and AI apps are told.
        if off {
            check(!AssistantCatalog.instructions.contains("Chrome") && AssistantCatalog.instructions.contains("(web browsers are not recorded)"),
                  "AI apps: the instructions say web browsers are not recorded and never mention Chrome pages")
            check(CaptureSession.recordingReason.contains("Web browsers are skipped") && !CaptureSession.recordingReason.contains("Chrome"),
                  "status: the recording line says web browsers are skipped")
            check(SettingsAppsContent.group("com.google.Chrome",excluded:[],browserPages:true) == .notRecorded
                  && SettingsAppsContent.subtitle("com.google.Chrome",group:.notRecorded) == nil
                  && SettingsAppsContent.browserLabel("com.google.Chrome") == SettingsAppsContent.notRecordedLabel,
                  "Settings: Google Chrome is listed as Not recorded in this version, with no page history line")
            // fix/setup-tweaks: the apps page has no footnote any more; its typing line names no Chrome pages.
            check(!DaydreamAppsContent.typingSwitchTitle.contains("Chrome"), "setup: the apps page doesn't offer Chrome pages")
            // ux/declutter: Settings › Advanced no longer repeats a browsers card; Apps to remember lists every
            // browser, Chrome included, under "Web browsers" as not recorded in this version.
            check(SettingsAppsContent.group("com.apple.Safari",excluded:[]) == .notRecorded
                  && SettingsAppsContent.AppGroup.notRecorded.rawValue == "Web browsers"
                  && SettingsAppsContent.browserLabel("com.apple.Safari") == SettingsAppsContent.notRecordedLabel
                  && !SettingsAppsContent.notRecordedLabel.contains("Chrome"),
                  "Settings › Apps to remember: web browsers read Not recorded in this version, never Chrome pages")
        } else {
            check(ChromePagesCard.title == "Web pages in Chrome" && ChromePagesCard.offDetail.hasPrefix("Off.")
                  && ChromePagesCard.explanation.contains { $0.contains("doesn't know by name is skipped too") },
                  "control: with the switch on, Apps to remember shows the Web pages in Chrome card, off by default, with the unknown-browser line")
            check(SettingsAppsContent.group("com.google.Chrome",excluded:[],browserPages:true) == .included
                  && SettingsAppsContent.browserLabel("com.google.Chrome") == SettingsAppsContent.chromeOffLabel,
                  "control: with the switch on Chrome is included while its pages are on, and reads Off otherwise")
        }
        print("\(passed) release switch checks passed (Chrome page history \(off ? "off" : "on")). No Apple Event, tap or prompt.")
    }
}
