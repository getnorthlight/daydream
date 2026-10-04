import Foundation
import Darwin

public struct SearchSyncResult: Codable {
    public var status: String
    public var scanned: Int
    public var upserted: Int
    public var deleted: Int
    public var cycleComplete: Bool
}

public enum LocalSearchIndexer {
    private static let queue=DispatchQueue(label:"macmem.search-index",qos:.utility)
    private static var scheduled=Set<String>()
    private static var originating=[String:OriginatingSearchStore]()
    /// Product automatic callbacks retain only a weak reference to the originating connection.
    /// Closing that store cancels the work; it never silently reopens an external connection.
    static func schedule(store:MemoryStore) {
        let home=store.home
        let candidate=OriginatingSearchStore(store)
        queue.async {
            let path=home.standardizedFileURL.path
            guard let source=candidate.store else {return}
            do {guard try TypesenseConfiguration.load(home:home) != nil else {return}}
            catch {source.discardTypedNarrativeCarry();return}
            if originating[path]?.store != nil {return}
            originating[path]=candidate
            tickOriginating(home:home,token:candidate.token)
        }
    }
    private static func tickOriginating(home:URL,token:UUID) {
        let path=home.standardizedFileURL.path
        guard let holder=originating[path],holder.token == token else {return}
        guard let store=holder.store else {originating.removeValue(forKey:path);return}
        let result=try? store.syncOriginatingSearchIndex()
        if result?.cycleComplete == false {
            // No strong store capture while waiting, and no network work under StoreLock.
            queue.asyncAfter(deadline:.now()+0.1) {tickOriginating(home:home,token:token)}
        } else {originating.removeValue(forKey:path)}
    }
    /// Coalesced best-effort work. Capture and writer completion do not await the index.
    public static func schedule(home: URL) {
        queue.async {
            let path=home.path
            guard !scheduled.contains(path), (try? TypesenseConfiguration.load(home:home)) != nil else { return }
            scheduled.insert(path)
            tick(home:home)
        }
    }
    private static func tick(home: URL) {
        let result=try? MemoryStore(home:home,writable:true).syncSearchIndex()
        if result?.cycleComplete == false {
            queue.asyncAfter(deadline:.now()+0.1) { tick(home:home) }
        } else { scheduled.remove(home.path) }
    }
}

extension MemoryStore {
    /// One bounded (100-source) reconciliation page. Its ledger lives in SQLite;
    /// failures never advance the page. Repeat to complete a rebuild or cleanup.
    public func syncSearchIndex(rebuild: Bool = false, now: Date = Date()) throws -> SearchSyncResult {
        guard writable else { throw MemError.denied }
        guard let config=try TypesenseConfiguration.load(home:home) else {
            return SearchSyncResult(status:"disabled",scanned:0,upserted:0,deleted:0,cycleComplete:true)
        }
        return try syncSearchIndex(config:config,transport:LocalTypesenseHTTP(config,sync:true),rebuild:rebuild,now:now)
    }
    func syncSearchIndex(config: TypesenseConfiguration, transport: TypesenseTransport, rebuild: Bool = false, now: Date) throws -> SearchSyncResult {
        try reconcileSearchIndex(config:config,transport:transport,rebuild:rebuild,now:now,originating:false)
    }
    func syncOriginatingSearchIndex(now:Date=Date()) throws ->SearchSyncResult {
        guard writable else {discardTypedNarrativeCarry();throw MemError.denied}
        do {
            guard let config=try TypesenseConfiguration.load(home:home) else {
                discardTypedNarrativeCarry()
                return SearchSyncResult(status:"disabled",scanned:0,upserted:0,deleted:0,cycleComplete:true)
            }
            return try syncOriginatingSearchIndex(config:config,transport:LocalTypesenseHTTP(config,sync:true),now:now)
        } catch {discardTypedNarrativeCarry();throw error}
    }
    /// Internal transport seam for deterministic local privacy controls; no public standalone bypass.
    func syncOriginatingSearchIndex(config:TypesenseConfiguration,transport:TypesenseTransport,now:Date) throws ->SearchSyncResult {
        do {return try reconcileSearchIndex(config:config,transport:transport,rebuild:false,now:now,originating:true)}
        catch {discardTypedNarrativeCarry();throw error}
    }
    private func reconcileSearchIndex(config:TypesenseConfiguration,transport:TypesenseTransport,rebuild:Bool,now:Date,originating:Bool) throws ->SearchSyncResult {
        func commit<T>(_ body:() throws ->T) throws ->T {
            if originating {return try transaction(preservingTypedNarrative:true) {try observingTypedNarrativeMaintenance(now:now,scope:.search,body)}}
            return try transaction(body)
        }
        // Cross-process serialization includes remote request and durable acknowledgement.
        let fd=open(home.appendingPathComponent("search-index.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw SearchFailure.busy }; defer { close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw SearchFailure.busy }
        defer { flock(fd,LOCK_UN) }
        let deadline=Date().addingTimeInterval(5)
        let root="/collections/"+config.collection
        let info=try transport.request("GET",root,query:[],body:nil,deadline:deadline)
        if info.status == 404 || rebuild {
            if rebuild && info.status != 404 {
                guard info.status == 200 else { throw SearchFailure.response }
                let removed=try transport.request("DELETE",root,query:[],body:nil,deadline:deadline)
                guard removed.status == 200 else { throw SearchFailure.response }
            }
            let schema:[String:Any] = ["name":config.collection,"default_sorting_field":"at","fields":[
                ["name":"source_id","type":"string","index":false],
                ["name":"revision","type":"string","index":false],
                ["name":"summary","type":"string"], ["name":"app","type":"string"],
                ["name":"app_keys","type":"string[]","facet":true],
                ["name":"site","type":"string","facet":true], ["name":"at","type":"int64"]]]
            let created=try transport.request("POST","/collections",query:[],body:JSONSerialization.data(withJSONObject:schema),deadline:deadline)
            guard created.status == 201 else { throw SearchFailure.response }
            try commit {
                try exec("DELETE FROM search_index_state")
                try exec("DELETE FROM metadata WHERE id IN ('search_cursor','search_endpoint','search_complete_revision','search_cycle_revision')")
            }
        } else { guard info.status == 200 else { throw SearchFailure.response } }
        let endpoint="\(config.port)/\(config.collection)"
        if try rows("SELECT body FROM metadata WHERE id='search_endpoint'").first?.first != endpoint {
            try commit {
                try exec("DELETE FROM search_index_state")
                try exec("DELETE FROM metadata WHERE id IN ('search_cursor','search_complete_revision','search_cycle_revision')")
                try exec("INSERT OR REPLACE INTO metadata VALUES('search_endpoint',?)",[endpoint])
            }
        }
        if try rows("SELECT body FROM metadata WHERE id='search_projection_version'").first?.first != ActionProjection.version {
            try commit {
                // Keep the deletion ledger; old projections need revalidation,
                // not an untracked collection replacement.
                try exec("DELETE FROM metadata WHERE id IN ('search_cursor','search_complete_revision','search_cycle_revision')")
                try exec("INSERT OR REPLACE INTO metadata VALUES('search_projection_version',?)",[ActionProjection.version])
            }
        }
        let cursor=try rows("SELECT body FROM metadata WHERE id='search_cursor'").first?.first ?? ""
        let ids=try searchPageIDs(after:cursor)
        var documents=[SearchDocument](), deleted=[String]()
        let revision=try disclosureRevision(), policyRevision=try policy().revision
        for id in ids {
            let prior=try rows("SELECT revision FROM search_index_state WHERE id=?",[id]).first?.first
            if let item=try read(id,now:now), let doc=SearchDocument.make(item) {
                if config.syntheticOnly == true && !item.evidence.synthetic { throw SearchFailure.configuration }
                if prior != doc.revision { documents.append(doc) }
            } else if prior != nil { deleted.append(id) }
        }
        // Record uncertain writes BEFORE transport. A timeout or concurrent source
        // deletion must not leave an untracked remote document behind.
        try commit {
            guard try revision == disclosureRevision(), try policyRevision == policy().revision else { throw SearchFailure.changed }
            for doc in documents { try exec("INSERT OR IGNORE INTO search_index_state VALUES(?,?)",[doc.source_id,""]) }
            if cursor.isEmpty { try exec("INSERT OR REPLACE INTO metadata VALUES('search_cycle_revision',?)",[revision]) }
        }
        // No bulk raw export; only changed projections. Each line must be acknowledged.
        if !documents.isEmpty {
            let data=Data(try documents.map { try json($0) }.joined(separator:"\n").utf8)
            let imported=try transport.request("POST",root+"/documents/import",query:[URLQueryItem(name:"action",value:"upsert")],body:data,deadline:deadline)
            guard imported.status == 200 else { throw SearchFailure.response }
            let lines=String(decoding:imported.data,as:UTF8.self).split(separator:"\n")
            guard lines.count == documents.count else { throw SearchFailure.response }
            for line in lines {
                guard let result=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any], result["success"] as? Bool == true else { throw SearchFailure.response }
            }
        }
        for id in deleted {
            let removed=try transport.request("DELETE",root+"/documents/"+fingerprint(id),query:[],body:nil,deadline:deadline)
            guard [200,404].contains(removed.status) else { throw SearchFailure.response }
        }
        guard try TypesenseConfiguration.load(home:home) == config else { throw SearchFailure.changed }
        try commit {
            guard try revision == disclosureRevision(), try policyRevision == policy().revision else { throw SearchFailure.changed }
            for doc in documents { try exec("INSERT OR REPLACE INTO search_index_state VALUES(?,?)",[doc.source_id,doc.revision]) }
            for id in deleted { try exec("DELETE FROM search_index_state WHERE id=?",[id]) }
            try exec("INSERT OR REPLACE INTO metadata VALUES('search_cursor',?)",[ids.count < 100 ? "" : ids.last!])
            if ids.count < 100, try rows("SELECT body FROM metadata WHERE id='search_cycle_revision'").first?.first == revision {
                try exec("INSERT OR REPLACE INTO metadata VALUES('search_complete_revision',?)",[revision])
            }
        }
        return SearchSyncResult(status:"synced",scanned:ids.count,upserted:documents.count,deleted:deleted.count,cycleComplete:ids.count < 100)
    }
    /// The next page's ids: every id after `cursor` in records or search_index_state, in SQLite's BINARY order, each once,
    /// at most `limit`. claude/perf2-1003: two primary-key range reads merged here. The single statement it replaces,
    /// `SELECT id FROM (SELECT id FROM records UNION SELECT id FROM search_index_state) WHERE id>? ORDER BY id LIMIT 100`,
    /// built and sorted the whole union under the store lock on every page (9 ms at 30,000 records, which the main
    /// thread waited out); the answer is the same (perf-1003 B compares them).
    func searchPageIDs(after cursor:String,limit:Int=100) throws -> [String] {
        let n=max(0,limit)
        let a=try rows("SELECT id FROM records WHERE id>? ORDER BY id LIMIT \(n)",[cursor]).map { $0[0] }
        let b=try rows("SELECT id FROM search_index_state WHERE id>? ORDER BY id LIMIT \(n)",[cursor]).map { $0[0] }
        var out=[String](),i=0,j=0
        out.reserveCapacity(n)
        while out.count<n && (i<a.count || j<b.count) {
            if j>=b.count {out.append(a[i]);i+=1;continue}
            if i>=a.count {out.append(b[j]);j+=1;continue}
            let x=a[i].utf8,y=b[j].utf8
            if x.elementsEqual(y) {out.append(a[i]);i+=1;j+=1}
            else if x.lexicographicallyPrecedes(y) {out.append(a[i]);i+=1}
            else {out.append(b[j]);j+=1}
        }
        return out
    }
}
