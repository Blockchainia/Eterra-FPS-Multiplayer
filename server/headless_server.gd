extends Node

const PORT := 9999
const MAX_CLIENTS := 32
const Player = preload("res://player.tscn")

# --- Round config (defaults) ---
var round_time: float = 30.0
var intermission_time: float = 15.0
var preparation_time: float = 5.0

# --- Round state ---
enum RoundState { INTERMISSION, PREPARATION, IN_ROUND }
var _state: int = RoundState.INTERMISSION
var _token: int = 0 # invalidates old timers
var _players_in_match: int = 0
var _state_ends_at_unix: float = 0.0
func _now() -> float: return Time.get_unix_time_from_system()

func _ready() -> void:
	# Ensure common parent for players
	var world := get_node_or_null("World")
	if world == null:
		world = Node.new()
		world.name = "World"
		add_child(world)
	multiplayer.root_path = world.get_path()

	_load_round_config()
	
	var net: Node = get_node("/root/Network")
	net.server_started.connect(func(p): print("[DEDICATED] Server started on port: ", p))
	net.peer_connected.connect(_on_peer_connected)
	net.peer_disconnected.connect(_on_peer_disconnected)

	var err: int = net.start_dedicated(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("[DEDICATED] Failed to start: %s" % err)

	print("[ROUND] Boot in INTERMISSION (idle)")
	_state = RoundState.INTERMISSION
	_players_in_match = 0

func _load_round_config() -> void:
	var path := "res://server/round_config.json"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var txt := f.get_as_text()
			var data = JSON.parse_string(txt)
			if typeof(data) == TYPE_DICTIONARY:
				round_time = float(data.get("round_time", round_time))
				intermission_time = float(data.get("intermission_time", intermission_time))
				preparation_time = float(data.get("preparation_time", preparation_time))
				print("[ROUND] Loaded config:", data)
			else:
				push_error("[ROUND] JSON not a dictionary; using defaults")
	else:
		print("[ROUND] No config found, using defaults")

func _bump_token() -> int:
	_token += 1
	return _token

func _set_timeout(seconds: float, cb: Callable) -> void:
	var t := _bump_token()
	var st := get_tree().create_timer(max(0.01, seconds))
	st.timeout.connect(func():
		if t == _token:
			cb.call())

# --- State helpers ---
func _enter_intermission(timed: bool) -> void:
	_state = RoundState.INTERMISSION
	print("[ROUND] → INTERMISSION", (" (timed)" if timed else " (idle)"))
	_state_ends_at_unix = (_now() + intermission_time) if timed else 0.0
	_broadcast_round_update()
	if timed and _players_in_match > 0:
		_set_timeout(intermission_time, func():
			if _players_in_match > 0:
				_reset_players_to_spawn()
				_enter_preparation())

func _enter_preparation() -> void:
	_state = RoundState.PREPARATION
	print("[ROUND] → PREPARATION (", preparation_time, "s)")
	_state_ends_at_unix = _now() + preparation_time
	_broadcast_round_update()
	_set_timeout(preparation_time, func(): _enter_round())

func _enter_round() -> void:
	_state = RoundState.IN_ROUND
	print("[ROUND] → IN_ROUND (", round_time, "s)")
	_state_ends_at_unix = _now() + round_time
	_broadcast_round_update()
	_set_timeout(round_time, func(): _enter_intermission(true))

func _on_peer_connected(id: int) -> void:
	_players_in_match += 1
	var player := Player.instantiate()
	player.name = str(id)
	get_node("World").add_child(player)
	print("[NET] + peer ", id, " (players=", _players_in_match, ")")
	_send_round_update_to(id)
	if _state == RoundState.INTERMISSION and _state_ends_at_unix == 0.0:
		# First player while idle → start round immediately
		_enter_round()

func _on_peer_disconnected(id: int) -> void:
	_players_in_match = max(0, _players_in_match - 1)
	var world := get_node_or_null("World")
	if world:
		var p := world.get_node_or_null(str(id))
		if p:
			p.queue_free()
	print("[NET] - peer ", id, " (players=", _players_in_match, ")")
	if _players_in_match == 0:
		_bump_token() # cancel any timers
		call_deferred("_enter_intermission", false)

func _reset_players_to_spawn() -> void:
	var world := get_node("World")
	for c in world.get_children():
		if c.has_method("rpc_reset_to_spawn"):
			# Each player node is owned by its authority peer; ask the authority to reset.
			c.rpc_id(int(c.name), "rpc_reset_to_spawn")

func _send_round_update_to(peer_id: int) -> void:
	var peers := multiplayer.get_peers()
	if not peers.has(peer_id):
		return
	var world := get_node("World")
	var player := world.get_node_or_null(str(peer_id))
	if player != null:
		player.rpc_id(peer_id, "rpc_round_update", _state, _state_ends_at_unix)

func _broadcast_round_update() -> void:
	var peers := multiplayer.get_peers()
	var world := get_node("World")
	for c in world.get_children():
		var pid := int(c.name)
		if peers.has(pid):
			_send_round_update_to(pid)
