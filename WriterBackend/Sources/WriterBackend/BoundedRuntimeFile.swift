import Foundation
import Darwin

enum BoundedRuntimeFile {
    static func read(_ url: URL, limit: Int = 32_768, checkCancellation: () throws -> Void = {try Task.checkCancellation()}, opened: (Int32) throws -> Void = {_ in}) throws -> Data {
        try checkCancellation()
        guard url.isFileURL, url.path.hasPrefix("/") else {throw WriterFailure.integrity}
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {throw WriterFailure.integrity}
        defer {close(directory)}
        let parts = url.path.split(separator: "/").map(String.init)
        guard let last = parts.last, !parts.contains("..") else {throw WriterFailure.integrity}
        for part in parts.dropLast() {
            try checkCancellation()
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard next >= 0 else {throw WriterFailure.integrity}
            close(directory); directory = next
        }
        let fd = openat(directory, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {throw WriterFailure.integrity}; defer {close(fd)}
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= limit else {throw WriterFailure.integrity}
        try opened(fd) // Internal fixture hook, never supplied by public loader.
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < Int(before.st_size) {
            try checkCancellation()
            let n = Darwin.read(fd, &buffer, min(buffer.count, Int(before.st_size) - data.count))
            guard n > 0 else {throw WriterFailure.integrity}
            data.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {throw WriterFailure.integrity}
        try checkCancellation(); return data
    }
}
