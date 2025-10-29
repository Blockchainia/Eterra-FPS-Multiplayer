extends Node

signal server_started(port)
signal server_stopped()
signal client_connected()
signal client_disconnected()
signal peer_connected(id)
signal peer_disconnected(id)
signal connection_failed()

var peer: ENetMultiplayerPeer
var is_dedicated := false
const DEFAULT_PORT := 9999
const DEFAULT_ADDRESS := "127.0.0.1"
const DEFAULT_MAX_CLIENTS := 32

func _ready() -> void:
	multiplayer.peer_connected.connect(func(id): emit_signal("peer_connected", id))
	multiplayer.peer_disconnected.connect(func(id): emit_signal("peer_disconnected", id))
	multiplayer.connection_failed.connect(func(): emit_signal("connection_failed"))

func start_host(port := DEFAULT_PORT, max_clients := DEFAULT_MAX_CLIENTS) -> int:
	is_dedicated = false
	return _start_server(port, max_clients)

func start_dedicated(port := DEFAULT_PORT, max_clients := DEFAULT_MAX_CLIENTS) -> int:
	is_dedicated = true
	return _start_server(port, max_clients)

func start_client(address := DEFAULT_ADDRESS, port := DEFAULT_PORT) -> int:
	is_dedicated = false
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		emit_signal("connection_failed")
		return err
	multiplayer.multiplayer_peer = peer
	emit_signal("client_connected")
	return OK

func stop() -> void:
	if multiplayer.multiplayer_peer != null:
		var p = multiplayer.multiplayer_peer
		if p is ENetMultiplayerPeer:
			(p as ENetMultiplayerPeer).close()
		multiplayer.multiplayer_peer = null

func _start_server(port: int, max_clients: int) -> int:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	emit_signal("server_started", port)
	return OK
