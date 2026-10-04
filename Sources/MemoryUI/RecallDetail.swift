import SwiftUI
import AppKit
import MemoryCore

// The pushed detail (find-A `ADetail`): the bar with Back and ^/v stepping, then the kit's
// `MomentDetailBody` (its Summary chip marks a cloud-written note). The results list stays mounted
// underneath, so popping returns to the same selection and scroll.

/// `‹  🔍 permission        ^ v` ("Result 3 of 7" is its VoiceOver value, not drawn).
struct RecallDetailBar: View {
    @ObservedObject var model: RecallModel
    let query: String

    var body: some View {
        let index = model.selectedIndex ?? 0
        let count = model.displayRows.count
        HStack(spacing: 10) {
            square("chevron.left", size: 30, radius: 8, label: "Back to Results", enabled: true) { model.back(); model.requestFocus() }
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
                .accessibilityHidden(true)
            Text(query.isEmpty ? (model.filter?.chipTitle ?? "Results") : query).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                square("chevron.up", size: 28, radius: 7, label: "Previous Result", enabled: index > 0) { model.move(-1); model.requestFocus() }
                square("chevron.down", size: 28, radius: 7, label: "Next Result", enabled: index < count - 1) { model.move(1); model.requestFocus() }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: RecallLayout.headerHeight)
        .background(DaydreamStyle.panelFill)
        .accessibilityElement(children: .contain)
        .accessibilityValue(model.positionText)
    }

    private func square(_ symbol: String, size: CGFloat, radius: CGFloat, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size > 29 ? 13 : 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct RecallDetailView: View {
    @ObservedObject var model: RecallModel
    let row: RecallRow

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if let m = row.moment { momentBody(m) } else { actionBody }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Moment")
    }

    private func momentBody(_ m: MomentSlice) -> some View {
        let loaded = model.members[m.id]
        let actions = loaded?.actions ?? []
        let complete = loaded?.complete ?? false
        let more = actions.count < m.actionCount && !complete
        return MomentDetailBody(moment: m, actions: actions, complete: complete,
                                showAllTitle: more ? "Show all \(DaydreamFormat.count(m.actionCount)) actions" : nil,
                                timeZone: model.timeZone, calendar: model.calendar, now: model.now,
                                showsHeader: true, unavailable: model.unavailableActions,
                                onShowAll: { model.loadMembers(m, limit: min(max(m.actionCount, 40), 2000)) },
                                onOpenOriginal: model.browser?.reopenCanonical == nil ? nil : { model.openOriginal(action: $0) },
                                onShowInContext: { model.showInDay() })
    }

    /// A single hit that is not (yet) part of a moment.
    private var actionBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                RecallHeroIcon(row: row, size: 52)
                VStack(alignment: .leading, spacing: 8) {
                    Text(RecallText.highlighted(row.title, terms: model.terms)).font(.system(size: 22, weight: .bold)).lineLimit(2)
                    Text(recallWhen(row, model: model)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 0) {
                RecallLabel(text: "What happened").padding(.bottom, 4)
                if let hit = row.anchor {
                    HStack(spacing: 10) {
                        Text(DaydreamFormat.time(row.time, model.timeZone)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        RecallRowIcon(row: row, size: 16, ring: DaydreamStyle.panelFill)
                        Text(RecallText.highlighted(hit.evidence.title.isEmpty ? row.title : hit.evidence.title, terms: model.terms))
                            .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        // fix/search-1003: a hit found by what was typed shows that part of the words (on this Mac only).
                        let line = row.typed[hit.id] ?? hit.summary
                        if !line.isEmpty {
                            Text(RecallText.highlighted(line, terms: model.terms)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 30)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }
}

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
