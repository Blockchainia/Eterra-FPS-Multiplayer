extends CharacterBody3D

@onready var camera: Camera3D = $Camera3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var muzzle_flash: GPUParticles3D = $Camera3D/pistol/GPUParticles3D
@onready var raycast: RayCast3D = $Camera3D/RayCast3D
@onready var gunshot_sound: AudioStreamPlayer3D = %GunshotSound

## Number of shots before a player dies
var health: int = 2
## The xyz position of the random spawns, you can add as many as you want!
@export var spawns: PackedVector3Array = PackedVector3Array([
	Vector3(-18, 0.2, 0),
	Vector3(18, 0.2, 0),
	Vector3(-2.8, 0.2, -6),
	Vector3(-17,0,17),
	Vector3(17,0,17),
	Vector3(17,0,-17),
	Vector3(-17,0,-17)
])
var sensitivity : float =  .005
var controller_sensitivity : float =  .010

var axis_vector : Vector2
var	mouse_captured : bool = true

const SPEED = 5.5
const JUMP_VELOCITY = 4.5
var _is_participant: bool = false
var _spawn_transform: Transform3D
var _last_fire_server: float = 0.0

func _can_translate() -> bool:
	var world := get_tree().get_root().get_node_or_null("World")
	if world and world.has_method("get_round_state"):
		return _is_participant and world.get_round_state() != 1
	return _is_participant

func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())
	print("[PLAYER] _enter_tree name=", name, " auth=", get_multiplayer_authority(), " is_auth=", is_multiplayer_authority())

func _ready() -> void:
	if not is_multiplayer_authority(): return

	# Do not auto-spawn into the arena unless the server marks us as a participant.
	_spawn_transform = global_transform
	if _is_participant:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		camera.current = true
		print("[PLAYER] _ready (participant) auth=", get_multiplayer_authority(), " pos=", global_transform.origin)
	else:
		camera.current = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		print("[PLAYER] _ready (spectator) auth=", get_multiplayer_authority(), " pos=", global_transform.origin)

func _process(_delta: float) -> void:
	sensitivity = Global.sensitivity
	controller_sensitivity = Global.controller_sensitivity

	rotate_y(-axis_vector.x * controller_sensitivity)
	camera.rotate_x(-axis_vector.y * controller_sensitivity)
	camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return

	axis_vector = Input.get_vector("look_left", "look_right", "look_up", "look_down")

	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * sensitivity)
		camera.rotate_x(-event.relative.y * sensitivity)
	camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)

	if Input.is_action_just_pressed("shoot") and anim_player.current_animation != "shoot":
		# Local feedback
		play_shoot_effects.rpc()
		gunshot_sound.play()
		# Report fire to server for authoritative validation
		var origin := camera.global_transform.origin
		var dir := -camera.global_transform.basis.z
		var ts := Time.get_unix_time_from_system()
		rpc_id(1, "rpc_report_fire", origin, dir, ts)

	if Input.is_action_just_pressed("respawn"):
		recieve_damage(2)

	if Input.is_action_just_pressed("capture"):
		if mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			mouse_captured = false
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true

@rpc("any_peer", "reliable")
func rpc_report_fire(origin: Vector3, dir: Vector3, ts: float) -> void:
	# --- Server authoritative hit validation ---
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()

	# Ensure this executes on the sender's own Player node on the server
	if sender != str(name).to_int():
		return

	# Rate limit (~12.5 shots/sec)
	var now := Time.get_unix_time_from_system()
	if now - _last_fire_server < 0.08:
		return
	_last_fire_server = now

	# Only participants can shoot
	var hs := get_tree().get_root().get_node_or_null("HeadlessServer")
	if hs and hs.has_method("is_participant"):
		if not hs.is_participant(sender):
			return

	# Robust server raycast
	var space := get_world_3d().direct_space_state
	var to := origin + dir.normalized() * 100.0
	var query := PhysicsRayQueryParameters3D.create(origin, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	# Exclude the shooter (and its shapes) to avoid self-hits
	var excludes: Array = [self, self.get_rid()]
	for n in get_children():
		if n is CollisionObject3D:
			excludes.append((n as CollisionObject3D).get_rid())
	query.exclude = excludes
	# Optional if you customized layers: query.collision_mask = 0xFFFFFFFF

	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return

	# Climb to a node that actually owns recieve_damage (collider may be a child)
	var node := hit.get("collider") as Node
	var climb := 0
	while node != null and not node.has_method("recieve_damage") and climb < 6:
		node = node.get_parent()
		climb += 1

	if node != null and node.has_method("recieve_damage"):
		# Apply damage LOCALLY on the server (this function will replicate HP/respawn)
		node.call("recieve_damage", 1)

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null:
		if not is_multiplayer_authority(): return

	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	if not _can_translate():
		# Allow gravity & look, but stop horizontal translation and jumping
		velocity.x = 0.0
		velocity.z = 0.0
		# Optional: block jump if you have JUMP logic nearby
		# if Input.is_action_just_pressed("jump"): pass  # ignore
		# Then still do gravity and move_and_slide() if your controller expects it:
		# velocity.y += gravity * delta  (if you use gravity)
		# move_and_slide()
		return

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector("left", "right", "up", "down")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y))
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	if anim_player.current_animation == "shoot":
		pass
	elif input_dir != Vector2.ZERO and is_on_floor() :
		anim_player.play("move")
	else:
		anim_player.play("idle")

	move_and_slide()

@rpc("call_local")
func play_shoot_effects() -> void:
	anim_player.stop()
	anim_player.play("shoot")
	muzzle_flash.restart()
	muzzle_flash.emitting = true

@rpc("any_peer", "reliable")
func set_health(new_health: int) -> void:
	# Only accept from server (peer 1) or when running on the server itself
	if multiplayer.get_remote_sender_id() != 1 and not multiplayer.is_server():
		return
	health = new_health
	print("[HP] set by server -> ", health)

@rpc("any_peer")
func recieve_damage(damage:= 1) -> void:
	# Server-only: validate and apply damage, then replicate health
	if not multiplayer.is_server():
		return
	var owner_id := str(name).to_int()
	health = max(health - damage, 0)
	print("[DMG][SERVER] player=", name, " -> HP=", health)
	# Sync new HP to owning client
	rpc_id(owner_id, "set_health", health)
	# If eliminated, hand off to HeadlessServer to respawn (server-authoritative)
	if health <= 0:
		var server := get_tree().get_root().get_node_or_null("HeadlessServer")
		if server and server.has_method("_on_player_eliminated"):
			server._on_player_eliminated(owner_id)
		return

@rpc("any_peer", "reliable")
func rpc_clear_velocity() -> void:
	# Only accept from server
	if multiplayer.get_remote_sender_id() != 1 and not multiplayer.is_server():
		return
	# CharacterBody3D always has a velocity property
	velocity = Vector3.ZERO

@rpc("any_peer", "reliable")
func rpc_do_respawn() -> void:
	# Only accept from server
	if multiplayer.get_remote_sender_id() != 1 and not multiplayer.is_server():
		return
	if not is_multiplayer_authority():
		return
	# Cosmetic-only client hook (e.g., screen flash, sound). Server already moved us & set HP.
	velocity = Vector3.ZERO
	print("[RESPAWN][CLIENT] cosmetic respawn fx")

@rpc("any_peer", "reliable")
func rpc_place_at(spawn: Vector3) -> void:
	# Only accept from server
	if multiplayer.get_remote_sender_id() != 1 and not multiplayer.is_server():
		return
	if not is_multiplayer_authority():
		return
	var t := global_transform
	t.origin = spawn
	global_transform = t
	velocity = Vector3.ZERO
	_spawn_transform = global_transform
	print("[RESPAWN][CLIENT] placed at ", spawn)

@rpc("any_peer")
func rpc_set_participation(is_participant: bool) -> void:
	if multiplayer.get_remote_sender_id() != 1 and not multiplayer.is_server():
		return
	# Server authoritative: flip between participant and spectator state.
	_is_participant = is_participant
	if not is_multiplayer_authority():
		return
	if _is_participant:
		camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		print("[PLAYER] → PARTICIPANT auth=", get_multiplayer_authority(), " pos=", global_transform.origin)
	else:
		camera.current = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# Move safely out of the play space while spectating
		var t := global_transform
		t.origin = Vector3(0, -1000, 0)
		global_transform = t
		print("[PLAYER] → SPECTATOR auth=", get_multiplayer_authority())

@rpc("any_peer")
func rpc_move_to_spectator_area() -> void:
	if multiplayer.get_remote_sender_id() != 1 and not multiplayer.is_server():
		return
	# Optional extra nudge from server; keeps spectators out of bounds
	if not is_multiplayer_authority(): return
	var t := global_transform
	t.origin = Vector3(0, -1000, 0)
	global_transform = t

@rpc("any_peer")
func rpc_set_ready(ready: bool) -> void:
	# Client → Server: mark this peer as ready/unready for next game
	if multiplayer.is_server():
		var server := get_tree().get_root().get_node_or_null("HeadlessServer")
		var sender := multiplayer.get_remote_sender_id()
		print("[READY] rpc_set_ready sender=", sender, " -> ", ready)
		if server and server.has_method("_on_player_ready_changed"):
			server._on_player_ready_changed(sender, ready)
	else:
		print("[READY] rpc_set_ready ignored on client (value=", ready, ")")

@rpc("any_peer")
func rpc_roster_update(participants: Array, ready: Array, inactive: Array) -> void:
	# Server → Client: update Player Menu roster
	var world := get_tree().get_root().get_node_or_null("World")
	if world and world.has_method("apply_roster_update"):
		world.apply_roster_update(participants, ready, inactive)

@rpc("any_peer")
func rpc_round_update(state: int, ends_at_unix: float) -> void:
	print("[ROUND] recv state=", state, " ends_at=", ends_at_unix)
	var world := get_tree().get_root().get_node_or_null("World")
	if world and world.has_method("apply_round_update"):
		world.apply_round_update(state, ends_at_unix)

func _on_animation_player_animation_finished(anim_name: StringName) -> void:
	if anim_name == "shoot":
		anim_player.play("idle")
