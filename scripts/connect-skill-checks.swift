// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// claude/rel-017c: DayDream's skill for ChatGPT (Sources/MemoryCore/AgentSkill.swift). Scratch folders only: a fake
// home with a ~/.codex folder. Nothing reads or writes the real home folder.
//
// Covers: the embedded copy equals skills/daydream, install, a second install changes nothing, an older copy DayDream
// wrote is refreshed (and a file it dropped removed), a folder DayDream didn't write or the person edited is left
// alone (install and remove), remove takes only DayDream's files, links are never written through, no ~/.codex means
// nothing is written, and the launch refresh writes only while ChatGPT has DayDream's entry.
import Foundation
@testable import MemoryCore

@main struct ConnectSkillChecks {
    static var passes = 0, failures = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
        let ok = (try? value()) ?? false
        if ok { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name) }
    }

    static func scratch() -> (AIAppConnectEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daydream-skill-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (AIAppConnectEnvironment(userHome: root, applicationFolders: []), root)
    }
    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    static func files(_ dir: URL) -> [String] {
        (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).sorted()
    }

    static func main() {
        let fm = FileManager.default

        // The embedded copy is the repo's skill, byte for byte.
        let repo = URL(fileURLWithPath: "skills/daydream", isDirectory: true)
        let repoFiles = files(repo).filter { var d: ObjCBool = false; fm.fileExists(atPath: repo.appendingPathComponent($0).path, isDirectory: &d); return !d.boolValue }
        check(Set(repoFiles) == Set(AgentSkillFiles.files.map(\.path)), "embedded: the same files as skills/daydream")
        for file in AgentSkillFiles.files {
            check(read(repo.appendingPathComponent(file.path)) == file.text, "embedded: \(file.path) matches")
        }

        // No ~/.codex: nothing written.
        do {
            let (env, root) = scratch()
            check(try AgentSkill.install(env) == .absent, "no .codex: absent")
            check(!fm.fileExists(atPath: root.appendingPathComponent(".codex").path), "no .codex: nothing written")
        }

        // Install, again, remove.
        do {
            let (env, root) = scratch()
            try! fm.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            let dir = AgentSkill.folder(env)
            check(dir.path == root.appendingPathComponent(".codex/skills/daydream").path, "folder: ~/.codex/skills/daydream")
            check(try AgentSkill.install(env) == .installed, "install: installed")
            for file in AgentSkillFiles.files { check(read(dir.appendingPathComponent(file.path)) == file.text, "install: wrote \(file.path)") }
            check(fm.fileExists(atPath: dir.appendingPathComponent(".daydream-skill.json").path), "install: record kept")
            let before = files(dir).map { read(dir.appendingPathComponent($0)) ?? "" }
            check(try AgentSkill.install(env) == .current, "twice: current")
            check(files(dir).map { read(dir.appendingPathComponent($0)) ?? "" } == before, "twice: nothing changed")
            check(try AgentSkill.remove(env) == .removed, "remove: removed")
            check(!fm.fileExists(atPath: dir.path), "remove: folder gone")
            check(fm.fileExists(atPath: root.appendingPathComponent(".codex/skills").path), "remove: ~/.codex/skills kept")
            check(try AgentSkill.remove(env) == .absent, "remove twice: absent")
        }

        // An older copy DayDream wrote is refreshed; a file the older skill had and this one doesn't is removed.
        do {
            let (env, root) = scratch()
            try! fm.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            let dir = AgentSkill.folder(env)
            try! fm.createDirectory(at: dir.appendingPathComponent("reference"), withIntermediateDirectories: true)
            let old = "---\nname: daydream\ndescription: Older.\n---\n", gone = "dropped\n"
            try! Data(old.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            try! Data(gone.utf8).write(to: dir.appendingPathComponent("reference/old.md"))
            let record = ["files": ["SKILL.md": AgentSkill.sha256(Data(old.utf8)), "reference/old.md": AgentSkill.sha256(Data(gone.utf8))]]
            try! JSONSerialization.data(withJSONObject: record).write(to: dir.appendingPathComponent(".daydream-skill.json"))
            check(try AgentSkill.install(env) == .updated, "older copy: updated")
            check(read(dir.appendingPathComponent("SKILL.md")) == AgentSkillFiles.files[0].text, "older copy: SKILL.md replaced")
            check(!fm.fileExists(atPath: dir.appendingPathComponent("reference/old.md").path), "older copy: dropped file removed")
            check(try AgentSkill.install(env) == .current, "older copy: then current")
        }

        // The person's own folder, or DayDream's copy that the person edited: left alone.
        do {
            let (env, root) = scratch()
            let dir = AgentSkill.folder(env)
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let theirs = "---\nname: daydream\ndescription: Mine.\n---\n"
            try! Data(theirs.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            check(try AgentSkill.install(env) == .keptTheirs, "their folder: kept on install")
            check(try AgentSkill.remove(env) == .keptTheirs, "their folder: kept on remove")
            check(read(dir.appendingPathComponent("SKILL.md")) == theirs, "their folder: unchanged")
            _ = root
        }
        do {
            let (env, root) = scratch()
            try! fm.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            let dir = AgentSkill.folder(env)
            _ = try? AgentSkill.install(env)
            let edited = AgentSkillFiles.files[0].text + "\nMy own note.\n"
            try! Data(edited.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            check(try AgentSkill.install(env) == .keptTheirs, "edited copy: kept on install")
            check(try AgentSkill.remove(env) == .keptTheirs, "edited copy: kept on remove")
            check(read(dir.appendingPathComponent("SKILL.md")) == edited, "edited copy: unchanged")
            // A file the person added beside DayDream's survives a remove; the folder stays.
            let (env2, root2) = scratch()
            try! fm.createDirectory(at: root2.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            _ = try? AgentSkill.install(env2)
            let added = AgentSkill.folder(env2).appendingPathComponent("notes.md")
            try! Data("mine\n".utf8).write(to: added)
            check(try AgentSkill.remove(env2) == .removed, "added file: DayDream's files removed")
            check(read(added) == "mine\n", "added file: kept")
            check(!fm.fileExists(atPath: AgentSkill.folder(env2).appendingPathComponent("SKILL.md").path), "added file: SKILL.md gone")
        }

        // Links are never written through.
        do {
            let (env, root) = scratch()
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try! fm.createSymbolicLink(at: root.appendingPathComponent(".codex"), withDestinationURL: elsewhere)
            check(try AgentSkill.install(env) == .absent, "linked .codex: absent")
            check(files(elsewhere).isEmpty, "linked .codex: nothing written")
            let (env2, root2) = scratch()
            try! fm.createDirectory(at: root2.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            let other = root2.appendingPathComponent("other", isDirectory: true)
            try! fm.createDirectory(at: other, withIntermediateDirectories: true)
            try! fm.createSymbolicLink(at: root2.appendingPathComponent(".codex/skills"), withDestinationURL: other)
            check(try AgentSkill.install(env2) == .keptTheirs, "linked skills folder: left alone")
            check(files(other).isEmpty, "linked skills folder: nothing written")
            let (env3, root3) = scratch()
            try! fm.createDirectory(at: root3.appendingPathComponent(".codex/skills"), withIntermediateDirectories: true)
            let target = root3.appendingPathComponent("target", isDirectory: true)
            try! fm.createDirectory(at: target, withIntermediateDirectories: true)
            try! fm.createSymbolicLink(at: AgentSkill.folder(env3), withDestinationURL: target)
            check(try AgentSkill.install(env3) == .keptTheirs, "linked daydream folder: left alone")
            check(files(target).isEmpty, "linked daydream folder: nothing written")
        }

        // The launch refresh: only while ChatGPT has DayDream's entry in ~/.codex/config.toml.
        do {
            let (env, root) = scratch()
            let codex = root.appendingPathComponent(".codex", isDirectory: true)
            try! fm.createDirectory(at: codex, withIntermediateDirectories: true)
            check(AgentSkill.refresh(env) == .absent, "refresh: not connected, nothing written")
            check(!fm.fileExists(atPath: AgentSkill.folder(env).path), "refresh: not connected, no folder")
            let toml = """
            [mcp_servers.daydream]
            command = "/Applications/DayDream.app/Contents/MacOS/mac-mem"
            args = ["--client", "chatgpt", "--recipient", "daydream-connect", "mcp"]
            env = { MAC_MEM_CAPABILITY = "synthetic" }
            """
            try! Data((toml + "\n").utf8).write(to: codex.appendingPathComponent("config.toml"))
            let connected = AIAppConnect.entryCommand(try! AIAppConnect.app("chatgpt"), env: env) != nil
            check(connected, "refresh: fixture reads as DayDream's entry")
            check(AgentSkill.refresh(env) == .installed, "refresh: connected, installed")
            check(AgentSkill.refresh(env) == .current, "refresh: connected, then current")
        }

        print("connect-skill: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
