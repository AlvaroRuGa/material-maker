extends Node

# Live mode: runs the JSON-lines server (mm_server.gd) inside the Material Maker editor, with
# the operations (mm_ops.gd) acting on the graph that is open in the current tab. Edits made
# through it appear immediately in the editor and can be undone with Ctrl+Z.
#
#   Started automatically on port 8765. MaterialMaker --live-server <port> / env MM_LIVE_PORT=<port> change it,
#   --no-live-server / MM_LIVE_PORT=off disable it.
#   godot --path <repo> -- --live-server 8765
#
# tools/mm.py talks to it with `mm.py live <op> [json args]`, and tools/mm_mcp.py when MM_LIVE_PORT is set.

const DEFAULT_PORT : int = 8765

var server : Node


# The server is on by default, like the editor servers of other DCC tools, so an agent can attach
# to an editor that was simply double-clicked. Opt out with --no-live-server or MM_LIVE_PORT=off.
static func requested_port() -> int:
	var args : PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if "--no-live-server" in args:
		return -1
	var idx : int = args.find("--live-server")
	if idx != -1 and idx + 1 < args.size() and args[idx + 1].is_valid_int():
		return args[idx + 1].to_int()
	var env : String = OS.get_environment("MM_LIVE_PORT")
	if env.to_lower() in ["off", "0", "false"]:
		return -1
	return env.to_int() if env.is_valid_int() else DEFAULT_PORT

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
		# most likely another Material Maker already owns the port; stay quiet, it is not an error for the user
		print("Live server not started: port %d unavailable (%s)" % [port, error_string(status)])
		server.queue_free()
		ops.queue_free()
