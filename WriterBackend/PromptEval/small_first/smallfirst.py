#!/usr/bin/env python3
"""prompt4 small-model-first writer: executable spec for the model view, the lenient
parser and validator6. Python 3 standard library only. Nothing here calls a model.

Pipeline (what the app would do, CanonicalNotes.swift after the change):
  1. model_view(request)  -> numbered ITEMS text + item table (item n -> action IDs).
     Code, not the model, merges repeated micro-actions, drops IDs/hashes/hedges,
     resolves bundle IDs to app names and neutralizes quotes and '<'/'>' in untrusted text.
  2. render(instruction, view, prefill)  -> the Qwen no-thinking prompt, with the
     assistant turn prefilled with '{"title":"' so the reply is always a JSON object.
  3. validate_v6(raw, request, actions, items)  -> a CanonicalNoteOutput-shaped note.
     Lenient parse; per-bullet checks DROP a bad bullet instead of failing the note;
     uncited items are repaired deterministically; the title falls back to a derived
     label instead of a generic one. The note fails only if no model bullet survives.

The stored note shape is unchanged: {requestID,title,bullets:[{text,actionIDs,assertion}],
generator,generatorVersion}; MemoryStore.commitNote (DerivedNotes.swift:146-169) already
accepts bullets that cite several actions.
"""
import json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import eval_writer as ew  # noqa: E402

VIEW_VERSION = "view1"
GENERATOR_VERSION = "qwen35-4b-q4-b9723-prompt4-view1-validator6"
CLOUD_GENERATOR_VERSION = "deepseek-v4-flash-0731-zdr-prompt4-view1-validator6"
PREFILL = '{"title":"'
MAX_TOKENS = 512
LIMITS = {"activity": 4, "day": 6}      # prompt asks for <=3 / <=5; one bullet of grace
TEXT_MAX = 300                          # graphemes; prompt asks for <=20 words
TITLE_MAX = 70

# App-name resolution for bundle IDs (the app passes LocalApp.catalog(); this is the fallback table).
APP_NAMES = dict(ew.FRIENDLY_APPS, **{"com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "com.apple.Terminal": "Terminal",
                                      "com.mitchellh.ghostty": "Ghostty", "dev.zed.Zed": "Zed", "com.apple.dt.Xcode": "Xcode",
                                      "com.anthropic.claudefordesktop": "Claude", "com.figma.Desktop": "Figma", "com.spotify.client": "Spotify",
                                      "com.apple.iCal": "Calendar", "com.apple.freeform": "Freeform", "com.apple.MobileSMS": "Messages"})

# ---------------------------------------------------------------- model view

WINDOW_KINDS = {"window.changed", "window.observed", "focus.observed", "browser.snapshot", "app.activated"}
BROWSER_KINDS = {"browser.tab_visited", "browser.tab_opened", "browser.extension_tab_visited", "browser.observed", "browser.extension_observed"}
CLICK_KINDS = {"mouse.click", "mouse.context_menu"}
LOW_SIGNAL = {"place", "idle", "other"}
CORR_ACTION = "User correction (not observed): "
CORR_NOTE = "\nUser correction to related note (not observed evidence): "
HIDDEN = "[sensitive title omitted]"

def looks_like_bundle(name):
    parts = name.split(".")
    return len(parts) >= 3 and all(p and re.fullmatch(r"[A-Za-z0-9_-]+", p) for p in parts)

def app_name(app):
    if not app: return "Mac"
    if looks_like_bundle(app): return APP_NAMES.get(app) or app.split(".")[-1]
    return app

def clean(s, limit):
    """Untrusted text as the model sees it: one line, no double quotes, no angle brackets."""
    s = re.sub(r"\s+", " ", s.replace('"', "'").replace("<", "‹").replace(">", "›")).strip()
    return s if len(s) <= limit else s[:limit - 1].rstrip() + "…"

AI_NOTE = "text addressed to AI tools"
INJECT = re.compile(r"(?i)\b(?:ignore|disregard|forget) (?:all |any )?(?:the |your )?(?:previous|prior|above|earlier|preceding) (?:instructions|prompts?|rules)|"
                    r"<\|?(?:im_start|im_end|endoftext)|</?think>|\byou are now\b|\bsystem prompt\b|\b(?:admin|developer|god) mode\b|"
                    r"\{\s*[\"'](?:title|bullets)[\"']\s*:|[\"'](?:actionIDs|assertion)[\"']\s*:")

def q(s, limit=240):
    """Quote untrusted text. Text from the first injection marker on is never shown to the model."""
    m = INJECT.search(s)
    if not m: return '"' + clean(s, limit) + '"'
    head = clean(s[:m.start()], limit).rstrip(" :;,-\u2014")
    return '"%s" plus %s' % (head, AI_NOTE) if len(head.split()) >= 2 else AI_NOTE

def _between(d, prefix, suffix):
    if d.startswith(prefix) and d.endswith(suffix) and len(d) >= len(prefix) + len(suffix): return d[len(prefix):len(d) - len(suffix)]
    return None

def classify(a):
    """(family, payload) from kind/state plus the fixed description templates in
    Sources/MemoryCore/Actions.swift:66-86 and Models.swift:190-222."""
    d, k, st, app = a["description"], a["kind"], a["state"], a["app"]
    base, *notes = d.split(CORR_NOTE)
    if base.startswith(CORR_ACTION): return "note", [base[len(CORR_ACTION):]] + notes
    if notes: return "note", notes
    if st == "unavailable": return "unavailable", None
    if k in WINDOW_KINDS or k in BROWSER_KINDS:
        m = re.match(r"Observed search results for (.*) in .*; submission and reading are not established\.$", base, re.S)
        if m: return "search", m.group(1)
        return "place", None
    if k in CLICK_KINDS: return "place", "click"
    if k == "keyboard.shortcut": return "place", "shortcut"
    if k == "keyboard.submit": return "place", "return"
    if k == "keyboard.text_input":
        rest = base[len("Typed a draft in %s." % app):].strip() if base.startswith("Typed a draft in %s." % app) else ""
        return "typed", rest
    if k in ("selection.changed", "terminal.value_changed"):
        return "screen", _between(base, 'Observed text in %s: "' % app, '". Authorship and completion are not established.')
    if k == "message.sent": return ("sent", None) if st == "sent" else ("seen", None)
    if k == "idle" or st == "idle": return "idle", None
    if st == "reported": return "report", _between(base, 'Assistant reported: "', '" (not independently verified).')
    if st == "planned": return "plan", _between(base, 'Stated a plan: "', '".')
    if st == "requested": return "asked", _between(base, 'Asked %s: "' % app, '".')
    if st in ("typed", "drafted_request"):
        return "typed", _between(base, 'Entered text in %s: "' % app, '".') or _between(base, 'Drafted a request in %s: "' % app, '".')
    if st == "viewed_search": return "search", _between(base, 'Viewed search results for "', '".')
    return "other", None

def times(n): return "" if n < 2 else "twice" if n == 2 else "a few times" if n <= 5 else "many times"

def join_and(xs): return xs[0] if len(xs) == 1 else ", ".join(xs[:-1]) + " and " + xs[-1]

def _place_body(it):
    place, app, browser = it["place"], it["app"], it["browser"]
    hidden, same = place == HIDDEN, place.strip().lower() == app.strip().lower()
    inputs = [one if it[key] == 1 else many for key, one, many in
              (("click", "a click", "clicks"), ("shortcut", "a shortcut", "shortcuts"), ("return", "a Return press", "Return presses")) if it[key]]
    if it["open"]:
        what = ("a window with a hidden title open" if hidden else "%s open in a tab" % clean(place, 120) if browser and place else
                "open" if same or not place else "a window titled with " + AI_NOTE + " open" if q(place, 120) == AI_NOTE else q(place, 120) + " open")
        body = what + (" " + times(it["open"]) if it["open"] > 1 else "")
        return body + (", with " + join_and(inputs) if inputs else "")
    where = ("" if not place or same else " in a window with a hidden title" if hidden else " on %s" % clean(place, 120) if browser
             else " in " + q(place, 120))
    return join_and(inputs) + where

def model_view(request, actions=None):
    """Returns (view text, items). items[n] = {family, app, actionIDs, payloads, line}."""
    acts = ew.sort_actions(actions if actions is not None else request["actions"])
    items, index = [], {}
    for a in acts:
        fam, payload = classify(a)
        app = app_name(a["app"])
        if fam == "place":
            browser = a["kind"] in BROWSER_KINDS
            place = (a["site"] or a["title"]) if browser else a["title"]
            key = ("place", app, place)
            if key not in index:
                index[key] = len(items)
                items.append({"family": "place", "app": app, "place": place, "browser": browser, "open": 0, "click": 0, "shortcut": 0,
                              "return": 0, "actionIDs": [], "payloads": [], "kinds": set()})
            it = items[index[key]]
            it[payload or "open"] += 1; it["browser"] = it["browser"] or browser
        elif fam in ("idle", "sent", "seen", "unavailable", "other"):
            key = (fam, app if fam != "idle" else "")
            if key not in index:
                index[key] = len(items)
                items.append({"family": fam, "app": app, "count": 0, "actionIDs": [], "payloads": [], "kinds": set(), "desc": a["description"]})
            it = items[index[key]]; it["count"] += 1
        elif fam == "typed" and ("typed", app, payload) in index:
            it = items[index[("typed", app, payload)]]
        else:
            if fam == "typed": index[("typed", app, payload)] = len(items)
            it = {"family": fam, "app": app, "actionIDs": [], "payloads": [p for p in (payload if isinstance(payload, list) else [payload]) if p], "kinds": set()}
            items.append(it)
        it["actionIDs"].append(a["id"]); it["kinds"].add(a["kind"])
    lines = []
    for n, it in enumerate(items, 1):
        f, p = it["family"], it["payloads"]
        body = {"place": lambda: _place_body(it),
                "typed": lambda: 'typed ' + q(p[0]) if p else "typed text (not captured)",
                "screen": lambda: "text on screen " + q(p[0]) if p else "text on screen",
                "search": lambda: "search results for " + q(p[0], 160),
                "sent": lambda: "SENT - the app confirmed a message was sent" + (" " + times(it["count"]) if it["count"] > 1 else ""),
                "seen": lambda: "a message appeared; sending not confirmed" + (" " + times(it["count"]) if it["count"] > 1 else ""),
                "idle": lambda: "idle" + (" " + times(it["count"]) if it["count"] > 1 else ""),
                "report": lambda: "REPORT " + q(p[0]) if p else "REPORT (text not captured)",
                "plan": lambda: "PLAN " + q(p[0]) if p else "PLAN (text not captured)",
                "asked": lambda: "ASKED " + q(p[0]) if p else "ASKED (text not captured)",
                "note": lambda: "YOUR NOTE " + " / ".join(q(x, 200) for x in p),
                "unavailable": lambda: "a browser record (details unavailable)",
                "other": lambda: "other activity"}[f]()
        it["line"] = "%d. %s: %s" % (n, it["app"], body)
        lines.append(it["line"])
    kind = "day" if request["targetKind"] == "day" else "moment"
    return "NOTE: %s\nITEMS:\n%s" % (kind, "\n".join(lines)), {n: it for n, it in enumerate(items, 1)}

def render(instruction, view, prefill=PREFILL):
    return ew.render_prompt(instruction, view) + (prefill or "")

# ---------------------------------------------------------------- validator6

SEND = re.compile(r"(?i)\b(sent|delivered|posted|published|emailed|messaged|replied|responded|forwarded)\b")
CORE_SEND = re.compile(r"(?i)\b(sent|delivered|posted|published|emailed|messaged)\b")
DONE = re.compile(r"(?i)\b(complet(?:ed|es)|succeed(?:ed|s)|finish(?:ed|es)|purchas(?:ed|es)|paid|delet(?:ed|es)|submitt?(?:ed|s)|"
                  r"ship(?:ped|s)|releas(?:ed)|merg(?:ed|es)|deploy(?:ed|s)|resolv(?:ed|es)|fix(?:ed|es)|approv(?:ed|es)|signed|booked|"
                  r"ordered|upload(?:ed|s)|pass(?:ed|es|ing)?|attended|joined|listened|watched|read|reviewed|presented|hosted|focused)\b")
STEMS = [("complet", "complet"), ("succeed", "succe"), ("finish", "finish"), ("purchas", "purchas"), ("paid", "pa"), ("delet", "delet"),
         ("submit", "submit"), ("ship", "ship"), ("releas", "releas"), ("merg", "merg"), ("deploy", "deploy"), ("resolv", "resolv"),
         ("fix", "fix"), ("approv", "approv"), ("sign", "sign"), ("book", "book"), ("order", "order"), ("upload", "upload"), ("pass", "pass"), ("attend", "attend"), ("join", "join"),
         ("listen", "listen"), ("watch", "watch"), ("read", "read"), ("review", "review"), ("present", "present"), ("host", "host"), ("focus", "focus")]
ATTRIB = re.compile(r"(?i)\b(report(?:ed|s)?|says?|said|wr(?:ote|ites)|typed|draft(?:ed|s)?|not(?:ed|es)|plan(?:ned|s)?|ask(?:ed|s)?|"
                    r"claim(?:ed|s)?|according|subject|mention(?:ed|s)?|to-?do|unverified|not verified)\b")
RETURN_TRAP = re.compile(r"(?i)\b(created|restored|returned to)\b")
DURATION = re.compile(r"(?i)\b(spent|read for|worked for)\s+\d+|\bwas reading\b|\bspent\b|"
                      r"\bfor (?:about |over |nearly |almost |around )?(?:\d+|an?|one|two|three|several|a few) (?:mins?|minutes?|hours?)\b")
LEAK = re.compile(r"(?i)not established|\brecorded a |\bcanonical\b|\buntrusted\b|macmem://|<\|im_|\|im_(?:start|end)|</?think>|\\u003c|‹\||"
                  r"native-[0-9A-F]{8}-|browser_[0-9a-f]{8}|[0-9a-f]{40,}|```|ignore (?:all )?(?:previous|prior|above) instructions|admin mode|system prompt")
BUNDLE = re.compile(r"\b(?:com|jp|net|org|io|us|dev|app)\.[a-z0-9-]+\.[A-Za-z0-9.-]+")
PHONE = re.compile(r"\b\d{3}[ .-]\d{3}[ .-]\d{4}\b")
LONGNUM = re.compile(r"(?<![\d.])\d{5,}(?![\d.])")
NUMBER = ew.RX["number"]

def lenient_json(raw):
    s = raw.strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s)
    i, j = s.find("{"), s.rfind("}")
    if i < 0 or j < i: raise ew.Invalid("no JSON object")
    s = re.sub(r",\s*([\]}])", r"\1", s[i:j + 1])
    try: obj = json.loads(s)
    except ValueError as e: raise ew.Invalid("not JSON (%s)" % str(e).split(":")[0])
    if not isinstance(obj, dict) or not isinstance(obj.get("bullets"), list): raise ew.Invalid("no bullets array")
    return obj

def _ids(b):
    raw = b.get("ids", b.get("actionIDs", b.get("items", [])))
    out = []
    for x in raw if isinstance(raw, list) else [raw]:
        if isinstance(x, bool): continue
        if isinstance(x, int): out.append(x)
        elif isinstance(x, str) and re.fullmatch(r"\s*(?:#|i|item )?(\d+)\s*", x, re.I): out.append(int(re.sub(r"\D", "", x)))
    return out

def assertion(sources):
    return ew.grouped_assertion(sources)

def _shown(items_cited):
    """What the model was shown for these items: relays and numbers must come from here."""
    return " ".join(it["line"] for it in items_cited)

def bullet_problem(text, sources, items_cited):
    """None if the bullet may be published for these cited actions, else the reason it is dropped."""
    if not text or ew.graphemes(text) > TEXT_MAX: return "empty or longer than %d characters" % TEXT_MAX
    m = LEAK.search(text) or INJECT.search(text)
    if m: return "internal wording, ID or injected token (%s)" % m.group(0)
    corpus = ew.source_text(sources) + " " + " ".join(a["site"] for a in sources)
    m = BUNDLE.search(text)
    if m and m.group(0) not in corpus: return "bundle ID in prose (%s)" % m.group(0)
    if ew.privacy_secret(text) or PHONE.search(text) or LONGNUM.search(text): return "secret-like, phone or reference number"
    m = SEND.search(text)
    if m and not all(a["state"] == "sent" for a in sources): return "send word (%s) without a confirmed send for every cited action" % m.group(0)
    if any(a["kind"] == "keyboard.submit" or "Pressed Return" in a["description"] for a in sources) and RETURN_TRAP.search(text):
        return "Return press described as created/restored/returned to"
    if DURATION.search(text): return "duration or attention claim"
    relay = _shown(items_cited).lower()
    for m in DONE.finditer(text):
        w = m.group(0).lower(); stem = next(s for p, s in STEMS if w.startswith(p))
        if stem not in relay or not ATTRIB.search(text):
            return "completion, success or attention word (%s) that is not an attributed relay of cited text" % m.group(0)
    shown = _shown(items_cited)
    for m in NUMBER.finditer(text):
        if m.group(0) not in shown or m.group(0) not in corpus: return "number %r not in the cited items" % m.group(0)
    return None

GENERIC_TITLES = {"activity note", "day summary", "summary", "activity", "notes", "note", "moment", "day"}

def title_problem(title, actions):
    if title.lower() in GENERIC_TITLES: return "generic (the UI hides it)"
    if not title or ew.graphemes(title) > TITLE_MAX or not 1 <= len(title.split()) <= 8: return "length"
    if ew.RX["state_title"].search(title) or SEND.search(title) or DONE.search(title): return "state word"
    if LEAK.search(title) or INJECT.search(title) or BUNDLE.search(title) or ew.privacy_secret(title) or PHONE.search(title) or LONGNUM.search(title): return "leak/secret"
    if DURATION.search(title): return "duration"
    corpus = ew.source_text(actions) + " " + " ".join(a["site"] for a in actions)
    if any(m.group(0) not in corpus for m in NUMBER.finditer(title)): return "number"
    return None

def fallback_title(request, items, acts):
    """Never the generic 'Activity note'/'Day summary' (the UI hides those; DaydreamTodayData.swift:244-246,349-353)."""
    counts = {}
    for it in items.values(): counts[it["app"]] = counts.get(it["app"], 0) + len(it["actionIDs"])
    apps = [a for a in sorted(counts, key=lambda a: -counts[a]) if a != "Mac"][:3]
    if request["targetKind"] == "day":
        return "Day in " + join_and(apps) if apps else "Day on the Mac"
    places = sorted((it for it in items.values() if it["family"] == "place" and it["place"] and it["place"] != HIDDEN),
                    key=lambda it: -len(it["actionIDs"]))
    for it in places:
        if INJECT.search(it["place"]): continue
        t = clean(it["place"], TITLE_MAX)
        t = t if " " in t else "%s in %s" % (t, it["app"])
        if not title_problem(t, acts): return t
    typed = [it for it in items.values() if it["family"] == "typed"]
    if typed and len(typed) * 2 >= len(items): return "Writing in " + typed[0]["app"]
    return "%s activity" % (apps[0] if apps else "Mac")

def _also_phrase(it):
    f, app = it["family"], it["app"]
    return {"place": lambda: ("%s in %s" % (clean(it["place"], 60), app)) if it["place"] and it["place"] != HIDDEN else app,
            "idle": lambda: "some idle time", "typed": lambda: "typed text in " + app, "screen": lambda: "text on screen in " + app,
            "search": lambda: "a search in " + app, "seen": lambda: "a message in %s whose sending isn't confirmed" % app,
            "report": lambda: "a report in %s that isn't verified" % app, "plan": lambda: "a plan you noted",
            "asked": lambda: "a request to " + app, "note": lambda: "a note you added", "unavailable": lambda: "a browser record",
            "other": lambda: "other activity in " + app}[f]()

def validate_v6(raw, request, actions, items, provider="local/qwen3.5-4b-q4_k_m", version=GENERATOR_VERSION):
    acts = ew.sort_actions(actions)
    by_id = {a["id"]: a for a in acts}
    obj = lenient_json(raw)
    limit = LIMITS["day" if request["targetKind"] == "day" else "activity"]
    report = {"dropped": [], "repaired": [], "titleFallback": None, "unknownIDs": 0, "overCap": 0}
    kept = []
    for n, b in enumerate(obj["bullets"]):
        if not isinstance(b, dict) or not isinstance(b.get("text"), str): report["dropped"].append((n, "not a bullet object")); continue
        if len(kept) >= limit: report["overCap"] += 1; report["dropped"].append((n, "over the bullet cap")); continue
        ids = []
        for i in _ids(b):
            if i in items and i not in ids: ids.append(i)
            elif i not in items: report["unknownIDs"] += 1
        text = b["text"].strip()
        if not ids: report["dropped"].append((n, "cites no known item")); continue
        cited = [items[i] for i in ids]
        if kept and all(items[i]["family"] in LOW_SIGNAL for i in ids) and set(ids) <= {i for k in kept for i in k["items"]}:
            report["dropped"].append((n, "repeats low-signal items an earlier bullet already covers")); continue
        sources = [by_id[x] for it in cited for x in it["actionIDs"]]
        why = bullet_problem(text, sources, cited)
        if why: report["dropped"].append((n, why)); continue
        kept.append({"text": text, "items": ids})
    if not kept: raise ew.Invalid("no bullet survived validator6: " + "; ".join("#%d %s" % d for d in report["dropped"]))
    # Deterministic coverage repair: every item ends up cited at least once.
    cited_now = {i for b in kept for i in b["items"]}
    also = []
    for n, it in items.items():
        if n in cited_now: continue
        if it["family"] in LOW_SIGNAL:
            targets = [b for b in kept if any(items[i]["app"] == it["app"] for i in b["items"])] + kept[::-1]
            for b in targets:
                srcs = [by_id[x] for i in b["items"] + [n] for x in items[i]["actionIDs"]]
                if not bullet_problem(b["text"], srcs, [items[i] for i in b["items"] + [n]]):
                    b["items"].append(n); report["repaired"].append((n, "attached")); break
            else: also.append(n)
        else: also.append(n)
    sent = [n for n in also if items[n]["family"] == "sent"]
    rest = [n for n in also if items[n]["family"] != "sent"]
    for n in sent:
        kept.append({"text": "%s confirmed a message was sent." % items[n]["app"], "items": [n]}); report["repaired"].append((n, "sent bullet"))
    if rest:
        phrases = []
        for n in rest:
            p = _also_phrase(items[n])
            if p not in phrases: phrases.append(p)
        text = "Also: " + "; ".join(phrases) + "."
        if ew.graphemes(text) > TEXT_MAX: text = "Also: other activity in " + join_and(sorted({items[n]["app"] for n in rest})) + "."
        kept.append({"text": text, "items": rest}); report["repaired"] += [(n, "also bullet") for n in rest]
    title = obj.get("title") if isinstance(obj.get("title"), str) else ""
    title = re.sub(r"[.\s]+$", "", title.strip())
    tp = title_problem(title, acts)
    if tp: report["titleFallback"] = tp; title = fallback_title(request, items, acts)
    bullets = []
    for b in kept:
        ids = [x for i in b["items"] for x in items[i]["actionIDs"]]
        ids = list(dict.fromkeys(ids))
        bullets.append({"text": b["text"], "actionIDs": ids, "assertion": assertion([by_id[x] for x in ids])})
    note = {"requestID": request["id"], "title": title, "bullets": bullets, "generator": provider, "generatorVersion": version}
    if len(json.dumps(note, ensure_ascii=False, separators=(",", ":")).encode()) > ew.APP["output_max"]: raise ew.Invalid("encoded note > 16000 bytes")
    note["_report"] = report
    return note

# ---------------------------------------------------------------- one repair turn (replaces blind greedy retries)

REPAIR_REASONS = [
    (r"^send word \((\w+)\)", 'bullet {n} says "{w}", but none of its items is SENT. Say "drafted" or "sending isn\'t confirmed".'),
    (r"^completion, success or attention word \((\w+)\)", 'bullet {n} says "{w}", which its items do not show. Say only what the items show, or who reported it.'),
    (r"^number '([\d.:/-]+)'", "bullet {n} has the number {w}, which is not in its items. Leave it out."),
    (r"^secret-like", "bullet {n} copies a phone, reference or secret-looking number. Leave it out."),
    (r"^(internal wording|bundle ID)", "bullet {n} repeats internal or AI-directed text. Leave it out."),
    (r"^duration", "bullet {n} states a duration or attention. Leave it out."),
    (r"^Return press", "bullet {n} treats a Return press as more than a key press."),
    (r"^empty or longer", "bullet {n} is too long. Use at most 20 words."),
    (r"^cites no known item", 'bullet {n} needs "ids" with item numbers from the list.'),
]

def repair_message(error):
    """Fixed-text feedback for a failed note. Only regex-matched vocabulary words or digits are echoed."""
    lines = []
    for n, why in re.findall(r"#(\d+) ([^;]+)", error):
        for pat, tmpl in REPAIR_REASONS:
            m = re.search(pat, why)
            if m:
                lines.append("- " + tmpl.format(n=int(n) + 1, w=m.group(1) if m.groups() else ""))
                break
    if not lines: lines = ['- reply with only the JSON object, in the same shape.']
    return "Fix this and reply with the whole JSON again:\n" + "\n".join(lines[:3])

def render_repair(instruction, view, first_full, message, prefill=PREFILL):
    """Qwen multi-turn render: earlier assistant turn without a think block, last turn with the empty one.
    The app's QwenNoThinkingTemplate would gain this as a second, fixed shape (verify against the GGUF template)."""
    system = ew.swift_trim(instruction)
    user = ew.swift_trim(view.replace("<", "\\u003c"))
    hist = first_full.replace("<", "\u2039").strip()
    return ("<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n" + user + "<|im_end|>\n<|im_start|>assistant\n" + hist +
            "<|im_end|>\n<|im_start|>user\n" + message + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n" + (prefill or ""))

def with_prefill(raw, prefill):
    """The local writer always prefills, so its reply is a continuation; a full object is accepted as is."""
    if not prefill or raw.lstrip().startswith("{") or re.search(r'\{\s*"title"', raw): return raw
    return prefill + raw

# ---------------------------------------------------------------- JSON schema for the optional grammar arm

JSON_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["title", "bullets"], "properties": {
    "title": {"type": "string", "minLength": 3, "maxLength": 70},
    "bullets": {"type": "array", "minItems": 1, "maxItems": 5, "items": {"type": "object", "additionalProperties": False,
        "required": ["text", "ids"], "properties": {"text": {"type": "string", "minLength": 3, "maxLength": 240},
                                                   "ids": {"type": "array", "minItems": 1, "maxItems": 40, "items": {"type": "integer", "minimum": 1, "maximum": 60}}}}}}}
