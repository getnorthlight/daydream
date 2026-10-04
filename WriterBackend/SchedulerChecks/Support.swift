import Foundation
// Standalone fixture aliases only. Production target compilation separately verifies imports.
public enum WriterFailure:Error {case invalidInput,unavailable,denied,invalidOutput,capacity,integrity,incompatible,busy}
public struct WriterTarget:Sendable {
    public enum Kind:String,Sendable {case activity,day}
    public let kind:Kind,day:String,timezone:String,activityID:String?
    public init(kind:Kind,day:String,timezone:String,activityID:String?=nil) {self.kind=kind;self.day=day;self.timezone=timezone;self.activityID=activityID}
}
