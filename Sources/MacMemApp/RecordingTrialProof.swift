#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import Foundation
import MemoryCore

/// A saved native original, never a generated note or a fixture, is trial evidence.
enum RecordingTrialProof {
    static func latest(store:MemoryStore,since:Date,now:Date) throws -> CanonicalAction? {
        let page=try store.actions(start:since,end:now,limit:30,now:now,descending:true)
        for action in page.actions {
            guard let item=try store.read(action.id,now:now),accepts(item.evidence,since:since,now:now) else {continue}
            return try store.action(action.id,now:now)
        }
        return nil
    }
    static func accepts(_ evidence:Evidence,since:Date,now:Date)->Bool {
        guard !evidence.synthetic,!evidence.secure,!evidence.privateWindow,
              let at=timestamp(evidence.at),at>=since,at<=now,
              !evidence.bundle.isEmpty else {return false}
        if evidence.kind == "keyboard.text_input" {return evidence.captureProvenance != nil}
        return evidence.id.hasPrefix("native-") &&
            ["window.changed","window.observed","focus.observed"].contains(evidence.kind)
    }
}

#endif
