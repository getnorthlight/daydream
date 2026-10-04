import { inspectFocus } from './focus.js';

export const HOST = 'com.macmem.browser_bridge';
const EXACT_ID = /^[a-p]{32}$/;
const TOKEN = /^[a-f0-9]{32}$/;
const SENSITIVE = ['1password.com','bitwarden.com','passwords.google.com','chase.com','bankofamerica.com','wellsfargo.com','citi.com','fidelity.com','schwab.com','paypal.com','venmo.com'];
const safeOrigin = (raw, permitted, excluded = [], ordinary = false) => {
  if (typeof raw !== 'string' || raw.length > 2048) return null;
  try {
    const u = new URL(raw);
    if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password || u.search || u.hash) return null;
    const path = decodeURIComponent(u.pathname).toLowerCase();
    if (/login|signin|sign-in|oauth|password|checkout|payment|wallet|bank|token|secret/.test(path)) return null;
    const host=u.hostname.toLowerCase().replace(/\.$/,'');
    if([...SENSITIVE,...excluded].some(d=>host===d||host.endsWith('.'+d)))return null;
    if(/login|signin|oauth|password|wallet|bank|token|secret/.test(host))return null;
    return ordinary || permitted.includes(u.origin) ? u.origin : null;
  } catch { return null; }
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// A single native port, no page/content-script ingress. Nothing starts until
// the user invokes the extension action. There is no permission request path.
export class ChromeBridge {
  constructor(api, now = () => performance.now()) {
    this.api = api; this.now = now; this.port = null; this.epoch = 1;
    this.busy = false; this.lastProbe = -Infinity; this.seen = new Set();
    this.status = 'disconnected';
  }
  invalidate() { this.epoch++; }
  disconnect(reason = 'disconnected') {
    this.invalidate(); const old = this.port; this.port = null;
    this.seen.clear(); this.status = reason; old?.disconnect();
  }
  connect() {
    if (this.port) return;
    if (!EXACT_ID.test(this.api.runtime.id)) { this.status = 'invalid_extension'; return; }
    try {
      const port = this.api.runtime.connectNative(HOST); this.port = port;
      this.status = 'awaiting_native_policy';
      port.onDisconnect.addListener(() => { if (this.port === port) this.disconnect('native_unavailable'); });
      port.onMessage.addListener(request => { if (this.port === port) void this.probe(request, port); });
      port.postMessage({ version: 1, kind: 'hello', extensionID: this.api.runtime.id, textEnabled: false });
    } catch { this.disconnect('native_unavailable'); }
  }
  async probe(request, port = this.port) {
    if (request?.kind === 'unavailable') { this.disconnect('native_unavailable'); return; }
    if (!port || port !== this.port || this.busy || this.now() - this.lastProbe < 100) return;
    if (!request || request.version !== 1 || request.kind !== 'probe' || request.textEnabled !== false ||
        !TOKEN.test(request.nonce) || !Number.isSafeInteger(request.policyRevision) || request.policyRevision < 1 ||
        !Array.isArray(request.allowedOrigins) || request.allowedOrigins.length > 32 ||
        request.allowedOrigins.some(o => typeof o !== 'string' || o.length > 256 || safeOrigin(o, [o]) !== o) ||
        (request.ordinaryMetadata !== undefined && (request.ordinaryMetadata !== true || request.allowedOrigins.length !== 0 ||
          !Array.isArray(request.excludedDomains) || request.excludedDomains.length > 64 ||
          request.excludedDomains.some(d=>typeof d!=='string'||d.length>253||!/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(d)))) ||
        this.seen.has(request.nonce)) { this.disconnect('invalid_native_policy'); return; }
    this.seen.add(request.nonce);
    if (this.seen.size > 128) this.seen.delete(this.seen.values().next().value);
    this.lastProbe = this.now(); this.busy = true;
    const epoch = this.epoch, started = this.now();
    const valid = () => this.port === port && this.epoch === epoch && this.now() - started <= 500;
    let result, timer;
    try {
      result = await Promise.race([(async () => {
      const a = await this.context(request.allowedOrigins, valid, request.excludedDomains, request.ordinaryMetadata);
      if (!valid() || !a) throw Error();
      const focus = await this.focus(a);
      if (!valid() || !focus || focus.safety !== 'noneditable') throw Error();
      const b = await this.context(request.allowedOrigins, valid, request.excludedDomains, request.ordinaryMetadata);
      if (!valid() || !same(a, b)) throw Error();
      const again = await this.focus(a);
      if (!valid() || !same(focus, again)) throw Error();
      const c = await this.context(request.allowedOrigins, valid, request.excludedDomains, request.ordinaryMetadata);
      if (!valid() || !same(a, c)) throw Error();
      return { version: 1, kind: 'observation', nonce: request.nonce, policyRevision: request.policyRevision,
        windowMode: 'normal', tabMode: 'normal', windowID: a.windowID, tabID: a.tabID,
        frameID: 0, documentID: a.documentID, navigationGeneration: epoch,
        focusID: focus.focusID, focusGeneration: focus.focusGeneration, role: focus.role,
        safety: 'noneditable', origin: a.origin, textEnabled: false };
      })(), new Promise((_, reject) => { timer = setTimeout(() => reject(Error()), 500); })]);
      this.status = 'metadata_candidate';
    } catch {
      // No URLs, titles, field hints, candidate values or exception messages.
      result = { version: 1, kind: 'unavailable', nonce: request.nonce, reason: 'missing_or_changed_proof' };
      this.status = 'missing_or_changed_proof';
    } finally { clearTimeout(timer); this.busy = false; }
    if (this.port === port) { try { port.postMessage(result); } catch { this.disconnect('native_unavailable'); } }
  }
  async context(permitted, valid = () => true, excluded = [], ordinary = false) {
    if (!valid()) return null;
    const window = await this.api.windows.getLastFocused({ populate: false });
    if (!valid() || window?.incognito !== false || window.focused !== true || !Number.isInteger(window.id)) return null;
    const tabs = await this.api.tabs.query({ windowId: window.id, active: true });
    if (!valid() || tabs.length !== 1) return null;
    const tab = tabs[0];
    if (tab.incognito !== false || tab.active !== true || tab.windowId !== window.id || tab.status !== 'complete' || !Number.isInteger(tab.id)) return null;
    const origin = safeOrigin(tab.url, permitted, excluded, ordinary);
    if (!origin || !await this.api.permissions.contains({ origins: [origin + '/*'] }) || !valid()) return null;
    const frames = await this.api.webNavigation.getAllFrames({ tabId: tab.id });
    if (!valid() || !frames || frames.length !== 1) return null; // unknown/cross-frame capture is unsupported
    const frame = frames[0];
    if (frame.frameId !== 0 || frame.parentFrameId !== -1 || frame.documentLifecycle !== 'active' || frame.errorOccurred ||
        typeof frame.documentId !== 'string' || !/^[a-f0-9-]{36}$/i.test(frame.documentId) || frame.url !== tab.url) return null;
    return { windowID: window.id, tabID: tab.id, documentID: frame.documentId, origin, url: tab.url };
  }
  async focus(context) {
    const result = await this.api.scripting.executeScript({ target: { tabId: context.tabID, documentIds: [context.documentID] }, world: 'ISOLATED', func: inspectFocus });
    if (result.length !== 1 || result[0].frameId !== 0 || result[0].documentId !== context.documentID) return null;
    const f = result[0].result;
    if (!f || !['button', 'link', 'document'].includes(f.role) || f.safety !== 'noneditable' ||
        !/^[a-f0-9-]{36}$/i.test(f.focusID) || !Number.isSafeInteger(f.focusGeneration) || f.focusGeneration < 1) return null;
    return { role: f.role, safety: f.safety, focusID: f.focusID, focusGeneration: f.focusGeneration };
  }
}
