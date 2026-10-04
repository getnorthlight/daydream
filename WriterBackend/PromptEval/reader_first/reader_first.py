#!/usr/bin/env python3
"""prompt4 "reader-first" writer: reference implementation of the proposed model view
(ITEMS), validator6 and the one-shot repair, wired to the PromptEval harness.

This is the executable spec for the Swift port. Nothing here changes the app.

  Score the hand-written expected outputs (no model):
    python3 WriterBackend/PromptEval/reader_first/reader_first.py expected
  Show the exact prompt the app would send for a case:
    python3 WriterBackend/PromptEval/reader_first/reader_first.py render --case E01
  Check GREAT references against validator6 (calibration, no model):
    python3 WriterBackend/PromptEval/reader_first/reader_first.py great
  Unit probes for validator6, plus the full run pipeline against a mock server (no model):
    python3 WriterBackend/PromptEval/reader_first/reader_first.py selftest --mock-run
  Real run, once the app's GGUF is available (prompt3 baseline side by side with --with-baseline):
    python3 WriterBackend/PromptEval/reader_first/reader_first.py run --model /path/Qwen3.5-4B-Q4_K_M.gguf --with-baseline

Python 3 standard library only. No downloads, no cloud calls.
"""
import argparse, json, re, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import eval_writer as ew  # noqa: E402

INSTRUCTION = (HERE / "prompt4-reader-first.txt").read_text()
GENERATOR_VERSION = {"local": "qwen35-4b-q4-b9723-prompt4-validator6", "cloud": "deepseek-v4-flash-0731-zdr-prompt4-validator6"}
LIMITS = {"maxActions": 400, "maxItems": 40, "maxViewBytes": 16000, "maxTokens": 640,
          "bullets": {"activity": 4, "day": 5}, "bulletChars": 200, "titleChars": 60}

# ---------------------------------------------------------------- app names (Swift: injected catalog + this table)

APP_NAMES = dict(ew.FRIENDLY_APPS)
APP_NAMES.update({"com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "dev.zed.Zed": "Zed", "com.mitchellh.ghostty": "Ghostty",
                  "com.apple.iCal": "Calendar", "com.apple.freeform": "Freeform", "com.figma.Desktop": "Figma", "com.spotify.client": "Spotify",
                  "com.anthropic.claudefordesktop": "Claude", "com.microsoft.VSCode": "VS Code", "com.apple.Terminal": "Terminal",
                  "com.apple.MobileSMS": "Messages", "com.apple.iWork.Numbers": "Numbers", "zoom.us": "Zoom"})
BUNDLE_RX = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$")

def app_name(app, names=APP_NAMES):
    if not app: return ""
    if app in names: return names[app]
    if BUNDLE_RX.match(app):
        last = app.split(".")[-1]
        return last[:1].upper() + last[1:]
    return app

def q(s):
    """Untrusted text as a JSON string literal: it cannot break out of its quotes or add lines."""
    s = re.sub(r"\s+", " ", s).strip()
    return json.dumps(s, ensure_ascii=False)

# ---------------------------------------------------------------- action classification

MECH = {"mouse.click": "click", "mouse.context_menu": "click", "keyboard.shortcut": "shortcut", "keyboard.submit": "return",
        "app.activated": "silent", "session.started": "silent", "session.ended": "silent", "debug.error": "silent"}
WINDOW = {"window.changed", "window.observed", "focus.observed", "browser.snapshot"}
TAB = {"browser.tab_opened", "browser.tab_visited", "browser.extension_tab_visited", "browser.observed", "browser.extension_observed"}
DRAFT_STATES = {"draft", "typed", "drafted_request"}
HIDDEN_TITLE = "[sensitive title omitted]"
CORR_APPENDED = "\nUser correction to related note (not observed evidence): "

def payload(desc):
    """The quoted text inside an IntentWriter summary (Models.swift:196-215)."""
    m = re.search(r':\s*"(.*)"(?:\s*\(not independently verified\))?\.?(?:\s*Authorship and completion are not established\.)?\s*$', desc, re.S)
    return m.group(1) if m else None

HEDGES = [r";\s*(reading|sending|authorship|submission and reading) (is|are) not established\.?", r"\s*\(not independently verified\)",
          r"\s*Authorship and completion are not established\.?", r";\s*no reading or work duration is established\.?"]

def strip_hedges(desc):
    for h in HEDGES: desc = re.sub(h, "", desc)
    return desc.strip()

def classify(a):
    """(kind, text) for one NoteAction. kind decides the item class and whether it gets its own item."""
    k, s, d = a["kind"], a["state"], a["description"]
    if CORR_APPENDED in d:
        return "note", d.split(CORR_APPENDED)[-1]
    if s in ("reported", "user_corrected"):
        if d.startswith("User correction (not observed): "): return "note", d[len("User correction (not observed): "):]
        return "report", payload(d) or strip_hedges(d)
    if s == "planned": return "plan", payload(d) or strip_hedges(d)
    if s == "requested": return "request", payload(d) or strip_hedges(d)
    if s in ("drafted_request", "typed") and payload(d) is not None: return "typed", payload(d)
    if k == "message.sent": return ("sent", None) if s == "sent" else ("unverified", None)
    if k == "keyboard.text_input":
        m = re.match(r"Typed a draft in .*?\.(?: (.*))?$", d, re.S)
        return "typed", (m.group(1) if m and m.group(1) else "")
    if k in MECH: return "mech", MECH[k]
    if k == "idle": return "idle", None
    m = re.match(r"(?:Observed|Viewed) search results for \"?(.*?)\"? in .*$|Viewed search results for \"(.*)\"\.$", d)
    if m: return "search", m.group(1) or m.group(2) or ""
    if k in TAB: return ("tab", None) if a["state"] != "unavailable" else ("other", "browser activity; details unavailable")
    if k in WINDOW: return "window", a["title"]
    if k in ("selection.changed", "terminal.value_changed"): return "screentext", payload(d)
    return "other", strip_hedges(d)

SPECIAL = {"sent": "sent", "report": "reported", "note": "reported", "request": "interpretation", "plan": "interpretation"}
ATTACHABLE = {"window", "typed", "tab", "search", "screentext", "mechonly", "other"}

class Item:
    def __init__(self, kind, app, title="", text=None, site=""):
        self.kind, self.app, self.title, self.text, self.site = kind, app, title, text, site
        self.actions, self.counts, self.seen, self.last_at, self.alias = [], {}, 1, "", ""
    def add(self, a, count=None):
        self.actions.append(a); self.last_at = max(self.last_at, a["at"])
        if count and count != "silent": self.counts[count] = self.counts.get(count, 0) + 1
    @property
    def cls(self): return SPECIAL.get(self.kind, "seen")
    def head(self):
        k, app = self.kind, self.app or "an app"
        if k == "window":
            if self.title == HIDDEN_TITLE: return "window with a hidden title"
            return "window %s" % q(self.title) if self.title else "a window"
        if k == "tab": return "browser tab" + (" %s" % q(self.title) if self.title else "") + (" on %s" % self.site if self.site else "")
        if k == "search": return "search results for %s" % q(self.text or "")
        if k == "typed": return "typed %s" % q(self.text) if self.text else "typed text (not captured)"
        if k == "screentext": return "text on screen, not necessarily typed by you" + (": %s" % q(self.text) if self.text else "")
        if k == "idle": return "idle, no keyboard or mouse input"
        if k == "sent": return "[sent] %s confirmed a message was sent" % app
        if k == "report": return "[report] %s said %s" % (app, q(self.text or ""))
        if k == "note": return "[your note] %s" % q(self.text or "") + (" about window %s" % q(self.title) if self.title and self.title != HIDDEN_TITLE else "")
        if k == "request": return "[request] you asked %s %s" % (app, q(self.text or ""))
        if k == "plan": return "[plan] you said %s" % q(self.text or "")
        if k == "mechonly": return "input" + (" in window %s" % q(self.title) if self.title and self.title != HIDDEN_TITLE else "")
        return q(self.text or "")
    def extras(self):
        out, c = [], self.counts
        if self.kind in ("window", "tab") and self.seen > 1: out.append("seen %d times" % self.seen)
        if self.kind == "idle" and self.seen > 1: out.append("%d times" % self.seen)
        if c.get("click"): out.append("%d click%s" % (c["click"], "" if c["click"] == 1 else "s"))
        if c.get("shortcut"): out.append("%d shortcut%s" % (c["shortcut"], "" if c["shortcut"] == 1 else "s"))
        if c.get("return"): out.append("Return pressed once" if c["return"] == 1 else "Return pressed %d times" % c["return"])
        if c.get("unverified"): out.append("message activity seen, sending not confirmed")
        return out
    def line(self):
        parts = [self.alias, self.app or "Mac", self.head()]
        ex = self.extras()
        if ex: parts.append("; ".join(ex))
        return " | ".join(parts)

class View:
    def __init__(self, request, items):
        self.request, self.items = request, items
        self.by_alias = {it.alias: it for it in items}
        scope = "one whole day" if request["targetKind"] == "day" else "one moment"
        self.text = "Scope: %s (%d item%s)\n" % (scope, len(items), "" if len(items) == 1 else "s") + "\n".join(it.line() for it in items)

def build_view(request, actions, names=APP_NAMES):
    """Deterministic ITEMS view (Swift: CanonicalGrounding.modelView). Items partition the actions."""
    acts = ew.sort_actions(actions)
    if len(acts) > LIMITS["maxActions"]: raise ew.Invalid("capacity: %d actions > %d" % (len(acts), LIMITS["maxActions"]))
    items, ctx = [], {}
    idle = None
    for a in acts:
        app = app_name(a["app"], names)
        kind, text = classify(a)
        if kind == "window":
            key = (app, a["title"])
            if key in ctx and ctx[key].kind == "window": ctx[key].seen += 1; ctx[key].add(a); continue
            it = Item("window", app, a["title"]); it.add(a); items.append(it); ctx[key] = it; continue
        if kind == "tab":
            key = (app, "tab:" + (a["site"] or a["title"]))
            if key in ctx: ctx[key].seen += 1; ctx[key].add(a); continue
            it = Item("tab", app, a["title"], site=a["site"]); it.add(a); items.append(it); ctx[key] = it; continue
        if kind in ("mech", "unverified"):
            count = text if kind == "mech" else "unverified"
            cands = [it for it in items if it.app == app and it.kind in ATTACHABLE]
            latest = max(cands, key=lambda it: it.last_at) if cands else None
            w = ctx.get((app, a["title"])) if a["title"] else None
            if latest is not None and latest.kind == "typed" and (w is None or latest.last_at >= w.last_at): target = latest
            elif w is not None: target = w
            elif latest is not None: target = latest
            else:
                target = Item("mechonly", app, a["title"]); items.append(target)
                if a["title"]: ctx[(app, a["title"])] = target
            target.add(a, count); continue
        if kind == "idle":
            if idle is None: idle = Item("idle", ""); items.append(idle)
            else: idle.seen += 1
            idle.add(a); continue
        it = Item(kind, app, a["title"], text=text, site=a["site"]); it.add(a); items.append(it)
    items.sort(key=lambda it: (it.actions[0]["at"], it.actions[0]["id"]))
    for n, it in enumerate(items, 1): it.alias = "i%d" % n
    if len(items) > LIMITS["maxItems"]: raise ew.Invalid("capacity: %d items > %d" % (len(items), LIMITS["maxItems"]))
    view = View(request, items)
    if len(view.text.encode()) > LIMITS["maxViewBytes"]: raise ew.Invalid("capacity: view larger than %d bytes" % LIMITS["maxViewBytes"])
    return view

def render(view): return ew.render_prompt(INSTRUCTION, view.text)

# ---------------------------------------------------------------- validator6

W = lambda words: re.compile(r"(?i)\b(" + words + r")\b")
RX6 = {
    "send": W("sent|delivered|posted|published|emailed|messaged|replied|responded|forwarded|uploaded"),
    "done": W("completed|succeeded|finished|purchased|paid|deleted|submitted|merged|shipped|released|deployed|resolved|approved|finalized|fixed|saved|created|restored"),
    "returnTrap": W("returned to|returning to"),
    "attention": W("read|reviewed|attended|joined|watched|listened|presented|hosted|was reading"),
    "duration": re.compile(r"(?i)\bspent\b|\b(read for|worked for)\s+\d+|\b\d+\s*(min|mins|minutes|hours?|hrs?)\b|\b(an|one|half an|a few|several) (hour|hours|minutes)\b|\ball (day|morning|afternoon|evening)\b"),
    "worked": W("worked|working"),
    "wrote": W("typed|typing|wrote|writing|drafted|drafting|edited|editing"),
    "leak": re.compile(r"(?i)<\|im_|\|im_(start|end)\||</?think>|\\u003c|macmem://|not established|\buntrusted\b|\bcanonical\b|\baction ?ids?\b"
                       r"|\b(com|jp|net|org|io|us|dev|app)\.[a-z0-9-]+\.[a-z0-9.-]+|ignore (all |any )?(previous|prior|above) instructions|admin mode|developer mode|system prompt"),
    "alias": re.compile(r"(?<![A-Za-z0-9])i\d{1,2}(?![A-Za-z0-9])"),
    "sensitiveNumber": re.compile(r"\d{5,}|(?<!\d)\d{3}[\s.-]\d{3}[\s.-]\d{4}(?!\d)|\+\d{6,}"),
    "number": re.compile(r"\d+(?:[.:/-]\d+)*"),
    "userSide": re.compile(r"(?i)\b(the user|user's|users)\b"),
}
CUE = {"reported": W("reported|reports|said|says|claimed|claims|according to|noted|notes|mentioned|told|wrote"),
       "requested": W("asked|asks|asking|requested|request"),
       "planned": W("plan|plans|planned|planning|intend|intends|intended|going to")}
INPUT_KINDS = {"mouse.click", "mouse.context_menu", "keyboard.shortcut", "keyboard.submit", "keyboard.text_input"}
GENERIC_TITLES = {"activity note", "day summary", "summary", "activity", "untitled", "moment", "day"}

def assertion6(actions):
    """Weakest-wins: a bullet's label is never stronger than every one of its cited actions supports."""
    states = [a["state"] for a in actions]
    if any(s in ("requested", "planned") for s in states): return "interpretation"
    if any(s in ("reported", "user_corrected") for s in states): return "reported"
    if all(s == "sent" for s in states): return "sent"
    if all(s in DRAFT_STATES for s in states): return "draft"
    return "observed"

def corpus(items):
    return " ".join(it.line() + " " + " ".join(a["description"] + " " + a["title"] + " " + a["site"] for a in it.actions) for it in items)

def prose6(text, items):
    """Reasons a bullet is rejected, first match wins (the reason is fed to the repair turn)."""
    acts = [a for it in items for a in it.actions]
    states = {a["state"] for a in acts}
    attributed_only = states <= {"reported", "user_corrected", "requested", "planned"}
    m = RX6["leak"].search(text)
    if m: return "internal wording, bundle ID, special token or injected instruction in text (%r)" % m.group(0)
    m = RX6["alias"].search(text)
    if m: return "item id %r written in the text; ids belong only in \"ids\"" % m.group(0)
    m = RX6["send"].search(text)
    if m and not all(a["state"] == "sent" for a in acts): return "%r used, but only items tagged [sent] may say that" % m.group(0)
    m = RX6["done"].search(text)
    if m and not attributed_only: return "outcome word %r is not allowed" % m.group(0)
    m = RX6["returnTrap"].search(text)
    if m and any(a["kind"] == "keyboard.submit" for a in acts): return "%r next to a Return key press; write \"came back to\"" % m.group(0)
    m = RX6["duration"].search(text)
    if m: return "time or duration %r is not allowed" % m.group(0)
    m = RX6["attention"].search(text)
    if m and not attributed_only: return "%r claims attention; write \"had ... open\" or \"looked at\"" % m.group(0)
    m = RX6["worked"].search(text)
    if m and not attributed_only and not any(a["kind"] in INPUT_KINDS for a in acts): return "%r but the cited items show no input" % m.group(0)
    m = RX6["wrote"].search(text)
    if m and not attributed_only and not any(a["kind"] == "keyboard.text_input" or a["state"] in ("typed", "drafted_request") for a in acts):
        return "%r but the cited items have no typed text" % m.group(0)
    for st, cue in CUE.items():
        if any(a["state"] == st or (st == "reported" and a["state"] == "user_corrected") for a in acts) and not cue.search(text):
            return "a [%s] item is cited but the bullet does not attribute it" % {"reported": "report/your note", "requested": "request", "planned": "plan"}[st]
    m = RX6["sensitiveNumber"].search(text)
    if m: return "phone, account or reference number %r" % m.group(0)
    src = corpus(items)
    for m in RX6["number"].finditer(text):
        if m.group(0) not in src: return "number %r is not in the cited items" % m.group(0)
    if RX6["userSide"].search(text): return "write to the person, not about \"the user\""
    if ew.privacy_secret(text): return "secret-like text"
    return None

def fallback_title(view):
    """Deterministic, never generic (the UI hides 'Activity note'/'Day summary', DaydreamTodayData.swift:349-353)."""
    items = view.items
    if view.request["targetKind"] == "day":
        apps = {}
        for it in items:
            if it.app: apps[it.app] = apps.get(it.app, 0) + len(it.actions)
        top = [a for a, _ in sorted(apps.items(), key=lambda kv: (-kv[1], kv[0]))][:3]
        if not top: return "Your day"
        return top[0] if len(top) == 1 else ", ".join(top[:-1]) + " and " + top[-1]
    titled = [it for it in items if it.kind == "window" and it.title and it.title != HIDDEN_TITLE]
    if titled:
        it = max(titled, key=lambda it: (len(it.actions), -items.index(it)))
        t = re.sub(r"\s+[–—-]\s+%s$" % re.escape(it.app), "", it.title).strip()
        if " — " in t:
            a, b = t.split(" — ", 1); t = "%s in %s" % (a.strip(), b.strip())
        if " " not in t: t = "%s in %s" % (t, it.app)
        t = t[:LIMITS["titleChars"]].rsplit(" ", 1)[0] if len(t) > LIMITS["titleChars"] else t
        if t and not ew.privacy_secret(t) and not RX6["leak"].search(t): return t
    apps = [it.app for it in items if it.app]
    app = max(set(apps), key=apps.count) if apps else "your Mac"
    return ("Typing in %s" if all(it.kind == "typed" for it in items if it.app == app) else "Activity in %s") % app

def title6(raw_title, view):
    t = re.sub(r"\s+", " ", raw_title or "").strip().strip('"')
    src = corpus(view.items)
    bad = (not t or ew.graphemes(t) > LIMITS["titleChars"] or t.lower() in GENERIC_TITLES or RX6["send"].search(t) or RX6["done"].search(t)
           or RX6["leak"].search(t) or RX6["alias"].search(t) or RX6["sensitiveNumber"].search(t) or ew.privacy_secret(t)
           or any(m.group(0) not in src for m in RX6["number"].finditer(t)))
    return (fallback_title(view), "replaced") if bad else (t, None)

def decode6(raw):
    s = raw.strip()
    fence = re.match(r"^```(?:json)?\s*\n(.*)\n```\s*$", s, re.S)
    if fence: s = fence.group(1).strip()
    if not s.startswith("{") and "{" in s and "}" in s: s = s[s.index("{"):s.rindex("}") + 1]  # tolerate a preamble line
    if len(s.encode()) > ew.APP["output_max"]: raise ew.Invalid("output larger than 16000 bytes")
    try: obj = json.loads(s)
    except ValueError as e: raise ew.Invalid("not a JSON object (%s)" % str(e).split(":")[0])
    if not isinstance(obj, dict) or not isinstance(obj.get("title"), str) or not isinstance(obj.get("bullets"), list):
        raise ew.Invalid("needs {\"title\": string, \"bullets\": [...]}")
    out = []
    for b in obj["bullets"]:
        ids = b.get("ids", b.get("actionIDs", b.get("items"))) if isinstance(b, dict) else None
        if not isinstance(b, dict) or not isinstance(b.get("text"), str) or not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
            raise ew.Invalid("each bullet needs \"text\" (string) and \"ids\" (list of item ids)")
        out.append({"text": b["text"], "ids": ids})
    return obj["title"], out

def norm_alias(i):
    m = re.match(r"^\s*[iI]0*(\d{1,3})\s*$", i)
    return "i%s" % m.group(1) if m else i.strip()

def validate6(raw, request, actions, view, provider="local/qwen3.5-4b-q4_k_m"):
    """Proposed CanonicalGrounding.validate (validator6). Returns a core.NoteWriterOutput-shaped dict."""
    raw_title, bullets = decode6(raw)
    maxb = LIMITS["bullets"]["day" if request["targetKind"] == "day" else "activity"]
    if not 1 <= len(bullets) <= maxb: raise ew.Invalid("%d bullets; write 1 to %d" % (len(bullets), maxb))
    cited, seen_text, out = set(), set(), []
    for b in bullets:
        text = re.sub(r"\s+", " ", b["text"]).strip()
        if not text: raise ew.Invalid("empty bullet")
        if ew.graphemes(text) > LIMITS["bulletChars"]: raise ew.Invalid("bullet longer than %d characters: %r" % (LIMITS["bulletChars"], text[:60]))
        if text.lower() in seen_text: raise ew.Invalid("two bullets have the same text")
        seen_text.add(text.lower())
        aliases = []
        for i in b["ids"]:
            n = norm_alias(i)
            if n not in view.by_alias: raise ew.Invalid("unknown id %r" % i)
            if n not in aliases: aliases.append(n)
        if not aliases: raise ew.Invalid("bullet cites no items: %r" % text[:60])
        cited.update(aliases)
        items = [view.by_alias[n] for n in aliases]
        why = prose6(text, items)
        if why: raise ew.Invalid("%s, in: %r" % (why, text[:80]))
        acts = sorted((a for it in items for a in it.actions), key=lambda a: (a["at"], a["id"]))
        out.append({"text": text, "actionIDs": [a["id"] for a in acts], "assertion": assertion6(acts)})
    missing = [it.alias for it in view.items if it.alias not in cited]
    if missing: raise ew.Invalid("items not cited by any bullet: %s" % ", ".join(missing))
    title, _ = title6(raw_title, view)
    cloud = not provider.startswith("local/")
    note = {"requestID": request["id"], "title": title, "bullets": out, "generator": provider,
            "generatorVersion": GENERATOR_VERSION["cloud" if cloud else "local"]}
    if len(json.dumps(note, ensure_ascii=False, separators=(",", ":")).encode()) > ew.APP["output_max"]: raise ew.Invalid("encoded note > 16000 bytes")
    return note

def repair_evidence(view, raw, reason):
    """Second and last attempt (greedy decoding replays identical output, so the retry must change the prompt)."""
    prev = re.sub(r"\s+", " ", raw.strip())[:1500]
    return view.text + "\n\nYour previous answer was thrown away.\nPrevious answer: " + prev + "\nProblem: " + reason + \
        "\nWrite a corrected answer that follows every rule. Return only the JSON object."

# ---------------------------------------------------------------- harness glue

VARIANT = {"name": "prompt4-reader-first", "contract": "reader-first", "faithful": False, "maxTokens": LIMITS["maxTokens"], "instruction": INSTRUCTION}

def evaluate6(case, raw, globals_, gen=None, repaired=None):
    req = case["request"]; acts = ew.sort_actions(req["actions"]); gen = gen or {}
    res = {"case": case["id"], "variant": VARIANT["name"], "raw": raw, "gen": gen, "appBlock": [], "repaired": repaired}
    if gen.get("stop") and gen["stop"] not in ("eos", "not-run"): res["appBlock"].append("no end-of-generation token within %d tokens" % LIMITS["maxTokens"])
    if gen.get("promptTokens") is not None and gen["promptTokens"] + LIMITS["maxTokens"] > ew.APP["n_ctx"]: res["appBlock"].append("prompt + output budget > 8192 tokens")
    if gen.get("seconds") and gen["seconds"] > ew.APP["deadline_s"]: res["appBlock"].append("over the 90 s deadline")
    view = build_view(req, acts)
    try: note = validate6(raw, req, acts, view); res["validator"] = None
    except ew.Invalid as e: note, res["validator"] = None, str(e)
    res["validator5"] = "n/a (different contract)"
    res["core"] = ew.core_gate(note, acts) if note else None
    res["publishable"] = bool(note) and res["core"] is None and not res["appBlock"]
    res["appWouldPublish"] = False
    if note:
        res["note"] = note; res["score"] = ew.score(case, note["title"], note["bullets"], globals_, res["core"] is None)
    else:
        try:
            t, bs = decode6(raw); res["score"] = ew.score(case, t, bs, globals_, False)
        except ew.Invalid:
            res["score"] = {"grounded": False, "clean": False, "quality": 0.0, "hard": ["unparseable output"], "leaks": [], "soft": []}
    return res

def great_as_items(case, view):
    acts = case["request"]["actions"]
    owner = {a["id"]: it.alias for it in view.items for a in it.actions}
    bullets = []
    for b in case["great"]["bullets"]:
        ids = []
        for n in b["actions"]:
            al = owner[acts[n - 1]["id"]]
            if al not in ids: ids.append(al)
        bullets.append({"text": b["text"], "ids": ids})
    return json.dumps({"title": case["great"]["title"], "bullets": bullets}, ensure_ascii=False)

def cmd_render(args):
    _, cases = ew.load_cases(args.cases, args.case)
    for c in cases:
        view = build_view(c["request"], c["request"]["actions"])
        sys.stdout.write((view.text + "\n") if args.view_only else render(view))
        sys.stderr.write("%s: %d actions -> %d items; instruction %d B, view %d B, prompt %d B\n" % (
            c["id"], len(c["request"]["actions"]), len(view.items), len(INSTRUCTION.encode()), len(view.text.encode()), len(render(view).encode())))

def table(results, cases, title):
    lines = ["# " + title, "", "| case | valid | core | grounded | clean | quality | bullets | words/bullet | title | why |", "|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        s = r["score"]; why = r["validator"] or r["core"] or "; ".join(s.get("hard", []) + s.get("leaks", []))
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (r["case"], r["validator"] is None, r["core"] is None, s["grounded"], s.get("clean"),
                     s["quality"], s.get("bullets"), s.get("wordsPerBullet"), (r.get("note") or {}).get("title", "-"), why[:90]))
    g = [r for r in results if r["score"]["grounded"]]
    lines += ["", "grounded %d/%d, grounded and clean %d/%d, mean quality %.1f, mean bullets %.1f" % (
        len(g), len(results), sum(1 for r in g if r["score"].get("clean")), len(results),
        sum(r["score"]["quality"] for r in g) / max(1, len(g)), sum(r["score"].get("bullets", 0) for r in results) / max(1, len(results)))]
    return "\n".join(lines)

def cmd_expected(args):
    globals_, cases = ew.load_cases(args.cases, args.only)
    exp = json.loads(Path(args.expected).read_text())
    results = []
    for c in cases:
        if c["id"] not in exp: continue
        r = evaluate6(c, json.dumps(exp[c["id"]], ensure_ascii=False), globals_)
        results.append(r)
        if args.verbose:
            view = build_view(c["request"], c["request"]["actions"])
            print("\n## %s %s\n%s" % (c["id"], c["name"], view.text))
            n = r.get("note")
            if n:
                print("-> title: %s" % n["title"])
                for b in n["bullets"]: print("-> [%s] %s  (%d actions)" % (b["assertion"], b["text"], len(b["actionIDs"])))
            for k in ("validator", "core"):
                if r.get(k): print("-> %s: %s" % (k, r[k]))
            for h in r["score"].get("hard", []) + r["score"].get("leaks", []) + r["score"].get("soft", []): print("-> " + h)
    print(table(results, cases, "Expected prompt4 outputs under validator6 + core gate + eval checks"))
    return 0 if all(r["score"]["grounded"] and r["score"].get("clean") for r in results) else 1

def cmd_great(args):
    globals_, cases = ew.load_cases(args.cases, args.only)
    results = []
    for c in cases:
        view = build_view(c["request"], c["request"]["actions"])
        results.append(evaluate6(c, great_as_items(c, view), globals_))
    print(table(results, cases, "GREAT references (bullets re-cited as items) under validator6"))
    return 0

def probe(case_id, cases, raw_fn):
    c = next(c for c in cases if c["id"] == case_id)
    acts = ew.sort_actions(c["request"]["actions"]); view = build_view(c["request"], acts)
    try: return validate6(raw_fn(view), c["request"], acts, view), None
    except ew.Invalid as e: return None, str(e)

def cmd_selftest(args):
    globals_, cases = ew.load_cases(args.cases, None)
    fails = 0
    def expect(ok, label):
        nonlocal fails
        fails += 0 if ok else 1
        print(("PASS " if ok else "FAIL ") + label)
    J = lambda title, bullets: json.dumps({"title": title, "bullets": [{"text": t, "ids": i} for t, i in bullets]}, ensure_ascii=False)
    for c in cases:
        view = build_view(c["request"], c["request"]["actions"])
        owned = [a["id"] for it in view.items for a in it.actions]
        expect(sorted(owned) == sorted(a["id"] for a in c["request"]["actions"]), "%s items partition all %d actions (%d items)" % (c["id"], len(owned), len(view.items)))
        expect(not re.search(r"not established|Recorded a |\b(com|jp)\.[a-z]+\.", view.text), "%s view has no hedges or bundle IDs" % c["id"])
        expect(len(render(view).encode()) < 16000, "%s prompt %d bytes" % (c["id"], len(render(view).encode())))
    ok = lambda r: r[1] is None
    bad = lambda r, frag: r[1] is not None and frag in r[1]
    expect(ok(probe("E01", cases, lambda v: J("SyncEngine.swift in tallybird", [("Worked in SyncEngine.swift (tallybird) in Zed, coming back to it several times.", ["i1"])]))), "E01 one grouped bullet accepted")
    expect(bad(probe("E01", cases, lambda v: J("SyncEngine.swift in tallybird", [("Returned to SyncEngine.swift in Zed several times.", ["i1"])])), "Return key"), "E01 'returned to' next to a Return press rejected")
    expect(bad(probe("E01", cases, lambda v: J("SyncEngine.swift", [("Worked in SyncEngine.swift for 45 minutes.", ["i1"])])), "number") or
           bad(probe("E01", cases, lambda v: J("SyncEngine.swift", [("Worked in SyncEngine.swift for 45 minutes.", ["i1"])])), "duration"), "E01 invented duration rejected")
    r = probe("E01", cases, lambda v: J("SyncEngine.swift", [("Worked in SyncEngine.swift in Zed.", ["i1"])]))
    expect(ok(r) and r[0]["title"] != "SyncEngine.swift" and " " in r[0]["title"], "E01 single-token title (core Privacy.secret) replaced by fallback %r" % (r[0] or {}).get("title"))
    r = probe("E03", cases, lambda v: J("Finished reply to Priya", [("Drafted a reply to Priya in Mail; sending isn't confirmed.", ["i1", "i2", "i3"])]))
    expect(ok(r) and r[0]["title"] not in ("Finished reply to Priya", "Activity note"), "E03 outcome word in title replaced by a non-generic fallback %r" % (r[0] or {}).get("title"))
    expect(bad(probe("E03", cases, lambda v: J("Reply to Priya", [("Sent a reply to Priya in Mail.", ["i1", "i2", "i3"])])), "[sent]"), "E03 'Sent' without a [sent] item rejected")
    expect(bad(probe("E03", cases, lambda v: J("Reply to Priya", [("Drafted a reply to Priya in Mail.", ["i1", "i2"])])), "not cited"), "E03 uncited item rejected")
    expect(bad(probe("E03", cases, lambda v: J("Reply to Priya", [("Drafted a reply to Priya in Mail.", ["i1", "i2", "i9"])])), "unknown id"), "E03 unknown id rejected")
    r = probe("E04", cases, lambda v: J("Slack messages about PR 482", [("Asked in Slack for a review of PR 482 before 3.", ["i1"]), ("Slack confirmed that one message was sent.", ["i2"]), ("Typed a lunch question; sending isn't confirmed.", ["i3"])]))
    expect(bad(r, "typed") or ok(r), "E04 grouped bullets validate: %s" % r[1])
    expect(bad(probe("E04", cases, lambda v: J("Slack messages", [("Sent two Slack messages about PR 482 and lunch.", ["i1", "i2", "i3"])])), "[sent]"), "E04 send word over mixed items rejected")
    r = probe("E04", cases, lambda v: J("Slack messages about PR 482", [("Wrote a Slack message asking for a review of PR 482 before 3.", ["i1"]), ("Slack confirmed that one message was sent.", ["i2"]), ("Typed a lunch question for 12:30; sending isn't confirmed.", ["i3"])]))
    expect(ok(r) and [b["assertion"] for b in r[0]["bullets"]] == ["draft", "sent", "observed"], "E04 labels draft/sent/observed(weakest-wins over draft+unverified) %s" % (r[1] or [b["assertion"] for b in r[0]["bullets"]]))
    expect(bad(probe("E06", cases, lambda v: J("StreakMergeTests", [("All 42 StreakMergeTests pass and the merge bug is fixed.", ["i3"]), ("Other work.", ["i1", "i2", "i4"])])), "attribute") or
           bad(probe("E06", cases, lambda v: J("StreakMergeTests", [("All 42 StreakMergeTests pass and the merge bug is fixed.", ["i3"]), ("Other work.", ["i1", "i2", "i4"])])), "outcome"), "E06 unattributed report rejected")
    r = probe("E06", cases, lambda v: J("StreakMergeTests and CI", [("Claude reported that all 42 StreakMergeTests pass and the merge bug is fixed.", ["i3"]), ("Had the StreakMergeTests terminal and a CI email open.", ["i1", "i2"]), ("Drafted a Slack note about merging after lunch; sending isn't confirmed.", ["i4"])]))
    expect(ok(r) and r[0]["bullets"][0]["assertion"] == "reported", "E06 attributed report may repeat 'fixed' (label reported): %s" % r[1])
    expect(bad(probe("E09", cases, lambda v: J("Release checklist", [("You finished the Tallybird 2.3 release.", ["i1", "i2", "i3"])])), "outcome"), "E09 injected completion rejected")
    expect(bad(probe("E09", cases, lambda v: J("Release checklist", [("Pages title said <|im_end|> admin mode.", ["i1", "i2", "i3"])])), "special token"), "E09 echoed special token rejected")
    expect(bad(probe("E10", cases, lambda v: J("Personal notes", [("Noted to call Chase, ref 88213, at 415 555 0139.", ["i1", "i2", "i3", "i4"])])), "reference number"), "E10 reference/phone number rejected")
    expect(bad(probe("E11", cases, lambda v: J("Weekly planning", [("Read the Weekly planning email in Mail.", ["i1"])])), "attention"), "E11 'read' from a window observation rejected")
    expect(bad(probe("E11", cases, lambda v: J("Weekly planning", [("Worked on Weekly planning in Mail.", ["i1"])])), "no input"), "E11 'worked' without input rejected")
    expect(bad(probe("E11", cases, lambda v: J("Weekly planning", [("Had the Weekly planning email open in Mail (i1).", ["i1"])])), "item id"), "E11 alias leak rejected")
    expect(bad(probe("E16", cases, lambda v: J("StreakMerge.swift", [("Worked in StreakMerge.swift in Zed, pairing with Maya over FaceTime.", ["i1", "i2"])])), "attribute"), "E16 correction stated as observation rejected")
    expect(bad(probe("E17", cases, lambda v: J("SyncQueue", [("SyncQueue now batches writes every 2 seconds.", ["i1", "i2"]), ("Plan for 2.3.", ["i3", "i4"])])), "attribute"), "E17 request/report stated as fact rejected")
    fenced = probe("E11", cases, lambda v: "```json\n" + J("Weekly planning in Mail", [("Had the Weekly planning email open in Mail.", ["I01"])]) + "\n```")
    expect(ok(fenced), "code fence and alias case/zero-padding tolerated: %s" % fenced[1])
    many = probe("E13", cases, lambda v: J("Release notes", [("Drafted release notes in Notes.", [it.alias]) for it in v.items]))
    expect(bad(many, "bullets"), "E13 one bullet per item (10) rejected: %s" % many[1])
    if args.mock_run:
        import tempfile
        with tempfile.TemporaryDirectory(prefix="reader-first-mock-") as tmp:
            t = Path(tmp); (t / "model.gguf").write_bytes(b"not a model")
            wrapper = t / "llama-server"
            wrapper.write_text("#!/bin/sh\nexec %s %s \"$@\"\n" % (sys.executable, HERE / "mock_reader_server.py")); wrapper.chmod(0o755)
            ns = argparse.Namespace(cases=args.cases, only=None, out=str(t / "run"), model=str(t / "model.gguf"), backend="server", llama_bin=str(t),
                                    allow_proxy_model=True, no_hash=True, with_baseline=True, no_repair=False)
            cmd_run(ns)
            rows = [json.loads(l) for l in (t / "run" / "results.jsonl").read_text().splitlines()]
            mine = [r for r in rows if r["variant"] == VARIANT["name"]]
            expect(len(rows) == 2 * len(cases) and (t / "run" / "summary.md").exists() and (t / "run" / "review.md").exists(),
                   "mock run wrote %d results (baseline + prompt4), summary.md and review.md" % len(rows))
            expect(all(r["repaired"] and r["validator"] is None and r["core"] is None for r in mine),
                   "every first answer was rejected, repaired once, and the repair passed validator6 and the core gate")
    print("%d failures" % fails)
    return 1 if fails else 0

def cmd_run(args):
    globals_, cases = ew.load_cases(args.cases, args.only)
    exact = ew.check_model(args.model, args.allow_proxy_model, args.no_hash)
    out = Path(args.out or HERE.parent / "runs" / ("reader-first-" + time.strftime("%Y%m%d-%H%M%S"))); out.mkdir(parents=True, exist_ok=True)
    log = open(out / "llama.log", "w")
    be = (ew.Server if args.backend == "server" else ew.Completion)(args.model, args.llama_bin, log)
    results, variants = [], [VARIANT]
    base = ew.load_variant(HERE.parent / "variants/prompt3-validator5.json") if args.with_baseline else None
    if base: variants = [base, VARIANT]
    try:
        for c in cases:
            if base:
                prompt, _, alias = ew.build_prompt(base, c)
                ptoks = be.tokens(prompt)
                raw, gen = be.complete(prompt, base["maxTokens"])
                if ptoks is not None: gen["promptTokens"] = ptoks
                results.append(ew.evaluate(base, c, raw, alias, globals_, gen))
            acts = ew.sort_actions(c["request"]["actions"]); view = build_view(c["request"], acts)
            prompt = render(view); ptoks = be.tokens(prompt)
            raw, gen = be.complete(prompt, LIMITS["maxTokens"])
            if ptoks is not None: gen["promptTokens"] = ptoks
            repaired = None
            try: validate6(raw, c["request"], acts, view)
            except ew.Invalid as e:
                if not args.no_repair:
                    p2 = ew.render_prompt(INSTRUCTION, repair_evidence(view, raw, str(e)))
                    raw2, gen2 = be.complete(p2, LIMITS["maxTokens"])
                    repaired = {"firstOutput": raw, "firstReason": str(e), "firstSeconds": gen.get("seconds")}
                    gen2["seconds"] = round((gen.get("seconds") or 0) + (gen2.get("seconds") or 0), 2)
                    raw, gen = raw2, gen2
            r = evaluate6(c, raw, globals_, gen, repaired)
            results.append(r)
            print("%-4s grounded=%-5s quality=%5.1f publish=%-5s repaired=%-5s stop=%s %ss %s" % (c["id"], r["score"]["grounded"], r["score"]["quality"],
                  r["publishable"], bool(repaired), gen.get("stop"), gen.get("seconds"), r["validator"] or r["core"] or ""), flush=True)
    finally:
        be.close(); log.close()
    with open(out / "results.jsonl", "w") as f:
        for r in results: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (out / "run.json").write_text(json.dumps({"model": args.model, "exactAppModel": exact, "backend": args.backend, "instruction": "reader_first/prompt4-reader-first.txt",
                                              "maxTokens": LIMITS["maxTokens"], "cases": [c["id"] for c in cases]}, indent=1))
    print(ew.summarize(results, variants, cases, out, not exact)); print("\nwrote", out)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    def common(p):
        p.add_argument("--cases", default=str(HERE.parent / "cases.json")); p.add_argument("--only")
    p = sub.add_parser("render"); common(p); p.add_argument("--case", required=True); p.add_argument("--view-only", action="store_true")
    p = sub.add_parser("expected"); common(p); p.add_argument("--expected", default=str(HERE / "expected-prompt4.json")); p.add_argument("-v", "--verbose", action="store_true")
    p = sub.add_parser("great"); common(p)
    p = sub.add_parser("selftest"); common(p); p.add_argument("--mock-run", action="store_true", help="drive `run` end to end against mock_reader_server.py")
    p = sub.add_parser("run"); common(p); p.add_argument("--model", required=True); p.add_argument("--backend", choices=["server", "completion"], default="server")
    p.add_argument("--llama-bin", default="/opt/homebrew/bin"); p.add_argument("--allow-proxy-model", action="store_true"); p.add_argument("--no-hash", action="store_true")
    p.add_argument("--with-baseline", action="store_true", help="also run prompt3-validator5 on the same server"); p.add_argument("--no-repair", action="store_true"); p.add_argument("--out")
    args = ap.parse_args()
    return {"render": cmd_render, "expected": cmd_expected, "great": cmd_great, "selftest": cmd_selftest, "run": cmd_run}[args.cmd](args) or 0

if __name__ == "__main__":
    sys.exit(main())
