extends Node3D

# Headless regression test for the V0.4 character asset pipeline:
# CharacterRegistry, AnimationController (both the real-model path and the
# placeholder fallback), and that none of it affects FootballPlayer
# gameplay. Run via:
#   godot --headless --path . tests/CharacterPipelineTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	# --- CharacterRegistry ---
	var known_scene: PackedScene = CharacterRegistry.get_scene("tokai_teio")
	_check("CharacterRegistry resolves a known visual_id to a scene", known_scene != null)
	_check("CharacterRegistry returns null for an unknown visual_id", CharacterRegistry.get_scene("nonexistent_character") == null)
	_check("CharacterRegistry returns null for an empty visual_id", CharacterRegistry.get_scene("") == null)

	# --- AnimationController: placeholder fallback path ---
	var placeholder_ac := AnimationController.new()
	add_child(placeholder_ac)
	placeholder_ac.set_visual("")
	await get_tree().process_frame

	_check("Placeholder visual supports team tint", placeholder_ac.supports_team_tint())
	placeholder_ac.set_team_color(Color(1, 0, 0))
	_check("Placeholder set_team_color does not crash and a visual exists", placeholder_ac.get_child_count() > 0)

	for state in ["idle", "walk", "run", "sprint", "dribble"]:
		placeholder_ac.set_state(state)
	_check("All locomotion states can be set on placeholder without error", true)

	for action in ["pass", "shoot", "celebration", "tackle"]:
		placeholder_ac.play_action(action)
		await get_tree().process_frame
	_check("All action triggers can be played on placeholder without error", true)

	# Procedural fallback should actually move the visual during a pulse.
	placeholder_ac.play_action("celebration")
	var visual := placeholder_ac.get_child(0)
	var rot_samples: Array[float] = []
	for i in range(10):
		await get_tree().process_frame
		rot_samples.append(visual.rotation.y)
	var rotation_changed := false
	for i in range(1, rot_samples.size()):
		if not is_equal_approx(rot_samples[i], rot_samples[0]):
			rotation_changed = true
	_check("Procedural celebration pulse actually animates the placeholder visual", rotation_changed)

	# --- AnimationController: real model path ---
	var real_ac := AnimationController.new()
	add_child(real_ac)
	real_ac.set_visual("tokai_teio")
	await get_tree().process_frame

	_check("Real model does not support team tint (keeps authored textures)", not real_ac.supports_team_tint())
	_check("Real model measured a sane bind-pose height", real_ac.last_measured_height > 0.01 and real_ac.last_measured_height < 10.0)

	var real_visual: Node3D = real_ac.get_child(0)
	var expected_scale: float = 1.6 / real_ac.last_measured_height
	_check("Real model auto-fit scale matches target_height / measured_height", is_equal_approx(real_visual.scale.x, expected_scale))

	var skeleton := _find_skeleton(real_visual)
	_check("Real model has a Skeleton3D (skinned mesh imported correctly)", skeleton != null)
	_check("Real model skeleton has bones", skeleton != null and skeleton.get_bone_count() > 0)

	for state in ["idle", "walk", "run", "sprint", "dribble"]:
		real_ac.set_state(state)
	for action in ["pass", "shoot", "celebration", "tackle"]:
		real_ac.play_action(action)
		await get_tree().process_frame
	_check("Real model handles all states/actions without error (procedural fallback, since it has 0 clips)", true)

	# --- FootballPlayer integration: gameplay must not care which visual is attached ---
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	ball.position = Vector3(0, 1, 0)
	add_child(ball)

	var data := PlayerData.new()
	data.id = "test_visual_player"
	data.display_name = "Test"
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60
	data.visual_id = "tokai_teio"

	var player: FootballPlayer = PlayerScene.instantiate()
	player.position = Vector3(0, 1, -3)
	add_child(player)
	player.apply_player_data(data)

	var controller := PlayerController.new()
	add_child(controller)
	controller.set_controlled_player(player)

	_check("FootballPlayer's animation_controller picked up the real model", not player.animation_controller.supports_team_tint())

	InputState.move_vector = Vector2(0, 1)
	var approached := false
	for i in range(180):
		await get_tree().physics_frame
		if player.global_position.distance_to(ball.global_position) < 2.5:
			approached = true
			break
	_check("Player with a real-model visual still moves/approaches normally", approached)

	for i in range(30):
		await get_tree().physics_frame
	_check("Player with a real-model visual still gains possession/dribbles normally", player.has_possession)

	var pre_pass_speed: float = ball.linear_velocity.length()
	InputState.pass_pressed = true
	for i in range(3):
		await get_tree().physics_frame
	_check("Player with a real-model visual can still pass normally", ball.linear_velocity.length() > pre_pass_speed + 1.0)
	InputState.move_vector = Vector2.ZERO

	# --- Full match spawn: exactly one player uses the real model, others fall back ---
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(5):
		await get_tree().physics_frame

	var real_model_count := 0
	var placeholder_count := 0
	for p in main.home_players + main.away_players:
		if p.animation_controller.supports_team_tint():
			placeholder_count += 1
		else:
			real_model_count += 1
	_check("Exactly one spawned player in the full match uses the real model", real_model_count == 1)
	_check("The other seven spawned players fall back to the placeholder", placeholder_count == 7)
	_check("The real-model player is the intended default-controlled MID (home_players[2])", not main.home_players[2].animation_controller.supports_team_tint())

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
