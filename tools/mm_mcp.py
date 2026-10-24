#!/usr/bin/env python3
"""MCP (Model Context Protocol) server for Material Maker, over stdio. No dependencies.

It starts one headless Material Maker (`--cli serve`) on first use and keeps a project open
between tool calls, so an agent can build a node graph step by step and look at renders.

Register it with an MCP client, e.g. Claude Code:

    claude mcp add material-maker -e MM_GODOT=/path/to/Godot_v4.7.2-stable_win64.exe -- python /path/to/material-maker/tools/mm_mcp.py

Relative file paths are resolved against the directory the client started this server in.
"""
import base64
import json
import os
import sys
import tempfile
import traceback

from mm_launcher import LauncherError, Server, interesting_log

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "material-maker", "version": "0.1.0"}

S = lambda description, **kw: dict(type="string", description=description, **kw)
I = lambda description, **kw: dict(type="integer", description=description, **kw)
B = lambda description: dict(type="boolean", description=description)
O = lambda description: dict(type="object", description=description)

GRAPH = S("Path of a subgraph node inside the project (e.g. 'MySubgraph'); default: top level")

# name -> (operation, description, properties, required)
TOOLS = {
    "list_node_types": ("list_node_types",
        "List the node types that can be added to a graph (name, label, short description). Use `filter` "
        "to search by words, e.g. 'noise', 'blur', 'brick'.",
        {"filter": S("Case-insensitive text matched against type, label and description")}, []),
    "node_type_info": ("node_type_info",
        "Show the parameters (name, type, default, range, enum values), input ports and output ports of a node "
        "type. Call this before add_node/set_parameters to know valid names and values.",
        {"type": S("Node type, from list_node_types")}, ["type"]),
    "new_project": ("new_project",
        "Start a new project containing a Material node (the sink that exports albedo, roughness, normal...). "
        "Replaces the open project (unsaved changes are lost).",
        {"size": I("Texture size as power of two exponent (11 = 2048, default)")}, []),
    "open_project": ("open",
        "Open a .ptex project file, replacing the open project.",
        {"path": S("Path to the .ptex file")}, ["path"]),
    "save_project": ("save",
        "Save the open project to a .ptex file (default: the file it was opened from).",
        {"path": S("Destination path (.ptex is appended if there is no extension)")}, []),
    "close_project": ("close", "Close the open project.", {}, []),
    "describe_graph": ("describe",
        "List all nodes of the open project (or of a subgraph) with their non-default parameters, "
        "input/output ports and the connections between them.",
        {"graph": GRAPH, "all_params": B("Also list parameters that have their default value")}, []),
    "get_node": ("get_node",
        "Full details of one node: every parameter with its value, and the ports with their descriptions.",
        {"node": S("Node name or path")}, ["node"]),
    "add_node": ("add_node",
        "Add a node to the graph. Returns the node as created (its name, ports and parameters). "
        "Parameters are given by name; colors as \"#rrggbb[aa]\", enums by label or index, "
        "gradients as [[position, \"#color\"], ...], floats as numbers or expressions.",
        {"type": S("Node type, from list_node_types"), "name": S("Name for the node (default: type_N)"),
         "parameters": O("Parameter values by name"), "graph": GRAPH,
         "position": dict(type="array", items=dict(type="number"), description="[x, y] position in the editor")},
        ["type"]),
    "remove_node": ("remove_node", "Delete a node (and its connections).", {"node": S("Node name")}, ["node"]),
    "rename_node": ("rename_node", "Rename a node, keeping its connections.",
        {"node": S("Current name"), "new_name": S("New name")}, ["node", "new_name"]),
    "set_parameters": ("set_parameters",
        "Change parameters of a node. Same value formats as add_node. Unknown names are rejected and the valid ones listed.",
        {"node": S("Node name"), "parameters": O("Parameter values by name")}, ["node", "parameters"]),
    "connect": ("connect",
        "Connect an output port of one node to an input port of another (replacing whatever was connected to that input). "
        "Ports are indices or names as shown by describe_graph / node_type_info. For the Material node inputs are "
        "albedo_tex, metallic_tex, roughness_tex, emission_tex, normal_tex, ao_tex, depth_tex, opacity_tex, sss_tex.",
        {"from": S("Source node"), "from_port": dict(description="Output port index or name (default 0)", type=["integer", "string"]),
         "to": S("Target node"), "to_port": dict(description="Input port index or name (default 0)", type=["integer", "string"]),
         "graph": GRAPH}, ["from", "to"]),
    "disconnect": ("disconnect", "Remove the connection going into an input port.",
        {"to": S("Target node"), "to_port": dict(description="Input port index or name (default 0)", type=["integer", "string"]),
         "graph": GRAPH}, ["to"]),
    "render": ("render",
        "Render the output of a node to an image and return it, so you can look at the result. For the Material node "
        "pass the channel as `output` ('albedo', 'roughness', 'normal', ...). Also returns min/mean/max statistics "
        "(useful to check that something is not blank).",
        {"node": S("Node to render (default: Material)"),
         "output": dict(description="Output port index/name, or material channel for the Material node (default 0)", type=["integer", "string"]),
         "size": I("Image size in pixels (default 256, max 8192)"),
         "save_path": S("Also write the image here (.png, .jpg, .webp, .exr)")}, []),
    "list_export_targets": ("list_export_targets", "List the export targets available for the Material node(s).", {}, []),
    "export": ("export",
        "Export the material's textures/files for a target engine (e.g. 'Godot/Godot 4 Standard', 'Unity/Unity URP', 'Unreal/...').",
        {"target": S("Export target (closest match is used)"), "size": I("Texture size in pixels (default 1024)"),
         "dir": S("Output directory"), "file_name": S("Base file name")}, ["dir"]),
    "batch": ("batch",
        "Run several operations in order in one call. `ops` is a list of {op, args} using the underlying operation names "
        "(new_project, open, save, add_node, set_parameters, connect, render, ...). Stops at the first error unless continue_on_error.",
        {"ops": dict(type="array", items=O("{op: string, args: object}")), "continue_on_error": B("Keep going after an error")}, ["ops"]),
}

server = None


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def schema(props, required):
    return {"type": "object", "properties": props, "required": required, "additionalProperties": False}


def get_server():
    global server
    if server is None:
        server = Server(cwd=os.getcwd())
    return server


def call_mm(op, args):
    try:
        resp = get_server().call(op, args)
    except LauncherError as e:
        return None, str(e)
    except (OSError, ValueError) as e:
        server.stop()
        return None, "Lost connection to Material Maker (%s). It will be restarted on the next call; the open project was lost." % e
    if not resp.get("ok"):
        text = resp.get("error", "error")
        if resp.get("details"):
            text += "\n" + json.dumps(resp["details"])
        return None, text
    return resp.get("result"), None


def tool_result(text, is_error=False, image=None):
    content = [{"type": "text", "text": text}]
    if image:
        content.append({"type": "image", "data": image, "mimeType": "image/png"})
    return {"content": content, "isError": is_error}


def run_render(args):
    """Render to a temp PNG that is returned as an image; optionally also save it (any format)."""
    save_path = args.pop("save_path", None)
    fd, temp_png = tempfile.mkstemp(suffix=".png", prefix="mm_render_")
    os.close(fd)
    try:
        result, err = call_mm("render", dict(args, out=temp_png))
        if err:
            return tool_result(err, True)
        result.pop("path", None)
        with open(temp_png, "rb") as f:
            raw = f.read()
        if save_path:
            save_abs = save_path if os.path.isabs(save_path) else os.path.join(os.getcwd(), save_path)
            if save_path.lower().endswith(".png"):
                os.makedirs(os.path.dirname(save_abs) or ".", exist_ok=True)
                with open(save_abs, "wb") as f:
                    f.write(raw)
                result["saved"] = save_abs
            else:
                saved, err = call_mm("render", dict(args, out=save_path))
                if err:
                    return tool_result(err, True)
                result["saved"] = saved.get("path")
        return tool_result(json.dumps(result, indent=1), False, base64.b64encode(raw).decode("ascii"))
    finally:
        try:
            os.remove(temp_png)
        except OSError:
            pass


def run_tool(name, arguments):
    if name not in TOOLS:
        return tool_result("Unknown tool '%s'" % name, True)
    args = dict(arguments or {})
    if name == "render":
        return run_render(args)
    result, err = call_mm(TOOLS[name][0], args)
    if err:
        return tool_result(err, True)
    return tool_result(json.dumps(result, indent=1))


def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        return {"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {}}, "serverInfo": SERVER_INFO,
                "instructions": "Build and inspect Material Maker texture graphs. Typical flow: new_project, list_node_types / "
                                "node_type_info, add_node, connect (into the Material node), render to check, save_project."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": n, "description": d, "inputSchema": schema(p, r)} for n, (_, d, p, r) in TOOLS.items()]}
    if method == "tools/call":
        params = msg.get("params", {})
        return run_tool(params.get("name"), params.get("arguments"))
    if mid is None:
        return None  # notification
    raise KeyError(method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        mid = msg.get("id")
        try:
            result = handle(msg)
            if mid is not None and result is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
        except KeyError as e:
            if mid is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found: %s" % e}}), flush=True)
        except Exception:
            log(traceback.format_exc())
            if mid is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "Internal error"}}), flush=True)
    if server is not None:
        server.stop()


if __name__ == "__main__":
    main()
