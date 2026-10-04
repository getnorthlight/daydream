import { AuthenticatedChromeBridge } from './authenticated.js';

// Safari 18.4+ uses the same documentId-targeted isolated-world API. Missing
// IDs, lifecycle, mode or injection result identity deny in the shared reader.
// Safari routes connectNative to its containing app, ignoring the host name.
// No invented document UUID, profile-ID/tab-ID join or private-mode fallback.
export class AuthenticatedSafariBridge extends AuthenticatedChromeBridge {
  constructor(api, trust, now, cryptoAPI) {
    super(api, trust ? { ...trust, browser: 'safari' } : null, now, cryptoAPI);
    this.browser = 'safari';
  }
}
