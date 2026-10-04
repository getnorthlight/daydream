import SwiftUI
import AppKit
import MemoryCore

// claude/searchui-1005 (owner 10/04): search has no pushed detail any more (it repeated the preview and added filler);
// Return and a double-click show a result in context. What stays here is the panel's Forget This Action confirmation.

// MARK: - Forget one action (private helper, amendment M4)

/// PRIVATE HELPER (A2, amendment M4): forgets a single ungrouped hit with an `action` scope. The kit's
/// `momentForgetConfirmation` builds only `activity` scopes (`MomentForgetRequest(moment:timeZone:)`);
/// a contract request asks for an action-scoped request there. Same flow: preview, confirm, then
/// commit (Forget) or release (Cancel) the preview.
struct RecallActionForgetModifier: ViewModifier {
    @ObservedObject var browser: ActivityBrowser
    @Binding var request: RecallActionForgetRequest?
    let onForgotten: (String) -> Void
    let onError: (String) -> Void
    @State private var preview: DeletionPreview?
    @State private var prepared: RecallActionForgetRequest?
    /// The request a preview is being prepared for off the main thread (`previewCanonicalDeleteOffMain`).
    @State private var preparing: RecallActionForgetRequest?
    /// The request whose Forget is being committed off the main thread: nothing is prepared for it meanwhile.
    @State private var committing: RecallActionForgetRequest?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { next in
                if let id = preview?.id, prepared != next { try? browser.cancelCanonicalDelete?(id); preview = nil; prepared = nil; preparing = nil }
                prepare()
            }
            .alert("Forget this action?", isPresented: Binding(get: { preview != nil && request != nil && prepared == request },
                                                              set: { if !$0 { preview = nil } })) {
                Button("Cancel", role: .cancel) { cancel() }
                Button("Forget", role: .destructive) { confirm() }
            } message: {
                Text(message)
            }
    }

    private var message: String {
        guard let prepared else { return "" }
        let base = "This permanently deletes 1 action from \(DaydreamFormat.time(prepared.at, prepared.timeZone)). This can't be undone."
        let w = (preview?.warning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? base : base + " " + w
    }

    private func prepare() {
        guard let request, preview == nil, committing != request else { return }
        if let make = browser.previewCanonicalDeleteOffMain {
            // gold r3-store: prepared off the main thread, as MomentForgetModifier does.
            guard preparing != request else { return }
            preparing = request
            let browser = browser
            Task { @MainActor in
                let made: Result<DeletionPreview, Error>
                do { made = .success(try await make(request.scope)) } catch { made = .failure(error) }
                let current = preparing == request && self.request == request && preview == nil
                if preparing == request { preparing = nil }
                switch made {
                case .success(let next) where current:
                    preview = next; prepared = request
                case .success(let next):
                    try? browser.cancelCanonicalDelete?(next.id)
                    if self.request != nil && self.request != request && preview == nil { prepare() }
                case .failure where current:
                    self.request = nil
                    onError("Deletion preview unavailable. No records deleted.")
                case .failure:
                    if self.request != nil && self.request != request && preview == nil { prepare() }
                }
            }
            return
        }
        do {
            guard let make = browser.previewCanonicalDelete else { throw MemError.missing }
            preview = try make(request.scope)
            prepared = request
        } catch {
            self.request = nil
            onError("Deletion preview unavailable. No records deleted.")
        }
    }

    private func cancel() {
        if let id = preview?.id { try? browser.cancelCanonicalDelete?(id) }
        preview = nil; prepared = nil; request = nil; preparing = nil
    }

    private func confirm() {
        guard let current = preview, let request, prepared == request else { cancel(); return }
        if let commit = browser.confirmCanonicalDeleteOffMain {
            // gold r3-store: committed off the main thread, as MomentForgetModifier does.
            preview = nil; prepared = nil; committing = request
            Task { @MainActor in
                let done: Result<Void, Error>
                do { try await commit(current.id); done = .success(()) } catch { done = .failure(error) }
                if committing == request { committing = nil }
                if self.request == request { self.request = nil }
                switch done {
                case .success: onForgotten(request.id)
                case .failure: onError("Nothing confirmed deleted. Refresh and review the scope again.")
                }
            }
            return
        }
        do {
            guard let commit = browser.confirmCanonicalDelete else { throw MemError.missing }
            try commit(current.id)
            preview = nil; prepared = nil; self.request = nil
            onForgotten(request.id)
        } catch {
            preview = nil; prepared = nil; self.request = nil
            onError("Nothing confirmed deleted. Refresh and review the scope again.")
        }
    }
}
