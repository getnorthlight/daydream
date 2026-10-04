import Foundation
import Darwin
import MemoryCore
import BackupRestore

// Only the signed app invokes this helper. No network listener or ambient store.
struct Request: Decodable {
    var operation: String
    var source: String
    var destination: String?
    var backup: String?
    var manifestSHA256: String?
    var build: String?
    var version: String?
    var prepared: BackupPrepared?
    var confirmed: Bool?
}
func emit<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= CanonicalBackupBounds.messageBytes else { throw BackupFailure.limit }
    FileHandle.standardOutput.write(data)
}
func url(_ path: String?) throws -> URL {
    guard let path, path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw BackupFailure.invalid }
    return URL(fileURLWithPath: path)
}
do {
    // Hard fallback even if launched without the app supervisor: just past the supervisor's own deadline, and room
    // for a backup of the whole history (these were 60 s, 30 s of CPU and 160 MiB: about two weeks of use, G29).
    let seconds = UInt32(CanonicalBackupBounds.seconds) + 60
    alarm(seconds)
    var coreDump = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &coreDump) == 0 else { throw BackupFailure.worker }
    var cpu = rlimit(rlim_cur: rlim_t(seconds), rlim_max: rlim_t(seconds))
    guard setrlimit(RLIMIT_CPU, &cpu) == 0 else { throw BackupFailure.worker }
    let fileBytes = rlim_t(CanonicalBackupBounds.fileBytes) + 64 * 1024 * 1024
    var bound = rlimit(rlim_cur: fileBytes, rlim_max: fileBytes)
    guard setrlimit(RLIMIT_FSIZE, &bound) == 0 else { throw BackupFailure.worker }
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
        data.append(chunk); guard data.count <= CanonicalBackupBounds.messageBytes else { throw BackupFailure.limit }
    }
    let request = try JSONDecoder().decode(Request.self, from: data)
    let sourceURL = try url(request.source)
    // Explicit app-selected existing store, never initialize a missing source.
    _ = try MemoryStore(home: sourceURL, automaticallySyncSearch: false)
    let source = try MemoryStore(home: sourceURL, writable: true, automaticallySyncSearch: false)
    switch request.operation {
    case "export":
        guard let build = request.build, let version = request.version else { throw BackupFailure.invalid }
        try emit(NativeBackup.export(source: source, destination: try url(request.destination), build: build, version: version))
    case "prepare":
        guard let pin = request.manifestSHA256 else { throw BackupFailure.invalid }
        try emit(NativeBackup.prepare(source: source, backup: try url(request.backup), manifestSHA256: pin, staging: try url(request.destination)))
    case "confirm":
        guard let prepared = request.prepared, request.confirmed == true else { throw BackupFailure.invalid }
        try emit(NativeBackup.confirm(source: source, prepared: prepared, confirmed: true))
    case "cancel":
        guard let prepared = request.prepared else { throw BackupFailure.invalid }
        try source.cancelCanonicalRestore(prepared.preview.id); try emit(["cancelled": true])
    default: throw BackupFailure.invalid
    }
} catch {
    // Never echo paths, history, SQL or credentials in errors.
    FileHandle.standardOutput.write(Data("{\"error\":\"backup_unavailable\"}".utf8))
    exit(1)
}
