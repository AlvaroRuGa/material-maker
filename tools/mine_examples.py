#!/usr/bin/env python3
"""Mine material_maker/examples/*.ptex for patterns an agent can reuse.

    python tools/mine_examples.py            # (re)generates the files under .claude/skills/material-maker/reference/

Writes:
  examples_stats.md      node frequency, typical parameters, what usually follows what, how each Material channel
                         is usually fed, and which examples exist per category
  examples_catalog.md    one compact entry per example (nodes, channel recipes, key parameters)
  examples_stats.json    the same data, machine readable

Standard library only. Run it again whenever examples are added.
"""
import collections
import glob
import json
import os
import statistics
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLES = os.path.join(REPO, "material_maker", "examples")
OUT = os.path.join(REPO, ".claude", "skills", "material-maker", "reference")

MATERIAL_INPUTS = ["albedo", "metallic", "roughness", "emission", "normal", "ao", "depth", "opacity", "sss"]

CATEGORIES = {
    "wood": ["wood", "plank"],
    "brick": ["brick"],
    "stone": ["stone", "rock", "wall", "medieval"],
    "tiles/floor": ["tile", "floor", "mosaic"],
    "metal": ["metal", "rust"],
    "organic": ["grass", "skin", "croc", "earth", "skull", "paper", "lava", "marble"],
    "abstract/other": [],
}


def node_type(n):
    if n.get("type"):
        return n["type"]
    if "nodes" in n:
        return "graph"
    sm = n.get("shader_model")
    if isinstance(sm, dict):
        return "shader:" + str(sm.get("name", "?"))
    return "?"


def param_repr(v):
    if isinstance(v, dict):
        if v.get("type") == "Gradient":
            return "gradient"
        if v.get("type") == "Color":
            return "#%02x%02x%02x" % tuple(int(round(v[k] * 255)) for k in "rgb")
        return v.get("type", "dict")
    if isinstance(v, float):
        return round(v, 3)
    return v


def categories_of(name):
    cats = [c for c, words in CATEGORIES.items() if any(w in name for w in words)]
    return cats or ["abstract/other"]


def expr(name, nodes, incoming, depth):
    """Upstream expression of a node, e.g. colorize(blend(perlin,warp(perlin,perlin)))."""
    t = node_type(nodes[name])
    if depth == 0:
        return t
    sources = incoming.get(name, [])
    if not sources:
        return t
    parts = []
    for port, src in sorted(sources):
        if src in nodes:
            parts.append(expr(src, nodes, incoming, depth - 1))
    # collapse repeated siblings: a,a,a -> a×3
    collapsed = []
    for p in parts:
        if collapsed and collapsed[-1][0] == p:
            collapsed[-1][1] += 1
        else:
            collapsed.append([p, 1])
    parts = [p if n == 1 else "%s×%d" % (p, n) for p, n in collapsed]
    text = "%s(%s)" % (t, ",".join(parts)) if parts else t
    return text if len(text) <= 110 else text[:107] + "..."


def load_examples():
    rv = {}
    for path in sorted(glob.glob(os.path.join(EXAMPLES, "*.ptex"))):
        try:
            data = json.load(open(path, encoding="utf8"))
        except ValueError:
            continue
        if "nodes" in data:
            rv[os.path.splitext(os.path.basename(path))[0]] = data
    return rv


def analyse(examples):
    type_count = collections.Counter()
    type_examples = collections.defaultdict(set)
    params = collections.defaultdict(lambda: collections.defaultdict(list))
    successors = collections.defaultdict(collections.Counter)
    channel_sigs = {c: collections.Counter() for c in MATERIAL_INPUTS}
    channel_examples = {c: collections.defaultdict(list) for c in MATERIAL_INPUTS}
    catalog = {}

    for ex_name, data in examples.items():
        nodes = {n["name"]: n for n in data["nodes"]}
        incoming = collections.defaultdict(list)
        for c in data.get("connections", []):
            incoming[c["to"]].append((c["to_port"], c["from"]))
            if c["from"] in nodes and c["to"] in nodes:
                successors[node_type(nodes[c["from"]])][node_type(nodes[c["to"]])] += 1
        for n in nodes.values():
            t = node_type(n)
            if t in ("material", "comment", "comment_line"):
                continue
            type_count[t] += 1
            type_examples[t].add(ex_name)
            for k, v in (n.get("parameters") or {}).items():
                params[t][k].append(param_repr(v))
        mats = [n for n in nodes.values() if node_type(n) == "material"]
        channels = {}
        if mats:
            m = mats[0]["name"]
            for port, src in incoming.get(m, []):
                if port < len(MATERIAL_INPUTS) and src in nodes:
                    ch = MATERIAL_INPUTS[port]
                    channels[ch] = expr(src, nodes, incoming, 3)
                    sig = expr(src, nodes, incoming, 2)   # grouped at 2 levels so patterns repeat
                    channel_sigs[ch][sig] += 1
                    channel_examples[ch][sig].append(ex_name)
        catalog[ex_name] = {
            "nodes": len(nodes),
            "categories": categories_of(ex_name),
            "types": collections.Counter(node_type(n) for n in nodes.values() if node_type(n) not in ("material", "comment")),
            "channels": channels,
            "material": {k: param_repr(v) for k, v in (mats[0].get("parameters") or {}).items()} if mats else {},
            "key_nodes": [
                {"name": n["name"], "type": node_type(n), "parameters": {k: param_repr(v) for k, v in (n.get("parameters") or {}).items()}}
                for n in nodes.values() if node_type(n) not in ("material", "comment", "comment_line", "colorize", "blend", "uniform", "normal_map", "graph", "uniform_greyscale")
            ],
        }
    return type_count, type_examples, params, successors, channel_sigs, channel_examples, catalog


def summarise_values(values):
    nums = [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if nums and len(nums) == len(values):
        common = collections.Counter(nums).most_common(3)
        return "%s..%s (median %s; common %s)" % (min(nums), max(nums), statistics.median(nums), ", ".join("%s×%d" % kv for kv in common))
    return ", ".join("%s×%d" % kv for kv in collections.Counter(map(str, values)).most_common(4))


def write_outputs(examples):
    type_count, type_examples, params, successors, channel_sigs, channel_examples, catalog = analyse(examples)
    os.makedirs(OUT, exist_ok=True)

    # --- stats.md
    L = ["# Patterns mined from the %d example projects\n" % len(examples),
         "Generated by `tools/mine_examples.py` — do not edit by hand. Counts are number of node uses.\n"]
    by_cat = collections.defaultdict(list)
    for n, c in catalog.items():
        for cat in c["categories"]:
            by_cat[cat].append(n)
    L.append("## Examples by category\n")
    for cat, names in sorted(by_cat.items()):
        L.append("- **%s** (%d): %s" % (cat, len(names), ", ".join(sorted(names))))
    L.append("\n## How each Material channel is usually fed\n")
    L.append("Expressions read upstream from the Material input (2 levels, repeated siblings collapsed). `colorize` = gradient map, `blend` = layer blend.\n")
    for ch in MATERIAL_INPUTS:
        total = sum(channel_sigs[ch].values())
        if not total:
            continue
        L.append("### %s (connected in %d/%d examples)" % (ch, total, len(examples)))
        for sig, cnt in channel_sigs[ch].most_common(6):
            L.append("- `%s` ×%d (e.g. %s)" % (sig, cnt, ", ".join(channel_examples[ch][sig][:3])))
        L.append("")
    L.append("## Node types by frequency, typical parameters, what they usually feed\n")
    for t, cnt in type_count.most_common(45):
        succ = ", ".join("%s×%d" % kv for kv in successors[t].most_common(4))
        L.append("### %s — %d uses in %d examples" % (t, cnt, len(type_examples[t])))
        if succ:
            L.append("feeds: %s" % succ)
        for pname, vals in sorted(params[t].items()):
            if all(isinstance(v, str) and v == "gradient" for v in vals):
                continue
            L.append("- `%s`: %s" % (pname, summarise_values(vals)))
        L.append("")
    open(os.path.join(OUT, "examples_stats.md"), "w", encoding="utf8").write("\n".join(L))

    # --- catalog.md
    C = ["# Example catalog\n", "One entry per example project (`material_maker/examples/<name>.ptex`). Generated by `tools/mine_examples.py`.\n",
         "Use the `show_example` / `import_from_example` tools for the full graph.\n"]
    for name in sorted(catalog):
        c = catalog[name]
        C.append("## %s  (%d nodes; %s)" % (name, c["nodes"], ", ".join(c["categories"])))
        C.append("types: " + ", ".join("%s×%d" % kv for kv in c["types"].most_common(8)))
        for ch, sig in c["channels"].items():
            C.append("- %s ← `%s`" % (ch, sig))
        for k in c["key_nodes"][:8]:
            ps = ", ".join("%s=%s" % kv for kv in list(k["parameters"].items())[:7])
            C.append("- %s (%s): %s" % (k["name"], k["type"], ps))
        C.append("")
    open(os.path.join(OUT, "examples_catalog.md"), "w", encoding="utf8").write("\n".join(C))

    # --- json
    data = {
        "examples": {n: dict(c, types=dict(c["types"])) for n, c in catalog.items()},
        "type_count": dict(type_count),
        "successors": {t: dict(s) for t, s in successors.items()},
    }
    json.dump(data, open(os.path.join(OUT, "examples_stats.json"), "w", encoding="utf8"), indent=1)
    return by_cat


if __name__ == "__main__":
    ex = load_examples()
    by_cat = write_outputs(ex)
    print("mined %d examples into %s" % (len(ex), OUT))
    for cat, names in sorted(by_cat.items()):
        print("  %-16s %d" % (cat, len(names)))
