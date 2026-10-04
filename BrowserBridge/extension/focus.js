// Serialized into an ISOLATED world by scripting.executeScript. No values,
// selection, labels, titles, keystrokes, clipboard, or page-message listeners.
export function inspectFocus() {
  const unknown = () => ({ safety: 'unknown', role: 'unknown', focusID: '', focusGeneration: 0 });
  if (!document.hasFocus() || document.visibilityState !== 'visible') return unknown();
  // Each injected document maintains isolated-world identities. Page JavaScript
  // cannot supply or access this map. Attribute/DOM claims may only add denies.
  const key = '__macmemBridgeFocusV1';
  const state = globalThis[key] ??= { ids: new WeakMap(), generation: 0, last: null };
  const active = document.activeElement;
  if (!active) return unknown();
  if (state.last !== active) { state.last = active; state.generation++; }
  if (!state.ids.has(active)) state.ids.set(active, crypto.randomUUID());
  const result = (safety, role) => ({ safety, role, focusID: state.ids.get(active), focusGeneration: state.generation });
  const controls = document.querySelectorAll('input,textarea,select,[contenteditable],iframe,frame');
  if (controls.length > 128) return unknown();
  for (const field of controls) {
    const type = (field.getAttribute('type') || '').toLowerCase();
    const auto = (field.getAttribute('autocomplete') || '').toLowerCase();
    const hint = ['id','name','aria-label'].map(name => field.getAttribute(name) || '').join(' ').toLowerCase();
    if (hint.length > 768 || /api[-_ ]?key|access[-_ ]?token|secret|credential|password|one[-_ ]?time|\botp\b/.test(hint)) return result('sensitive', 'unknown');
    if (type.length > 64 || auto.length > 256) return unknown();
    if (type === 'password' || /(?:^|\s)(?:username|current-password|new-password|one-time-code|cc-[a-z-]+)(?:\s|$)/.test(auto)) return result('sensitive', 'unknown');
  }
  if (active.shadowRoot || active.tagName.includes('-') || /^(IFRAME|FRAME)$/.test(active.tagName)) return unknown();
  if (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName)) return result('editable', 'unknown');
  // Shadow focus, custom elements and page-authored ARIA roles stay unknown.
  // The actual noneditable document body is a metadata-only candidate, not AX.
  const role = active.tagName === 'BUTTON' ? 'button' : active.tagName === 'A' && active.hasAttribute('href') ? 'link' : active.tagName === 'BODY' && active === document.body ? 'document' : 'unknown';
  if (role === 'unknown') return unknown();
  // Local focus changes invalidate a sampled result, even when focus returns.
  if (!state.listening) {
    document.addEventListener('focusin', () => { state.generation++; }, true);
    document.addEventListener('focusout', () => { state.generation++; }, true);
    state.listening = true;
  }
  return result('noneditable', role);
}
