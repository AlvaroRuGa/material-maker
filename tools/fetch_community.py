#!/usr/bin/env python3
"""Download community materials from materialmaker.org into a local cache (for studying patterns).

    python tools/fetch_community.py                      # all CC0 assets (default)
    python tools/fetch_community.py --license CC0 --limit 20
    python tools/fetch_community.py --license CC-BY      # needs attribution if you reuse anything

Cache: tools/.cache/community/ (ignored by git)
    list.json     the site's asset list
    index.json    id -> {name, author, license, tags, type, description} for the downloaded assets
    <id>.ptex     the asset, as the app would save it

The site is run by volunteers: requests are throttled and the script resumes where it stopped, so run it once and keep the cache.
Respect the licenses: CC0 is free to use; CC-BY needs attribution (the index keeps author and license); CC-BY-SA also needs sharing alike.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = "https://www.materialmaker.org"
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache", "community")
HEADERS = {"User-Agent": "material-maker-study/0.1 (offline pattern mining; contact via GitHub AlvaroRuGa)"}


def get(url, retries=4):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read().decode("utf-8")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            wait = 2 ** attempt
            print("  retry %d for %s (%s), waiting %ds" % (attempt + 1, url, e, wait), file=sys.stderr)
            time.sleep(wait)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--license", default="CC0")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--delay", type=float, default=0.3, help="seconds between requests")
    args = ap.parse_args()

    os.makedirs(CACHE, exist_ok=True)
    raw = get(BASE + "/api/getMaterials")
    if raw is None:
        sys.exit("cannot fetch the asset list")
    assets = json.loads(raw)
    json.dump(assets, open(os.path.join(CACHE, "list.json"), "w", encoding="utf8"))
    wanted = [a for a in assets if a.get("license") == args.license]
    if args.limit:
        wanted = wanted[:args.limit]
    index_path = os.path.join(CACHE, "index.json")
    index = json.load(open(index_path, encoding="utf8")) if os.path.exists(index_path) else {}

    done = failed = skipped = 0
    for n, a in enumerate(wanted, 1):
        path = os.path.join(CACHE, "%s.ptex" % a["id"])
        if os.path.exists(path):
            index[a["id"]] = a
            skipped += 1
            continue
        raw = get("%s/api/getMaterial?id=%s" % (BASE, a["id"]))
        try:
            payload = json.loads(raw) if raw else None
            inner = payload["json"] if isinstance(payload, dict) else None
            json.loads(inner)  # must be valid JSON
        except (ValueError, KeyError, TypeError):
            failed += 1
            print("  failed: %s %s" % (a["id"], a.get("name")), file=sys.stderr)
            time.sleep(args.delay)
            continue
        with open(path, "w", encoding="utf8") as f:
            f.write(inner)
        index[a["id"]] = a
        done += 1
        if n % 25 == 0:
            json.dump(index, open(index_path, "w", encoding="utf8"))
            print("%d/%d  (new %d, cached %d, failed %d)" % (n, len(wanted), done, skipped, failed), flush=True)
        time.sleep(args.delay)
    json.dump(index, open(index_path, "w", encoding="utf8"), indent=0)
    print("finished: %d new, %d already cached, %d failed, %d assets in index" % (done, skipped, failed, len(index)))


if __name__ == "__main__":
    main()
