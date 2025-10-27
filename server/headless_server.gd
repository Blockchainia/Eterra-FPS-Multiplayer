extends Node

const PORT := 9999
const MAX_CLIENTS := 32
const Player = preload("res://player.tscn")

func _ready() -> void:
	# Ensure a consistent parent named "World" for all player nodes
	var world := get_node_or_null("World")
	if world == null:
		world = Node.new()
		world.name = "World"
		add_child(world)
	# Align multiplayer RPC/root to the World node so client/server node paths match
	multiplayer.root_path = world.get_path()

	var net: Node = get_node("/root/Network")
	net.server_started.connect(func(p): print("[DEDICATED] Server started on port: ", p))
	net.peer_connected.connect(_on_peer_connected)
	net.peer_disconnected.connect(_on_peer_disconnected)

	var err: int = net.start_dedicated(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("[DEDICATED] Failed to start: %s" % err)

func _on_peer_connected(id: int) -> void:
	var player := Player.instantiate()
	player.name = str(id)
	get_node("World").add_child(player)

func _on_peer_disconnected(id: int) -> void:
	var world := get_node_or_null("World")
	if world:
		var p := world.get_node_or_null(str(id))
		if p:
			p.queue_free()
