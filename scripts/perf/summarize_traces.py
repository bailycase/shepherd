#!/usr/bin/env python3
"""Summarize a swiftui-<label>.trace and hitches-<label>.trace pair recorded by stress.sh (run in its work dir)."""
import subprocess, sys, collections, xml.etree.ElementTree as ET
label = sys.argv[1]
def export(trace, schema, out):
    subprocess.run(["xctrace", "export", "--input", trace, "--xpath", f"/trace-toc/run[@number='1']/data/table[@schema='{schema}']"], stdout=open(out, "w"), stderr=subprocess.DEVNULL)
def dur(s):
    v, u = s.split(); return float(v) * {'ns': 1e-6, 'µs': 1e-3, 'ms': 1, 's': 1000}[u]
# SwiftUI updates
export(f"swiftui-{label}.trace", "swiftui-updates", f"su-{label}.xml")
byid = {}; descd = collections.Counter(); desc = collections.Counter(); bodies = collections.Counter(); n = 0; total = 0
for ev, e in ET.iterparse(f"su-{label}.xml", events=("end",)):
    if "id" in e.attrib and e.tag != "row": byid[e.attrib["id"]] = (e.attrib.get("fmt"), e.text)
    if e.tag != "row": continue
    vals = []
    for c in e:
        if "ref" in c.attrib: v = byid.get(c.attrib["ref"], (None, None)); vals.append(v[0] or v[1] or "")
        else: vals.append(c.attrib.get("fmt") or c.text or "")
    d = dur(vals[1]); k = vals[3]; ds = vals[5][:70]
    n += 1; total += d; desc[ds] += 1; descd[ds] += d
    if "Body" in k: bodies[ds] += 1
    e.clear()
print(f"== {label}: SwiftUI 20 s: {n} updates, {total:.0f} ms ==")
for k, v in descd.most_common(12): print(f"{v:8.1f} ms {desc[k]:8d}  {k}")
print("bodies:", ", ".join(f"{k} {v}" for k, v in bodies.most_common(6)))
# Hitches
for schema in ("hitches", "hitches-updates", "potential-hangs"):
    export(f"hitches-{label}.trace", schema, f"{schema}-{label}.xml")
def rows(f):
    root = ET.parse(f).getroot(); byid = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}
    def val(c):
        e = byid.get(c.attrib.get("ref"), c); return e.attrib.get("fmt") or (e.text or "")
    return [dict((c.tag, val(c)) for c in r) for r in root.iter("row")]
h = sorted(dur(r["duration"]) for r in rows(f"hitches-{label}.xml"))
u = sorted(dur(r["duration"]) for r in rows(f"hitches-updates-{label}.xml"))
p = [dur(r["duration"]) for r in rows(f"potential-hangs-{label}.xml")]
q = lambda a, f: a[min(len(a) - 1, int(len(a) * f))] if a else 0
print(f"hitches 30 s: {len(h)}  p50 {q(h,.5):.1f} p90 {q(h,.9):.1f} max {q(h,1):.1f} ms; >=20ms {sum(x>=20 for x in h)}")
print(f"commits 30 s: {len(u)} ({len(u)/30:.0f}/s)  p50 {q(u,.5):.1f} p90 {q(u,.9):.1f} p99 {q(u,.99):.1f} max {q(u,1):.1f} ms; sum {sum(u):.0f} ms")
print(f"potential hangs: {len(p)}, >100ms: {[round(x) for x in p if x>100]}")
