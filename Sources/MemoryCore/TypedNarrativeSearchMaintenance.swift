import Foundation
import CSQLite

/// A queued automatic index page never owns a store lifetime or reopens its home.
final class OriginatingSearchStore {
 weak var store:MemoryStore?
 let token=UUID()
 init(_ store:MemoryStore) {self.store=store}
}


/// Search-derived SQL only. Literal metadata keys are part of the exact statement.
/// Source, policy, disclosure, expiry and arbitrary metadata are never accepted.
enum TypedNarrativeMaintenanceScope {
 case summary,search,pendingPrepare
 var statements:Set<String> {
  switch self {case .summary:return TypedNarrativeMaintenance.statements;case .search:return Self.searchStatements;case .pendingPrepare:return TypedNarrativeNotePreparation.statements}
 }
 static let searchStatements:Set<String> = [
  "DELETE FROM search_index_state",
  "DELETE FROM metadata WHERE id IN ('search_cursor','search_endpoint','search_complete_revision','search_cycle_revision')",
  "DELETE FROM metadata WHERE id IN ('search_cursor','search_complete_revision','search_cycle_revision')",
  "INSERT OR REPLACE INTO metadata VALUES('search_endpoint',?)",
  "INSERT OR REPLACE INTO metadata VALUES('search_projection_version',?)",
  "INSERT OR REPLACE INTO metadata VALUES('search_cycle_revision',?)",
  "INSERT OR REPLACE INTO metadata VALUES('search_cursor',?)",
  "INSERT OR REPLACE INTO metadata VALUES('search_complete_revision',?)",
  "INSERT OR IGNORE INTO search_index_state VALUES(?,?)",
  "INSERT OR REPLACE INTO search_index_state VALUES(?,?)",
  "DELETE FROM search_index_state WHERE id=?"
 ]
 func permits(action:Int32,first:String?,second:String?,database:String?,source:String?,statement:String?) -> Bool {
  if self == .pendingPrepare {return TypedNarrativeNotePreparation.permits(action:action,first:first,second:second,database:database,source:source,statement:statement)}
  if self == .summary {return TypedNarrativeMaintenance.permits(action:action,first:first,second:second,database:database,source:source,statement:statement)}
  guard source == nil else {return false}
  switch action {
  case SQLITE_READ,SQLITE_SELECT,SQLITE_FUNCTION,SQLITE_RECURSIVE:return true
  case SQLITE_PRAGMA:return first == "data_version" && second == nil
  case SQLITE_INSERT,SQLITE_DELETE:
   guard database == "main",let statement,Self.searchStatements.contains(statement) else {return false}
   let verb = action == SQLITE_INSERT ? "INSERT " : "DELETE "
   guard statement.hasPrefix(verb) else {return false}
   if first == "metadata" {return statement.contains("INTO metadata ") || statement.hasPrefix("DELETE FROM metadata ")}
   return first == "search_index_state" && (statement.contains("INTO search_index_state ") || statement.hasPrefix("DELETE FROM search_index_state"))
  default:return false
  }
 }
}
