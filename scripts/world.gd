extends Node

@onready var main_menu: PanelContainer = $Menu/MainMenu
@onready var options_menu: PanelContainer = $Menu/Options
@onready var pause_menu: PanelContainer = $Menu/PauseMenu
@onready var address_entry: LineEdit = %AddressEntry
@onready var menu_music: AudioStreamPlayer = %MenuMusic

const Player = preload("res://player.tscn")
const PORT := 9999
var paused: bool = false
var options: bool = false

var controller: bool = false

# --- Player menu / roster ---
var _participants: Array = []
var _ready_specs: Array = []
var _inactive_specs: Array = []
var _menu_visible: bool = false
var _menu_layer: CanvasLayer
var _player_menu: Panel
var _list_participants: ItemList
var _list_ready: ItemList
var _list_inactive: ItemList
var _btn_ready: Button
var _has_shown_menu_once: bool = false

# --- Round HUD state ---
const STATE_NAMES := {0: "Intermission", 1: "Preparation", 2: "In Round"}
var _round_state: int = 0
var _round_ends_at: float = 0.0
var _round_label: Label

func _ready() -> void:
	# Hook into Network singleton events so the world adds/removes players consistently
	Network.server_started.connect(func(_p): print("[CLIENT] Host started"))
	Network.peer_connected.connect(add_player)
	Network.peer_disconnected.connect(remove_player)
	Network.connection_failed.connect(func(): push_error("[CLIENT] Connection failed"))
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func(): push_error("[CLIENT] Connection failed (low-level)"))
	# Align RPC root with the node that owns players on the client
	multiplayer.root_path = get_path()
	# HUD label setup
	_round_label = _ensure_round_label()
	_update_round_label()

	_wire_player_menu_nodes()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		var u := (event as InputEventKey).unicode
		# Toggle on backquote (` = 96) or tilde (~ = 126) without relying on platform key constants
		if u == 96 or u == 126:
			_set_player_menu_visible(!_menu_visible)
			get_viewport().set_input_as_handled()
			return
	if Input.is_action_pressed("pause") and !main_menu.visible and !options_menu.visible:
		paused = !paused
	if event is InputEventJoypadMotion:
		controller = true
	elif event is InputEventMouseMotion:
		controller = false

func _process(_delta: float) -> void:
	if paused:
		$Menu/Blur.show()
		pause_menu.show()
		if !controller:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_round_label()

func _on_connected_to_server() -> void:
	# We just successfully connected to a (likely headless) server.
	# Spawn our local player so camera/current gets set by player.gd (_ready).
	add_player(multiplayer.get_unique_id())
	_set_player_menu_visible(true)
	_has_shown_menu_once = true
	# Match host behavior: capture mouse when entering gameplay from Join.
	if !controller:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func apply_roster_update(participants: Array, ready: Array, inactive: Array) -> void:
	if _list_participants == null or _list_ready == null or _list_inactive == null or _btn_ready == null:
		print("[HUD] attempting auto-wire of player menu nodes...")
		_wire_player_menu_nodes()
	print("[ROSTER][CLIENT] update parts=", participants.size(), " ready=", ready.size(), " inactive=", inactive.size())
	_participants = participants
	_ready_specs = ready
	_inactive_specs = inactive
	_refresh_player_menu()
	# Only auto-show the first time (initial connect). Afterwards, respect user toggle.
	if not _has_shown_menu_once and _menu_layer and not _menu_layer.visible:
		_set_player_menu_visible(true)
		_has_shown_menu_once = true

func _refresh_player_menu() -> void:
	if _list_participants == null or _list_ready == null or _list_inactive == null:
		print("[HUD] player menu lists not wired (participants=", _list_participants, ", ready=", _list_ready, ", inactive=", _list_inactive, ")")
		return
	_list_participants.clear()
	_list_ready.clear()
	_list_inactive.clear()
	for id in _participants:
		_list_participants.add_item(str(id))
	for id in _ready_specs:
		_list_ready.add_item(str(id))
	for id in _inactive_specs:
		_list_inactive.add_item(str(id))
	# Make sure lists/panel are visible and redraw
	if _player_menu:
		_player_menu.visible = true
	if _list_participants:
		_list_participants.visible = true
		_list_participants.queue_redraw()
	if _list_ready:
		_list_ready.visible = true
		_list_ready.queue_redraw()
	if _list_inactive:
		_list_inactive.visible = true
		_list_inactive.queue_redraw()
	print("[HUD] list counts -> parts=", (_list_participants and _list_participants.get_item_count()) if _list_participants else -1,
		" ready=", (_list_ready and _list_ready.get_item_count()) if _list_ready else -1,
		" inactive=", (_list_inactive and _list_inactive.get_item_count()) if _list_inactive else -1)

	# Update Ready button label based on our status
	if _btn_ready:
		var me: int = multiplayer.get_unique_id()
		var is_ready: bool = _ready_specs.has(me)
		var is_participant: bool = _participants.has(me)
		_btn_ready.text = ("Sit Out Next Game" if (is_ready or is_participant) else "Join Next Game")

func _on_ready_button_pressed() -> void:
	var me: int = multiplayer.get_unique_id()
	var is_ready: bool = _ready_specs.has(me)
	var is_participant: bool = _participants.has(me)
	# If we are ready or currently a participant, clicking should mark us to SIT OUT next game (ready=false).
	# Otherwise, we JOIN next game (ready=true).
	var want_ready: bool = not (is_ready or is_participant)
	print("[READY][CLIENT] click from ", me, " -> want_ready=", want_ready, " (is_ready=", is_ready, ", is_participant=", is_participant, ")")
	var player := get_node_or_null(str(me))
	if player == null:
		print("[READY][CLIENT] local player node not found at path:", String(get_path()) + "/" + str(me))
		return
	# Send RPC to server peer (1)
	player.rpc_id(1, "rpc_set_ready", want_ready)

func _set_player_menu_visible(v: bool) -> void:
	print("[HUD] menu visible -> ", v)
	_menu_visible = v
	if _menu_layer:
		_menu_layer.visible = v
	# Mouse handling
	if v:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		if !paused and !options:
			if !controller:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_resume_pressed() -> void:
	if !options:
		$Menu/Blur.hide()
	$Menu/PauseMenu.hide()
	if !controller:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	paused = false
	
func _on_options_pressed() -> void:
	_on_resume_pressed()
	$Menu/Options.show()
	$Menu/Blur.show()
	%Fullscreen.grab_focus()
	if !controller:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	options = true


func _on_back_pressed() -> void:
	if options:
		$Menu/Blur.hide()
		if !controller:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		options = false


# Gracefully handle quit (menu button)
func _on_quit_pressed() -> void:
	# Gracefully disconnect the client before quitting the game
	Network.stop()
	get_tree().quit()


# Catch window close button
func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Gracefully disconnect if the window is closed directly
		Network.stop()
		get_tree().quit()

func _on_host_button_pressed() -> void:
	main_menu.hide()
	$Menu/DollyCamera.hide()
	$Menu/Blur.hide()
	menu_music.stop()

	var err := Network.start_host(PORT, 32)
	if err != OK:
		push_error("Failed to host: %s" % err)
		return

	# Ensure local player exists (self doesn't emit peer_connected for host)
	add_player(multiplayer.get_unique_id())
	_set_player_menu_visible(true)
	_has_shown_menu_once = true

	if options_menu.visible:
		options_menu.hide()

	upnp_setup()

func _on_join_button_pressed() -> void:
	main_menu.hide()
	$Menu/Blur.hide()
	menu_music.stop()

	var addr := address_entry.text.strip_edges()
	if addr.is_empty():
		addr = "127.0.0.1"
	var err := Network.start_client(addr, PORT)
	if err != OK:
		push_error("Failed to connect: %s" % err)
		return

	if options_menu.visible:
		options_menu.hide()

func _on_options_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		options_menu.show()
	else:
		options_menu.hide()
		
func _on_music_toggle_toggled(toggled_on: bool) -> void:
	if !toggled_on:
		menu_music.stop()
	else:
		menu_music.play()

func add_player(peer_id: int) -> void:
	# Do not create a local player for the dedicated server peer (1) when we are a client.
	# On a listen host, multiplayer.is_server() is true, so we still spawn the local player with id 1 explicitly.
	if peer_id == 1 and not multiplayer.is_server():
		return

	var player: Node = Player.instantiate()
	player.name = str(peer_id)
	add_child(player)

func remove_player(peer_id: int) -> void:
	var player: Node = get_node_or_null(str(peer_id))
	if player:
		player.queue_free()

func upnp_setup() -> void:
	var upnp: UPNP = UPNP.new()

	upnp.discover()
	upnp.add_port_mapping(PORT)

	var ip: String = upnp.query_external_address()
	if ip == "":
		print("Failed to establish upnp connection!")
	else:
		print("Success! Join Address: %s" % upnp.query_external_address())

func apply_round_update(state: int, ends_at_unix: float) -> void:
	_round_state = state
	_round_ends_at = ends_at_unix
	_update_round_label()

func _ensure_round_label() -> Label:
	var lbl: Label = get_node_or_null("HUD/RoundLabel") as Label
	if lbl == null:
		var hud: CanvasLayer = get_node_or_null("HUD") as CanvasLayer
		if hud == null:
			hud = CanvasLayer.new()
			hud.name = "HUD"
			add_child(hud)
		lbl = Label.new()
		lbl.name = "RoundLabel"
		hud.add_child(lbl)
		lbl.position = Vector2(16, 16)
		lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	return lbl

func _update_round_label() -> void:
	if _round_label == null:
		return
	var name: String = (STATE_NAMES.get(_round_state, "Unknown") as String)
	var remain: int = 0
	if _round_ends_at > 0.0:
		var now: float = Time.get_unix_time_from_system()
		remain = int(max(0.0, _round_ends_at - now))
	var mm: int = remain / 60
	var ss: int = remain % 60
	_round_label.text = "%s — %02d:%02d" % [name, mm, ss]
	_round_label.visible = true


func get_round_state() -> int:
	return _round_state

func _wire_player_menu_nodes() -> void:
	# Try strict paths first
	_menu_layer = get_node_or_null("HUD_PlayerMenu") as CanvasLayer
	_player_menu = get_node_or_null("HUD_PlayerMenu/PlayerMenu") as Panel
	_list_participants = get_node_or_null("HUD_PlayerMenu/PlayerMenu/VBox/H/ColParticipants/Participants") as ItemList
	_list_ready = get_node_or_null("HUD_PlayerMenu/PlayerMenu/VBox/H/ColReady/Ready") as ItemList
	_list_inactive = get_node_or_null("HUD_PlayerMenu/PlayerMenu/VBox/H/ColInactive/Inactive") as ItemList
	_btn_ready = get_node_or_null("HUD_PlayerMenu/PlayerMenu/VBox/ReadyButton") as Button
	# Try find_child as fallback
	if _player_menu != null:
		if _list_participants == null:
			_list_participants = _player_menu.find_child("Participants", true, false)
		if _list_ready == null:
			_list_ready = _player_menu.find_child("Ready", true, false)
		if _list_inactive == null:
			_list_inactive = _player_menu.find_child("Inactive", true, false)
		if _btn_ready == null:
			_btn_ready = _player_menu.find_child("ReadyButton", true, false)
	# Fallback: if any list is still null, try to assign by scanning all ItemList nodes under the panel
	if _player_menu != null and (_list_participants == null or _list_ready == null or _list_inactive == null):
		var found_lists: Array = []
		for n in _player_menu.get_children():
			# recursive scan for ItemLists
			if n is ItemList:
				found_lists.append(n)
			elif n is Control:
				for m in n.find_children("", "ItemList", true, false):
					found_lists.append(m)
		# Try to identify lists by name keywords
		for il in found_lists:
			var nm := String(il.name).to_lower()
			if _list_participants == null and (nm.find("part") >= 0 or nm.find("player") >= 0):
				_list_participants = il
			elif _list_ready == null and nm.find("ready") >= 0:
				_list_ready = il
			elif _list_inactive == null and (nm.find("inactive") >= 0 or nm.find("spect") >= 0):
				_list_inactive = il
		# If still missing, assign by position order
		if _list_participants == null and found_lists.size() > 0:
			_list_participants = found_lists[0]
		if _list_ready == null and found_lists.size() > 1:
			_list_ready = found_lists[1]
		if _list_inactive == null and found_lists.size() > 2:
			_list_inactive = found_lists[2]
		print("[HUD] fallback mapped lists -> participants:", _list_participants, " ready:", _list_ready, " inactive:", _list_inactive)
	# Fallback: find any Button that looks like a Ready toggle
	if _btn_ready == null and _player_menu != null:
		for b in _player_menu.find_children("", "Button", true, false):
			var nm := String(b.name).to_lower()
			if nm.find("ready") >= 0 or nm.find("join") >= 0:
				_btn_ready = b
				break
		if _btn_ready:
			var already := false
			for c in _btn_ready.pressed.get_connections():
				if c["target"] == self and String(c["method"]) == StringName("_on_ready_button_pressed"):
					already = true
					break
			if not already:
				_btn_ready.pressed.connect(_on_ready_button_pressed)
	# Ensure the Ready button is connected even when found via strict path
	if _btn_ready:
		var connected := false
		for c in _btn_ready.pressed.get_connections():
			if c["target"] == self and String(c["method"]) == StringName("_on_ready_button_pressed"):
				connected = true
				break
		if not connected:
			_btn_ready.pressed.connect(_on_ready_button_pressed)
	if _player_menu:
		print("[HUD] player menu path=", _player_menu.get_path())
	if _list_participants:
		print("[HUD] participants list path=", _list_participants.get_path())
	if _list_ready:
		print("[HUD] ready list path=", _list_ready.get_path())
	if _list_inactive:
		print("[HUD] inactive list path=", _list_inactive.get_path())
	if _btn_ready:
		print("[HUD] ready button path=", _btn_ready.get_path())
	print("[HUD] wired menu nodes: layer=", _menu_layer != null, ", panel=", _player_menu != null, ", lists=", _list_participants != null and _list_ready != null and _list_inactive != null, ", button=", _btn_ready != null)
