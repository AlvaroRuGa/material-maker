# Material Maker from the command line, and for AI agents

This fork adds a scriptable, headless interface to Material Maker:

| Piece | What it is |
|---|---|
| `material_maker/cli/mm_ops.gd` | One set of operations (open, add node, connect, set parameter, render, export...) shared by everything below |
| `material_maker/cli/mm_cli.gd` | The `--cli <command>` entry point (hooked into `parse_args.gd`) |
| `material_maker/cli/mm_server.gd` | `--cli serve`: newline-delimited JSON over localhost TCP, keeps a project open between calls |
| `tools/mm.py` | Convenience launcher for the CLI (finds Godot, hides engine log noise, pretty-prints JSON) |
| `material_maker/cli/mm_live.gd` | Starts that server inside the running editor (`--live-server`), see "Live mode" |
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

## No windows pop up

Rendering needs a GPU context, so Godot always creates a (tiny) window, even headless. On Windows the tools therefore start it on a private,
invisible desktop: nothing appears on screen, in the taskbar or the tray, and focus is never stolen. The process is tied to the launcher, so it
cannot be left behind if the launcher crashes. Set `MM_SHOW_WINDOW=1` to see the window again (debugging). On other systems the process is started
in the background; Linux/macOS may still show a window briefly. The live editor (`mm.py gui`, `open_editor`) is a normal visible window.

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

## Live mode: watch the editor while an agent edits

Headless mode works on its own private copy of the project. In live mode the same operations run inside the
real editor, acting on the project in the current tab: nodes appear as they are added, widgets and previews
update, and every edit goes into the undo history (Ctrl+Z works).

**There is nothing to start.** The editor opens a local server (127.0.0.1:8765) by itself, and the MCP server
attaches to it automatically when one is open (otherwise it falls back to a headless copy). So the whole
workflow is:

1. Register the MCP server once (copy `tools/mcp.json.example` to `.mcp.json` in your project and fix the paths,
   or add the same block to your user MCP config). `MM_GODOT` is only needed for headless mode and for the
   `open_editor` tool; it is not needed if you open Material Maker yourself.
2. Open Material Maker (double-click, or `godot --path <repo>`).
3. Ask the agent to build something. Tools `editor_status` (live or headless?), `open_editor` (starts the editor
   for you), `auto_layout`, `screenshot_editor` are available in addition to the editing tools.

By hand, without MCP:

```sh
python tools/mm.py live ping                                 # any operation: live <op> ['{"json": "args"}']
python tools/mm.py live add_node '{"type":"bricks","name":"Bricks"}'
python tools/mm.py live connect '{"from":"Bricks","to":"Material","to_port":"albedo"}'
python tools/mm.py live auto_layout                          # arrange left to right and center the view
python tools/mm.py live screenshot '{"out":"editor.png"}'    # what the editor window looks like
python tools/mm.py live quit_editor                          # clean exit (a force-kill leaves a crash-recovery file)
python tools/mm.py gui                                       # start the editor from the command line
```

Settings: `--live-server <port>` or `MM_LIVE_PORT=<port>` change the port; `--no-live-server` or
`MM_LIVE_PORT=off` disable the server (and MCP auto-attach).

Differences from headless mode:
* the project is whatever the current tab holds; `new_project` / `open` open a new tab / load into the
  editor, `save` saves it like File > Save. `close` is not available (close the tab yourself);
* edits are made in the graph the editor currently shows (it switches to a subgraph when you target one);
* `rename_node` and `auto_layout` rebuild the view and are not in the undo history.

Security: the server accepts connections from this machine only and executes whatever operations it receives,
including opening and writing files, so any local program can drive your editor while it is open. Connections
that do not start with a JSON request (such as a web page making an HTTP request to localhost) are dropped.
Disable it with `--no-live-server` if that is not acceptable.

## Examples as a library

The projects in `material_maker/examples` are exposed as tools so an agent can learn from them and reuse working node chains
instead of starting from nothing:

```sh
python tools/mm.py examples wood                          # search by name or node types
python tools/mm.py show-example wood --render albedo -o wood.png     # graph, parameters, channel wiring, optional render
python tools/mm.py import-example my.ptex wood colorize_2 --upstream # copy a node and everything feeding it into a project
```

**Community library.** `list_examples community=true` (CLI: `examples --community wood`) searches the ~1,800 materials of
materialmaker.org (default: CC0 only; `--license CC-BY|any`). They are named `community:<id>` and work with `show-example` and
`import-example`; results carry the author and licence (`attribution`). They are read from `tools/.cache/community/` if you downloaded
them with `python tools/fetch_community.py` (all CC0 assets, ~45 MB, throttled, resumable, git-ignored), otherwise fetched on demand into
the user data folder. `python tools/mine_community.py` turns that cache into `community_stats.md` for the skill (aggregated statistics only).
Respect the licences: CC-BY needs credit to the author.

MCP tools: `list_examples`, `show_example` (returns the render as an image), `import_from_example` (undoable in live mode).
The example's Material node is never copied; connect the imported nodes to your own Material. Inputs that were fed from nodes you did not
copy are returned in `open_inputs`.

## Claude Code skill

`.claude/skills/material-maker/` teaches an agent how to use all of this: workflow, the Material input contract, verified gotchas
(for instance that the `depth` input is inverted), and short recipes per material family (`recipes/`).
`reference/` holds data mined from the examples; regenerate it with `python tools/mine_examples.py` after adding examples.
Add a recipe when you have a result you are happy with (and checked by rendering), not before.

## Not covered (yet)

Painting projects, a lit render of the finished material outside the editor, and brushes. Headless rendering
is per node output (and per Material channel).

## Tests

```sh
python tools/test_cli.py       # needs MM_GODOT or MM_EXE
```
