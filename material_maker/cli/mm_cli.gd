extends Node

# Command line interface of Material Maker.
#
#   MaterialMaker --cli <command> [arguments]          (exported build)
#   godot --path <repo> --no-window -- --cli <command> (from source)
#
# Run with "--cli help" for the list of commands. Results are printed as a single
# line "@@MM_RESULT@@ {json}" so that scripts can easily skip engine log noise;
# tools/mm.py wraps this and pretty-prints it.

const RESULT_MARKER : String = "@@MM_RESULT@@ "

const HELP : String = """Material Maker command line interface

usage: --cli <command> [arguments]

Project files
  new <file> [--size N]                    create a project with a Material node (size = 2^N, default 11)
  info <file> [--graph G] [--all]          list nodes, parameters, connections (--all: include default parameters)
  node <file> <node>                       full details of one node
  targets <file>                           list export targets of the material node(s)

Editing (the file is rewritten unless --out <other file> is given)
  add <file> <type> [--name N] [--graph G] [param=value ...]
  set <file> <node> <param=value ...>      values are JSON, or plain text (colors: "#ff8800", enums: by name)
  remove <file> <node>
  rename <file> <node> <new_name>
  connect <file> <from[:out]> <to[:in]> [--graph G]    ports are indices or names
  disconnect <file> <to[:in]> [--graph G]

Output
  render <file> [--node N] [--output O] [--size S] [-o out.png]   (png, jpg, webp, exr)
  export <file> [-t target] [--size S] [-o dir] [--name base]

Discovery
  types [filter]                           list node types
  type-info <type>                         parameters, inputs, outputs of a node type

Automation
  batch <script.json>                      run {"ops":[{"op":"open","args":{...}}, ...]} in one session
  serve [--port N]                         JSON-lines TCP server on 127.0.0.1 (used by the MCP bridge)

Global options:  --result-file <path>  also write the result JSON to a file
"""

var ops : Node = null


func _ready() -> void:
	ops = load("res://material_maker/cli/mm_ops.gd").new()
	add_child(ops)
	var args : PackedStringArray = _collect_args()
	var code : int = await run(args)
	get_tree().quit(code)

static func _collect_args() -> PackedStringArray:
	var all : PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var idx : int = all.find("--cli")
	if idx == -1:
		idx = all.find("--serve")
		if idx != -1:
			all[idx] = "serve"
			return all.slice(idx)
		return PackedStringArray()
	return all.slice(idx + 1)

static func parse_value(s : String):
	var json : JSON = JSON.new()
	if json.parse(s) == OK:
		return json.data
	return s

func _emit(result : Dictionary, result_file : String) -> int:
	var text : String = JSON.stringify(ops.jsonable(result))
	print(RESULT_MARKER + text)
	if result_file != "":
		var f : FileAccess = FileAccess.open(ops.abs_path(result_file), FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(ops.jsonable(result), "\t"))
	return 1 if result.has("error") else 0

func run(argv : PackedStringArray) -> int:
	# Split options (--x / -x) from positionals
	var pos : Array = []
	var opt : Dictionary = {}
	var i : int = 0
	var flags : Array = ["--all", "--no-save", "-q"]
	while i < argv.size():
		var a : String = argv[i]
		if a.begins_with("-") and a.length() > 1 and not a.is_valid_float():
			if a in flags or i + 1 >= argv.size():
				opt[a.lstrip("-")] = true
			else:
				i += 1
				opt[a.lstrip("-")] = argv[i]
		else:
			pos.append(a)
		i += 1
	var result_file : String = str(opt.get("result-file", ""))
	if pos.is_empty() or pos[0] == "help":
		print(HELP)
		return 0
	var command : String = pos[0]
	pos = pos.slice(1)
	var result : Dictionary = await _dispatch(command, pos, opt)
	return _emit(result, result_file)

func _need(pos : Array, n : int, usage : String) -> bool:
	if pos.size() < n:
		print("usage: --cli " + usage)
		return false
	return true

func _params_from(items : Array) -> Dictionary:
	var rv : Dictionary = {}
	for it in items:
		var s : String = str(it)
		var eq : int = s.find("=")
		if eq > 0:
			rv[s.left(eq)] = parse_value(s.substr(eq + 1))
	return rv

func _split_port(s : String) -> Array:
	var c : int = s.rfind(":")
	if c <= 0:
		return [s, 0]
	var p = s.substr(c + 1)
	return [s.left(c), p.to_int() if p.is_valid_int() else p]

func _open(file : String) -> Dictionary:
	return await ops.call_op("open", { path = file })

func _finish_edit(result : Dictionary, opt : Dictionary) -> Dictionary:
	if result.has("error") or opt.has("no-save"):
		return result
	var saved : Dictionary = await ops.call_op("save", { path = str(opt.get("out", ops.path)) })
	if saved.has("error"):
		return saved
	result["saved"] = saved.path
	return result

func _dispatch(command : String, pos : Array, opt : Dictionary) -> Dictionary:
	var r : Dictionary
	match command:
		"ping":
			return await ops.call_op("ping", {})
		"types":
			return await ops.call_op("list_node_types", { filter = pos[0] if pos.size() > 0 else "" })
		"type-info":
			if not _need(pos, 1, "type-info <type>"):
				return { error = "missing argument" }
			return await ops.call_op("node_type_info", { type = pos[0] })
		"new":
			if not _need(pos, 1, "new <file> [--size N]"):
				return { error = "missing argument" }
			r = await ops.call_op("new_project", { size = int(opt.get("size", 11)) })
			if r.has("error"):
				return r
			r = await ops.call_op("save", { path = pos[0] })
			return r
		"info", "node", "targets":
			if not _need(pos, 1, command + " <file>"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			match command:
				"info":
					return await ops.call_op("describe", { graph = str(opt.get("graph", "")), all_params = opt.has("all") })
				"node":
					return await ops.call_op("get_node", { node = pos[1] if pos.size() > 1 else "" })
				_:
					return await ops.call_op("list_export_targets", {})
		"add":
			if not _need(pos, 2, "add <file> <type> [--name N] [--graph G] [param=value ...]"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			r = await ops.call_op("add_node", { type = pos[1], name = str(opt.get("name", "")), graph = str(opt.get("graph", "")), parameters = _params_from(pos.slice(2)) })
			return await _finish_edit(r, opt)
		"set":
			if not _need(pos, 3, "set <file> <node> <param=value ...>"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			r = await ops.call_op("set_parameters", { node = pos[1], parameters = _params_from(pos.slice(2)) })
			return await _finish_edit(r, opt)
		"remove":
			if not _need(pos, 2, "remove <file> <node>"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			r = await ops.call_op("remove_node", { node = pos[1] })
			return await _finish_edit(r, opt)
		"rename":
			if not _need(pos, 3, "rename <file> <node> <new_name>"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			r = await ops.call_op("rename_node", { node = pos[1], new_name = pos[2] })
			return await _finish_edit(r, opt)
		"connect":
			if not _need(pos, 3, "connect <file> <from[:out]> <to[:in]>"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			var from : Array = _split_port(pos[1])
			var to : Array = _split_port(pos[2])
			r = await ops.call_op("connect", { graph = str(opt.get("graph", "")), from = from[0], from_port = from[1], to = to[0], to_port = to[1] })
			return await _finish_edit(r, opt)
		"disconnect":
			if not _need(pos, 2, "disconnect <file> <to[:in]>"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			var target : Array = _split_port(pos[1])
			r = await ops.call_op("disconnect", { graph = str(opt.get("graph", "")), to = target[0], to_port = target[1] })
			return await _finish_edit(r, opt)
		"render":
			if not _need(pos, 1, "render <file> [--node N] [--output O] [--size S] [-o out.png]"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			var out : String = str(opt.get("o", opt.get("out", "")))
			if out == "":
				out = pos[0].get_basename() + ".png"
			var args : Dictionary = { size = int(opt.get("size", 256)), out = out, output = parse_value(str(opt.get("output", "0"))) }
			if opt.has("node"):
				args.node = str(opt.node)
			return await ops.call_op("render", args)
		"export":
			if not _need(pos, 1, "export <file> [-t target] [--size S] [-o dir]"):
				return { error = "missing argument" }
			r = await _open(pos[0])
			if r.has("error"):
				return r
			var export_args : Dictionary = { size = int(opt.get("size", 1024)), dir = str(opt.get("o", opt.get("dir", pos[0].get_base_dir()))) }
			if opt.has("t"):
				export_args.target = str(opt.t)
			elif opt.has("target"):
				export_args.target = str(opt.target)
			if opt.has("name"):
				export_args.file_name = str(opt.name)
			return await ops.call_op("export", export_args)
		"batch":
			if not _need(pos, 1, "batch <script.json>"):
				return { error = "missing argument" }
			var f : FileAccess = FileAccess.open(ops.abs_path(pos[0]), FileAccess.READ)
			if f == null:
				return { error = "Cannot read '%s'" % pos[0] }
			var json : JSON = JSON.new()
			if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary or json.data is Array):
				return { error = "Invalid JSON in '%s': %s (line %d)" % [pos[0], json.get_error_message(), json.get_error_line()] }
			var batch_args : Dictionary = json.data if json.data is Dictionary else { ops = json.data }
			return await ops.call_op("batch", batch_args)
		"serve":
			var server : Node = load("res://material_maker/cli/mm_server.gd").new()
			server.ops = ops
			add_child(server)
			var status : Error = server.start(int(opt.get("port", 8765)))
			if status != OK:
				return { error = "Cannot listen on port %s (%s)" % [str(opt.get("port", 8765)), error_string(status)] }
			print("@@MM_READY@@ %d" % server.port)
			await server.stopped
			return { ok = true }
	print(HELP)
	return { error = "Unknown command '%s'" % command }
