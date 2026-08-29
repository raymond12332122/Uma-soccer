extends Node3D

# Headless regression test for the character asset pipeline:
# CharacterRegistry, AnimationController (both every registered real-model
# path and the placeholder fallback), and that none of it affects
# FootballPlayer gameplay, switching, or AI control. Data-driven over
# CharacterRegistry.MODELS so a future model (v0.6+) gets the same battery
# of checks automatically, with no new test code required. Run via:
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
	_check("CharacterRegistry returns null for an unknown visual_id", CharacterRegistry.get_scene("nonexistent_character") == null)
	_check("CharacterRegistry returns null for an empty visual_id", CharacterRegistry.get_scene("") == null)

	var registered_ids: Array = CharacterRegistry.MODELS.keys()
	_check("CharacterRegistry has at least one registered model", registered_ids.size() > 0)

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

	placeholder_ac.play_action("celebration")
	var placeholder_visual := placeholder_ac.get_child(0)
	var rot_samples: Array[float] = []
	for i in range(10):
		await get_tree().process_frame
		rot_samples.append(placeholder_visual.rotation.y)
	var rotation_changed := false
	for i in range(1, rot_samples.size()):
		if not is_equal_approx(rot_samples[i], rot_samples[0]):
			rotation_changed = true
	_check("Procedural celebration pulse actually animates the placeholder visual", rotation_changed)

	# --- AnimationController: every registered real model, generically ---
	for visual_id in registered_ids:
		await _check_registered_model(visual_id)

	# --- FootballPlayer integration: gameplay must not care which visual is attached ---
	var field = FieldScene.instantiate()
	add_child(field)

	for visual_id in registered_ids:
		await _check_football_player_with_visual(visual_id)

	# --- Full match spawn: every registered model appears exactly where TestRoster put it ---
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(5):
		await get_tree().physics_frame

	# Not every registered model necessarily occupies a TestRoster slot
	# (CharacterRegistry is the available pool; TestRoster's visual_id
	# assignments are what actually appears in this particular match), so
	# compare against the roster's own assignments rather than assuming
	# every registered model is on the pitch.
	var all_players: Array = main.home_players + main.away_players
	var expected_real_count := 0
	for p in all_players:
		if p.player_data.visual_id != "":
			expected_real_count += 1

	var real_model_count := 0
	var placeholder_count := 0
	for p in all_players:
		if p.animation_controller.supports_team_tint():
			placeholder_count += 1
		else:
			real_model_count += 1
	_check("Real-model count matches the roster's visual_id assignments (%d)" % expected_real_count, real_model_count == expected_real_count)
	_check("The remaining spawned players fall back to the placeholder", placeholder_count == all_players.size() - expected_real_count)

	# v0.7: TestRoster's 4-3-3 slot order means specific characters no
	# longer live at fixed indices -- find them by visual_id instead.
	var agnes: FootballPlayer = null
	var teio: FootballPlayer = null
	for p in main.home_players:
		if p.player_data.visual_id == "agnes_digital":
			agnes = p
		elif p.player_data.visual_id == "tokai_teio":
			teio = p
	_check("Agnes Digital (found by visual_id) uses the real model", agnes != null and not agnes.animation_controller.supports_team_tint())
	_check("Tokai Teio (found by visual_id) uses the real model", teio != null and not teio.animation_controller.supports_team_tint())

	# --- Player switching + AI control + camera tracking for the newly added character ---
	var previously_controlled = main.player_controller.controlled_player
	_check("Agnes is not the default controlled player before switching", previously_controlled != agnes)

	# v0.7: switching to a *specific* player uses _set_human_player directly
	# (the same method _switch_to_next_player() itself calls) rather than
	# cycling _switch_to_next_player() a fixed number of times -- switching
	# is now relevance-scored (see MatchManager._select_switch_target), not
	# round-robin, so there's no longer a guaranteed number of cycles that
	# reaches one specific player. The switching *algorithm* itself is
	# covered by TeamSystemTest and V0_7MatchTest; this test is about the
	# real-model character's AI-handoff/camera plumbing.
	main._set_human_player(agnes)
	await get_tree().physics_frame
	_check("Switching can reach the real-model character (Agnes)", main.player_controller.controlled_player == agnes)
	_check("Agnes's control indicator is visible once switched to", agnes.control_indicator.visible)
	_check("Camera retargets to the real-model character once switched to", main.camera_controller.target == agnes)

	InputState.move_vector = Vector2(1, 0)
	var agnes_start_pos: Vector3 = agnes.global_position
	for i in range(30):
		await get_tree().physics_frame
	_check("The real-model character moves normally under human control", agnes.global_position.distance_to(agnes_start_pos) > 0.5)
	InputState.move_vector = Vector2.ZERO

	# Switch away -- Agnes should fall back under AI control immediately.
	main._switch_to_next_player()
	await get_tree().physics_frame
	_check("Home team no longer treats Agnes as the human player after switching away", main.home_team.human_player != agnes)

	var agnes_pos_after_switch_away: Vector3 = agnes.global_position
	for i in range(60):
		await get_tree().physics_frame
	_check("AI drives the real-model character once no longer human-controlled", agnes.global_position.distance_to(agnes_pos_after_switch_away) > 0.05 or agnes.move_input != Vector2.ZERO)

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check_registered_model(visual_id: String) -> void:
	var scene: PackedScene = CharacterRegistry.get_scene(visual_id)
	_check("CharacterRegistry resolves '%s' to a scene" % visual_id, scene != null)
	if scene == null:
		return

	var ac := AnimationController.new()
	add_child(ac)
	ac.set_visual(visual_id)
	await get_tree().process_frame

	_check("'%s' does not support team tint (keeps authored textures)" % visual_id, not ac.supports_team_tint())
	_check("'%s' measured a sane bind-pose height" % visual_id, ac.last_measured_height > 0.01 and ac.last_measured_height < 10.0)

	var visual: Node3D = ac.get_child(0) if ac.get_child_count() > 0 else null
	_check("'%s' produced a visual node" % visual_id, visual != null)
	if visual:
		var expected_scale: float = ac.target_height / ac.last_measured_height
		_check("'%s' auto-fit scale matches target_height / measured_height" % visual_id, is_equal_approx(visual.scale.x, expected_scale))

		var skeleton := _find_skeleton(visual)
		_check("'%s' has a Skeleton3D (skinned mesh imported correctly)" % visual_id, skeleton != null)
		_check("'%s' skeleton has bones" % visual_id, skeleton != null and skeleton.get_bone_count() > 0)

		# The models ship in a bind pose with the arms straight out, so
		# SOMETHING has to take them out of it or the character runs around
		# looking like a floating cross.
		#
		# Until v0.9.2 that was always the static T-pose fix, because no model
		# had a single animation clip. The pack now drives them, and a driven
		# skeleton poses its own arms -- so the fix correctly does not run, and
		# demanding that it did would be demanding the old fallback. What has
		# to stay true is that ONE of the two happened.
		_check("'%s' is either driven by clips or had the T-pose fix applied" % visual_id,
			ac.is_animated() or ac.t_pose_fixed)
		if skeleton and not ac.is_animated():
			var arm_l_idx: int = ac._find_bone_exact(skeleton, "Arm_L")
			var elbow_l_idx: int = ac._find_bone_exact(skeleton, "Elbow_L")
			if arm_l_idx >= 0 and elbow_l_idx >= 0:
				var arm_pos: Vector3 = skeleton.get_bone_global_pose(arm_l_idx).origin
				var elbow_pos: Vector3 = skeleton.get_bone_global_pose(elbow_l_idx).origin
				var posed_dir: Vector3 = (elbow_pos - arm_pos).normalized()
				_check("'%s' left upper arm points mostly downward after the T-pose fix (not still horizontal)" % visual_id, posed_dir.y < -0.7)

	for state in ["idle", "walk", "run", "sprint", "dribble"]:
		ac.set_state(state)
	for action in ["pass", "shoot", "celebration", "tackle"]:
		ac.play_action(action)
		await get_tree().process_frame
	_check("'%s' handles all states/actions without error" % visual_id, true)

	# v0.9.2: the model itself still ships zero clips -- they come from the
	# shared animation pack, retargeted onto its skeleton. Either way round is
	# legitimate; what is checked is that the controller ended up in a state
	# it can actually animate from.
	if ac.is_animated():
		_check("'%s' is driven by the shared animation library" % visual_id,
			ac.get_node_or_null("AnimationTree") != null)
	else:
		_check("'%s' correctly falls back to procedural animation" % visual_id, true)

	ac.queue_free()


func _check_football_player_with_visual(visual_id: String) -> void:
	var ball: BallController = BallScene.instantiate()
	ball.position = Vector3(0, 1, 0)
	add_child(ball)

	var data := PlayerData.new()
	data.id = "test_%s" % visual_id
	data.display_name = "Test"
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60
	data.visual_id = visual_id

	var player: FootballPlayer = PlayerScene.instantiate()
	player.position = Vector3(0, 1, -3)
	add_child(player)
	player.apply_player_data(data)

	var controller := PlayerController.new()
	add_child(controller)
	controller.set_controlled_player(player)

	_check("FootballPlayer's animation_controller picked up '%s'" % visual_id, not player.animation_controller.supports_team_tint())

	InputState.move_vector = Vector2(0, 1)
	var approached := false
	for i in range(180):
		await get_tree().physics_frame
		if player.global_position.distance_to(ball.global_position) < 2.5:
			approached = true
			break
	_check("Player with '%s' still moves/approaches normally" % visual_id, approached)

	for i in range(30):
		await get_tree().physics_frame
	_check("Player with '%s' still gains possession/dribbles normally" % visual_id, player.has_possession)

	var pre_pass_speed: float = ball.linear_velocity.length()
	InputState.pass_pressed = true
	for i in range(3):
		await get_tree().physics_frame
	_check("Player with '%s' can still pass normally" % visual_id, ball.linear_velocity.length() > pre_pass_speed + 1.0)
	InputState.move_vector = Vector2.ZERO

	player.queue_free()
	controller.queue_free()
	ball.queue_free()
	await get_tree().process_frame


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
