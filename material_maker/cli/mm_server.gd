extends Node

# Minimal JSON-lines server over TCP (127.0.0.1 only).
#
# Request  : {"id": 1, "op": "render", "args": {...}}\n
# Response : {"id": 1, "ok": true, "result": {...}}\n   or   {"id": 1, "ok": false, "error": "..."}\n
#
# Requests of a connection are processed one at a time, in order. The special op
# "shutdown" stops the server (and the process).

signal stopped

var ops : Node = null
var port : int = 0

var _server : TCPServer = TCPServer.new()
var _peers : Array = []   # [{ peer = StreamPeerTCP, buffer = PackedByteArray }]
var _busy : bool = false


func start(listen_port : int) -> Error:
	var status : Error = _server.listen(listen_port, "127.0.0.1")
	if status == OK:
		port = _server.get_local_port() if listen_port == 0 else listen_port
	set_process(status == OK)
	return status

func _process(_delta : float) -> void:
	if _server.is_connection_available():
		_peers.append({ peer = _server.take_connection(), buffer = PackedByteArray() })
	if _busy:
		return
	for p in _peers.duplicate():
		var peer : StreamPeerTCP = p.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(p)
			continue
		var available : int = peer.get_available_bytes()
		if available > 0:
			var data : Array = peer.get_data(available)
			if data[0] == OK:
				p.buffer.append_array(data[1])
		var newline : int = p.buffer.find(10)
		if newline != -1:
			var line : String = p.buffer.slice(0, newline).get_string_from_utf8()
			p.buffer = p.buffer.slice(newline + 1)
			_busy = true
			await _handle(peer, line)
			_busy = false
			return

func _reply(peer : StreamPeerTCP, response : Dictionary) -> void:
	peer.put_data((JSON.stringify(ops.jsonable(response)) + "\n").to_utf8_buffer())

func _handle(peer : StreamPeerTCP, line : String) -> void:
	var json : JSON = JSON.new()
	if json.parse(line) != OK or not (json.data is Dictionary):
		# Not our protocol (for instance a web page making an HTTP request to localhost): hang up, so
		# that no later line of the same connection can be taken for a command.
		_reply(peer, { id = null, ok = false, error = "Request must be a JSON object on one line" })
		peer.disconnect_from_host()
		return
	var request : Dictionary = json.data
	var id = request.get("id")
	var op : String = str(request.get("op", ""))
	if op == "shutdown":
		_reply(peer, { id = id, ok = true, result = { ok = true } })
		await get_tree().create_timer(0.1).timeout
		_server.stop()
		stopped.emit()
		return
	ops.cwd = str(request.get("cwd", ""))
	var result : Dictionary = await ops.call_op(op, request.get("args", {}))
	if result.has("error"):
		var message : String = str(result.error)
		result.erase("error")
		_reply(peer, { id = id, ok = false, error = message, details = result })
	else:
		_reply(peer, { id = id, ok = true, result = result })
