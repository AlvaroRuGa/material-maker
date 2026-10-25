# Bricks and walls

Sources: examples `bricks`, `improved_brick`, `stone_wall`, `stylized_wall`, `pile_of_bricks`, `brick_rotated`, and a moss-covered
brick wall edited by hand (renders checked).

## Brick layout nodes
- `bricks`: `rows`, `columns`, `row_offset` (0.5 = running bond), `mortar`, `bevel`, `round`. Examples use mortar 0.01-0.09, bevel 0-0.15.
- `bricks_uneven3_2` ("Uneven Bricks 2"): rows of bricks of varied width. `iterations` (splits, 6-10) and `min_size` (0.1 = very varied,
  0.25 = fairly regular). Row heights stay equal.
- `bricks_uneven4`: varied widths AND heights. `randomness` 0.35-0.6, x=4 across, y=8 down for wide bricks (labels are swapped, see
  SKILL.md). Mortar ~0.07, bevel ~0.15, round 0.1.
- All give output 0 = pattern (1 on bricks), 1 = random color per brick, plus position/UV outputs on some.

## Stone wall chain (`stone_wall`)
- `bricks` (columns 3, mortar 0.05, bevel 0.15) displaced by `warp` with a `perlin` (iterations 8, persistence 0.8, scale 4):
  amount 0.05, eps 0.05 -> slightly wobbly edges.
- Albedo: `blend` of `colorize(blend(perlin, bricks))`, `colorize(perlin)` and `colorize(warp(bricks, perlin))`.
- Roughness, ao, depth, normal all derive from the same warped bricks blended with perlin (`normal_map(blend(warp(bricks,perlin),perlin))`).
- That is the pattern to copy: one warped brick height field, several colorizes for the channels.

## Extra realism (from `improved_brick`)
- Two `bricks` nodes with different settings (one providing mortar/bevel shape, one the face), several `perlin` at scales 4, 16, 128
  (iterations 8, persistence 0.5-1) for large stains, mid variation and fine grain.
- Separate `normal_map`s for different detail levels, blended.

## Cracks, chips and moss (hand-built, worked well)
- Cracks: `voronoi2` borders output -> `colorize` (white -> black within 0.04) -> `warp` by a high-frequency `fbm2` (scale 20,
  amount 0.04) -> multiply with a `colorize`d low-frequency noise (0.45-0.55 step) so cracks break up.
- Chips at edges: `fbm2` (scale 14, noise type 3) thresholded with `colorize` (0.5 -> 0.62) multiplied by an edge mask
  (`colorize` of the bricks pattern: 0 -> 0, 0.1 -> 1, 0.55 -> 0).
- Moss: `fbm2` (scale 5, iterations 7) -> threshold `colorize` (0.45 -> 0.62) as mask; make it stronger in the mortar by blending it with
  a mortar mask (bricks pattern colorized 0 -> 0.7 gray, 0.3 -> 0); albedo = mix(stone, moss color, mask). Moss gradient #0d1a08 -> #1f3814 -> #40591a.
- Stone color: 4-stop gray-green gradient (#141313 -> #383333 -> #6b6154 -> #8c8070).

## Depth
Bricks high, mortar low in the height map; invert before `depth`. Cracks and chips subtract from the height (multiply).

## Community medians (34 brick materials)
`bricks`: rows 6, columns 4, row_offset 0.5, mortar 0.01 (p75 0.1), bevel 0.1, round 0.14, corner 0.3. Normal map is `normal_map2` in half of them,
depth goes through `invert` in 44% (a `colorize` in another 22%). AO usually from `occlusion2`/`hbao`. They typically add `warp` (53%) with
amount ~0.07 and `fbm2` (74%) for stains. References (CC0): 489 Ancient Bricks, 1933 Genshin Impact_Brick_01, 744 Stylized cobblestone,
438 Damaged Plaster Wall, 629 Hand Painted Style Bricks.
