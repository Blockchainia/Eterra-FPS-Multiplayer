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

func _unhandled_input(event: InputEvent) -> void:
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
	# Match host behavior: capture mouse when entering gameplay from Join.
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
