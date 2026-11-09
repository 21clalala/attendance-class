import re, sys, requests
sys.path.insert(0, "sync")
src = open("sync/comci_sync.py", encoding="utf-8").read()
ns = {"re": re}
exec(src[src.index("def deobfuscate"):src.index("def discover_endpoint")], ns)
s = requests.Session()
r = s.get("http://comci.net:4082/st", headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}, timeout=20)
print("status", r.status_code, "cookies", list(s.cookies.keys()), "set-cookie?", "set-cookie" in {k.lower() for k in r.headers})
html = r.content.decode("euc-kr", errors="replace")
js = ns["deobfuscate"](html)
print("html", len(html), "js", len(js))
for pat in [r"HOUR[A-Z_]*", r"token", r"Token", r"cookie", r"setRequestHeader|headers\s*:", r"\$\.ajax\(", r"\.get\(|\.post\(|getJSON", r"url\s*:", r"\./\d+", r"btoa\(", r"sc_data", r"school_ra", r"hour"]:
    seen = set()
    for m in re.finditer(pat, js):
        seg = re.sub(r"\s+", " ", js[max(0, m.start() - 220): m.end() + 260])
        key = seg[150:300]
        if key in seen: continue
        seen.add(key)
        print(f"[{pat}]", seg)
        if len(seen) >= 4: break
# also any raw script outside obfuscation
for m in re.finditer(r"<script[^>]*>(.{0,400})", html, re.S):
    print("[script]", re.sub(r"\s+", " ", m.group(1))[:300])
