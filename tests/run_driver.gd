extends Node3D

# Interactive session driver for agent/CI use -- launches the REAL game
# entry point (scenes/Main.tscn, exactly what F5 in the editor or the
# exported APK runs) and drives it through a representative human session
# via the same InputState autoload TouchControls/keyboard feed: approach
# the ball, sprint, switch player, pass, force a shot into goal, restart.
# Prints "DRIVER: ..." progress lines and saves PNG screenshots at a few
# points so a caller can visually confirm the app is actually rendering
# and responding, not just instantiating.
#
# This is NOT the test suite (see tests/*_test.gd for PASS/FAIL
# assertions) -- it's a driver for interactively exercising/screenshotting
# the running app. See .claude/skills/run-uma-soccer/SKILL.md for how to
# invoke it (headless functional-only, or windowed with real screenshots
# under Xvfb).
#
# Run via:
#   godot --path . tests/RunDriver.tscn                     (windowed, needs a display -- real screenshots)
#   godot --headless --path . tests/RunDriver.tscn           (functional only -- screenshots skipped, see _screenshot())

const MainScene := preload("res://scenes/Main.tscn")

var _shot_index: int = 0


func _ready() -> void:
	_drive()


func _drive() -> void:
	var main = MainScene.instantiate()
	add_child(main)

	for i in range(10):
		await get_tree().physics_frame

	print("DRIVER: spawned -- home=%d away=%d controlled=%s" % [
		main.home_players.size(), main.away_players.size(),
		main.player_controller.controlled_player.player_data.display_name
	])
	await _screenshot("01_kickoff")

	# Move the controlled player toward the ball, like the left joystick.
	var controlled = main.player_controller.controlled_player
	for i in range(120):
		var to_ball: Vector2 = Vector2(main.ball.global_position.x, main.ball.global_position.z) - Vector2(controlled.global_position.x, controlled.global_position.z)
		InputState.move_vector = to_ball.normalized() if to_ball.length() > 0.1 else Vector2.ZERO
		await get_tree().physics_frame
		if controlled.has_possession:
			break
	print("DRIVER: approached ball -- has_possession=%s pos=%s" % [controlled.has_possession, controlled.global_position])

	# Hold sprint for a bit -- confirms the stamina-drain mechanic runs live.
	var stamina_before: float = controlled.current_stamina
	InputState.sprint_held = true
	for i in range(30):
		await get_tree().physics_frame
	InputState.sprint_held = false
	print("DRIVER: sprinted -- stamina %.0f%% -> %.0f%%" % [stamina_before / controlled.max_stamina * 100.0, controlled.current_stamina / controlled.max_stamina * 100.0])

	# Pass (if we have the ball) -- PASS button equivalent.
	if controlled.has_possession:
		InputState.pass_pressed = true
		await get_tree().physics_frame
		print("DRIVER: pressed PASS")
	InputState.move_vector = Vector2.ZERO
	await _screenshot("02_midplay")

	# Switch to another player (SWITCH button equivalent). Needs 2 physics
	# frames, not 1: the first await resumes right as that tick begins, at
	# which point MatchManager._physics_process for the same tick hasn't
	# necessarily consumed InputState.switch_pressed yet -- see SKILL.md
	# Gotchas.
	var before_switch: String = main.player_controller.controlled_player.player_data.display_name
	InputState.switch_pressed = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	print("DRIVER: pressed SWITCH -- %s -> %s" % [before_switch, main.player_controller.controlled_player.player_data.display_name])
	await _screenshot("03_after_switch")

	# Force a goal via a direct ball placement (proves scoring + UI update
	# resolve correctly end-to-end). Clear the defending (away) team out of
	# the way first -- by this point in the session the away goalkeeper has
	# been realistically defending for hundreds of frames and may be
	# standing right in the goal mouth; teleporting the ball in on top of
	# them lets them immediately clear it (a real, correct save) before the
	# Area3D trigger ever registers the goal. See SKILL.md Gotchas.
	for p in main.away_players:
		p.global_position = Vector3(200, 1, 200)
	# Capture pre_score and the target BEFORE moving the ball, then move the
	# ball as the very last statement before the wait loop -- this is not
	# just tidiness. Godot's physics runs on its own thread; if the ball
	# lands directly inside a goal trigger, the Area3D body_entered signal
	# (and thus the score increment) can fire essentially as soon as the
	# next physics step processes it, which -- under real-time windowed
	# rendering -- can beat the *next* line of GDScript on the main thread.
	# Reading main.home_score into pre_score any time after the position
	# write risks racing an already-incremented score, making a genuine
	# goal look like scored=false. See SKILL.md Gotchas.
	var goal_pos: Vector3 = main.get_node("Field/GoalAreaRight").global_position
	var pre_score: int = main.home_score
	# A plain `global_position =` write on a RigidBody3D can be lost under
	# real-time windowed execution -- see SKILL.md Gotchas. Go through
	# PhysicsServer3D directly for a teleport the physics thread can't miss.
	var xform: Transform3D = main.ball.global_transform
	xform.origin = goal_pos
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)

	var scored := false
	for i in range(90):
		await get_tree().physics_frame
		if main.home_score > pre_score:
			scored = true
			break
	print("DRIVER: goal test -- scored=%s score_label='%s'" % [scored, main.score_label.text])
	await _screenshot("04_after_goal")

	# Restart (R key equivalent).
	main.restart_match()
	await get_tree().physics_frame
	print("DRIVER: restart_match() -- score_label='%s'" % main.score_label.text)

	print("DRIVER: SESSION COMPLETE")
	get_tree().quit(0)


func _screenshot(label: String) -> void:
	_shot_index += 1
	# Under --headless (dummy renderer, no real display), frame_post_draw
	# never fires -- awaiting it hangs forever. Skip screenshots entirely
	# in that mode; run windowed (see SKILL.md) to actually get them.
	if DisplayServer.get_name() == "headless":
		print("DRIVER: screenshot skipped (headless -- no display to capture)")
		return
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var filename: String = "user://driver_%02d_%s.png" % [_shot_index, label]
	img.save_png(filename)
	print("DRIVER: screenshot -> %s" % ProjectSettings.globalize_path(filename))
