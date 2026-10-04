// The owner build (typing-all SPEC-LATER §3) always carries both flags:
// `DAYDREAM_OWNER_TYPING` opens expanded and website typing, and website
// typing is the private Chrome typing code (`DAYDREAM_CHROME_TYPING`).
// The owner flag alone is a build error, never a half-owner build.
#if DAYDREAM_OWNER_TYPING && !DAYDREAM_CHROME_TYPING
#error("DAYDREAM_OWNER_TYPING needs DAYDREAM_CHROME_TYPING too: build the owner app with scripts/package.sh and DAYDREAM_OWNER_TYPING=1")
#endif
