import Foundation
import CryptoKit

/// A long-lived MCP process must not keep serving old code after bundle replacement.
/// Updates ship app, CLI, adapter and this manifest as one signed bundle.
public struct CompanionIdentity {
    public let manifest:URL?
    public let version:String
    private let initial:Data?
    public init(executable:URL) throws {
        let contents=executable.deletingLastPathComponent().deletingLastPathComponent()
        if contents.lastPathComponent == "Contents" {
            let url=contents.appendingPathComponent("Resources/Companions.json")
            let data=try Data(contentsOf:url)
            guard let info=Self.parse(data) else { throw MemError.invalid("Invalid companion manifest") }
            manifest=url; initial=data
            version=info["version"] as? String ?? "unknown"
        } else { manifest=nil; initial=nil; version="development" }
    }
    /// What an AI app's model reads when a request lands while DayDream is being replaced. The next request is answered
    /// by the updated copy (`mac-mem mcp` carries on as it: see `freshness`), so trying again is all it takes.
    public static let updatingMessage = "DayDream is being updated. Try again in a moment."
    public func validate() throws {
        if let manifest, try Data(contentsOf:manifest) != initial { throw MemError.invalid(Self.updatingMessage) }
    }

    /// Whether the DayDream on disk is still the one this process started from.
    public enum Freshness: Equatable {
        /// The same bundle (or a development binary, which is never replaced).
        case current
        /// A complete, different DayDream is in place: its manifest reads and, when the manifest lists it, its `mac-mem`
        /// matches the manifest's hash. The process can carry on as that copy.
        case replaced(executable: URL)
        /// The bundle is being replaced: the manifest is missing or unreadable, or `mac-mem` doesn't match it yet.
        case updating
    }

    /// Compares the manifest on disk with the one this process loaded. `loaded` is nil when the process couldn't read
    /// one at start (it began mid-update), so any complete bundle counts as replaced. Reads a few KB; hashes `mac-mem`
    /// only when the manifest changed.
    public static func freshness(executable:URL, loaded:CompanionIdentity?) -> Freshness {
        let contents=executable.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return .current }
        if let loaded, loaded.manifest == nil { return .current }
        let url=contents.appendingPathComponent("Resources/Companions.json")
        guard let data=try? Data(contentsOf:url), let info=parse(data) else { return .updating }
        if let loaded, data == loaded.initial { return .current }
        let binary=contents.appendingPathComponent("MacOS/mac-mem")
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:binary.path,isDirectory:&directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath:binary.path) else { return .updating }
        if let expected=(info["sha256"] as? [String:Any])?["MacOS/mac-mem"] as? String {
            guard let bytes=try? Data(contentsOf:binary),
                  SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == expected.lowercased() else { return .updating }
        }
        return .replaced(executable:binary)
    }

    private static func parse(_ data:Data) -> [String:Any]? {
        guard data.count < 8192, let info=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              info["schema"] as? Int == 1, let build=info["build"] as? String, UInt64(build) != nil else { return nil }
        return info
    }
}
