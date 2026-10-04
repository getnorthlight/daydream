import Foundation

public enum MemoryOnboardingChoice:String,Codable {
    case understand = "Understand What You’ve Done So Far"
    case scratch = "Start From Scratch"
}
public struct MemoryOnboardingState:Codable {
    public var choice:MemoryOnboardingChoice
    public var status:String
    public var retainedActionCount:Int
    public var explanation:String
    public var activeImportID:String? = nil
}
public struct OnboardingImportPreview:Codable {
    public var id:String
    public var snapshotPath:String
    public var snapshotSHA256:String
    public var policySHA256:String
    public var counts:[String:Int]
    public var start:String?
    public var end:String?
    public var blocked:Bool
    public var revision:String
    public var expiresAt:String
}
extension MemoryStore {
    /// Read-only, including on a read-only connection. nil means no choice yet.
    public func onboardingState() throws -> MemoryOnboardingState? {
        try readSnapshot {
            guard let body=try rows("SELECT body FROM metadata WHERE id='onboarding'").first?.first else {return nil}
            var state=try decode(MemoryOnboardingState.self,body)
            state.retainedActionCount=Int(try rows("SELECT count(*) FROM records").first![0])!
            return state
        }
    }
    public func chooseOnboarding(_ choice:MemoryOnboardingChoice) throws -> MemoryOnboardingState {
        try transaction {
            let count=Int(try rows("SELECT count(*) FROM records").first![0])!
            let state=MemoryOnboardingState(choice:choice,status:choice == .scratch ? "import_skipped" : "awaiting_explicit_source",retainedActionCount:count,explanation:choice == .scratch ? (count == 0 ? "Import skipped. No existing history was erased; capture and grants are unchanged." : "Import skipped. Existing DayDream actions and all old collector history are retained; capture and grants are unchanged.") : "Choose one authorized source snapshot. Review counts, dates and policy exclusions before confirming import. No scanning, uploading or access grants.")
            try exec("INSERT OR REPLACE INTO metadata VALUES('onboarding',?)",[json(state)])
            return state
        }
    }
    public func prepareOnboardingImport(snapshotURL:URL,expectedHash:String,now:Date=Date()) throws -> OnboardingImportPreview {
        guard try rows("SELECT id FROM records LIMIT 1").isEmpty || !(try rows("SELECT id FROM metadata WHERE id='migration_destination'")).isEmpty else { throw MemError.invalid("Existing memory is retained. Import requires an explicitly selected isolated staging destination, not reset.") }
        if try rows("SELECT id FROM metadata WHERE id='migration_destination'").isEmpty { try initializeMigrationDestination() }
        let snapshot=try LegacyMigration.load(snapshotURL,expected:expectedHash)
        let manifest=try migrationDryRun(snapshot:snapshot,hash:expectedHash,root:snapshotURL.deletingLastPathComponent(),now:now)
        let dates=snapshot.entries.compactMap { timestamp($0.at) }.sorted()
        let preview=OnboardingImportPreview(id:UUID().uuidString,snapshotPath:snapshotURL.path,snapshotSHA256:expectedHash,policySHA256:manifest.policySHA256,counts:manifest.counts,start:dates.first.map(iso),end:dates.last.map(iso),blocked:manifest.blocked,revision:try disclosureRevision(),expiresAt:iso(now.addingTimeInterval(900)))
        try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)",["onboarding_import_"+preview.id,json(preview)])
        return preview
    }
    public func confirmOnboardingImport(previewID:String,confirmed:Bool,acceptPolicyExclusions:Bool,limit:Int=100,now:Date=Date()) throws -> MigrationProgress {
        guard confirmed, let body=try rows("SELECT body FROM metadata WHERE id=?",["onboarding_import_"+previewID]).first?.first else { throw MemError.denied }
        var preview=try decode(OnboardingImportPreview.self,body)
        guard !preview.blocked, timestamp(preview.expiresAt).map({$0 >= now}) == true,
              preview.revision == (try disclosureRevision()), acceptPolicyExclusions || !preview.counts.contains(where:{$0.key.hasPrefix("excluded") && $0.value > 0}) else { throw MemError.invalid("Import preview blocked, stale or policy exclusions not accepted") }
        let path=URL(fileURLWithPath:preview.snapshotPath)
        let snapshot=try LegacyMigration.load(path,expected:preview.snapshotSHA256)
        let progress=try importMigration(snapshot:snapshot,hash:preview.snapshotSHA256,policyHash:preview.policySHA256,root:path.deletingLastPathComponent(),limit:limit,now:now,expectedDisclosure:preview.revision)
        preview.revision=try disclosureRevision()
        try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)",["onboarding_import_"+preview.id,json(preview)])
        if progress.complete {
            let state=MemoryOnboardingState(choice:.understand,status:"import_complete",retainedActionCount:Int(try rows("SELECT count(*) FROM records").first![0])!,explanation:"Reviewed history imported. Capture and grants are unchanged.")
            try exec("INSERT OR REPLACE INTO metadata VALUES('onboarding',?)",[json(state)])
        }
        return progress
    }
}
