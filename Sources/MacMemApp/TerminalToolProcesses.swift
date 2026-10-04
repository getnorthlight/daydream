import AppKit
import Darwin
import MemoryCore

/// claude/cc-label-1003 (owner 10/03): "is there any way to know I was sending this all to Claude?" A weak signal, used
/// only beside a prompt-shaped line (`PromptShape`) in a terminal whose title named no tool: the AI coding tool the
/// terminal app's own processes run (Claude Code, Codex, Gemini CLI, Aider), when exactly one does. Process names and,
/// for a script host (node, bun, python), its first arguments' file names: the same reads `ps` makes for the person's
/// own processes, with no new permission, no prompt and nothing stored but the tool's name. A tab can't be mapped to its
/// TTY without Automation access, so two tools running in one terminal app (or none) say nothing.
final class TerminalToolProcesses: @unchecked Sendable {
    static let shared = TerminalToolProcesses()
    /// One answer per terminal app is reused this long (a burst of lines costs one scan).
    static let reuse: TimeInterval = 3
    static let tools: [String: String] = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider"]
    static let hosts: Set<String> = ["node", "bun", "deno", "python", "python3"]
    private let lock = NSLock()
    private var cache: [String: (tool: String?, at: Date)] = [:]

    func tool(bundle: String, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[bundle], now.timeIntervalSince(hit.at) < Self.reuse { return hit.tool }
        let roots = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        let found = roots.isEmpty ? nil : Self.scan(roots: roots)
        cache[bundle] = (found, now)
        return found
    }

    /// The one AI tool among the descendants of `roots`, or nil (none, or more than one).
    static func scan(roots: Set<pid_t>) -> String? {
        // Every process's parent, as `ps` reads it (KERN_PROC_ALL: root-owned ones like `login` included).
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        size += 16 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        var parent = [pid_t: pid_t]()
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) where p.kp_proc.p_pid > 0 {
            parent[p.kp_proc.p_pid] = p.kp_eproc.e_ppid
        }
        func descends(_ pid: pid_t) -> Bool {
            var p = pid, steps = 0
            while let up = parent[p], up > 1, steps < 24 {
                if roots.contains(up) { return true }
                p = up; steps += 1
            }
            return false
        }
        var found = Set<String>()
        for pid in parent.keys where descends(pid) {
            if let t = toolName(pid) { found.insert(t); if found.count > 1 { return nil } }
        }
        return found.first
    }

    static func toolName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf).lowercased()
        if let t = tools[name] { return t }
        // A native install's binary is named by its version; its argv[0] is the command ("claude").
        let args = arguments(pid)
        if let first = args.first.map({ ($0 as NSString).lastPathComponent.lowercased() }), let t = tools[first] { return t }
        guard hosts.contains(name) || hosts.contains(args.first.map { ($0 as NSString).lastPathComponent.lowercased() } ?? "") else { return nil }
        for a in args.dropFirst().prefix(2) {
            let lower = a.lowercased()
            if let t = tools[(lower as NSString).lastPathComponent] { return t }
            if lower.contains("claude-code") { return "Claude Code" }
            if lower.contains("@openai/codex") { return "Codex" }
            if lower.contains("gemini-cli") { return "Gemini CLI" }
        }
        return nil
    }

    /// A process's arguments (KERN_PROCARGS2), at most the first three; empty when unreadable.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        size = min(size, 64 * 1024)
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, data[i] != 0 { i += 1 }        // the executable path
        while i < size, data[i] == 0 { i += 1 }        // its padding
        var out: [String] = []
        while i < size, out.count < min(Int(argc), 3) {
            var j = i
            while j < size, data[j] != 0 { j += 1 }
            out.append(String(decoding: data[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }
}
