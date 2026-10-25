# Tiles and patterned floors

Sources: examples `tiles`, `floor1`, `floor2`, `mosaic`, `wooden_floor` (see `recipes/wood.md` for planks).

> Parameter values come straight from the example files; the descriptions of how things look are inferred from them. Use `show_example` with `render` to see the real result before relying on a detail.

## Square tiles with grout (`floor1`)
- `bricks` with `columns` 6, `mortar` 0.01, `bevel` 0.03 as the tile layout (row_offset 0 for a square grid, 0.5 for a stagger).
- `perlin` (iterations 7, persistence 0.95, scale 4) for surface variation; `transform` nodes (`repeat` on, rotate 90 or scale 0.5)
  to tile or rotate a pattern.
- Albedo is a `blend` stack: noise color + tile color + pattern overlay; roughness/depth/normal from `blend(perlin, ...)`.

## Hex / patterned tiles (`tiles`)
- `shape` (sides 6, edge 0.062) repeated with `transform` (repeat on, scale 0.125) gives a hexagon grid; a second `transform` offset by
  0.56 interleaves another layer; `bricks` (columns 8, mortar 0.1) adds a grid for the grout.
- `pattern` (x_scale 2, x_wave 4, y_wave 3) makes decorative waves.

## Tips
- Random per-tile color: bricks output 1 (desaturate first if you only want brightness variation).
- Grout: darker, rougher and lower than the tiles; use the bricks pattern as the mask for all three.
- Use `transform` with `repeat` on when scaling patterns down so they still tile.
