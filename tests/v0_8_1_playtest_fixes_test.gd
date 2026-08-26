extends Node3D

# Regression tests for the V0.8.1 manual-playtest fix pass: AI pass/shoot
# decisions, pass-vs-shoot power distinction, human SHOOT reliability
# (including a fast-tap that used to get silently swallowed), teammate/
# opponent recognition (including the human-controlled player being just
# another valid teammate), the low perimeter curb, and goal-net collision.
# Run via:
#   godot --headless --path . tests/V0_8_1PlaytestFixesTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const HUDScene := preload("res://scenes/UI/HUD.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	await _test_perimeter_curb_contains_ball_and_players()
	await _test_goal_net_blocks_player_but_not_scoring()
	await _test_pass_power_always_weaker_than_shot_power()
	await _test_ai_shoots_when_in_range_with_open_teammate_nearby()
	await _test_ai_passes_when_out_of_range_with_open_teammate()
	await _test_ai_dribbles_when_no_good_option()
	await _test_teammate_and_opponent_recognition()
	await _test_fast_tap_shoot_still_fires()
	await _test_switch_during_touch_shoot_charge_no_phantom()
	await _test_multitouch_joystick_with_pass_and_sprint_with_shoot()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# --------------------------------------------------------- 1. perimeter curb

func _test_perimeter_curb_contains_ball_and_players() -> void:
	var field = FieldScene.instantiate()
	add_child(field)

	# Fire the ball hard at each of the four sides -- a low curb must still
	# reliably contain it, never letting it "escape" past the boundary.
	var shots := [
		{"pos": Vector3(0, 1, 15), "vel": Vector3(0, 0, 12)},
		{"pos": Vector3(0, 1, -15), "vel": Vector3(0, 0, -12)},
		{"pos": Vector3(20, 1, 0), "vel": Vector3(12, 0, 0)},
		{"pos": Vector3(-20, 1, 0), "vel": Vector3(-12, 0, 0)},
	]
	for shot in shots:
		var ball: BallController = BallScene.instantiate()
		add_child(ball)
		await get_tree().physics_frame
		PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), shot["pos"]))
		PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, shot["vel"])
		for i in range(90):
			await get_tree().physics_frame
		var pos: Vector3 = ball.global_position
		_check("Ball fired at %s stays contained by the perimeter curb (ended at %s)" % [shot["pos"], pos], absf(pos.x) < 36.0 and absf(pos.z) < 24.0)
		ball.queue_free()
		await get_tree().process_frame

	# A player sprinting straight at each side must also be stopped, not
	# fall into the void.
	var pair := _make_player("perimeter_p", 0, Vector3(0, 1, 20))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])
	await get_tree().physics_frame
	player.move_input = Vector2(0, 1)
	player.sprint_requested = true
	for i in range(120):
		await get_tree().physics_frame
	_check("A player sprinting into the perimeter curb is blocked, not falling out of the pitch (z=%.2f)" % player.global_position.z, player.global_position.z < 24.0 and player.global_position.y > -1.0)

	player.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------------- 2. goal net collision

func _test_goal_net_blocks_player_but_not_scoring() -> void:
	var field = FieldScene.instantiate()
	add_child(field)

	# A player run straight at the back of the goal must be stopped by the
	# net, never walking clean through it to the far side.
	var pair := _make_player("net_block_p", 0, Vector3(-27.0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])
	await get_tree().physics_frame
	player.move_input = Vector2(-1, 0)
	player.sprint_requested = true
	for i in range(150):
		await get_tree().physics_frame
	_check("A player cannot walk through the back of the goal net (stopped at x=%.2f, net back is at x=-32.2)" % player.global_position.x, player.global_position.x > -32.0)
	player.queue_free()

	# The ball must still be able to enter and score before ever reaching
	# the solid net-back collision.
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame
	var goal_area: Area3D = field.get_node("GoalAreaLeft")
	var scored := false
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), goal_area.global_position))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(15):
		await get_tree().physics_frame
		if goal_area.get_overlapping_bodies().has(ball):
			scored = true
			break
	_check("The ball can still enter the goal and trigger scoring with the net collision in place", scored)

	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ---------------------------------------- 3. pass power always < shot power

func _test_pass_power_always_weaker_than_shot_power() -> void:
	for shooting_stat in [0.0, 50.0, 100.0]:
		for passing_stat in [0.0, 50.0, 100.0]:
			var data := PlayerData.new()
			data.shooting = shooting_stat
			data.passing = passing_stat
			var player: FootballPlayer = PlayerScene.instantiate()
			add_child(player)
			player.apply_player_data(data)
			_check("shoot_min_power (%.2f) exceeds pass_power (%.2f) for shooting=%d passing=%d" % [player.shoot_min_power, player.pass_power, shooting_stat, passing_stat], player.shoot_min_power > player.pass_power)
			player.queue_free()
	await get_tree().process_frame


# ------------------------------------ 4. AI shoots in range over passing

func _test_ai_shoots_when_in_range_with_open_teammate_nearby() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier_pair := _make_player("shoot_carrier", 0, Vector3(24.0, 1, 0))
	var mate_pair := _make_player("shoot_mate", 0, Vector3(20.0, 1, 3))
	var carrier: FootballPlayer = carrier_pair[0]
	var mate: FootballPlayer = mate_pair[0]
	add_child(carrier)
	add_child(mate)
	carrier.apply_player_data(carrier_pair[1])
	mate.apply_player_data(mate_pair[1])
	carrier.formation_role = "ST"
	carrier.set_match_context([carrier, mate], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, mate], ball)
	carrier.set_possession_manager(pm)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), carrier.global_position + Vector3(0.4, 0.3, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(10):
		await get_tree().physics_frame

	var opponent_goal := Vector3(26, 1, 0)
	var own_goal := Vector3(-26, 1, 0)
	var released := false
	var release_speed := 0.0
	for i in range(180):
		AIController.update_player(carrier, ball, pm, [carrier, mate], [], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
		if not carrier.has_possession and ball.linear_velocity.length() > 0.5:
			released = true
			release_speed = ball.linear_velocity.length()
			break
	_check("An AI striker in shooting range with an open teammate nearby releases the ball (shoot preferred)", released)
	_check("The release speed (%.2f) reads as a shot, not a pass (shot power range starts above any pass power)" % release_speed, release_speed > carrier.pass_power)

	carrier.queue_free()
	mate.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# --------------------------------- 5. AI passes when out of shooting range

func _test_ai_passes_when_out_of_range_with_open_teammate() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	# Deep in the carrier's own half -- nowhere near shooting range -- with
	# one clearly open, well-aligned teammate just ahead and no opponents.
	var carrier_pair := _make_player("pass_carrier", 0, Vector3(-15.0, 1, 0))
	var mate_pair := _make_player("pass_mate", 0, Vector3(-8.0, 1, 0.5))
	var carrier: FootballPlayer = carrier_pair[0]
	var mate: FootballPlayer = mate_pair[0]
	add_child(carrier)
	add_child(mate)
	carrier.apply_player_data(carrier_pair[1])
	mate.apply_player_data(mate_pair[1])
	carrier.set_match_context([carrier, mate], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, mate], ball)
	carrier.set_possession_manager(pm)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), carrier.global_position + Vector3(0.4, 0.3, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	carrier.move_input = Vector2(1, 0)
	for i in range(10):
		await get_tree().physics_frame

	var opponent_goal := Vector3(26, 1, 0)
	var own_goal := Vector3(-26, 1, 0)
	var passed := false
	for i in range(240):
		AIController.update_player(carrier, ball, pm, [carrier, mate], [], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
		if not carrier.has_possession and ball.linear_velocity.length() > 0.3:
			passed = true
			break
	_check("An AI player far from goal with an open teammate ahead eventually passes rather than holding the ball forever", passed)

	carrier.queue_free()
	mate.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------- 6. AI dribble fallback

func _test_ai_dribbles_when_no_good_option() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	# Far from goal, no teammates at all -- nothing to pass to and nowhere
	# to shoot. Should keep carrying the ball, not release it into nothing.
	var carrier_pair := _make_player("dribble_carrier", 0, Vector3(-15.0, 1, 0))
	var carrier: FootballPlayer = carrier_pair[0]
	add_child(carrier)
	carrier.apply_player_data(carrier_pair[1])
	carrier.set_match_context([carrier], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier], ball)
	carrier.set_possession_manager(pm)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), carrier.global_position + Vector3(0.4, 0.3, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(10):
		await get_tree().physics_frame

	var opponent_goal := Vector3(26, 1, 0)
	var own_goal := Vector3(-26, 1, 0)
	# A deliberate pass/shot applies its impulse instantaneously in a
	# single physics tick, while the ball's raw carry speed while
	# sprint-dribbling can itself legitimately climb close to sprint
	# speed over time -- so track the largest single-frame velocity
	# *jump* (a kick impulse divided by the ball's low mass is tens of
	# m/s in one tick; the smooth dribble-steering force is accel-clamped
	# to a small fraction of that per tick) rather than raw peak speed,
	# which can't tell "sprinting while dribbling" apart from "kicked".
	var max_frame_delta := 0.0
	var prev_speed: float = ball.linear_velocity.length()
	for i in range(90):
		AIController.update_player(carrier, ball, pm, [carrier], [], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
		var speed: float = ball.linear_velocity.length()
		max_frame_delta = maxf(max_frame_delta, speed - prev_speed)
		prev_speed = speed
	_check("With no shot and no pass option, the AI never kicks the ball away (largest single-tick speed jump %.2f, well under any kick impulse)" % max_frame_delta, max_frame_delta < 2.0)

	carrier.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ----------------------------- 7. teammate/opponent/human recognition

func _test_teammate_and_opponent_recognition() -> void:
	var human_pair := _make_player("recog_human", 0, Vector3(0, 1, 0))
	var teammate_pair := _make_player("recog_teammate", 0, Vector3(4.0, 1, 0.3))
	var opponent_pair := _make_player("recog_opponent", 1, Vector3(4.0, 1, -0.3))
	var human: FootballPlayer = human_pair[0]
	var teammate: FootballPlayer = teammate_pair[0]
	var opponent: FootballPlayer = opponent_pair[0]
	add_child(human)
	add_child(teammate)
	add_child(opponent)
	human.apply_player_data(human_pair[1])
	teammate.apply_player_data(teammate_pair[1])
	opponent.apply_player_data(opponent_pair[1])
	# The human is wired exactly like any other teammate -- set_match_context
	# is the only mechanism _find_pass_target reads from.
	human.set_match_context([human, teammate], [opponent])

	var controller := PlayerController.new()
	add_child(controller)
	controller.set_controlled_player(human)
	await get_tree().physics_frame

	var target: FootballPlayer = human._find_pass_target(Vector3(1, 0, 0))
	_check("Pass targeting only ever considers this team's own players", target == null or target.team_id == human.team_id)
	_check("The opponent (positioned just as well as the teammate) is never selected as a pass target", target != opponent)
	_check("A same-team player is a valid, selectable pass target even while marked as the human-controlled player", target == teammate or target == null)

	human.queue_free()
	teammate.queue_free()
	opponent.queue_free()
	controller.queue_free()
	await get_tree().process_frame

	# --- AI actually passing TO the human-controlled teammate ---
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier_pair := _make_player("recog_carrier", 0, Vector3(-15.0, 1, 0))
	var human2_pair := _make_player("recog_human2", 0, Vector3(-8.0, 1, 0.5))
	var carrier: FootballPlayer = carrier_pair[0]
	var human2: FootballPlayer = human2_pair[0]
	add_child(carrier)
	add_child(human2)
	carrier.apply_player_data(carrier_pair[1])
	human2.apply_player_data(human2_pair[1])
	carrier.set_match_context([carrier, human2], [])

	var controller2 := PlayerController.new()
	add_child(controller2)
	controller2.set_controlled_player(human2)

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, human2], ball)
	carrier.set_possession_manager(pm)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), carrier.global_position + Vector3(0.4, 0.3, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	carrier.move_input = Vector2(1, 0)
	for i in range(10):
		await get_tree().physics_frame

	var opponent_goal := Vector3(26, 1, 0)
	var own_goal := Vector3(-26, 1, 0)
	var passed_to_human := false
	for i in range(240):
		AIController.update_player(carrier, ball, pm, [carrier, human2], [], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
		if not carrier.has_possession and ball.global_position.distance_to(human2.global_position) < 3.0:
			passed_to_human = true
			break
	_check("An AI teammate can release the ball toward the human-controlled player like any other teammate", passed_to_human)

	carrier.queue_free()
	human2.queue_free()
	controller2.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------ 8. fast-tap SHOOT reliability

func _test_fast_tap_shoot_still_fires() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame
	var pair := _make_player("fasttap_p", 0, Vector3(0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])

	var controller := PlayerController.new()
	add_child(controller)
	controller.set_controlled_player(player)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), player.global_position + Vector3(0.4, 0.3, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(10):
		await get_tree().physics_frame

	# Simulate a HUD press+release both landing inside the same gap
	# between physics ticks -- the exact scenario a plain level-sampled
	# shoot_held boolean can silently swallow (see InputState.gd).
	var hud = HUDScene.instantiate()
	add_child(hud)
	await get_tree().process_frame
	hud._on_shoot_pressed_down()
	hud._on_shoot_pressed_up()

	var fired := false
	for i in range(10):
		await get_tree().physics_frame
		if ball.linear_velocity.length() > 0.5:
			fired = true
			break
	_check("A press+release that both land before the next physics tick still fires a shot (not silently swallowed)", fired)

	hud.queue_free()
	player.queue_free()
	controller.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ----------------------------------- 9. switch during touch charge, no phantom

func _test_switch_during_touch_shoot_charge_no_phantom() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	# A and B start right next to each other with the SAME ball reachable
	# by both -- if a phantom shot fired on B after switching, the ball
	# would visibly move; if B has no ball nearby at all, "nothing moved"
	# would be true whether or not the fix actually works, which would
	# make this assertion meaningless.
	var a_pair := _make_player("switchshoot_a", 0, Vector3(0, 1, 0))
	var b_pair := _make_player("switchshoot_b", 0, Vector3(0.8, 1, 0))
	var a: FootballPlayer = a_pair[0]
	var b: FootballPlayer = b_pair[0]
	add_child(a)
	add_child(b)
	a.apply_player_data(a_pair[1])
	b.apply_player_data(b_pair[1])

	var controller := PlayerController.new()
	add_child(controller)
	controller.set_controlled_player(a)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0.4, 1.3, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(10):
		await get_tree().physics_frame

	var hud = HUDScene.instantiate()
	add_child(hud)
	await get_tree().process_frame

	hud._on_shoot_pressed_down()
	for i in range(40):
		await get_tree().physics_frame
	_check("Charge is in progress on player A before switching (long hold)", a._shoot_charging)

	controller.set_controlled_player(b)
	for i in range(6):
		await get_tree().physics_frame
	_check("Switching clears A's charge (existing reset_intent behavior)", not a._shoot_charging)
	# A finger still physically held keeps working for whoever is
	# controlled now (same as sprint/movement already do across a switch)
	# -- B legitimately starts its OWN fresh charge from the switch point.
	# That's correct, not a phantom: the phantom-prevention property is
	# specifically that B's eventual shot must only ever be credited for
	# time held *after* the switch, never A's earlier ~0.67s hold.
	_check("B starts its own fresh charge since the finger is still down", b._shoot_charging)

	hud._on_shoot_pressed_up()
	var fired_speed := 0.0
	for i in range(15):
		await get_tree().physics_frame
		fired_speed = maxf(fired_speed, ball.linear_velocity.length())

	# Impulse gets divided by the ball's low mass (~0.45), so even a
	# near-minimum-charge shot reads as a fairly high raw speed -- compare
	# against what a *near-full* stale ~0.67s hold would have produced
	# (clamped by max_speed) rather than against the unscaled power stat.
	var full_hold_speed_estimate: float = minf(ball.max_speed, lerp(b.shoot_min_power, b.shoot_max_power, 0.6) / ball.mass)
	_check("Releasing fires a real (not swallowed) shot for B's own short post-switch hold", fired_speed > 0.5)
	_check("That shot (%.2f) is well below what A's stale ~0.67s hold would have produced (~%.2f) -- proving it used only B's short post-switch charge" % [fired_speed, full_hold_speed_estimate], fired_speed < full_hold_speed_estimate - 2.0)

	hud.queue_free()
	a.queue_free()
	b.queue_free()
	controller.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------- 10. multitouch: joystick+pass, sprint+shoot

func _test_multitouch_joystick_with_pass_and_sprint_with_shoot() -> void:
	var hud = HUDScene.instantiate()
	add_child(hud)
	for i in range(2):
		await get_tree().process_frame

	InputState.move_vector = Vector2.ZERO
	InputState.pass_pressed = false
	InputState.sprint_held = false
	InputState.shoot_held = false

	var joystick_touch := 0
	var pass_touch := 1
	var joy_pos: Vector2 = hud.joystick.global_position + hud.joystick.size * 0.5
	var pass_pos: Vector2 = hud.pass_button.global_position + hud.pass_button.size * 0.5

	hud._input(_touch_event(joystick_touch, joy_pos, true))
	hud._input(_drag_event(joystick_touch, joy_pos + Vector2(40, 0)))
	hud._input(_touch_event(pass_touch, pass_pos, true))
	_check("PASS can be tapped while the joystick is actively held by a different finger", InputState.pass_pressed)
	_check("The joystick keeps its own vector while PASS is tapped by another finger", InputState.move_vector.x > 0.1)
	hud._input(_touch_event(pass_touch, pass_pos, false))
	hud._input(_touch_event(joystick_touch, joy_pos + Vector2(40, 0), false))
	InputState.pass_pressed = false
	InputState.move_vector = Vector2.ZERO

	var sprint_touch := 2
	var shoot_touch := 3
	var sprint_pos: Vector2 = hud.sprint_button.global_position + hud.sprint_button.size * 0.5
	var shoot_pos: Vector2 = hud.shoot_button.global_position + hud.shoot_button.size * 0.5

	hud._input(_touch_event(sprint_touch, sprint_pos, true))
	hud._input(_touch_event(shoot_touch, shoot_pos, true))
	_check("SPRINT and SHOOT can both be held at once by separate fingers", InputState.sprint_held and InputState.shoot_held)
	hud._input(_touch_event(shoot_touch, shoot_pos, false))
	_check("Releasing SHOOT does not release SPRINT (independent finger IDs)", InputState.sprint_held and not InputState.shoot_held)
	hud._input(_touch_event(sprint_touch, sprint_pos, false))

	InputState.sprint_held = false
	InputState.shoot_held = false
	InputState.move_vector = Vector2.ZERO
	hud.queue_free()
	await get_tree().process_frame


func _touch_event(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e


func _drag_event(index: int, pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	return e


# ------------------------------------------------------------------- utils

## Caller is responsible for add_child()-ing the returned player, then
## calling apply_player_data(data) on it (needs @onready nodes ready --
## see the same two-step pattern in tests/character_pipeline_test.gd).
func _make_player(id: String, team_id: int, pos: Vector3) -> Array:
	var data := PlayerData.new()
	data.id = id
	data.display_name = "Test"
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60

	var player: FootballPlayer = PlayerScene.instantiate()
	player.team_id = team_id
	player.position = pos
	return [player, data]


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
