import Foundation
import MemoryCore

/// claude/crashguard-015: the "this file is not linked" and "the same file" tests ask the file system (lstat per
/// component, device + inode), not URL values or strings, so a trailing slash, a directory hint, the /private prefix
/// or letter case (each differs between Foundation releases, and between a CFURL from the OS and a URL built here)
/// never changes the answer, while a real symbolic link still does.
func runFilePathChecks(root: URL) throws {
    let fm = FileManager.default
    let real = root.appendingPathComponent("Real", isDirectory: true)
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    let file = real.appendingPathComponent("manifest.json")
    try Data("{}".utf8).write(to: file)
    let link = root.appendingPathComponent("linked")
    try? fm.removeItem(at: link)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    let fileLink = root.appendingPathComponent("manifest-link.json")
    try? fm.removeItem(at: fileLink)
    try fm.createSymbolicLink(at: fileLink, withDestinationURL: file)
    let other = root.appendingPathComponent("Other", isDirectory: true)
    try fm.createDirectory(at: other, withIntermediateDirectories: true)

    let plain = URL(fileURLWithPath: real.path)
    let slashed = URL(fileURLWithPath: real.path + "/")
    let hinted = URL(fileURLWithPath: real.path, isDirectory: true)
    let fromCF = (URL(fileURLWithPath: real.path + "/") as CFURL) as URL
    let dotted = URL(fileURLWithPath: real.path + "/./")
    let parented = URL(fileURLWithPath: real.path + "/../Real")
    // The temporary folder is /var/folders/..., which is /private/var/folders/... on disk.
    let resolvedRoot = real.resolvingSymlinksInPath().path
    let privatePath = resolvedRoot.hasPrefix("/private/") ? resolvedRoot : "/private" + resolvedRoot
    let privateURL = URL(fileURLWithPath: privatePath)
    let lowered = URL(fileURLWithPath: real.deletingLastPathComponent().path + "/real")
    let caseInsensitive = fm.fileExists(atPath: lowered.path)

    try check(URL(fileURLWithPath: real.path, isDirectory: false) != hinted, "file paths: URL == tells a directory hint apart (why the tests never compare URLs)")
    try check([plain, slashed, hinted, fromCF, dotted, parented, file].allSatisfy(FilePaths.unlinked),
              "file paths: a real file or folder, with a trailing slash, directory hint, CFURL round trip, . or .., is not linked")
    try check(FilePaths.unlinked(privateURL) && FilePaths.unlinked(URL(fileURLWithPath: "/tmp")) && FilePaths.unlinked(URL(fileURLWithPath: "/private/tmp")),
              "file paths: the system's /var, /tmp links and the /private prefix are not counted as links")
    try check(!caseInsensitive || FilePaths.unlinked(lowered), "file paths: another letter case of a real folder is not a link (case-insensitive volume)")
    try check(FilePaths.unlinked(real.appendingPathComponent("not-yet/inside")), "file paths: a folder that doesn't exist yet is not a link")
    try check(!FilePaths.unlinked(link) && !FilePaths.unlinked(link.appendingPathComponent("manifest.json")) && !FilePaths.unlinked(fileLink)
              && !FilePaths.unlinked(URL(fileURLWithPath: link.path + "/")) && !FilePaths.unlinked(link.appendingPathComponent("not-yet")),
              "file paths: a path through a symbolic link is still refused, with or without a trailing slash")
    try check(!FilePaths.unlinked(URL(string: "https://example.com/a")!), "file paths: a web URL is never an unlinked file")

    try check(FilePaths.same(plain, slashed) && FilePaths.same(hinted, plain) && FilePaths.same(fromCF, dotted) && FilePaths.same(parented, plain),
              "file paths: one folder written six ways is the same folder")
    try check(FilePaths.same(privateURL, plain), "file paths: /private/var/... and /var/... are the same folder")
    try check(!caseInsensitive || FilePaths.same(lowered, plain), "file paths: another letter case is the same folder (case-insensitive volume)")
    try check(FilePaths.same(link, real) && FilePaths.same(fileLink, file), "file paths: a link and its target are the same file")
    try check(!FilePaths.same(real, other) && !FilePaths.same(real, root) && !FilePaths.same(file, real),
              "file paths: another folder or a file inside is not the same")
    try check(!FilePaths.same(real, root.appendingPathComponent("missing")) && FilePaths.same(root.appendingPathComponent("missing/"), root.appendingPathComponent("missing")),
              "file paths: an existing and a missing file differ; one missing path written two ways is the same")
    try check(FilePaths.path(slashed) == FilePaths.path(plain) && FilePaths.path(URL(fileURLWithPath: "/")) == "/", "file paths: path drops a trailing slash but keeps /")
}
