extends Node

# Live mode: runs the JSON-lines server (mm_server.gd) inside the Material Maker editor, with
# the operations (mm_ops.gd) acting on the graph that is open in the current tab. Edits made
# through it appear immediately in the editor and can be undone with Ctrl+Z.
#
#   MaterialMaker --live-server [port]      (default port 8765, or env MM_LIVE_PORT)
#   godot --path <repo> -- --live-server 8765
#
# tools/mm.py talks to it with `mm.py live <op> [json args]`, and tools/mm_mcp.py when MM_LIVE_PORT is set.

const DEFAULT_PORT : int = 8765

var server : Node


static func requested_port() -> int:
	var args : PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var idx : int = args.find("--live-server")
	if idx != -1:
		if idx + 1 < args.size() and args[idx + 1].is_valid_int():
			return args[idx + 1].to_int()
		return DEFAULT_PORT
	var env : String = OS.get_environment("MM_LIVE_PORT")
	return env.to_int() if env.is_valid_int() else -1

static func start_if_requested(main_window : Node) -> void:
	var port : int = requested_port()
	if port < 0:
		return
	var live : Node = load("res://material_maker/cli/mm_live.gd").new()
	main_window.add_child(live)
	live.start(main_window, port)

func start(main_window : Node, port : int) -> void:
	var ops : Node = load("res://material_maker/cli/mm_ops.gd").new()
	add_child(ops)
	ops.live = func(): return main_window.get_current_graph_edit()
	server = load("res://material_maker/cli/mm_server.gd").new()
	server.ops = ops
	add_child(server)
	var status : Error = server.start(port)
	if status == OK:
		print("@@MM_READY@@ %d" % server.port)
		mm_globals.set_tip_text("Live server listening on 127.0.0.1:%d" % server.port, 8, 1)
	else:
		push_error("Live server: cannot listen on port %d (%s)" % [port, error_string(status)])
