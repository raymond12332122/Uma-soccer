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
			# v0.8.3: these are launch speeds now, and the strongest possible
			# pass is PassEvaluator's band ceiling scaled by this player's
			# passing skill -- compare against that, not a single field.
			var max_pass_speed: float = PassEvaluator.PASS_SPEED_MAX * player.pass_speed_scale
			_check("shoot_min_speed (%.2f) exceeds this player's fastest possible pass (%.2f) for shooting=%d passing=%d" % [player.shoot_min_speed, max_pass_speed, shooting_stat, passing_stat], player.shoot_min_speed > max_pass_speed)
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
	_check("The release speed (%.2f) reads as a shot, not a pass (the shot speed band starts above any pass speed)" % release_speed, release_speed > PassEvaluator.PASS_SPEED_MAX * carrier.pass_speed_scale)

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

	# v0.8.7: there is now an opponent in front of the carrier. Previously
	# this scene had NO opponents at all, which meant _forward_space scored
	# maximal and CARRY_SPACE_BONUS pushed the pass threshold to ~1.00 -- the
	# AI was being asked to pass while facing thirty metres of empty grass,
	# which is not what "prefers a useful pass over blindly dribbling" means
	# and is not what a footballer does. The assertion only ever passed
	# because its old detector counted the carrier LOSING the ball as a pass,
	# and pre-v0.8.7 close control lost it constantly.
	#
	# The opponent is placed ahead of the carrier's run but well off the line
	# to the teammate (3m clear of a 1.5m LANE_BLOCK_RADIUS), so the pass is
	# genuinely the better option and the lane to it is genuinely open.
	var opp_pair := _make_player("pass_opp", 1, Vector3(-11.0, 1, -3.0))
	var opp: FootballPlayer = opp_pair[0]
	add_child(opp)
	opp.apply_player_data(opp_pair[1])
	carrier.set_match_context([carrier, mate], [opp])

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
	# v0.8.7: detect an actual PASS rather than inferring one from "the
	# carrier no longer has the ball and the ball is moving". That proxy was
	# satisfied by the carrier simply LOSING the ball, which the pre-v0.8.7
	# close control did constantly -- the ball was jammed against the
	# carrier's capsule and squirted away on its own (measured then:
	# possession survived 31 of 120 frames at a walking pace). So the
	# assertion could pass without a pass ever being played. Now that a
	# carrier keeps the ball, the only honest signal is the kick itself.
	var passed := false
	var kicks_before: int = carrier.kick_count
	for i in range(240):
		AIController.update_player(carrier, ball, pm, [carrier, mate], [opp], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
		if carrier.kick_count > kicks_before and carrier.last_kick_kind == FootballPlayer.KickKind.PASS:
			passed = true
			break
	_check("An AI player far from goal with an open teammate ahead eventually passes rather than holding the ball forever", passed)

	opp.queue_free()
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
	# v0.8.7: the threshold is now anchored to the constant that actually
	# separates the two behaviours instead of a bare 2.0. Close control is no
	# longer a continuous steering force whose per-tick effect is tiny by
	# construction -- it is a series of discrete TOUCHES, each a real
	# impulse -- so "a single tick changed the ball's speed" stopped being
	# evidence of a kick on its own. What still distinguishes them is size:
	# a touch is capped (FootballPlayer.TOUCH_MAX_DELTA_V) strictly below the
	# slowest pass the game can play, so a jump at or above PASS_SPEED_MIN is
	# a kick and anything under it is a dribble. That is the property this
	# assertion was always reaching for.
	_check("With no shot and no pass option, the AI never kicks the ball away (largest single-tick speed jump %.2f, under the %.1f m/s that would make it a pass)"
		% [max_frame_delta, PassEvaluator.PASS_SPEED_MIN], max_frame_delta < PassEvaluator.PASS_SPEED_MIN)
	_check("...and a dribble touch is bounded below the weakest pass by construction",
		FootballPlayer.TOUCH_MAX_DELTA_V < PassEvaluator.PASS_SPEED_MIN)

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
	# v0.8.3: an AI carrier with clear grass ahead and nobody near it now
	# correctly prefers to keep running (see AIController.CARRY_SPACE_BONUS)
	# -- with literally zero opponents on the pitch, dribbling forever is
	# the right football decision, so the original setup no longer tests
	# what it claims. An opponent closing the carrier down gives the pass a
	# reason to exist; the property under test (the human-controlled
	# teammate is a valid, selectable receiver like any other) is unchanged.
	# Placed BEHIND and to the side of the carrier, not between them and the
	# receiver: an opponent sitting in the passing lane physically blocks
	# the ball (it is a real rigid body against a real capsule), which would
	# make this test fail for a reason that has nothing to do with target
	# selection.
	var marker_pair := _make_player("recog_marker", 1, Vector3(-14.0, 1, -1.6))
	var marker: FootballPlayer = marker_pair[0]
	add_child(marker)
	marker.apply_player_data(marker_pair[1])
	carrier.set_match_context([carrier, human2], [marker])

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
	# v0.8.3: asserts on the PASS EVENT rather than on where the ball
	# eventually came to rest. The original wording ("ball ends up near the
	# human while the passer no longer has it") turned out to be testing
	# something else entirely: measured frame by frame, the pass fires
	# correctly and travels toward the human, but the passer -- now the
	# nearest player to a loose ball, and therefore its nominated chaser --
	# runs onto their own pass and re-collects it before it arrives. That
	# is a question about who chases a loose ball, not about whether the
	# human is a selectable receiver, which is what this test is named for.
	# FootballPlayer.last_kick_target records the intended receiver
	# directly, so the claim can now be checked for real.
	var passed_to_human := false
	for i in range(360):
		AIController.update_player(carrier, ball, pm, [carrier, human2], [marker], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
		if carrier.kick_count > 0:
			passed_to_human = carrier.last_kick_kind == FootballPlayer.KickKind.PASS and carrier.last_kick_target == human2
			break
	_check("An AI teammate can release the ball toward the human-controlled player like any other teammate", passed_to_human)

	marker.queue_free()
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

	# v0.8.3: shoot_min_speed/shoot_max_speed are already launch speeds in
	# m/s, so there is no mass division to undo here any more. Compare
	# against what a *near-full* stale ~0.67s hold would have produced
	# (clamped by the ball's own speed cap).
	var full_hold_speed_estimate: float = minf(ball.max_speed, lerp(b.shoot_min_speed, b.shoot_max_speed, 0.6))
	_check("Releasing fires a real (not swallowed) shot for B's own short post-switch hold", fired_speed > 0.5)
	# v0.8.3: the margin is now expressed as a fraction of B's own shot band
	# rather than a flat 2.0 m/s. The band was recalibrated (12.5-17 m/s
	# launch speed, versus a much wider raw-impulse range before), so a flat
	# absolute margin no longer means the same thing -- a quarter of the
	# band is the same *proportional* claim the original was making.
	var band_margin: float = (b.shoot_max_speed - b.shoot_min_speed) * 0.25
	_check("That shot (%.2f) is well below what A's stale ~0.67s hold would have produced (~%.2f) -- proving it used only B's short post-switch charge" % [fired_speed, full_hold_speed_estimate], fired_speed < full_hold_speed_estimate - band_margin)

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
