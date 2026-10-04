import Foundation
import CSQLite

/// Pending-request preparation only. Content-independent and never SQL admission.
/// Every trigger/view, unknown statement and protected mutation consumes carry.
enum TypedNarrativeNotePreparation {
 static let supersede = "UPDATE note_requests SET state='superseded',body='' WHERE state='pending' AND json_extract(body,'$.request.targetID')=?"
 static let insert = "INSERT INTO note_requests VALUES(?,?,'pending')"
 static let statements:Set<String> = [supersede,insert]
 static func permits(action:Int32,first:String?,second:String?,database:String?,source:String?,statement:String?) -> Bool {
  guard source == nil else {return false}
  switch action {
  case SQLITE_READ,SQLITE_SELECT,SQLITE_FUNCTION,SQLITE_RECURSIVE:return true
  case SQLITE_PRAGMA:return first == "data_version" && second == nil
  case SQLITE_INSERT:return database == "main" && first == "note_requests" && second == nil && statement == insert
  case SQLITE_UPDATE:return database == "main" && first == "note_requests" && ["state","body"].contains(second ?? "") && statement == supersede
  default:return false
  }
 }
}
