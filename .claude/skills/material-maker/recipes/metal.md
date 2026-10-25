# Metal

Sources: examples `rusted_metal` (checked in detail), `metal_pattern`, `metal_pattern_2`, `metal_pattern_3` (skimmed).

## Rusted metal (`rusted_metal`)
Three `perlin` nodes (scale 4, iterations 8, persistence 0.7 / 0.8 / 0.9 - different seeds):
- **Metal base**: `perlin` (0.8) -> `colorize` gray #565656 -> #b1b1b1.
- **Rust color**: `perlin` (0.8) -> `colorize` #351700 -> #ff3000 (dark brown to bright orange-red).
- **Rust mask**: `perlin` (0.9) -> `colorize` with a hard step at 0.45 (black below, white above).
- **Albedo** = `blend`(Normal): background = metal gray, layer = rust color, opacity input = the mask, amount 0.8.
  Mask white means rust shows.
- **Metallic** = the same mask, connected straight to the Material (the example does this; it is binary, so decide for yourself whether
  rusty or clean areas should be metallic and invert with a `colorize` if needed).
- **Roughness** = `blend` (Overlay, 0.5) of the inverted mask (`colorize` white -> black) and a gray `colorize` of `perlin` (0.7).
- No normal map in this example; add `normal_map` from a noise if you want relief.

## Patterned metal (`metal_pattern*`)
- A pattern subgraph is the height field; `normal_map(colorize(graph))` for the normal.
- Albedo: `blend(colorize(perlin), uniform, blend(colorize(blend), colorize(graph)))` - noise over a base `uniform` color, with the
  pattern in a different shade. `perlin` iterations 7, persistence 0.85-0.9.
- Roughness comes from the same blend as albedo through its own `colorize`.

## Notes
- Clean metals: `metallic` uniform near 1, roughness 0.2-0.5 with fine scratches (high-scale stretched noise).
- Put dirt/rust in recesses by using the inverted height as the mask for the wear layer.
