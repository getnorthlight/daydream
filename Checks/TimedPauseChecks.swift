import Foundation
import MemoryCore

func runTimedPauseChecks() throws {
    let now=Date(timeIntervalSince1970:1800000000)
    var pause=TimedPause()
    for minutes in [5,15,30,120] {
        let ticket=pause.begin(minutes:minutes,wasRecording:true,now:now)!
        try check(ticket.deadline == now.addingTimeInterval(Double(minutes)*60),"pause duration \(minutes) minutes")
        try check(!pause.expire(ticket,now:now,permitted:true,replacementSafe:true,awake:true),"pause does not expire early")
        try check(pause.expire(ticket,now:ticket.deadline,permitted:true,replacementSafe:true,awake:true),"safe expiry resumes once")
        try check(!pause.expire(ticket,now:ticket.deadline,permitted:true,replacementSafe:true,awake:true),"duplicate expiry rejected")
    }
    try check(pause.begin(minutes:5,wasRecording:false,now:now) == nil,"stopped capture cannot arm resume")
    for reason in ["stop","resume early","replacement","quit","sleep","permission loss","error","privacy change"] {
        let ticket=pause.begin(minutes:5,wasRecording:true,now:now)!
        pause.cancel()
        try check(!pause.expire(ticket,now:ticket.deadline,permitted:true,replacementSafe:true,awake:true),reason+" cancels stale callback")
    }
    let first=pause.begin(minutes:5,wasRecording:true,now:now)!
    let second=pause.begin(minutes:15,wasRecording:true,now:now)!
    try check(!pause.expire(first,now:first.deadline,permitted:true,replacementSafe:true,awake:true),"another pause replaces old ticket")
    try check(pause.ticket == second,"stale callback cannot consume replacement ticket")
    for guards in [(false,true,true),(true,false,true),(true,true,false)] {
        let ticket=pause.begin(minutes:5,wasRecording:true,now:now)!
        try check(!pause.expire(ticket,now:ticket.deadline,permitted:guards.0,replacementSafe:guards.1,awake:guards.2),"failed expiry prerequisite refuses capture")
        try check(pause.ticket == nil,"failed expiry never retries after prerequisite restored")
    }
    // Saturday test issue 11: a timed pause must end by itself. A timer held back by a busy main thread, an
    // open menu or App Nap still resumes, once.
    for lateBy in [6.0,20,90,600] {
        let late=pause.begin(minutes:5,wasRecording:true,now:now)!
        try check(pause.expire(late,now:late.deadline.addingTimeInterval(lateBy),permitted:true,replacementSafe:true,awake:true),"late expiry (\(Int(lateBy)) s) still resumes")
        try check(!pause.expire(late,now:late.deadline.addingTimeInterval(lateBy+1),permitted:true,replacementSafe:true,awake:true),"late expiry resumes once")
    }
    pause=TimedPause()
    try check(pause.ticket == nil,"restart has no persisted resume intent")
    let home=FileManager.default.temporaryDirectory.appendingPathComponent("macmem-stop-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:home)}
    let store=try MemoryStore(home:home,writable:true)
    let capture=try CaptureSession(store:store)
    try capture.start(permitted:true,now:now); try capture.stop(now:now)
    try check(try store.captureStatus(now:now)["state"] == "off","Stop persists OFF, not a misleading paused state")
    try capture.health(permitted:true,now:now.addingTimeInterval(7200))
    try check(capture.state == "off","Stop remains OFF after time and permission restoration")
}
