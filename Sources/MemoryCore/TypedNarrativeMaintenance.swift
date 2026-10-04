import Foundation
import CSQLite

/// Content-independent classification of writePending's fixed derivation statements.
/// Does not grant SQL access: the observer always permits the original database action.
enum TypedNarrativeMaintenance {
 static let queueTriggers:Set<String> = ["summary_queue_record_insert","summary_queue_record_update","summary_queue_summary_delete","summary_queue_summary_update"]
 static let statements:Set<String> = [
  "DELETE FROM typed_recipients WHERE id NOT IN (SELECT id FROM typed_text)",
  "INSERT OR REPLACE INTO summaries VALUES(?,'{}',?)",
  "INSERT OR REPLACE INTO summaries VALUES(?,?,?)",
  "DELETE FROM summary_queue",
  "INSERT OR IGNORE INTO summary_queue VALUES(?)",
  "DELETE FROM summary_queue WHERE id=?",
  "CREATE TEMP TABLE IF NOT EXISTS summary_queue(id TEXT PRIMARY KEY)",
  "CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_record_insert AFTER INSERT ON main.records BEGIN INSERT OR IGNORE INTO summary_queue VALUES(new.id); END",
  "CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_record_update AFTER UPDATE ON main.records BEGIN INSERT OR IGNORE INTO summary_queue VALUES(new.id); END",
  "CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_summary_delete AFTER DELETE ON main.summaries BEGIN INSERT OR IGNORE INTO summary_queue VALUES(old.id); END",
  "CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_summary_update AFTER UPDATE ON main.summaries BEGIN INSERT OR IGNORE INTO summary_queue VALUES(old.id); INSERT OR IGNORE INTO summary_queue VALUES(new.id); END"
 ]
 static func permits(action:Int32,first:String?,second:String?,database:String?,source:String?,statement:String?) -> Bool {
  if let source,!queueTriggers.contains(source) {return false}
  switch action {
  case SQLITE_READ,SQLITE_SELECT,SQLITE_FUNCTION,SQLITE_RECURSIVE: return true
  case SQLITE_PRAGMA: return first == "data_version" && second == nil
  case SQLITE_INSERT,SQLITE_UPDATE,SQLITE_DELETE:
   guard let statement,statements.contains(statement) else {return false}
   if database == "temp",first == "summary_queue" {return true}
   if action == SQLITE_DELETE,database == "main",first == "typed_recipients",statement == "DELETE FROM typed_recipients WHERE id NOT IN (SELECT id FROM typed_text)" {return true}
   if database == "main",first == "summaries",statement.hasPrefix("INSERT OR REPLACE INTO summaries ") {return true}
   // SQLite also reports main.sqlite_master INSERT while authorizing a TEMP trigger on main tables.
   // This exact CREATE TEMP statement is the only accepted main schema action.
   if action == SQLITE_INSERT, database == "main",first == "sqlite_master",statement.hasPrefix("CREATE TEMP TRIGGER IF NOT EXISTS ") {return true}
   return database == "temp" && ["sqlite_master","sqlite_temp_master"].contains(first ?? "") && statement.hasPrefix("CREATE TEMP ")
  case SQLITE_CREATE_TEMP_INDEX:
   return first == "sqlite_autoindex_summary_queue_1" && second == "summary_queue" && database == "temp" && statement == "CREATE TEMP TABLE IF NOT EXISTS summary_queue(id TEXT PRIMARY KEY)"
  case SQLITE_CREATE_TEMP_TABLE,SQLITE_CREATE_TEMP_TRIGGER:
   return statement.map{statements.contains($0) && $0.hasPrefix("CREATE TEMP ")} == true
  default: return false
  }
 }
}
