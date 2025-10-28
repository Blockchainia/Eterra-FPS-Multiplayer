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

# --- Participation & readiness ---
var _ready_flags := {}           # peer_id -> bool (true = ready spectator)
var _participants := {}          # peer_id -> true for participants in current round

func _connected_peers() -> Array:
	return multiplayer.get_peers()

func _ready_count() -> int:
	var n := 0
	for id in _connected_peers():
		if bool(_ready_flags.get(id, false)):
			n += 1
	return n

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
	_participants.clear()
	_broadcast_round_update()
	_broadcast_roster()
	# Everyone becomes a spectator during intermission
	var world := get_node("World")
	for c in world.get_children():
		var pid := int(c.name)
		c.rpc_id(pid, "rpc_set_participation", false)
		c.rpc_id(pid, "rpc_move_to_spectator_area")
	if timed and _players_in_match > 0:
		_set_timeout(intermission_time, func():
			if _players_in_match > 0 and _ready_count() > 0:
				_reset_players_to_spawn()
				_enter_preparation()
			else:
				print("[ROUND] no ready spectators → staying idle intermission")
				_enter_intermission(false))

func _enter_preparation() -> void:
	_state = RoundState.PREPARATION
	print("[ROUND] → PREPARATION (", preparation_time, "s)")
	_state_ends_at_unix = _now() + preparation_time
	# Build participants from current ready spectators
	_participants.clear()
	var _ready_now: Array = []
	for id in _connected_peers():
		if bool(_ready_flags.get(id, false)):
			_ready_now.append(id)
	print("[ROUND] prep: ready spectators → ", _ready_now)
	for id in _connected_peers():
		if bool(_ready_flags.get(id, false)):
			_participants[id] = true
	var _parts_now: Array = []
	for k in _participants.keys():
		_parts_now.append(k)
	print("[ROUND] prep: participants this round → ", _parts_now)
	# Inform each client of their participation status for this round
	var world := get_node("World")
	for c in world.get_children():
		var pid := int(c.name)
		var is_part := _participants.has(pid)
		c.rpc_id(pid, "rpc_set_participation", is_part)
		if not is_part:
			c.rpc_id(pid, "rpc_move_to_spectator_area")
	_broadcast_round_update()
	_broadcast_roster()
	_set_timeout(preparation_time, func(): _enter_round())

func _enter_round() -> void:
	_state = RoundState.IN_ROUND
	print("[ROUND] → IN_ROUND (", round_time, "s)")
	_state_ends_at_unix = _now() + round_time
	print("[ROUND] ends_at_unix:", _state_ends_at_unix)
	_broadcast_round_update()
	_broadcast_roster()
	_set_timeout(round_time, func(): _enter_intermission(true))

func _on_peer_connected(id: int) -> void:
	_players_in_match += 1
	var player := Player.instantiate()
	player.name = str(id)
	player.set_multiplayer_authority(id, true)
	print("[NET] set authority for player ", id)
	get_node("World").add_child(player)
	# New connections start as spectators and are moved out of the arena
	player.rpc_id(id, "rpc_set_participation", false)
	player.rpc_id(id, "rpc_move_to_spectator_area")
	_ready_flags[id] = false
	_participants.erase(id)
	print("[NET] + peer ", id, " (players=", _players_in_match, ")")
	print("[ROSTER] after connect -> ready_flags:", _ready_flags)
	_send_round_update_to(id)
	_broadcast_roster()

func _on_peer_disconnected(id: int) -> void:
	var world := get_node_or_null("World")
	if world:
		var p := world.get_node_or_null(str(id))
		if p:
			p.queue_free()
	_ready_flags.erase(id)
	_participants.erase(id)
	print("[ROSTER] after disconnect -> ready_flags:", _ready_flags, " participants:", _participants)
	_players_in_match = max(0, _players_in_match - 1)
	print("[NET] - peer ", id, " (players=", _players_in_match, ")")
	_broadcast_roster()
	if _players_in_match == 0:
		_bump_token() # cancel any timers
		call_deferred("_enter_intermission", false)

func _reset_players_to_spawn() -> void:
	var world := get_node("World")
	print("[ROUND] resetting to spawn participants:")
	for c in world.get_children():
		var pid := int(c.name)
		if _participants.has(pid):
			print("  - pid", pid)
			c.rpc_id(pid, "rpc_reset_to_spawn")

func _send_round_update_to(peer_id: int) -> void:
	var peers := multiplayer.get_peers()
	if not peers.has(peer_id):
		return
	var world := get_node("World")
	var player := world.get_node_or_null(str(peer_id))
	if player != null:
		print("[ROUND] send state ", _state, " to peer ", peer_id, " ends_at ", _state_ends_at_unix)
		player.rpc_id(peer_id, "rpc_round_update", _state, _state_ends_at_unix)

func _broadcast_round_update() -> void:
	var peers := multiplayer.get_peers()
	var world := get_node("World")
	print("[ROUND] broadcast state:", _state, " ends_at:", _state_ends_at_unix)
	for c in world.get_children():
		var pid := int(c.name)
		if peers.has(pid):
			_send_round_update_to(pid)

# --- Roster helpers ---

func _current_roster_triplet() -> Array:
	var participants: Array = []
	var ready: Array = []
	var inactive: Array = []
	var peers := _connected_peers()
	for id in peers:
		if _participants.has(id):
			participants.append(id)
		elif bool(_ready_flags.get(id, false)):
			ready.append(id)
		else:
			inactive.append(id)
	return [participants, ready, inactive]

func _send_roster_update_to(peer_id: int) -> void:
	var peers := multiplayer.get_peers()
	if not peers.has(peer_id):
		return
	var world := get_node("World")
	var player := world.get_node_or_null(str(peer_id))
	if player != null:
		var r := _current_roster_triplet()
		print("[ROSTER] send to ", peer_id, " | parts:", r[0].size(), " ready:", r[1].size(), " inactive:", r[2].size())
		if not player.has_method("rpc_roster_update"):
			print("[ROSTER][WARN] Player ", peer_id, " missing rpc_roster_update on server-side script. Re-export headless with updated scripts?")
			return
		player.rpc_id(peer_id, "rpc_roster_update", r[0], r[1], r[2])

func _broadcast_roster() -> void:
	var peers := multiplayer.get_peers()
	var world := get_node("World")
	var r := _current_roster_triplet()
	print("[ROSTER] broadcast | parts:", r[0].size(), " ready:", r[1].size(), " inactive:", r[2].size())
	for c in world.get_children():
		var pid := int(c.name)
		if peers.has(pid):
			var player := c
			if not player.has_method("rpc_roster_update"):
				print("[ROSTER][WARN] Player ", pid, " missing rpc_roster_update on server-side script. Re-export headless with updated scripts?")
				continue
			player.rpc_id(pid, "rpc_roster_update", r[0], r[1], r[2])

func _on_player_ready_changed(peer_id: int, ready: bool) -> void:
	_ready_flags[peer_id] = ready
	print("[ROSTER] ready update -> ", peer_id, " = ", ready)
	# During PREPARATION, reflect the player's wish immediately in participation
	if _state == RoundState.PREPARATION:
		if ready:
			_participants[peer_id] = true
			var p := get_node("World").get_node_or_null(str(peer_id))
			if p:
				p.rpc_id(peer_id, "rpc_set_participation", true)
		else:
			_participants.erase(peer_id)
			var p := get_node("World").get_node_or_null(str(peer_id))
			if p:
				p.rpc_id(peer_id, "rpc_set_participation", false)
				p.rpc_id(peer_id, "rpc_move_to_spectator_area")

	# If idling in intermission (no timer set) and someone readies up, begin preparation immediately.
	if _state == RoundState.INTERMISSION and _state_ends_at_unix == 0.0 and _ready_count() > 0:
		print("[ROUND] idle→preparation (first ready spectator detected)")
		_enter_preparation()
	_broadcast_roster()
