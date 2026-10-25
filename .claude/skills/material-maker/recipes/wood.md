# Wood

Sources: examples `wood`, `wooden_floor`, `wood_with_blood`, plus a plank texture built and tuned by hand (renders checked).
Start with `import_from_example` on `wood` (albedo chain: node `colorize_2` with `with_upstream`) if you want grain quickly.

## Grain (official `wood` example)
- `perlin` stretched: `scale_x` 32, `scale_y` 4, iterations 6, persistence 1 -> fine fibres (high scale_x with low scale_y = vertical grain).
- A second stretched perlin (32 x 4, iterations 3, persistence 0.5) warped by a broad perlin (4 x 4) through `warp`
  (amount 0.1, eps 0.05), then warped again by a stretched `voronoi` (scale 5 x 4) via `colorize` -> knots and flowing rings.
- `blend` (blend_type 2) of fibres and warped pattern = the height/pattern backbone.
- `colorize` the backbone for albedo (dark brown to amber), another `colorize` for roughness, `normal_map` from it
  (resolution 11, strength ~1).

## Planks / floorboards
- `bricks` as the plank layout: `columns` 1 with `rows` 10 and `mortar` 0.02 (horizontal boards, `wooden_floor`), or
  rows 1 / columns 4-5 with mortar 0.015-0.025 (vertical boards, `wood_with_blood`, my planks).
- Make each plank different: `bricks` output 1 -> `decompose` -> `transform` (tx from Red, ty from Green) applied to the grain
  noise (`wooden_floor`). Otherwise every plank has the same grain.
- Tint planks slightly: bricks output 1 desaturated (`adjust_hsv` saturation 0) as an overlay gives brightness variation without
  green/purple boards. Keep it weak: 0.15 worked; 0.3-0.5 washed the planks out to pale gray in a test.
- Gaps: `colorize` of the bricks pattern (0 -> near black, ~0.45 -> white) multiplied onto albedo.
- Height for normal/depth: the bricks pattern (planks high, gaps low) with only ~8-20% grain mixed in; strong grain in the height
  makes the normal map noisy. Invert for `depth`.

## Ring grain without stretched noise (my planks)
`sine_wave` (frequency ~36) warped by stretched `fbm2` (scale_x 8, scale_y 2, iterations 5) through `warp` (amount 0.11, eps 0.04),
colorized brown (#5e3517 -> #a8703a -> #c58d52 -> #e0b078), multiplied with fine streaks (`fbm2` scale 90 x 2 colorized gray 0.55 -> 1).
Wobble amount 0.15 looks flame-like; 0.09-0.11 is calmer.

## Streaky grain alternative (worked well in a test)
Two `noise_anisotropic` nodes stretched along the grain, multiplied together, through an oak-brown `colorize`; planks from `bricks2`
(2 columns, 6 rows, row_offset 0.37 for staggered boards). Gave convincing horizontal boards with little effort, but identical grain on
every board unless you add the per-plank `decompose` -> `transform` offset above.
Axes: for horizontal streaks use a LOW `scale_x` and a HIGH `scale_y` on `noise_anisotropic` (found by trial in a test); for vertical grain the
reverse. Set `repeat` on the `transform` that offsets each plank, otherwise the shifted noise leaves seams and stops tiling.

## Colors (important)
fbm/perlin outputs sit near 0.5, so a gradient spanning 0-1 gives low contrast. Put the dark stop around 0.3 and the light stop around 0.8
(or boost contrast first) and check the albedo render's mean/min/max: a good oak albedo has mean around 0.3-0.45 and min near 0.1.

## Colors that worked
Dark #5e3517, mid #a8703a, light #e0b078 (oak-like). Darker/redder for mahogany, grayer for weathered wood.
