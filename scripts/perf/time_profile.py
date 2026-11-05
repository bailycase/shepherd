#!/usr/bin/env python3
"""Aggregate main-thread backtraces from an xctrace time-profile export (time-profile.xml in the cwd),
optionally only inside the windows of potential-hangs.xml: `time_profile.py hangs`. Release builds need
the dSYM path and load address edited below for atos."""
import xml.etree.ElementTree as ET, collections, sys, re
root = ET.parse('time-profile.xml').getroot()
byid = {e.attrib['id']: e for e in root.iter() if 'id' in e.attrib}
def res(e): return byid[e.attrib['ref']] if 'ref' in e.attrib else e
def tms(s):  # "00:01.130.706" -> ms
    m, rest = s.split(':'); sec, ms, us = rest.split('.'); return (int(m)*60+int(sec))*1000 + int(ms) + int(us)/1000
windows = []
if len(sys.argv) > 1 and sys.argv[1] == 'hangs':
    h = ET.parse('potential-hangs.xml').getroot(); hb = {e.attrib['id']: e for e in h.iter() if 'id' in e.attrib}
    for r in h.iter('row'):
        cs = list(r); t = (hb.get(cs[0].attrib.get('ref'), cs[0])); d = hb.get(cs[1].attrib.get('ref'), cs[1])
        t0 = tms(t.attrib['fmt']); windows.append((t0, t0 + float(d.attrib['fmt'].split()[0])))
samples = 0; incl = collections.Counter(); leaf = collections.Counter(); appframes = collections.Counter()
for r in root.iter('row'):
    cs = list(r)
    t = res(cs[0]).attrib['fmt']; th = res(cs[1]); thname = th.attrib.get('fmt', '')
    if 'Main Thread' not in thname: continue
    if windows:
        ms = tms(t)
        if not any(a <= ms <= b for a, b in windows): continue
    bt = next((c for c in cs if res(c).tag in ('backtrace','tagged-backtrace')), None)
    if bt is None: continue
    bt = res(bt)
    frames = []
    for f in bt.iter('frame'):
        f = res(f); name = f.attrib.get('name', '?'); bin_ = res(f.find('binary')).attrib.get('name', '') if f.find('binary') is not None else ''
        frames.append(f"{name} [{bin_}]")
    if not frames: continue
    samples += 1
    leaf[frames[0]] += 1
    for fr in set(frames): incl[fr] += 1
    for fr in set(frames):
        if '[Shepherd' in fr: appframes[fr] += 1
import subprocess
def atos(d, load, keys):
    addrs=[k.split(' [')[0] for k in keys]
    out=subprocess.run(["atos","-o",d,"-arch","arm64","-l",load]+addrs,capture_output=True,text=True).stdout.split("\n")
    return {k: o.split(" (in ")[0] for k,o in zip(keys,out)}
hexes=[k for k in appframes if re.match(r"0x[0-9a-f]+ \[Shepherd Nightly\]",k)]
names=atos("dsyms/Shepherd Nightly.app.dSYM/Contents/Resources/DWARF/Shepherd Nightly","0x1025a4000",hexes)
merged=collections.Counter()
for k,v in appframes.items(): merged[names.get(k,k)]+=v
appframes=merged
print(f"main-thread samples: {samples}  (windows: {len(windows)})\n")
print("== inclusive, Shepherd frames ==")
for k, v in appframes.most_common(45): print(f"{v:5d} {v*100/samples:5.1f}%  {k[:150]}")
print("\n== leaves ==")
for k, v in leaf.most_common(15): print(f"{v:5d} {v*100/samples:5.1f}%  {k[:120]}")
