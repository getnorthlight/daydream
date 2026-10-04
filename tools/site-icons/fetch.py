#!/usr/bin/env python3
"""Maintainer tool (never run by the app): refresh the bundled website icons.

For each row of sites.tsv it asks that site itself (no favicon service, no history) for
the icon its page declares (SVG or large PNG first, then apple-touch-icon, then
/favicon.ico), rasterizes it to a <=128 px PNG with rasterize.swift and records where
the bytes came from in sources.tsv. The app never makes a favicon request.

usage: fetch.py <rasterize-binary> [--only name,name] [--force]
"""
import gzip, hashlib, html.parser, os, re, subprocess, sys, tempfile, time, urllib.parse, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[1] / 'Sources/MemoryUI/Resources/SiteIcons'
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

def get(url, limit=3_000_000):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': '*/*', 'Accept-Language': 'en-US'})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read(limit)
        return r.geturl(), (gzip.decompress(data) if data[:2] == b'\x1f\x8b' else data)

class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(); self.icons = []
    def handle_starttag(self, tag, attrs):
        if tag != 'link': return
        a = {k.lower(): (v or '') for k, v in attrs}
        rel = a.get('rel', '').lower().split()
        if 'icon' in rel or 'apple-touch-icon' in rel or 'apple-touch-icon-precomposed' in rel:
            if a.get('href'): self.icons.append((rel, a.get('href'), a.get('sizes', '').lower(), a.get('type', '').lower(), a.get('media', '')))

def rank(rel, href, sizes, typ, media):
    if 'dark' in media: return -1
    if typ == 'image/svg+xml' or href.lower().split('?')[0].endswith('.svg'): return 1000
    m = [int(x) for x in re.findall(r'(\d+)x\d+', sizes)]
    size = max(m) if m else 0
    if 'apple-touch-icon' in ' '.join(rel): return 400 + min(size, 180)
    return size if size else 32

def candidates(page):
    final, body = get(page)
    p = Links(); p.feed(body.decode('utf-8', 'replace'))
    ranked = sorted(p.icons, key=lambda i: -rank(*i))
    urls = [urllib.parse.urljoin(final, i[1]) for i in ranked if rank(*i) >= 0]
    root = urllib.parse.urljoin(final, '/')
    return urls + [root + 'apple-touch-icon.png', root + 'favicon.ico']

def main():
    raster = sys.argv[1]
    only = set(sys.argv[sys.argv.index('--only') + 1].split(',')) if '--only' in sys.argv else None
    force = '--force' in sys.argv
    rows = [l.split('\t') for l in (HERE / 'sites.tsv').read_text().splitlines() if l and not l.startswith('#')]
    srcfile = HERE / 'sources.tsv'
    sources = {}
    if srcfile.exists():
        for l in srcfile.read_text().splitlines():
            if l and not l.startswith('#'): sources[l.split('\t')[0]] = l
    today = time.strftime('%Y-%m-%d')
    for row in rows:
        name, page, direct = row[0], row[1], (row[2] if len(row) > 2 else None)
        if only and name not in only: continue
        if (OUT / f'{name}.png').exists() and not force and name in sources: continue
        try: urls = [direct] if direct else candidates(page)
        except Exception as e:
            root = urllib.parse.urljoin(page, '/'); urls = [root + 'apple-touch-icon.png', root + 'favicon.ico']
        done = False
        for url in urls:
            try:
                if url.startswith('data:'): continue
                final, data = get(url)
                if len(data) < 64 or data[:15].lower().startswith((b'<!doctype html', b'<html')): continue
                with tempfile.NamedTemporaryFile(delete=False) as t: t.write(data)
                r = subprocess.run([raster, t.name, str(OUT / f'{name}.png')], capture_output=True, text=True)
                os.unlink(t.name)
                if r.returncode == 0:
                    sources[name] = '\t'.join([name, url, hashlib.sha256(data).hexdigest(), today, r.stdout.strip() + 'px'])
                    print('ok', name, r.stdout.strip(), url); done = True; break
            except Exception as e:
                continue
        if not done: print('MISS', name)
    srcfile.write_text('# icon\tsource URL (the site\'s own declared icon)\tsha256 of the downloaded bytes\tretrieved\tbundled size\n'
                       + '\n'.join(sources[k] for k in sorted(sources)) + '\n')

main()
