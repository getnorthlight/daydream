import Foundation
import Darwin

/// claude/crashguard-015: file locations are compared through the file system, never as URL values or raw strings.
/// `URL ==` compares the URL's string (a trailing slash, a directory hint, a base URL), and what
/// `standardizedFileURL` / `resolvingSymlinksInPath()` return (the /private prefix, letter case, a trailing slash)
/// differs between macOS releases' Foundation and between a CFURL from the OS and a URL built here. Such a check
/// would refuse the right file on one release and pass on another. These ask the file system instead.
public enum FilePaths {
    /// The standardized path, without a trailing slash ("/" stays "/").
    public static func path(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
    /// No symbolic link anywhere in `url`'s path, checked component by component with lstat. The system's own
    /// /tmp, /var and /etc links (to /private/...) don't count: Foundation itself writes /private/var as /var.
    /// Components that don't exist yet are not links. Any other lstat failure (no permission) fails closed.
    public static func unlinked(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var current = ""
        for (index, part) in URL(fileURLWithPath: path(url)).pathComponents.enumerated() where part != "/" {
            current += "/" + part
            var st = stat()
            if lstat(current, &st) != 0 { return errno == ENOENT }
            guard st.st_mode & S_IFMT == S_IFLNK else { continue }
            guard index == 1, ["tmp", "var", "etc"].contains(part), systemLink(current, part) else { return false }
        }
        return true
    }
    /// Both name the same existing file (same device and inode, so letter case, /private, links and slashes don't
    /// matter). If neither exists, their standardized, link-resolved paths are compared; if only one does, they differ.
    public static func same(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        let ea = stat(path(a), &sa) == 0, eb = stat(path(b), &sb) == 0
        if ea && eb { return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino }
        if ea != eb { return false }
        return path(a.standardizedFileURL.resolvingSymlinksInPath()) == path(b.standardizedFileURL.resolvingSymlinksInPath())
    }
    private static func systemLink(_ path: String, _ name: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: 64)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n > 0 else { return false }
        let target = String(decoding: buffer[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return target == "private/" + name || target == "/private/" + name
    }
}
