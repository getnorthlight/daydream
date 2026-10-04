import Foundation

public enum ListingMode: String, Codable { case every, indexed }

public struct WindowListing: Equatable {
    public var ids: [String]
    public var mode: ListingMode
}

public struct WindowEntry: Codable {
    public var id: String
    public var mode: String
    public var bounds: Rect?
    /// Only read when every window is "normal". Printed to the terminal by
    /// `windows`; the JSON report keeps its length only.
    public var name: String?
}

public struct WindowTable {
    public var listing: WindowListing
    public var windows: [WindowEntry]
    public var strictPause: Bool { windows.contains { $0.mode != "normal" } }
}

/// Step 1 of the join, and the `windows` command.
public enum WindowPass {
    /// `ID of every window`; falls back to `ID of window 1, 2, ...` until the
    /// first error. Either way the audit sees a complete listing.
    public static func list(_ ae: AppleEventPort, prefer: ListingMode = .every) -> WindowListing? {
        if prefer == .every, let ids = ae.send(.window(.every, .id)).list, !ids.contains(where: { $0.isEmpty }) {
            return WindowListing(ids: ids, mode: .every)
        }
        var ids: [String] = []
        for i in 1...33 {
            guard let id = ae.send(.window(.index(i), .id)).text, !id.isEmpty else {
                return WindowListing(ids: ids, mode: .indexed)
            }
            if i == 33 { return nil } // Implausibly many windows: treat as a failed listing.
            ids.append(id)
        }
        return nil
    }

    /// Modes for every window, then geometry. Names only when every window is
    /// normal and `names` is true. Strict: any non-normal window means no name
    /// is read for any window.
    public static func table(_ ae: AppleEventPort, prefer: ListingMode = .every, names: Bool) -> WindowTable? {
        guard let listing = list(ae, prefer: prefer) else { return nil }
        var rows = listing.ids.map { WindowEntry(id: $0, mode: ae.send(.window(.id($0), .mode)).text ?? "", bounds: nil, name: nil) }
        for i in rows.indices { rows[i].bounds = ae.send(.window(.id(rows[i].id), .bounds)).rect }
        let table = WindowTable(listing: listing, windows: rows)
        guard names, !table.strictPause else { return table }
        var named = table
        for i in named.windows.indices { named.windows[i].name = ae.send(.window(.id(named.windows[i].id), .name)).text }
        return named
    }
}

/// Which `first window` descriptors work against the real Chrome. Only the
/// window `id` is read here, never a title or address.
public struct DescriptorResult: Codable {
    public var everyIDs: [String]?
    public var indexedIDs: [String]?
    public var firstAbsolute: String?
    public var firstAbsoluteStatus: Int32
    public var firstLegacyEnum: String?
    public var firstLegacyEnumStatus: Int32
    public var firstIndex1: String?
    public var boundsRawType: String?
    public var listReplyType: String?

    public var frontID: String? { everyIDs?.first ?? indexedIDs?.first }
    public var fixedWorks: Bool { frontID != nil && firstAbsolute == frontID }
    public var legacyWorks: Bool { frontID != nil && firstLegacyEnum == frontID }
    public var listingWorks: Bool { everyIDs != nil || indexedIDs != nil }

    public static func probe(_ ae: AppleEventPort) -> DescriptorResult {
        let every = ae.send(.window(.every, .id))
        let indexed = WindowPass.list(ae, prefer: .indexed)
        let abs = ae.send(.window(.firstAbsolute, .id))
        let legacy = ae.send(.window(.firstLegacyEnum, .id))
        let idx = ae.send(.window(.index(1), .id))
        let front = every.list?.first ?? indexed?.ids.first
        let bounds = front.map { ae.send(.window(.id($0), .bounds)) }
        return DescriptorResult(everyIDs: every.list, indexedIDs: indexed?.ids,
                                firstAbsolute: abs.text, firstAbsoluteStatus: abs.status,
                                firstLegacyEnum: legacy.text, firstLegacyEnumStatus: legacy.status,
                                firstIndex1: idx.text, boundsRawType: bounds?.rawType, listReplyType: every.rawType)
    }
}
