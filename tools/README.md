# Material Maker from the command line, and for AI agents

This fork adds a scriptable, headless interface to Material Maker:

| Piece | What it is |
|---|---|
| `material_maker/cli/mm_ops.gd` | One set of operations (open, add node, connect, set parameter, render, export...) shared by everything below |
| `material_maker/cli/mm_cli.gd` | The `--cli <command>` entry point (hooked into `parse_args.gd`) |
| `material_maker/cli/mm_server.gd` | `--cli serve`: newline-delimited JSON over localhost TCP, keeps a project open between calls |
| `tools/mm.py` | Convenience launcher for the CLI (finds Godot, hides engine log noise, pretty-prints JSON) |
| `tools/mm_mcp.py` | MCP server (stdio, no dependencies) so an AI agent can build graphs and *look at the renders* |

The old `--export` command line (`parse_args.gd`) is unchanged.

## Requirements

* Godot 4.7.2 (what this repo targets) **or** an exported Material Maker build.
* A GPU / working Vulkan driver. Rendering uses real shaders, so it does not work with `--headless`; the
  tools use `--no-window` instead (nothing is shown on screen).
* Python 3.8+ for `tools/mm.py` and `tools/mm_mcp.py` (standard library only).

Tell the tools where the program is:

```sh
export MM_GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64     # run from this source tree
# or
export MM_EXE=/path/to/MaterialMaker                          # exported build, runs `<exe> --cli ...`
```

(On Windows the `_console.exe` variant of Godot is picked automatically if it sits next to the exe.)

## CLI

```sh
python tools/mm.py help
python tools/mm.py new brick.ptex --size 10
python tools/mm.py types noise                       # search node types
python tools/mm.py type-info bricks                  # parameters / ports of a node type
python tools/mm.py add brick.ptex bricks --name Bricks rows=6 columns=3 mortar=0.1
python tools/mm.py add brick.ptex colorize --name Col 'gradient=[[0,"#301800"],[1,"#ff9040"]]'
python tools/mm.py connect brick.ptex Bricks:0 Col:0
python tools/mm.py connect brick.ptex Col Material:albedo
python tools/mm.py set brick.ptex Bricks pattern=Herringbone
python tools/mm.py info brick.ptex
python tools/mm.py render brick.ptex --output albedo --size 512 -o brick.png
python tools/mm.py export brick.ptex -t "Godot/Godot 4 Standard" --size 1024 -o out/
```

Parameter values are JSON (`rows=6`, `flag=true`) or plain text. Colors are `"#rrggbb[aa]"`, enums can be given
by label (`pattern=Herringbone`) or index, gradients are `[[position, "#color"], ...]`. Ports are indices or
names; the Material node accepts `albedo`, `roughness`, `normal`, ... for its inputs.
Editing commands rewrite the file unless `--out other.ptex` or `--no-save` is given.

`python tools/mm.py batch script.json` runs `{"ops": [{"op": "new_project", "args": {...}}, ...]}` in a single
Godot session (startup takes a few seconds, so batching is much faster than many separate commands).

Without the Python wrapper:

```sh
godot --path <repo> --no-window -- --cli render brick.ptex -o brick.png     # a line "@@MM_RESULT@@ {json}" is printed
MaterialMaker --cli render brick.ptex -o brick.png
```

Relative paths are resolved against the directory in the `MM_CWD` environment variable (set by the wrapper),
because `godot --path` changes Godot's working directory.

## MCP server

Register `tools/mm_mcp.py` with any MCP client. For Claude Code:

```sh
claude mcp add material-maker -e MM_GODOT=/path/to/godot -- python /path/to/material-maker/tools/mm_mcp.py
```

or in a JSON config:

```json
{ "mcpServers": { "material-maker": {
    "command": "python",
    "args": ["/path/to/material-maker/tools/mm_mcp.py"],
    "env": { "MM_GODOT": "/path/to/godot" } } } }
```

Tools: `list_node_types`, `node_type_info`, `new_project`, `open_project`, `save_project`, `close_project`,
`describe_graph`, `get_node`, `add_node`, `remove_node`, `rename_node`, `set_parameters`, `connect`,
`disconnect`, `render` (returns the image inline plus min/mean/max statistics), `list_export_targets`,
`export`, `batch`.

One Material Maker process is started on first use and keeps the project open between calls; call
`save_project` to persist it.

## Not covered (yet)

Painting projects, the 3D preview / lit rendering of the finished material, brushes, and driving a running
GUI instance. Rendering is per node output (and per Material channel).

## Tests

```sh
python tools/test_cli.py       # needs MM_GODOT or MM_EXE
```
