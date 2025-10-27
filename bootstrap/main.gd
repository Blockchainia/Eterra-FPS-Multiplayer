extends Node

# Force-include these scenes so the exporter packs them even when loaded dynamically
const _keep_server := preload("res://server/headless_server.tscn")
const _keep_client := preload("res://world.tscn")

# Path to your scenes
const CLIENT_SCENE := "res://world.tscn"
const SERVER_SCENE := "res://server/headless_server.tscn"

func _ready() -> void:
	print("[BOOT] Starting Eterra build...")
	# Defer scene switch to avoid tree modification during _ready()
	call_deferred("_boot")

func _boot() -> void:
	# Detect headless or dedicated server mode
	if OS.has_feature("headless") or OS.has_feature("dedicated_server"):
		print("[BOOT] Headless mode detected — loading server scene")
		_change_scene(SERVER_SCENE)
	else:
		print("[BOOT] Client mode detected — loading world scene")
		_change_scene(CLIENT_SCENE)

func _change_scene(path: String) -> void:
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("[BOOT] Failed to load scene: %s (error %s)" % [path, err])
