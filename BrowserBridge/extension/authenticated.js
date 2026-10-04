import { ChromeBridge, HOST } from './bridge.js';
import { bindInvalidation } from './lifecycle.js';

const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const token = value => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
const b64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)));
const unb64 = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
const fields = ['version', 'browser', 'extensionID', 'clientNonce', 'sessionID', 'sequence', 'payload', 'signature'].sort().join(',');
export const signedBytes = (frame, direction) => encoder.encode(`daydream-browser-metadata-v3\n${direction}\n${frame.browser}\n${frame.extensionID}\n${frame.clientNonce}\n${frame.sessionID}\n${frame.sequence}\n${frame.payload}`);
export async function signFrame(payload, binding, key, cryptoAPI = crypto) {
  const frame = { version: 3, browser: 'chrome', ...binding, payload: b64(encoder.encode(JSON.stringify(payload))), signature: '' };
  frame.signature = b64(await cryptoAPI.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, signedBytes(frame, 'extension-to-app')));
  if (encoder.encode(JSON.stringify(frame)).length > 4096) throw Error('frame_bound');
  return frame;
}

// Explicit local trust is injected by reviewed enrollment, never from messages.
// No enrollment, key creation/storage or auto-connect here. Runtime background
// remains inert until the app owner supplies that lifecycle and reviews pins.
export class AuthenticatedChromeBridge {
  constructor(api, trust, now = () => performance.now(), cryptoAPI = crypto) {
    this.api = api; this.trust = trust; this.now = now; this.crypto = cryptoAPI;
    this.collector = new ChromeBridge(api, now); this.port = null; this.locked = false;
    this.browser = trust?.browser ?? 'chrome';
    this.status = 'unconfigured'; this.session = null; this.sequence = 0;
  }
  invalidate() { this.collector.invalidate(); }
  disconnect(reason = 'disconnected') {
    const port = this.port; this.port = null; this.collector.disconnect();
    this.cleanup?.(); this.cleanup = null;
    this.session = null; this.sequence = 0; this.status = reason;
    port?.disconnect();
  }
  connect() {
    if (this.port) return;
    const t = this.trust;
    const validID = this.browser === 'chrome' ? /^[a-p]{32}$/ : /^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$/;
    if (!t || !['chrome','safari'].includes(this.browser) || !validID.test(t.extensionID) || t.extensionID !== this.api.runtime.id ||
        t.extensionPrivateKey?.type !== 'private' || t.extensionPrivateKey.extractable !== false ||
        t.appPublicKey?.type !== 'public' || t.extensionPrivateKey.algorithm?.namedCurve !== 'P-256' ||
        t.appPublicKey.algorithm?.namedCurve !== 'P-256') { this.status = 'trusted_enrollment_missing'; return; }
    try {
      this.cleanup = bindInvalidation(this.api, this);
      const port = this.api.runtime.connectNative(HOST); this.port = port;
      this.clientNonce = this.crypto.randomUUID().replaceAll('-', '');
      this.collector = new ChromeBridge(this.api, this.now);
      this.status = 'awaiting_authenticated_app';
      port.onDisconnect.addListener(() => { if (this.port === port) this.disconnect('native_unavailable'); });
      port.onMessage.addListener(frame => { if (this.port === port) void this.receive(frame, port); });
      port.postMessage({ version: 3, kind: 'metadata_hello', browser: this.browser, extensionID: t.extensionID, clientNonce: this.clientNonce, textEnabled: false });
    } catch { this.disconnect('native_unavailable'); }
  }
  async receive(frame, port = this.port) {
    if (!port || port !== this.port) return;
    if (this.locked) { this.disconnect('overlapping_signed_request'); return; }
    this.locked = true;
    const epoch = this.collector.epoch, started = this.now(), clientNonce = this.clientNonce;
    const valid = () => this.port === port && this.clientNonce === clientNonce && this.collector.epoch === epoch && this.now() - started <= 1000;
    try {
      if (!frame || Object.keys(frame).sort().join(',') !== fields || encoder.encode(JSON.stringify(frame)).length > 4096 ||
          frame.version !== 3 || frame.browser !== this.browser || frame.extensionID !== this.trust.extensionID || frame.clientNonce !== clientNonce ||
          !token(frame.sessionID) || (this.session && frame.sessionID !== this.session) ||
          !Number.isSafeInteger(frame.sequence) || frame.sequence <= this.sequence ||
          typeof frame.payload !== 'string' || typeof frame.signature !== 'string') throw Error();
      const payload = unb64(frame.payload), signature = unb64(frame.signature);
      if (payload.length > 2600 || signature.length !== 64 ||
          !await this.crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, this.trust.appPublicKey,
            signature, signedBytes(frame, 'app-to-extension')) || !valid()) throw Error();
      const request = JSON.parse(decoder.decode(payload));
      if(request.kind==='diagnostic'){
        if(Object.keys(request).sort().join(',')!==['kind','nonce','deployment','issuedAt'].sort().join(',') ||
          !/^[a-f0-9-]{36}$/.test(request.nonce)||!/^[a-f0-9]{64}$/.test(request.deployment)||!Number.isFinite(request.issuedAt))throw Error();
        this.session=frame.sessionID;this.sequence=frame.sequence;
        const reply=await signFrame({...request,kind:'diagnostic_ack',runtimeID:this.api.runtime.id,contentRead:false},
          {browser:this.browser,extensionID:this.trust.extensionID,clientNonce,sessionID:this.session,sequence:frame.sequence},this.trust.extensionPrivateKey,this.crypto);
        if(!valid())throw Error();port.postMessage(reply);this.status='diagnostic_acknowledged';return;
      }
      const keys=['version','kind','nonce','policyRevision','allowedOrigins','textEnabled'];
      if(request.ordinaryMetadata===true)keys.push('ordinaryMetadata','excludedDomains');
      if (Object.keys(request).sort().join(',') !== keys.sort().join(',')) throw Error();
      this.session = frame.sessionID; this.sequence = frame.sequence;
      let candidate;
      // Reuse the existing deny-first Chrome/isolated-world collector; no page
      // message can enter this virtual port and no unsigned candidate is sent.
      const local = { postMessage: value => { candidate = value; }, disconnect() {} };
      this.collector.port = local;
      await this.collector.probe(request, local);
      if (!valid() || !candidate) throw Error();
      const result = await signFrame(candidate, { browser: this.browser, extensionID: this.trust.extensionID, clientNonce,
        sessionID: this.session, sequence: frame.sequence }, this.trust.extensionPrivateKey, this.crypto);
      if (!valid()) throw Error();
      port.postMessage(result); this.status = candidate.kind === 'observation' ? 'signed_metadata_candidate' : 'missing_or_changed_proof';
    } catch { if (this.port === port) this.disconnect('authentication_or_context_changed'); }
    finally { this.locked = false; }
  }
}
