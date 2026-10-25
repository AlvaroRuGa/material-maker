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

# Buffer nodes (Buffer, Iterate buffer, and the ones inside nodes such as Normal map) are computed
# asynchronously by the dependency system. Reading them before that has finished yields empty
# textures (e.g. a flat 0.5, 0.5, 0.0 "normal map"), so wait for them.
func _wait_for_buffers(timeout_ms : int = 60000) -> bool:
	var start : int = Time.get_ticks_msec()
	mm_deps.update()
	var settled_frames : int = 0
	while settled_frames < 3:
		await get_tree().process_frame
		var busy : bool = mm_deps.updating or mm_deps.update_scheduled
		for b in mm_deps.buffers.values():
			if (b.object is MMGenBuffer or b.object is MMGenIterateBuffer) and b.status in [mm_deps.Buffer.Invalidated, mm_deps.Buffer.Updating, mm_deps.Buffer.UpdatingInvalidated]:
				busy = true
				break
		settled_frames = 0 if busy else settled_frames + 1
		if Time.get_ticks_msec() - start > timeout_ms:
			return false
	return true

func op_render(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open")
	var buffers_ready : bool = await _wait_for_buffers()
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
	if not buffers_ready:
		rv.warning = "Timed out waiting for buffer nodes to finish; the image may be incomplete"
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

# Examples ---------------------------------------------------------------------------------
# The example projects shipped with Material Maker, as a library to learn from and to borrow
# node chains from. They are read as plain data; only `show_example` with a render instantiates one.

const EXAMPLE_DIRS : Array = ["res://material_maker/examples"]
const CHANNELS : Array = ["albedo", "metallic", "roughness", "emission", "normal", "ao", "depth", "opacity", "sss"]

var _example_cache : Dictionary = {}

func _example_dirs() -> Array:
	var dirs : Array = EXAMPLE_DIRS.duplicate()
	dirs.append(OS.get_executable_path().get_base_dir().path_join("examples"))   # exported builds ship them beside the exe
	return dirs

func _example_names() -> Array:
	var names : Array = []
	for d in _example_dirs():
		var dir : DirAccess = DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			if f.get_extension() == "ptex" and f.get_basename() not in names:
				names.append(f.get_basename())
	names.sort()
	return names

const SITE : String = "https://www.materialmaker.org"

var _community_list : Array = []
var _community_meta : Dictionary = {}   # id -> metadata of community assets seen so far (author, license...)

func _http_get(url : String) -> String:
	var http : HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.timeout = 30.0
	var status : Error = http.request(url, ["User-Agent: material-maker-cli"])
	if status != OK:
		http.queue_free()
		return ""
	var result : Array = await http.request_completed
	http.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		return ""
	return result[3].get_string_from_utf8()

func _community_cache_dirs() -> Array:
	return [ProjectSettings.globalize_path("res://tools/.cache/community"), "user://community"]

func _get_community_list() -> Array:
	if not _community_list.is_empty():
		return _community_list
	for d in _community_cache_dirs():
		var f : FileAccess = FileAccess.open(d.path_join("list.json"), FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				_community_list = parsed
				break
	if _community_list.is_empty():
		var text : String = await _http_get(SITE + "/api/getMaterials")
		var parsed = JSON.parse_string(text)
		if parsed is Array:
			_community_list = parsed
			DirAccess.make_dir_recursive_absolute("user://community")
			var out : FileAccess = FileAccess.open("user://community/list.json", FileAccess.WRITE)
			if out != null:
				out.store_string(text)
	for a in _community_list:
		_community_meta[str(int(a.get("id", 0)))] = a   # JSON numbers arrive as floats
	return _community_list

func _attribution(example_name : String) -> Dictionary:
	if not example_name.begins_with("community:"):
		return {}
	var m : Dictionary = _community_meta.get(example_name.substr(10), {})
	return { name = m.get("name", ""), author = m.get("author", ""), license = m.get("license", ""), source = SITE + "/materials" } if not m.is_empty() else {}

# "name" is an example shipped with Material Maker, or "community:<id>" for a material of
# materialmaker.org (read from a local cache, else downloaded once into user://community)
func _load_example(example_name : String) -> Dictionary:
	if _example_cache.has(example_name):
		return _example_cache[example_name]
	if example_name.begins_with("community:"):
		var id : String = example_name.substr(10)
		if not id.is_valid_int():
			return {}
		await _get_community_list()
		var text : String = ""
		for d in _community_cache_dirs():
			var f : FileAccess = FileAccess.open(d.path_join(id + ".ptex"), FileAccess.READ)
			if f != null:
				text = f.get_as_text()
				break
		if text == "":
			var payload = JSON.parse_string(await _http_get(SITE + "/api/getMaterial?id=" + id))
			if payload is Dictionary and payload.has("json"):
				text = str(payload.json)
				DirAccess.make_dir_recursive_absolute("user://community")
				var out : FileAccess = FileAccess.open("user://community/%s.ptex" % id, FileAccess.WRITE)
				if out != null:
					out.store_string(text)
		var data : Dictionary = mm_loader.string_to_dict_tree(text) if text != "" else {}
		if not data.is_empty():
			_example_cache[example_name] = data
		return data
	for d in _example_dirs():
		var file_path : String = d.path_join(example_name + ".ptex")
		if FileAccess.file_exists(file_path):
			var f : FileAccess = FileAccess.open(file_path, FileAccess.READ)
			var data : Dictionary = mm_loader.string_to_dict_tree(f.get_as_text())
			if not data.is_empty():
				_example_cache[example_name] = data
				return data
	return {}

static func _raw_type(n : Dictionary) -> String:
	if n.has("type") and str(n.type) != "":
		return str(n.type)
	if n.has("nodes"):
		return "graph"
	if n.has("shader_model") and n.shader_model is Dictionary:
		return "shader:" + str(n.shader_model.get("name", "?"))
	return "?"

# Graph dictionary inside an example, following a path of subgraph names ("" = top level)
func _example_graph(data : Dictionary, graph_path : String) -> Dictionary:
	var g : Dictionary = data
	if graph_path == "" or graph_path == ".":
		return g
	for part in graph_path.split("/"):
		var found : bool = false
		for n in g.get("nodes", []):
			if str(n.get("name", "")) == part and n.has("nodes"):
				g = n
				found = true
				break
		if not found:
			return {}
	return g

func _channel_sources(g : Dictionary) -> Dictionary:
	var rv : Dictionary = {}
	var types : Dictionary = {}
	for n in g.get("nodes", []):
		types[str(n.get("name", ""))] = _raw_type(n)
	for c in g.get("connections", []):
		if types.get(str(c.to), "") == "material" and int(c.to_port) < CHANNELS.size():
			rv[CHANNELS[int(c.to_port)]] = "%s:%s" % [c.from, types.get(str(c.from), "?")]
	return rv

func op_list_examples(args : Dictionary) -> Dictionary:
	var filter : String = str(args.get("filter", "")).to_lower()
	var query_words : Array = filter.split(" ", false)
	var rv : Array = []
	if bool(args.get("community", false)):
		var assets : Array = await _get_community_list()
		if assets.is_empty():
			return _err("Cannot reach materialmaker.org (no internet, or the site is down)")
		var wanted_license : String = str(args.get("license", "CC0"))
		var limit : int = int(args.get("limit", 25))
		var total : int = 0
		for a in assets:
			if int(a.get("type", 0)) != 0 or (wanted_license != "any" and str(a.get("license", "")) != wanted_license):
				continue
			var text : String = ("%s %s %s" % [a.get("name", ""), a.get("tags", ""), a.get("description", "")]).to_lower()
			var ok : bool = true
			for w in query_words:
				if w not in text:
					ok = false
			if not ok:
				continue
			total += 1
			if rv.size() < limit:
				rv.append({ name = "community:" + str(int(a.id)), title = a.get("name", ""), author = a.get("author", ""), license = a.get("license", ""), tags = a.get("tags", ""), description = a.get("description", "") })
		return { count = total, shown = rv.size(), licenses = wanted_license, examples = rv, note = "Use name with show_example/import_from_example. CC-BY needs credit to the author if you reuse it." }
	for example_name in _example_names():
		var data : Dictionary = await _load_example(example_name)
		var counts : Dictionary = {}
		for n in data.get("nodes", []):
			var t : String = _raw_type(n)
			counts[t] = counts.get(t, 0) + 1
		var haystack : String = example_name.to_lower() + " " + " ".join(counts.keys())
		var matches : bool = true
		for w in query_words:
			if w not in haystack:
				matches = false
		if not matches:
			continue
		var top : Array = counts.keys()
		top.sort_custom(func(a, b): return counts[a] > counts[b])
		var channels : Dictionary = _channel_sources(data)
		rv.append({ name = example_name, nodes = data.get("nodes", []).size(), main_types = top.filter(func(t): return t not in ["material", "comment"]).slice(0, 6), channels = channels.keys() })
	return { count = rv.size(), examples = rv }

func op_show_example(args : Dictionary) -> Dictionary:
	var example_name : String = str(args.get("name", ""))
	var data : Dictionary = await _load_example(example_name)
	if data.is_empty():
		var close : Array = _example_names().filter(func(n): return example_name != "" and (example_name in n or n in example_name))
		return _err("Unknown example '%s'" % example_name, { suggestions = close.slice(0, 8), hint = "use list_examples" })
	var graph_path : String = str(args.get("graph", ""))
	var g : Dictionary = _example_graph(data, graph_path)
	if g.is_empty():
		return _err("Graph '%s' not found in example '%s'" % [graph_path, example_name])
	var nodes : Array = []
	for n in g.get("nodes", []):
		var item : Dictionary = { name = n.get("name", ""), type = _raw_type(n) }
		if item.type == "comment":
			item.text = str(n.get("text", ""))
		if n.has("nodes"):
			item.children = n.nodes.size()
		var params : Dictionary = {}
		for k in n.get("parameters", {}).keys():
			var v = jsonable(MMType.deserialize_value(n.parameters[k]))
			if v is Dictionary and v.has("points"):
				v = "gradient(%d stops)" % v.points.size()
			params[k] = v
		if not params.is_empty():
			item.parameters = params
		item.position = [n.get("node_position", {}).get("x", 0), n.get("node_position", {}).get("y", 0)]
		nodes.append(item)
	var conns : Array = []
	for c in g.get("connections", []):
		conns.append("%s:%d -> %s:%d" % [c.from, c.from_port, c.to, c.to_port])
	var rv : Dictionary = { name = example_name, graph = graph_path, nodes = nodes, connections = conns, material_channels = _channel_sources(g) }
	var credit : Dictionary = _attribution(example_name)
	if not credit.is_empty():
		rv.attribution = credit
	if args.has("render") or args.has("out"):
		var gen = await mm_loader.create_gen(data.duplicate(true))
		if gen == null:
			rv.render_error = "Cannot instantiate the example"
			return rv
		add_child(gen)
		var saved_root : MMGenGraph = root
		root = gen
		var render_args : Dictionary = { size = int(args.get("size", 256)), out = str(args.get("out", "")), output = args.get("render", "albedo") }
		if args.has("node"):
			render_args.node = args.node
		var r : Dictionary = await op_render(render_args)
		root = saved_root
		remove_child(gen)
		gen.queue_free()
		rv.render = r
	return rv

func op_import_from_example(args : Dictionary) -> Dictionary:
	if not _has_project():
		return _err("No project is open (use new_project or open)")
	var example_name : String = str(args.get("example", ""))
	var data : Dictionary = await _load_example(example_name)
	if data.is_empty():
		return _err("Unknown example '%s' (use list_examples)" % example_name)
	var src : Dictionary = _example_graph(data, str(args.get("from_graph", "")))
	if src.is_empty():
		return _err("Graph '%s' not found in example '%s'" % [str(args.get("from_graph", "")), example_name])
	var dest : MMGenGraph = _graph_at(str(args.get("graph", "")))
	if dest == null:
		return _err("Graph '%s' not found" % str(args.get("graph", "")))
	var by_name : Dictionary = {}
	for n in src.get("nodes", []):
		by_name[str(n.get("name", ""))] = n
	var wanted : Array = []
	for w in args.get("nodes", []):
		if not by_name.has(str(w)):
			return _err("Example '%s' has no node '%s'" % [example_name, str(w)], { available = by_name.keys() })
		if _raw_type(by_name[str(w)]) == "material":
			return _err("The Material node cannot be imported; connect imported nodes to your own Material")
		wanted.append(str(w))
	if wanted.is_empty():
		return _err("'nodes' must list at least one node name (see show_example)")
	if bool(args.get("with_upstream", false)):
		var i : int = 0
		while i < wanted.size():
			for c in src.get("connections", []):
				if str(c.to) == wanted[i] and str(c.from) not in wanted and by_name.has(str(c.from)):
					wanted.append(str(c.from))
			i += 1
	var node_data : Array = []
	var min_x : float = INF
	var max_x : float = -INF
	var min_y : float = INF
	for w in wanted:
		var nd : Dictionary = by_name[w].duplicate(true)
		node_data.append(nd)
		var p : Dictionary = nd.get("node_position", {})
		min_x = min(min_x, float(p.get("x", 0)))
		max_x = max(max_x, float(p.get("x", 0)))
		min_y = min(min_y, float(p.get("y", 0)))
	var conn_data : Array = []
	var open_inputs : Array = []
	for c in src.get("connections", []):
		if str(c.to) in wanted:
			if str(c.from) in wanted:
				conn_data.append(c.duplicate())
			else:
				open_inputs.append("%s:%d (was fed by %s)" % [c.to, c.to_port, c.from])
	# put the group to the left of everything already in the graph
	var left : float = 0.0
	var found : bool = false
	for ch in dest.get_children():
		if ch is MMGenBase:
			left = min(left, ch.position.x) if found else ch.position.x
			found = true
	var offset : Vector2 = Vector2((left - 450.0 - max_x) if found else -min_x, -min_y)
	var created : Array = []
	if is_live():
		_show_graph(dest)
		var ui_nodes : Array = await _ge().create_nodes({ nodes = node_data, connections = conn_data }, offset)
		for u in ui_nodes:
			created.append(u.generator)
	else:
		var result : Dictionary = await mm_loader.add_to_gen_graph(dest, node_data, conn_data, offset)
		created = result.generators
	var mapping : Dictionary = {}
	for g in created:
		mapping[str(g.orig_name) if g.orig_name != null else str(g.name)] = str(g.name)
	dirty = true
	var rv : Dictionary = { ok = true, imported = mapping, connections = conn_data.size(), open_inputs = open_inputs }
	var credit : Dictionary = _attribution(example_name)
	if not credit.is_empty():
		rv.attribution = credit
		if str(credit.license) != "CC0":
			rv.attribution_required = "Licensed %s: credit '%s' by %s if you publish this." % [credit.license, credit.name, credit.author]
	return rv

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
	"render", "list_export_targets", "export", "screenshot", "auto_layout", "center_view", "quit_editor", "list_examples", "show_example", "import_from_example", "batch",
]
