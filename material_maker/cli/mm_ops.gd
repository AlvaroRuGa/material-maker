extends Node

# Headless Material Maker "session": one open project (a MMGenGraph) and a set of
# JSON-friendly operations on it. This is the single implementation shared by the
# command line (mm_cli.gd), the TCP server used by the MCP bridge (mm_server.gd)
# and batch scripts.
#
# Every operation takes a Dictionary of arguments and returns a Dictionary. On
# failure the result contains an "error" key (and never throws).


const DEFAULT_SIZE : int = 256

# Built-in generator types that are not described by an .mmg file.
const BUILTIN_TYPES : Dictionary = {
	buffer = "Buffer (renders its input to a texture)",
	iterate_buffer = "Iterate buffer",
	image = "Image loaded from a file",
	text = "Text",
	switch = "Switch",
	reroute = "Reroute",
	ios = "Graph inputs/outputs (inside subgraphs)",
	comment = "Comment",
	export = "Export",
	autoexport = "Auto export",
	graph = "Empty subgraph",
}

# Live mode: set to a Callable returning the MMGraphEdit of the current tab of the running
# editor. Edits then go through the editor's own (undoable) API so the graph is redrawn as
# it changes, instead of working on a private headless copy.
var live : Callable = Callable()

var root : MMGenGraph = null
var path : String = ""
var dirty : bool = false


func _err(message : String, extra : Dictionary = {}) -> Dictionary:
	var rv : Dictionary = { error = message }
	rv.merge(extra)
	return rv


# Helpers -----------------------------------------------------------------------

func is_live() -> bool:
	return live.is_valid()

func _ge():
	return live.call() if live.is_valid() else null

# In live mode the project is whatever the editor has open, so refresh before each operation
func _sync_live() -> void:
	var ge = _ge()
	if ge == null or ge.top_generator == null or not is_instance_valid(ge.top_generator):
		root = null
		path = ""
		dirty = false
	else:
		root = ge.top_generator
		path = ge.save_path
		dirty = ge.need_save

# Edits must happen in the graph that the editor currently shows
func _show_graph(graph : MMGenGraph) -> void:
	var ge = _ge()
	if ge != null and ge.generator != graph:
		ge.update_view(graph)

# Godot changes its working directory to the project when started with --path, so the
# launcher passes the caller's directory in MM_CWD and relative paths are resolved there.
var cwd : String = ""   # set per request by the server (the caller's directory)

func abs_path(p : String) -> String:
	if p == "" or p.is_absolute_path() or p.begins_with("res://") or p.begins_with("user://"):
		return p
	var base : String = cwd if cwd != "" else OS.get_environment("MM_CWD")
	return base.path_join(p) if base != "" else p

func _has_project() -> bool:
	return root != null and is_instance_valid(root)

func _graph_at(graph_path : String) -> MMGenGraph:
	if not _has_project():
		return null
	if graph_path == "" or graph_path == "." or graph_path == "/":
		return root
	var n : Node = root.get_node_or_null(NodePath(graph_path))
	return n if n is MMGenGraph else null

func _node_at(node_path : String) -> MMGenBase:
	if not _has_project():
		return null
	if node_path == "" or node_path == ".":
		return root
	var n : Node = root.get_node_or_null(NodePath(node_path))
	return n if n is MMGenBase else null

func _rel_path(n : Node) -> String:
	if n == root:
		return ""
	return String(root.get_path_to(n))

static func jsonable(v):
	if v is Color:
		return "#"+v.to_html(v.a < 1.0)
	if v is Object and v.has_method("serialize"):
		return jsonable(v.serialize())
	if v is Dictionary:
		var d : Dictionary = {}
		for k in v.keys():
			d[str(k)] = jsonable(v[k])
		return d
	if v is Array:
		var a : Array = []
		for i in v:
			a.append(jsonable(i))
		return a
	if v is PackedFloat32Array or v is PackedInt32Array or v is PackedStringArray or v is PackedVector2Array or v is PackedColorArray:
		return jsonable(Array(v))
	if v is Vector2:
		return [v.x, v.y]
	if v is Vector3:
		return [v.x, v.y, v.z]
	if v is StringName:
		return str(v)
	if v is Object or v is Callable or v is Signal or v is RID:
		return str(v)
	return v

func _def_summary(def : Dictionary) -> Dictionary:
	var rv : Dictionary = {}
	for k in def.keys():
		if k in ["default", "min", "max", "step", "type", "name", "label", "shortdesc", "longdesc", "values", "first", "last", "control", "function"]:
			rv[k] = jsonable(def[k])
	return rv

func _port_summary(defs : Array) -> Array:
	var rv : Array = []
	for i in defs.size():
		var d : Dictionary = defs[i]
		var item : Dictionary = { index = i }
		for k in ["name", "label", "type", "shortdesc", "longdesc", "default"]:
			if d.has(k):
				item[k] = jsonable(d[k])
		rv.append(item)
	return rv

func _default_matches(gen : MMGenBase, param : String, value) -> bool:
	var def : Dictionary = gen.get_parameter_def(param)
	if not def.has("default"):
		return false
	var dv = MMType.deserialize_value(def.default)
	if def.get("type", "") == "size" and (dv is int or dv is float) and def.has("first"):
		dv -= def.first
	if (dv is float or dv is int) and (value is float or value is int):
		return is_equal_approx(float(dv), float(value))
	return JSON.stringify(jsonable(dv)) == JSON.stringify(jsonable(value))

func _compact_ports(defs : Array) -> Array:
	var rv : Array = []
	for i in defs.size():
		var d : Dictionary = defs[i]
		rv.append("%d:%s(%s)" % [i, d.get("name", d.get("shortdesc", "")), d.get("type", "")])
	return rv

func _node_summary(gen : MMGenBase, all_params : bool, compact : bool = false) -> Dictionary:
	var rv : Dictionary = {
		name = gen.name,
		type = gen.model if gen.model != null else gen.get_type(),
		position = [gen.position.x, gen.position.y],
	}
	if gen.get_script() == MMGenGraph:
		rv.is_graph = true
		rv.children = gen.get_children().filter(func(c): return c is MMGenBase).size()
	var params : Dictionary = {}
	for p in gen.get_parameter_defs():
		var value = gen.parameters[p.name] if gen.parameters.has(p.name) else null
		if value == null:
			continue
		if all_params or not _default_matches(gen, p.name, value):
			params[p.name] = jsonable(value)
	rv.parameters = params
	if compact:
		rv.inputs = _compact_ports(gen.get_input_defs())
		rv.outputs = _compact_ports(gen.get_output_defs())
	else:
		rv.inputs = _port_summary(gen.get_input_defs())
		rv.outputs = _port_summary(gen.get_output_defs())
	return rv

# Resolves a port given as index, numeric string or port name/label
func _resolve_port(defs : Array, port) -> int:
	if port is float or port is int:
		return int(port)
	var s : String = str(port)
	if s.is_valid_int():
		return s.to_int()
	for i in defs.size():
		var d : Dictionary = defs[i]
		for k in ["name", "label", "shortdesc"]:
			if d.has(k) and str(d[k]).to_lower() == s.to_lower():
				return i
	# Material inputs are called albedo_tex, roughness_tex...: accept the short form
	for i in defs.size():
		if str(defs[i].get("name", "")).to_lower() == s.to_lower() + "_tex":
			return i
	return -1

func _free_name(graph : MMGenGraph, prefix : String) -> String:
	var i : int = 0
	while graph.has_node(NodePath("%s_%d" % [prefix, i])):
		i += 1
	return "%s_%d" % [prefix, i]

func _close() -> void:
	if _has_project():
		remove_child(root)
		root.queue_free()
	root = null
	path = ""
	dirty = false

func _adopt(gen : MMGenBase) -> void:
	_close()
	if gen is MMGenGraph:
		root = gen
	else:
		# Wrap a lone generator in a graph so that everything below can assume a graph
		root = MMGenGraph.new()
		root.name = "graph"
		add_child(root)
		root.add_generator(gen)
		remove_child(root)
	add_child(root)


# Parameter value coercion ---------------------------------------------------------

func _coerce_color(v):
	if v is String:
		if Color.html_is_valid(v):
			return Color.html(v)
		var named : Color = Color.from_string(v, Color(-1, -1, -1))
		if named.r >= 0.0:
			return named
		return null
	if v is Array and v.size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if v.size() > 3 else 1.0)
	if v is Dictionary and v.has("r"):
		return Color(float(v.r), float(v.g), float(v.b), float(v.get("a", 1.0)))
	return null

func _coerce_gradient(v):
	# Accepts [[pos, color], ...], [{pos,r,g,b,a}, ...] or a full {type:"Gradient"} dictionary
	if v is Array:
		var points : Array = []
		for item in v:
			if item is Array and item.size() == 2:
				var c = _coerce_color(item[1])
				if c == null:
					return null
				points.append({ pos = float(item[0]), r = c.r, g = c.g, b = c.b, a = c.a })
			elif item is Dictionary and item.has("pos"):
				if item.has("color"):
					var c2 = _coerce_color(item.color)
					if c2 == null:
						return null
					points.append({ pos = float(item.pos), r = c2.r, g = c2.g, b = c2.b, a = c2.a })
				else:
					points.append(item)
			else:
				return null
		var g : MMGradient = MMGradient.new()
		g.deserialize(points)
		return g
	return MMType.deserialize_value(v)

func _coerce_param(gen : MMGenBase, param : String, value) -> Dictionary:
	var def : Dictionary = gen.get_parameter_def(param)
	if def.is_empty():
		var names : Array = gen.get_parameter_defs().map(func(d): return d.name)
		return _err("Node '%s' has no parameter '%s'" % [gen.name, param], { available = names })
	match def.get("type", ""):
		"float":
			if value is float or value is int:
				return { value = float(value) }
			if value is String:
				if value.is_valid_float():
					return { value = value.to_float() }
				return { value = value }  # expression such as "$size*2"
		"int", "size":
			if value is float or value is int or (value is String and value.is_valid_int()):
				return { value = int(value) }
		"boolean":
			if value is bool:
				return { value = value }
			if value is String and value.to_lower() in ["true", "false"]:
				return { value = value.to_lower() == "true" }
			if value is float or value is int:
				return { value = value != 0 }
		"enum":
			if value is float or value is int or (value is String and value.is_valid_int()):
				return { value = int(value) }
			if value is String:
				var values : Array = def.get("values", [])
				for i in values.size():
					if str(values[i].get("name", "")).to_lower() == value.to_lower() or str(values[i].get("value", "")).to_lower() == value.to_lower():
						return { value = i }
				return _err("Unknown enum value '%s' for '%s'" % [value, param], { available = values.map(func(d): return d.get("name", "")) })
		"color":
			var c = _coerce_color(value)
			if c != null:
				return { value = c }
			return _err("Cannot interpret '%s' as a color (use \"#rrggbb[aa]\", [r,g,b,a] or {r,g,b,a})" % str(value))
		"gradient":
			var g = _coerce_gradient(value)
			if g != null:
				return { value = g }
			return _err("Cannot interpret value as a gradient (use [[pos, \"#color\"], ...])")
		"string", "file", "font":
			return { value = str(value) }
	return { value = MMType.deserialize_value(value) }

func _coerce_params(gen : MMGenBase, params : Dictionary) -> Dictionary:
	var values : Dictionary = {}
	for p in params.keys():
		var r : Dictionary = _coerce_param(gen, p, params[p])
		if r.has("error"):
			return r
		values[p] = r.value
	return { values = values }

func _apply_params(gen : MMGenBase, params : Dictionary) -> Dictionary:
	var coerced : Dictionary = _coerce_params(gen, params)
	if coerced.has("error"):
		return coerced
	var applied : Dictionary = {}
	var serialized : Dictionary = {}
	for p in coerced.values.keys():
		applied[p] = jsonable(coerced.values[p])
		serialized[p] = MMType.serialize_value(coerced.values[p])
		if not is_live():
			gen.set_parameter(p, coerced.values[p])
	if is_live() and not serialized.is_empty():
		_ge().set_node_parameters(gen, serialized)   # undoable, updates the node widgets
	return { applied = applied }


# Operations -------------------------------------------------------------------------

func op_ping(_args : Dictionary) -> Dictionary:
	return { pong = true, live = is_live(), godot = Engine.get_version_info().string, material_maker = ProjectSettings.get_setting("application/config/release", "") }

func op_list_node_types(args : Dictionary) -> Dictionary:
	var filter : String = str(args.get("filter", "")).to_lower()
	var rv : Array = []
	for k in mm_loader.predefined_generators.keys():
		var g : Dictionary = mm_loader.predefined_generators[k]
		var label : String = ""
		if g.has("shader_model") and g.shader_model.has("name"):
			label = g.shader_model.name
		elif g.has("label"):
			label = g.label
		var desc : String = ""
		if g.has("shader_model") and g.shader_model.has("shortdesc"):
			desc = g.shader_model.shortdesc
		if filter == "" or filter in k.to_lower() or filter in label.to_lower() or filter in desc.to_lower():
			rv.append({ type = k, label = label, description = desc })
	for k in BUILTIN_TYPES.keys():
		if filter == "" or filter in k or filter in BUILTIN_TYPES[k].to_lower():
			rv.append({ type = k, label = k, description = BUILTIN_TYPES[k], builtin = true })
	rv.sort_custom(func(a, b): return a.type < b.type)
	return { count = rv.size(), types = rv }

func _make_gen(type : String) -> MMGenBase:
	var data : Dictionary = { type = type }
	if type == "graph":
		data = { nodes = [], connections = [] }
	var gen = await mm_loader.create_gen(data)
	return gen

func op_node_type_info(args : Dictionary) -> Dictionary:
	var type : String = str(args.get("type", ""))
	if type == "" or not (mm_loader.predefined_generators.has(type) or BUILTIN_TYPES.has(type) or type == "material"):
		return _err("Unknown node type '%s' (use list_node_types)" % type)
	var gen : MMGenBase = await _make_gen(type)
	if gen == null:
		return _err("Cannot instantiate node type '%s'" % type)
	add_child(gen)
	var rv : Dictionary = {
		type = type,
		parameters = gen.get_parameter_defs().map(func(d): return _def_summary(d)),
		inputs = _port_summary(gen.get_input_defs()),
		outputs = _port_summary(gen.get_output_defs()),
	}
	if mm_loader.predefined_generators.has(type):
		var g : Dictionary = mm_loader.predefined_generators[type]
		if g.has("shader_model"):
			rv.description = g.shader_model.get("longdesc", g.shader_model.get("shortdesc", ""))
	remove_child(gen)
	gen.free()
	return rv

func op_new_project(args : Dictionary) -> Dictionary:
	var size_exp : int = int(args.get("size", 11))
	if is_live():
		await mm_globals.main_window.new_material()
		_sync_live()
		if not _has_project():
			return _err("The editor could not create a project")
		var material : Node = root.get_node_or_null("Material")
		if material != null:
			material.set_parameter("size", size_exp)
		return { ok = true, nodes = root.get_children().size() }
	var gen = await mm_loader.create_gen({ nodes = [{ name = "Material", type = "material", parameters = { size = size_exp } }], connections = [] })
	if gen == null:
		return _err("Cannot create project")
	_adopt(gen)
	path = str(args.get("path", ""))
	dirty = true
	return { ok = true, nodes = root.get_children().size() }

func op_open(args : Dictionary) -> Dictionary:
	var file : String = abs_path(str(args.get("path", "")))
	if file == "" or not FileAccess.file_exists(file):
		return _err("File not found: '%s'" % file)
	if is_live():
		if not await mm_globals.main_window.do_load_project(file):
			return _err("The editor could not load '%s'" % file)
		_sync_live()
		return { ok = true, path = path, nodes = root.get_children().filter(func(c): return c is MMGenBase).size() if _has_project() else 0 }
	var gen = await mm_loader.load_gen(file)
	if gen == null:
		return _err("Cannot load '%s'" % file)
	_adopt(gen)
	path = file
	dirty = false
	return { ok = true, path = path, nodes = root.get_children().filter(func(c): return c is MMGenBase).size() }

func op_save(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open")
	var file : String = abs_path(str(args.get("path", path)))
	if file == "":
		return _err("No path given")
	if file.get_extension() == "":
		file += ".ptex"
	if file.get_base_dir() != "":
		DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	if is_live():
		if not await _ge().save_file(file):
			return _err("The editor could not save '%s'" % file)
	else:
		mm_loader.save_gen(file, root)
	path = file
	dirty = false
	return { ok = true, path = file }

func op_close(_args : Dictionary) -> Dictionary:
	if is_live():
		return _err("close is not available in live mode (close the tab in the editor)")
	_close()
	return { ok = true }

func op_describe(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open")
	var graph : MMGenGraph = _graph_at(str(args.get("graph", "")))
	if graph == null:
		return _err("Graph '%s' not found" % str(args.get("graph", "")))
	var all_params : bool = bool(args.get("all_params", false))
	var nodes : Array = []
	for c in graph.get_children():
		if c is MMGenBase:
			nodes.append(_node_summary(c, all_params, true))
	var conns : Array = []
	for c in graph.connections:
		conns.append("%s:%d -> %s:%d" % [c.from, c.from_port, c.to, c.to_port])
	return { path = path, dirty = dirty, graph = _rel_path(graph), nodes = nodes, connections = conns }

func op_get_node(args : Dictionary) -> Dictionary:
	var gen : MMGenBase = _node_at(str(args.get("node", "")))
	if gen == null:
		return _err("Node '%s' not found" % str(args.get("node", "")))
	return _node_summary(gen, true)

func op_add_node(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open (use new_project or open)")
	var graph : MMGenGraph = _graph_at(str(args.get("graph", "")))
	if graph == null:
		return _err("Graph '%s' not found" % str(args.get("graph", "")))
	var type : String = str(args.get("type", ""))
	if not (mm_loader.predefined_generators.has(type) or BUILTIN_TYPES.has(type)):
		var close : Array = mm_loader.predefined_generators.keys().filter(func(k): return type != "" and (type in k or k in type))
		return _err("Unknown node type '%s'" % type, { suggestions = close.slice(0, 10) })
	if is_live():
		return await _live_add_node(graph, type, args)
	var gen : MMGenBase = await _make_gen(type)
	if gen == null:
		return _err("Cannot instantiate node type '%s'" % type)
	var node_name : String = str(args.get("name", ""))
	if node_name == "":
		node_name = _free_name(graph, type)
	elif graph.has_node(NodePath(node_name)):
		gen.free()
		return _err("A node named '%s' already exists" % node_name)
	gen.name = node_name
	if args.has("position"):
		gen.position = Vector2(args.position[0], args.position[1])
	else:
		gen.position = _next_position(graph)
	if not graph.add_generator(gen):
		gen.free()
		return _err("Cannot add node '%s' here" % type)
	if args.has("parameters"):
		var r : Dictionary = _apply_params(gen, args.parameters)
		if r.has("error"):
			graph.remove_generator(gen)
			return r
	dirty = true
	return _node_summary(gen, false, true)

# New nodes go to the left of everything else (the Material sink sits on the right), in the order
# they are added, so a chain built from generator to material reads left to right.
func _next_position(graph : MMGenGraph) -> Vector2:
	var min_x : float = 0.0
	var found : bool = false
	for c in graph.get_children():
		if c is MMGenBase:
			min_x = min(min_x, c.position.x) if found else c.position.x
			found = true
	return Vector2(min_x - 330.0 if found else 0.0, 0.0)

func op_auto_layout(args : Dictionary) -> Dictionary:
	var graph : MMGenGraph = _graph_at(str(args.get("graph", "")))
	if graph == null:
		return _err("Graph '%s' not found" % str(args.get("graph", "")))
	var gens : Array = graph.get_children().filter(func(c): return c is MMGenBase)
	var outgoing : Dictionary = {}
	for c in graph.connections:
		if not outgoing.has(c.from):
			outgoing[c.from] = []
		outgoing[c.from].append(c.to)
	# depth = longest path to a node that feeds nothing (relaxation, so loops cannot hang it)
	var depth : Dictionary = {}
	for g in gens:
		depth[str(g.name)] = 0
	for _i in gens.size():
		var changed : bool = false
		for from in outgoing.keys():
			for t in outgoing[from]:
				if depth.has(str(from)) and depth.has(str(t)) and depth[str(from)] < depth[str(t)] + 1 and depth[str(t)] < gens.size():
					depth[str(from)] = depth[str(t)] + 1
					changed = true
		if not changed:
			break
	var layers : Dictionary = {}
	for g in gens:
		var d : int = depth[str(g.name)]
		if not layers.has(d):
			layers[d] = []
		layers[d].append(g)
	for d in layers.keys():
		var y : float = 0.0
		for g in layers[d]:
			var h : float = 220.0 + 30.0 * max(g.get_parameter_defs().size(), g.get_input_defs().size())
			g.position = Vector2(-380.0 * d, y)
			y += h
	if is_live():
		_ge().update_view(graph)
		_ge().center_view()
	dirty = true
	return { ok = true, layers = layers.size() }

func op_quit_editor(_args : Dictionary) -> Dictionary:
	if not is_live():
		return _err("quit_editor is only available in live mode")
	# Deferred so the reply is sent first. A normal exit also deletes the crash-recovery file;
	# force-killing the editor leaves it behind and the next start asks to "load unsaved work".
	get_tree().create_timer(0.3).timeout.connect(func(): get_tree().quit())
	return { ok = true }

func op_center_view(_args : Dictionary) -> Dictionary:
	if not is_live():
		return _err("center_view is only available in live mode")
	_ge().center_view()
	return { ok = true }

func _live_add_node(graph : MMGenGraph, type : String, args : Dictionary) -> Dictionary:
	# Validate and convert the parameters on a throw-away instance first, so that a bad
	# request leaves the editor (and its undo history) untouched.
	var temp : MMGenBase = await _make_gen(type)
	if temp == null:
		return _err("Cannot instantiate node type '%s'" % type)
	var serialized : Dictionary = {}
	if args.has("parameters"):
		var coerced : Dictionary = _coerce_params(temp, args.parameters)
		if coerced.has("error"):
			temp.free()
			return coerced
		for p in coerced.values.keys():
			serialized[p] = MMType.serialize_value(coerced.values[p])
	temp.free()
	var node_name : String = str(args.get("name", ""))
	if node_name == "":
		node_name = _free_name(graph, type)
	elif graph.has_node(NodePath(node_name)):
		return _err("A node named '%s' already exists" % node_name)
	var pos : Vector2
	if args.has("position"):
		pos = Vector2(args.position[0], args.position[1])
	else:
		pos = _next_position(graph)
	var node_data : Dictionary = { type = type } if type != "graph" else { nodes = [], connections = [] }
	node_data.name = node_name
	node_data.node_position = { x = pos.x, y = pos.y }
	if not serialized.is_empty():
		node_data.parameters = serialized
	_show_graph(graph)
	var nodes : Array = await _ge().create_nodes({ nodes = [node_data], connections = [] })
	if nodes.is_empty():
		return _err("The editor refused to add node '%s'" % type)
	return _node_summary(nodes[0].generator, false, true)

func op_remove_node(args : Dictionary) -> Dictionary:
	var gen : MMGenBase = _node_at(str(args.get("node", "")))
	if gen == null or gen == root:
		return _err("Node '%s' not found" % str(args.get("node", "")))
	var parent : Node = gen.get_parent()
	if is_live():
		_show_graph(parent)
		var ui : Node = _ge().get_node_or_null("node_" + gen.name)
		if ui == null or not gen.can_be_deleted():
			return _err("Node '%s' cannot be removed" % gen.name)
		_ge().remove_node(ui)
	elif not (parent is MMGenGraph) or not parent.remove_generator(gen):
		return _err("Node '%s' cannot be removed" % gen.name)
	dirty = true
	return { ok = true }

func op_set_parameters(args : Dictionary) -> Dictionary:
	var gen : MMGenBase = _node_at(str(args.get("node", "")))
	if gen == null:
		return _err("Node '%s' not found" % str(args.get("node", "")))
	var r : Dictionary = _apply_params(gen, args.get("parameters", {}))
	if r.has("error"):
		return r
	dirty = true
	return { ok = true, applied = r.applied }

func op_set_parameter(args : Dictionary) -> Dictionary:
	return op_set_parameters({ node = args.get("node", ""), parameters = { str(args.get("parameter", "")): args.get("value") } })

func op_rename_node(args : Dictionary) -> Dictionary:
	var gen : MMGenBase = _node_at(str(args.get("node", "")))
	var new_name : String = str(args.get("new_name", ""))
	if gen == null or gen == root:
		return _err("Node '%s' not found" % str(args.get("node", "")))
	var parent : MMGenGraph = gen.get_parent()
	if new_name == "" or parent.has_node(NodePath(new_name)):
		return _err("Invalid or already used name '%s'" % new_name)
	var old_name : String = gen.name
	for c in parent.connections:
		if c.from == old_name:
			c.from = new_name
		if c.to == old_name:
			c.to = new_name
	gen.name = new_name
	if is_live():
		_ge().update_view(parent)   # rebuild the node widgets: they are named after the generators
	dirty = true
	return { ok = true, name = gen.name }

func op_connect(args : Dictionary) -> Dictionary:
	var graph : MMGenGraph = _graph_at(str(args.get("graph", "")))
	if graph == null:
		return _err("Graph '%s' not found" % str(args.get("graph", "")))
	var from : Node = graph.get_node_or_null(NodePath(str(args.get("from", ""))))
	var to : Node = graph.get_node_or_null(NodePath(str(args.get("to", ""))))
	if not (from is MMGenBase):
		return _err("Source node '%s' not found" % str(args.get("from", "")))
	if not (to is MMGenBase):
		return _err("Target node '%s' not found" % str(args.get("to", "")))
	var from_port : int = _resolve_port(from.get_output_defs(), args.get("from_port", 0))
	var to_port : int = _resolve_port(to.get_input_defs(), args.get("to_port", 0))
	if from_port < 0 or from_port >= from.get_output_defs().size():
		return _err("Invalid output port '%s' on '%s'" % [str(args.get("from_port", 0)), from.name], { outputs = _port_summary(from.get_output_defs()) })
	if to_port < 0 or to_port >= to.get_input_defs().size():
		return _err("Invalid input port '%s' on '%s'" % [str(args.get("to_port", 0)), to.name], { inputs = _port_summary(to.get_input_defs()) })
	if is_live():
		_show_graph(graph)
		_ge().on_connect_node("node_" + from.name, from_port, "node_" + to.name, to_port)
		var made : bool = graph.connections.any(func(c): return c.from == from.name and c.from_port == from_port and c.to == to.name and c.to_port == to_port)
		if not made:
			return _err("Connection refused (would create a loop?)")
	elif not graph.connect_children(from, from_port, to, to_port):
		return _err("Connection refused (would create a loop?)")
	dirty = true
	return { ok = true, connection = "%s:%d -> %s:%d" % [from.name, from_port, to.name, to_port] }

func op_disconnect(args : Dictionary) -> Dictionary:
	var graph : MMGenGraph = _graph_at(str(args.get("graph", "")))
	if graph == null:
		return _err("Graph '%s' not found" % str(args.get("graph", "")))
	var to : Node = graph.get_node_or_null(NodePath(str(args.get("to", ""))))
	if not (to is MMGenBase):
		return _err("Target node '%s' not found" % str(args.get("to", "")))
	var to_port : int = _resolve_port(to.get_input_defs(), args.get("to_port", 0))
	var found : bool = false
	for c in graph.connections.duplicate():
		if c.to == to.name and c.to_port == to_port:
			if is_live():
				_show_graph(graph)
				_ge().on_disconnect_node("node_" + c.from, c.from_port, "node_" + c.to, c.to_port)
			else:
				graph.disconnect_children_by_name(c.from, c.from_port, c.to, c.to_port)
			found = true
	if not found:
		return _err("Nothing is connected to '%s' input %d" % [to.name, to_port])
	dirty = true
	return { ok = true }

func op_render(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open")
	var gen : MMGenBase = _node_at(str(args.get("node", "Material" if _has_project() and root.has_node("Material") else "")))
	if gen == null:
		return _err("Node '%s' not found" % str(args.get("node", "")))
	var outputs : Array = gen.get_output_defs()
	if outputs.is_empty() and not gen.get_input_defs().is_empty():
		# Sink nodes (Material): render what is connected to one of their inputs ("albedo", "normal", ...)
		var inputs : Array = gen.get_input_defs()
		var wanted = args.get("output", 0)
		var input_index : int = _resolve_port(inputs, wanted)
		if input_index < 0:
			input_index = _resolve_port(inputs, str(wanted) + "_tex")
		if input_index < 0 or input_index >= inputs.size():
			return _err("Node '%s' has no input '%s'" % [gen.name, str(wanted)], { inputs = _port_summary(inputs) })
		var source = gen.get_source(input_index)
		if source == null:
			return _err("Nothing is connected to input %d (%s) of '%s'" % [input_index, inputs[input_index].get("name", ""), gen.name])
		gen = source.generator
		args = args.duplicate()
		args["output"] = source.output_index
		outputs = gen.get_output_defs()
	var output_index : int = _resolve_port(outputs, args.get("output", 0))
	if output_index < 0 or output_index >= outputs.size():
		return _err("Node '%s' has no output '%s'" % [gen.name, str(args.get("output", 0))], { outputs = _port_summary(outputs) })
	var size : int = int(args.get("size", DEFAULT_SIZE))
	if size < 4 or size > 8192:
		return _err("size must be between 4 and 8192")
	var started : int = Time.get_ticks_msec()
	var image : Image = await gen.render_output(output_index, Vector2i(size, size))
	if image == null or image.is_empty():
		return _err("Rendering failed (shader error? check the log)")
	var rv : Dictionary = { node = gen.name, output = output_index, width = image.get_width(), height = image.get_height(), render_ms = Time.get_ticks_msec() - started }
	rv.merge(_image_stats(image))
	var out : String = abs_path(str(args.get("out", "")))
	if out != "":
		if out.get_base_dir() != "":
			DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var status : Error
		match out.get_extension().to_lower():
			"exr":
				status = image.save_exr(out)
			"jpg", "jpeg":
				status = image.save_jpg(out)
			"webp":
				status = image.save_webp(out)
			_:
				if image.get_format() in [Image.FORMAT_RGBAF, Image.FORMAT_RGBAH, Image.FORMAT_RGBF, Image.FORMAT_RGBH]:
					image.convert(Image.FORMAT_RGBA8)
				status = image.save_png(out)
		if status != OK:
			return _err("Cannot write '%s' (%s)" % [out, error_string(status)])
		rv.path = out
	return rv

func _image_stats(image : Image) -> Dictionary:
	var img : Image = image.duplicate()
	img.convert(Image.FORMAT_RGBAF)
	var step : int = max(1, int(img.get_width() / 64))
	var sum : Color = Color(0, 0, 0, 0)
	var lo : Color = Color(INF, INF, INF, INF)
	var hi : Color = Color(-INF, -INF, -INF, -INF)
	var n : int = 0
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c : Color = img.get_pixel(x, y)
			sum += c
			lo = Color(min(lo.r, c.r), min(lo.g, c.g), min(lo.b, c.b), min(lo.a, c.a))
			hi = Color(max(hi.r, c.r), max(hi.g, c.g), max(hi.b, c.b), max(hi.a, c.a))
			n += 1
	var fmt = func(c : Color) -> Array: return [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001), snappedf(c.a, 0.001)]
	return { mean_rgba = fmt.call(sum / float(max(n, 1))), min_rgba = fmt.call(lo), max_rgba = fmt.call(hi) }

func op_list_export_targets(_args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open")
	var rv : Dictionary = {}
	for c in root.get_children():
		if c.has_method("get_export_profiles"):
			rv[c.name] = c.get_export_profiles()
	return { materials = rv }

func op_export(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open")
	var target : String = str(args.get("target", "Godot/Godot 4 Standard"))
	var size : int = int(args.get("size", 1024))
	var out_dir : String = abs_path(str(args.get("dir", ".")))
	var out_name : String = str(args.get("file_name", path.get_file().get_basename() if path != "" else "material"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var exported : Array = []
	var stack : Array = [root]
	while stack.size():
		var c : Node = stack.pop_back()
		stack.append_array(c.get_children())
		if c is MMGenBase and c.has_method("export_material"):
			var best : String = target
			if c.has_method("get_export_profiles") and c.get_export_profiles().find(target) == -1:
				var best_similarity : float = 0.0
				best = ""
				for p : String in c.get_export_profiles():
					var s : float = p.similarity(target)
					if s > best_similarity:
						best_similarity = s
						best = p
				if best == "":
					return _err("Unsupported target '%s'" % target, { available = c.get_export_profiles() })
			var prefix : String = out_dir.path_join(out_name)
			await c.export_material(prefix, best, size, true)
			exported.append({ node = c.name, target = best, prefix = prefix })
	if exported.is_empty():
		return _err("Project has no exportable material node")
	return { ok = true, exported = exported }

func op_screenshot(args : Dictionary) -> Dictionary:
	if not is_live():
		return _err("screenshot is only available in live mode (the editor window)")
	var image : Image = get_viewport().get_texture().get_image()
	var out : String = abs_path(str(args.get("out", "")))
	if out == "":
		return _err("'out' (a .png path) is required")
	if out.get_base_dir() != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	if image.save_png(out) != OK:
		return _err("Cannot write '%s'" % out)
	return { ok = true, path = out, width = image.get_width(), height = image.get_height() }

func op_batch(args : Dictionary) -> Dictionary:
	var results : Array = []
	for item in args.get("ops", []):
		if not (item is Dictionary) or not item.has("op"):
			results.append(_err("Each batch item needs an 'op'"))
			break
		var r : Dictionary = await call_op(str(item.op), item.get("args", {}))
		results.append(r)
		if r.has("error") and not bool(args.get("continue_on_error", false)):
			break
	return { results = results }

func call_op(op : String, args : Dictionary) -> Dictionary:
	var method : String = "op_" + op.replace("-", "_")
	if not has_method(method):
		return _err("Unknown operation '%s'" % op, { operations = OPERATIONS })
	if is_live():
		_sync_live()
	var rv = await call(method, args)
	return rv if rv is Dictionary else { result = rv }

const OPERATIONS : Array = [
	"ping", "list_node_types", "node_type_info", "new_project", "open", "save", "close", "describe", "get_node",
	"add_node", "remove_node", "rename_node", "set_parameter", "set_parameters", "connect", "disconnect",
	"render", "list_export_targets", "export", "screenshot", "auto_layout", "center_view", "quit_editor", "batch",
]
