# Rock, earth and voronoi-style surfaces

Sources: examples `rock`, `dry_earth`, `crocodile_skin`, `lava`, `marble`, `emmental`. Import with `import_from_example` and adjust.

> Parameter values come straight from the example files; the descriptions of how things look are inferred from them. Use `show_example` with `render` to see the real result before relying on a detail.

## Rock (`rock`)
- Two `voronoi` (scale 4, randomness 1, intensity 0.85 and 1.0) blended with a `perlin` (iterations 6, persistence 0.85, scale 4),
  colorized for albedo.
- Normal: `normal_map(warp(voronoi, perlin))` with warp amount 0.3, eps 0.045 - the warped cells give chipped, uneven rock faces.
- Roughness and metallic: `colorize(perlin)` (metallic stays near 0 for rock).

## Dry earth (`dry_earth`)
- Cracked-mud look: `voronoi` (scale 4, intensity 0.6) warped by a `perlin` (amount 0.4, eps 0.045) for the cracks, blended with
  `perlin` (iterations 10, persistence 0.9, scale 2) for dusty variation.
- Albedo = `blend(warp(colorize(voronoi), perlin), colorize(perlin))`; depth from `blend(perlin, colorize(warp(...)))`.

## Skin / scales (`crocodile_skin`)
- A single `voronoi` (scale 16, intensity 0.4) feeds three `colorize` nodes: albedo, roughness and the `normal_map`.
- Simple and effective: reuse one pattern for all channels, vary only the gradients.

## General
- Persistence 0.8-1 with many iterations (8-10) gives rough, detailed noise; 0.5 gives soft clouds.
- Warp noise by a different, lower-frequency noise for natural, non-repeating edges.
- Metallic: `uniform` 0.
