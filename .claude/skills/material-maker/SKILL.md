---
name: material-maker
description: Build, edit and render procedural textures and PBR materials in Material Maker using the material-maker MCP tools (or tools/mm.py). Use when asked to create, modify, inspect or export a Material Maker project (.ptex), make a wood/brick/stone/metal/etc. texture, or work with node graphs in this repo.
---

# Material Maker skill

Material Maker builds textures from a graph of generator nodes that end in one **Material** node.
You work with it through the `material-maker` MCP tools (CLI fallback: `python tools/mm.py ...`, see tools/README.md).

## Modes
- **Live**: the user has the editor open, you are attached to it. Edits appear on their screen and are undoable.
  `screenshot_editor` shows what they see. Call `editor_status` to find out; `open_editor` starts the editor.
- **Headless**: a private hidden copy. Nothing is visible to the user until the file is saved and opened.
Prefer live when the user is watching. Say which mode you are in if it matters.

## Workflow
1. **Pin down the target** (material type, tiling, size, style, target engine). Ask only if it changes the result a lot.
2. **Look at examples first**: `list_examples` (filter by words like `wood`, `voronoi`), `show_example` with `render` to see it.
   Start from a close example with `import_from_example` (`with_upstream`) instead of building from zero, then adapt.
   Recipes: see the index below.
3. **Check node details** with `node_type_info` before using a node type you have not used (parameter names, ranges, ports).
4. **Build from sources to the Material**: add generators, `connect`, then plug results into the Material channels.
5. **Look at it**: `render` intermediate nodes while building and the final channels (`albedo`, `roughness`, `depth`...). The
   returned min/mean/max tell you if something is blank or washed out. Fix the weakest part first (usually color and scale).
6. **Save** with `save_project` (live: like File > Save). In live mode call `auto_layout` at the end so the graph is readable.
7. If the user wants files for an engine, use `export` (and look at the exported maps, see gotchas on normals).

## The Material node (inputs, by index)
0 albedo · 1 metallic · 2 roughness · 3 emission · 4 normal · 5 ao · 6 depth · 7 opacity · 8 sss. Accepts names (`"albedo"`).
`size` parameter is a power of two exponent (10 = 1024, 11 = 2048).

Typical graph (from the examples, normal_map is used in 31 of them):
- one **height pattern** (grayscale: bricks, noise blends, voronoi...) is the backbone;
- `colorize` (gradient map) turns patterns into albedo, roughness, ao;
- `normal_map` built from the height pattern feeds `normal`; keep its Buffer option on (it is by default in examples);
- metallic is usually a `uniform` (0 for non-metals), or a mask for rust/paint wear;
- `depth` gets the height, **inverted** (see gotchas).
Roughness and albedo should differ: do not feed the same gradient output to both.

## Gotchas (all verified)
- **Depth is inverted**: the Material `depth` input treats white as deep. Official examples put a `colorize` (white to black)
  or an `invert` node between the height map and `depth`. Feeding the height directly makes holes look raised.
- **`bricks_uneven4`**: the labels are swapped. `x` = divisions across (horizontal), `y` = divisions down. For wide bricks use
  x=4, y=8, not the reverse. `randomness` ~0.35-0.6 keeps a brick look; 0.7+ gives slivers, ~0.45 with square cells looks like a grid.
- **`bricks`** (plain): `rows`/`columns` as labelled; vertical planks = rows 1, columns N. Output 0 = pattern (1 inside bricks, 0 in mortar),
  output 1 = random color per brick (it has hue: desaturate with `adjust_hsv` saturation 0 before using it as a brightness tint).
- **Per-brick variation** (from `wooden_floor`): `bricks` output 1 -> `decompose` -> Red to `transform` input `tx`, Green to `ty`: each
  plank/brick then shows a different part of the texture. Without it all planks look identical.
- **`warp`** modes are only Slope and Distance to top; it pushes along the gradient of the displacement input, it does not translate.
  Use `transform` (inputs tx, ty, r, sx, sy) for offsets.
- **`sine_wave`** varies along X (vertical stripes); stretch noise with scale_x much larger than scale_y for vertical grain.
- **Headless `render` of a normal output is unreliable** (returns flat 0.5, 0.5, 0.0). Check normals through `export` and look at the
  exported `_normal.png` instead. Depth, albedo and other channels render fine.
- **Live mode**: `open_editor` with a file does not load the file (use `open_project`). `rename_node` and `auto_layout` rebuild the view
  and are not undoable. `close_project` is not available; the user closes tabs.
- **`blend` vs `blend2` have different ports.** `blend` (used by most examples): `s1` = foreground/layer, `s2` = background, `a` = mask.
  `blend2`: `b` = background, `l1` = layer, `a1` = opacity. Check with `node_type_info`; wiring them the wrong way round swaps the layers.
  Types by label (same list in both): Normal, Multiply (2), Screen, Overlay, Soft Light, Darken, Additive (12)... Multiply is the usual way
  to apply masks (gaps, cracks, wear) to a color or height.
- **Noise outputs cluster around 0.5** (fbm/perlin rarely reach 0 or 1). A gradient that spans 0 to 1 therefore looks flat and pale:
  compress the stops to the real range (about 0.3-0.8; read min/mean/max from a `render` of the noise node) or add contrast.
- **`render` inside `batch` returns statistics only**, no image. Call `render` on its own when you need to look at the result.
- Parameter values: floats as numbers, enums by label (`"Multiply"`) or index, colors `"#rrggbb"`, gradients `[[pos,"#color"],...]`.
  `set_parameters` lists the valid names if you get one wrong.
- The example Material node cannot be imported; connect imported nodes to your own Material.

## Quality checklist
- Compare against the brief: color temperature and brightness are the first thing that goes wrong (washed out grays, too dark gaps).
- Overlay/tint layers: start weak (opacity 0.1-0.2); 0.3+ washes the albedo out.
- Several scales of detail (large shapes, medium variation, fine grain), not one noise layer.
- Color from gradients with 3-4 stops and a bit of hue shift; pure gray reads as fake.
- Edges/mortar/cavities darker, raised parts lighter, and wear/moss/dirt concentrated in cavities and edges.
- Check the roughness and depth renders, not just albedo.
- Name nodes meaningfully (`stone_noise`, `moss_mask`) so the user can edit the graph later.

## Recipes (read the one that matches; they are short)
- `recipes/wood.md` - grain, planks, floors
- `recipes/bricks-and-walls.md` - bricks, uneven bricks, stone walls, moss
- `recipes/stone-rock-earth.md` - rock, dry earth, skin-like voronoi surfaces
- `recipes/metal.md` - rusted and patterned metal
- `recipes/tiles-and-floors.md` - tiles, patterned floors

## Reference data (generated by `python tools/mine_examples.py`; read only what you need)
- `reference/examples_stats.md` - how each Material channel is usually fed, node usage and typical parameter ranges
- `reference/examples_catalog.md` - one short entry per example (nodes, channel chains, key parameters)
Use `list_examples` / `show_example` for the live data; the files above are for skimming patterns.
