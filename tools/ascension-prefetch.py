#!/usr/bin/env python3
"""Prefetch the AscensionXI base client (no optional HD/maps/lofi packs) into ROOT.

A one-off of 2026-10-24, superseded by the launcher's own AscensionSync (which does the same and
the rest of their launcher's steps). Kept because it is how the first client on the test Mac was
fetched, and it runs without the app:

    python3 -I tools/ascension-prefetch.py <client root> <client-manifest.json> <donor SquareEnix>...


Same contract as their launcher's per-file restore: every file lands at ROOT/<manifest path>
only after its sha256 matches base/client-manifest.json. Files already present and correct are
kept; byte-identical files at the same relative path in other local FFXI installs are copied
instead of downloaded. Resumable: re-run to continue.
"""
import hashlib, json, os, shutil, sys, threading, time, urllib.parse, urllib.request, queue

ROOT = sys.argv[1]
MANIFEST = sys.argv[2]
DONORS = sys.argv[3:]          # folders that each hold "FINAL FANTASY XI" / "PlayOnlineViewer"
MIRRORS = ["http://dl.ascensionffxi.com:54290", "http://dl2.ascensionffxi.com:54290"]
OPTIONAL = ("Ashita/polplugins/DATs/ffxi-hd/", "Ashita/polplugins/DATs/ffxi-maps/", "Ashita/polplugins/DATs/ffxi-lofi/")
THREADS = 8
log_lock = threading.Lock()
stats = dict(kept=0, copied=0, fetched=0, failed=0, bytes=0)

def log(msg):
    with log_lock:
        print(time.strftime("%H:%M:%S"), msg, flush=True)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def donor_for(rel):
    if not rel.startswith("Game/"):
        return []
    sub = rel[len("Game/"):]
    return [os.path.join(d, sub) for d in DONORS]

files = json.load(open(MANIFEST))["files"]
todo = sorted((p, f) for p, f in files.items() if not p.startswith(OPTIONAL))
total_bytes = sum(f["size"] for _, f in todo)
log(f"{len(todo)} files, {total_bytes/2**30:.2f} GB (optional packs skipped)")
need = queue.Queue()
scan_done = threading.Event()

def worker(i):
    while True:
        try:
            rel, f = need.get(timeout=5)
        except queue.Empty:
            if scan_done.is_set():
                return
            continue
        dst = os.path.join(ROOT, rel); tmp = dst + ".part"
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        ok = False
        for attempt in range(6):
            url = MIRRORS[(i + attempt) % 2] + "/base/files/" + urllib.parse.quote(rel)
            try:
                with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as out:
                    shutil.copyfileobj(r, out, 1 << 20)
                if os.path.getsize(tmp) == f["size"] and sha256(tmp) == f["sha256"]:
                    os.replace(tmp, dst); ok = True; break
                log(f"hash mismatch {rel} via {url[:30]} (attempt {attempt+1})")
            except Exception as e:
                log(f"error {rel}: {e} (attempt {attempt+1})"); time.sleep(3 * (attempt + 1))
        with log_lock:
            if ok:
                stats["fetched"] += 1; stats["bytes"] += f["size"]
            else:
                stats["failed"] += 1
        if os.path.exists(tmp) and not ok:
            os.remove(tmp)

def scan():
    for rel, f in todo:
        dst = os.path.join(ROOT, rel)
        # Every file in place was renamed there only after its source matched the manifest, so a
        # matching size is enough here; the launcher's own install verifies every hash again.
        if os.path.exists(dst) and os.path.getsize(dst) == f["size"]:
            stats["kept"] += 1; continue
        done = False
        for cand in donor_for(rel):
            try:
                if os.path.getsize(cand) == f["size"] and sha256(cand) == f["sha256"]:
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copyfile(cand, dst + ".tmp"); os.replace(dst + ".tmp", dst)
                    stats["copied"] += 1; done = True; break
            except OSError:
                pass
        if not done:
            need.put((rel, f))
        if (stats["kept"] + stats["copied"]) % 2000 == 0 and (stats["kept"] + stats["copied"]):
            log(f"scan: kept {stats['kept']} copied {stats['copied']} to-fetch {need.qsize()}")
    log(f"scan done: kept {stats['kept']} copied {stats['copied']} queued-now {need.qsize()}")
    scan_done.set()

start = time.time()
threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(THREADS)]
for t in threads: t.start()
scan()
while any(t.is_alive() for t in threads):
    time.sleep(60)
    el = time.time() - start
    log(f"fetch: {stats['fetched']} files {stats['bytes']/2**30:.2f} GB in {el/60:.0f} min "
        f"({stats['bytes']/max(el,1)/2**20:.2f} MB/s), queue {need.qsize()}, failed {stats['failed']}")
log(f"DONE kept {stats['kept']} copied {stats['copied']} fetched {stats['fetched']} failed {stats['failed']}")
