#!/usr/bin/env python3
"""Aggregate patterns from the community materials cached by tools/fetch_community.py.

    python tools/mine_community.py

Writes under .claude/skills/material-maker/reference/:
  community_stats.md     per material family: how channels are fed, node usage, typical parameter ranges,
                         how often the depth input is inverted, and ids of representative assets
  community_stats.json   the same, machine readable

Only aggregated statistics are written (no asset content is copied). Asset ids can be fetched again with
tools/fetch_community.py; CC0 assets need no attribution, anything else keeps author/license in the cache index.
"""
import collections
import glob
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mine_examples import MATERIAL_INPUTS, expr, node_type, param_repr  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(REPO, "tools", ".cache", "community")
OUT = os.path.join(REPO, ".claude", "skills", "material-maker", "reference")

# first match wins; matched against lower-cased "name tags description"
FAMILIES = [
    ("wood", ["wood", "plank", "parquet", "timber", "bark"]),
    ("bricks", ["brick"]),
    ("tiles/floor", ["tile", "floor", "mosaic", "cobble", "pavement", "paving"]),
    ("metal", ["metal", "rust", "steel", "iron", "copper", "gold", "scratch"]),
    ("rock/stone", ["rock", "stone", "marble", "granite", "slate", "cliff", "wall"]),
    ("ground/organic", ["ground", "dirt", "soil", "mud", "sand", "grass", "earth", "leaf", "leaves", "moss", "snow", "ice", "lava", "skin", "scale"]),
    ("fabric/paper", ["fabric", "cloth", "leather", "paper", "carpet", "knit", "wool", "canvas"]),
    ("sci-fi/pattern", ["sci", "tech", "panel", "pattern", "hex", "circuit", "metalpattern"]),
]
KEY_TYPES = ["bricks", "perlin", "fbm2", "voronoi", "warp", "normal_map", "colorize", "blend", "transform", "pattern", "noise_anisotropic"]


def family_of(meta):
    text = ("%s %s %s" % (meta.get("name", ""), meta.get("tags", ""), meta.get("description", ""))).lower()
    for fam, words in FAMILIES:
        if any(w in text for w in words):
            return fam
    return "other"


def gradient_inverted(node):
    g = (node.get("parameters") or {}).get("gradient")
    pts = g.get("points") if isinstance(g, dict) else None
    if not pts or len(pts) < 2:
        return None
    pts = sorted(pts, key=lambda p: p["pos"])
    lum = lambda p: 0.2126 * p["r"] + 0.7152 * p["g"] + 0.0722 * p["b"]
    return lum(pts[0]) > lum(pts[-1])


def depth_is_inverted(nodes, incoming, material):
    """True/False if the depth input is clearly inverted/direct, None if unknown."""
    for port, src in incoming.get(material, []):
        if port == 6 and src in nodes:
            n = nodes[src]
            t = node_type(n)
            if t == "invert":
                return True
            if t == "colorize":
                return gradient_inverted(n)
            return False
    return None


def load_assets():
    index_path = os.path.join(CACHE, "index.json")
    index = json.load(open(index_path, encoding="utf8")) if os.path.exists(index_path) else {}
    assets = []
    for path in sorted(glob.glob(os.path.join(CACHE, "*.ptex"))):
        aid = os.path.splitext(os.path.basename(path))[0]
        meta = index.get(aid, {"id": aid})
        if str(meta.get("type", "0")) != "0":
            continue
        if "animated" in str(meta.get("tags", "")).lower():
            continue
        try:
            data = json.load(open(path, encoding="utf8"))
        except ValueError:
            continue
        nodes = {n["name"]: n for n in data.get("nodes", []) if isinstance(n, dict) and "name" in n}
        material = next((k for k, n in nodes.items() if node_type(n) == "material"), None)
        if material is None:
            continue
        assets.append((aid, meta, data, nodes, material))
    return assets


def quantiles(values):
    values = sorted(values)
    n = len(values)
    return values[n // 4], values[n // 2], values[(3 * n) // 4]


def analyse(assets):
    fams = collections.defaultdict(list)
    for a in assets:
        fams[family_of(a[1])].append(a)
    result = {}
    for fam, items in fams.items():
        type_assets = collections.Counter()
        sigs = {c: collections.Counter() for c in MATERIAL_INPUTS}
        params = collections.defaultdict(lambda: collections.defaultdict(list))
        succ = collections.defaultdict(collections.Counter)
        node_counts = []
        depth_inv = collections.Counter()
        for aid, meta, data, nodes, material in items:
            incoming = collections.defaultdict(list)
            for c in data.get("connections", []):
                incoming[c["to"]].append((c["to_port"], c["from"]))
                if c["from"] in nodes and c["to"] in nodes:
                    succ[node_type(nodes[c["from"]])][node_type(nodes[c["to"]])] += 1
            types = set()
            for n in nodes.values():
                t = node_type(n)
                if t in ("material", "comment", "comment_line"):
                    continue
                types.add(t)
                if t in KEY_TYPES:
                    for k, v in (n.get("parameters") or {}).items():
                        pv = param_repr(v)
                        if isinstance(pv, (int, float)) and not isinstance(pv, bool):
                            params[t][k].append(pv)
            for t in types:
                type_assets[t] += 1
            node_counts.append(len([1 for n in nodes.values() if node_type(n) not in ("comment", "comment_line")]))
            for port, src in incoming.get(material, []):
                if port < len(MATERIAL_INPUTS) and src in nodes:
                    sigs[MATERIAL_INPUTS[port]][expr(src, nodes, incoming, 0)] += 1
            d = depth_is_inverted(nodes, incoming, material)
            if d is not None:
                depth_inv["inverted" if d else "direct"] += 1
        result[fam] = {
            "count": len(items),
            "nodes_median": statistics.median(node_counts),
            "type_assets": type_assets,
            "sigs": sigs,
            "params": params,
            "succ": succ,
            "depth": depth_inv,
            "ids": [(a[0], a[1].get("name", "")) for a in sorted(items, key=lambda a: -len(a[3]))[:8]],
        }
    return result


def write(result, total):
    os.makedirs(OUT, exist_ok=True)
    L = ["# Patterns mined from community materials (CC0)\n",
         "Generated by `tools/mine_community.py` from %d CC0 materials downloaded with `tools/fetch_community.py`. "
         "Aggregated statistics only. 'share' = fraction of assets in the family that use the node / pattern.\n" % total]
    depth_total = collections.Counter()
    for fam in result.values():
        depth_total.update(fam["depth"])
    if depth_total:
        s = sum(depth_total.values())
        L.append("**Depth input wiring overall**: %d%% of the %d assets that connect `depth` put an invert/white-to-black gradient before it "
                 "(the rest feed the height directly).\n" % (round(100 * depth_total["inverted"] / s), s))
    L.append("Families: " + ", ".join("%s (%d)" % (f, r["count"]) for f, r in sorted(result.items(), key=lambda kv: -kv[1]["count"])) + "\n")
    for fam, r in sorted(result.items(), key=lambda kv: -kv[1]["count"]):
        if r["count"] < 5:
            continue
        L.append("## %s - %d assets, median %d nodes\n" % (fam, r["count"], r["nodes_median"]))
        if r["depth"]:
            s = sum(r["depth"].values())
            L.append("depth wiring: %d%% inverted (%d assets connect depth)\n" % (round(100 * r["depth"]["inverted"] / s), s))
        L.append("Most used nodes: " + ", ".join("%s %d%%" % (t, round(100 * c / r["count"])) for t, c in r["type_assets"].most_common(14)) + "\n")
        for ch in ("albedo", "roughness", "normal", "depth", "ao", "metallic"):
            tot = sum(r["sigs"][ch].values())
            if tot < max(3, r["count"] // 10):
                continue
            L.append("**%s** (connected in %d%%) is fed by: %s" % (ch, round(100 * tot / r["count"]),
                     ", ".join("%s %d%%" % (sig, round(100 * c / tot)) for sig, c in r["sigs"][ch].most_common(7))))
        L.append("")
        L.append("Typical parameters (p25 / median / p75):")
        for t in KEY_TYPES:
            if t not in r["params"] or t in ("colorize",):
                continue
            parts = []
            for k, vals in sorted(r["params"][t].items()):
                if len(vals) >= 5 and len(set(vals)) > 1:
                    q1, q2, q3 = quantiles(vals)
                    parts.append("%s %g/%g/%g" % (k, q1, q2, q3))
            if parts:
                L.append("- `%s`: %s" % (t, "; ".join(parts[:9])))
        L.append("")
        pairs = []
        for a, cnt in r["succ"].items():
            for b, c in cnt.items():
                if a not in ("comment",) and b not in ("material", "comment"):
                    pairs.append((c, a, b))
        pairs.sort(reverse=True)
        L.append("Common links: " + ", ".join("%s->%s x%d" % (a, b, c) for c, a, b in pairs[:10]) + "\n")
        L.append("Larger example ids (fetch with `tools/fetch_community.py`, or `website:<id>`): " + ", ".join("%s (%s)" % kv for kv in r["ids"]) + "\n")
    open(os.path.join(OUT, "community_stats.md"), "w", encoding="utf8").write("\n".join(L))
    summary = {f: {"count": r["count"], "nodes_median": r["nodes_median"], "types": dict(r["type_assets"].most_common(25)),
                   "depth": dict(r["depth"])} for f, r in result.items()}
    json.dump(summary, open(os.path.join(OUT, "community_stats.json"), "w", encoding="utf8"), indent=1)


if __name__ == "__main__":
    assets = load_assets()
    if not assets:
        sys.exit("no cached materials: run tools/fetch_community.py first")
    result = analyse(assets)
    write(result, len(assets))
    print("mined %d materials" % len(assets))
    for f, r in sorted(result.items(), key=lambda kv: -kv[1]["count"]):
        print("  %-16s %d" % (f, r["count"]))
