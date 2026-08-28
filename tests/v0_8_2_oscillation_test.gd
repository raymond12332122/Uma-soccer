extends Node3D

# Regression tests for the V0.8.2 AI movement-oscillation hotfix.
#
# The reported bug: AI players visibly looping forward -> backward ->
# forward -> backward. Diagnostics attributed 47 of 47 observed movement
# reversals to AI state changes (zero to anything else), driven by three
# separate signals chattering frame-to-frame. Each test below pins one of
# those signals, plus an end-to-end check that a stable game state
# produces a stable movement intent. Run via:
#   godot --headless --path . tests/V0_8_2OscillationTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	await _test_brief_contact_does_not_flip_team_possession()
	await _test_sustained_contact_does_flip_team_possession()
	await _test_shape_state_dwell_holds_but_ball_interaction_preempts()
	await _test_pressing_and_holding_agree_at_contact_range()
	await _test_possession_grace_absorbs_control_radius_chatter()
	await _test_stable_game_state_produces_stable_movement_target()
	await _test_full_match_ai_states_are_not_thrashing()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# ------------------------------------- 1/2. team-possession confirmation
#
# Root cause #1: last_team_with_possession flipped on a single frame of a
# player having the ball inside their control radius -- measured flipping
# every 11-17 frames (~0.2s) in a real match. Because the whole team's
# attacking/defending shape hangs off that one signal, every flip swung
# all ten outfielders' targets 10-21m in the opposite direction at once.

func _test_brief_contact_does_not_flip_team_possession() -> void:
	var ctx := await _make_possession_scenario()
	var pm: PossessionManager = ctx["pm"]
	var home_p: FootballPlayer = ctx["home"]
	var away_p: FootballPlayer = ctx["away"]
	var ball: BallController = ctx["ball"]

	_teleport(ball, home_p.global_position + Vector3(0.4, 0.3, 0))
	for i in range(20):
		await get_tree().physics_frame
	_check("Home is established as the team in possession", pm.last_team_with_possession == 0)

	# A glancing touch: the ball passes through the away player's control
	# radius for a handful of frames, far under TEAM_POSSESSION_CONFIRM_TIME.
	_teleport(ball, away_p.global_position + Vector3(0.3, 0.3, 0))
	for i in range(6):
		await get_tree().physics_frame
	_check("A ~0.1s touch by an opponent does NOT hand them team possession", pm.last_team_with_possession == 0)

	_teleport(ball, home_p.global_position + Vector3(0.4, 0.3, 0))
	for i in range(6):
		await get_tree().physics_frame
	_check("Team possession is still unchanged after the ball returns", pm.last_team_with_possession == 0)

	await _teardown(ctx)


func _test_sustained_contact_does_flip_team_possession() -> void:
	var ctx := await _make_possession_scenario()
	var pm: PossessionManager = ctx["pm"]
	var home_p: FootballPlayer = ctx["home"]
	var away_p: FootballPlayer = ctx["away"]
	var ball: BallController = ctx["ball"]

	_teleport(ball, home_p.global_position + Vector3(0.4, 0.3, 0))
	for i in range(20):
		await get_tree().physics_frame
	_check("Home is established as the team in possession (sustained case)", pm.last_team_with_possession == 0)

	# A genuine interception: the away player keeps it well past the
	# confirm time. The filter must not swallow a real turnover.
	for i in range(40):
		_teleport(ball, away_p.global_position + Vector3(0.3, 0.3, 0))
		await get_tree().physics_frame
	_check("A sustained opponent possession DOES flip team possession", pm.last_team_with_possession == 1)
	_check("A real turnover resets the transition clock", pm.time_since_last_team_change < AIController.TRANSITION_WINDOW)

	await _teardown(ctx)


# ------------------------------------- 3. shape-state dwell hysteresis
#
# Root cause #2: _determine_state was recomputed from instantaneous
# inputs every frame, and several of its states have directly opposing
# targets, so any input flicker became a full movement reversal.

func _test_shape_state_dwell_holds_but_ball_interaction_preempts() -> void:
	var ctx := await _make_possession_scenario()
	var pm: PossessionManager = ctx["pm"]
	var home_p: FootballPlayer = ctx["home"]
	var ball: BallController = ctx["ball"]

	# Establish home possession so a home player sits in attacking shape.
	_teleport(ball, home_p.global_position + Vector3(0.4, 0.3, 0))
	for i in range(20):
		await get_tree().physics_frame

	# Then park the ball well clear and wait past POSSESSION_GRACE, so the
	# observed player is genuinely ball-less -- otherwise HOLDING_POSSESSION
	# (correctly) preempts everything and there's no shape state to test.
	for i in range(30):
		_teleport(ball, Vector3(0, 1, 30))
		await get_tree().physics_frame
	_check("Observed player is ball-less before the dwell checks", not home_p.has_possession)

	# Put the observed player into a settled shape state by hand, then ask
	# for a different shape state -- the dwell must refuse it for now.
	home_p.ai_state = AIController.AIState.SUPPORTING_ATTACK
	home_p.ai_state_time = 0.0
	pm.last_team_with_possession = 1  # pretend the opponent now has it

	var held: int = AIController._determine_state(home_p, pm, null, "MID", 1.0 / 60.0)
	_check("A shape state is held through a single-frame swing in the possession signal", held == AIController.AIState.SUPPORTING_ATTACK)

	# Once the dwell genuinely elapses, the change is allowed through --
	# this is hysteresis, not a freeze.
	home_p.ai_state_time = AIController.MIN_SHAPE_STATE_DWELL + 0.01
	var released: int = AIController._determine_state(home_p, pm, null, "MID", 1.0 / 60.0)
	_check("The same change IS applied once MIN_SHAPE_STATE_DWELL has elapsed", released != AIController.AIState.SUPPORTING_ATTACK)

	# Ball interaction is priority 1 and must never wait on the dwell.
	home_p.ai_state = AIController.AIState.SUPPORTING_ATTACK
	home_p.ai_state_time = 0.0
	var pressing: int = AIController._determine_state(home_p, pm, home_p, "MID", 1.0 / 60.0)
	_check("Being nominated to press the ball preempts the dwell immediately", pressing == AIController.AIState.PRESSING)

	await _teardown(ctx)


# ------------------------------------- 4. PRESSING vs HOLDING agreement
#
# Root cause #3: a player in the act of winning the ball flip-flopped
# between HOLDING_POSSESSION (aim at the opponent goal) and PRESSING (aim
# at the ball underfoot) on consecutive frames -- a ~40m target swing.

func _test_pressing_and_holding_agree_at_contact_range() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pair := _make_player("press_agree", 0, Vector3(0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([player], ball)
	player.set_possession_manager(pm)

	var opponent_goal := Vector3(26, 1, 0)
	var own_goal := Vector3(-26, 1, 0)

	# Ball at the player's feet: pressing and holding must point the same
	# way, so a toggle between the two cannot reverse the player.
	_teleport(ball, player.global_position + Vector3(0.35, 0.3, 0))
	for i in range(5):
		await get_tree().physics_frame

	AIController.update_player(player, ball, pm, [player], [], own_goal, opponent_goal, opponent_goal, player, null, 1.0 / 60.0)
	var pressing_input: Vector2 = player.move_input

	player.ai_state = -1
	AIController.update_player(player, ball, pm, [player], [], own_goal, opponent_goal, opponent_goal, null, null, 1.0 / 60.0)
	var other_input: Vector2 = player.move_input

	var agree: bool = pressing_input.length() < 0.1 or other_input.length() < 0.1 or pressing_input.normalized().dot(other_input.normalized()) > 0.0
	_check("With the ball at their feet, pressing and carrying point the same way (no ~40m flip)", agree)

	# Far from the ball, pressing should still genuinely chase it. Wait
	# past POSSESSION_GRACE first so this is a real ball-less press rather
	# than the tail of the possession we just had.
	for i in range(20):
		_teleport(ball, Vector3(-10, 1, 0))
		await get_tree().physics_frame
	_check("Player is genuinely ball-less before the long-range press check", not player.has_possession)
	player.ai_state = -1
	AIController.update_player(player, ball, pm, [player], [], own_goal, opponent_goal, opponent_goal, player, null, 1.0 / 60.0)
	_check("Far from the ball, a pressing player still chases it (hysteresis did not disable pressing)", player.move_input.x < 0.0)

	player.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------- 5. has_possession grace

func _test_possession_grace_absorbs_control_radius_chatter() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pair := _make_player("grace_p", 0, Vector3(0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])

	_teleport(ball, player.global_position + Vector3(0.4, 0.3, 0))
	for i in range(10):
		await get_tree().physics_frame
	_check("Player has possession of a ball at their feet", player.has_possession)

	# Ball briefly leaves the control radius, as it does constantly while
	# contesting -- possession must not drop out from under the AI.
	#
	# v0.9.0: this used to teleport the ball FOUR METRES away and assert
	# possession survived. That is not the "one-frame excursion outside the
	# control radius" the check is named for -- the control radius is
	# ~1.55-1.90m -- and asserting it enshrined the exact defect this
	# milestone fixes. Measured in a live match, the ball reached 3.56m from
	# a player who still counted as having it, which is what makes a
	# turnover look absurd from the outside and is precisely the human
	# playtest's "AI steals from unrealistic distances". Retention is now
	# capped at FootballPlayer.RETAIN_MAX_DISTANCE (2.20m).
	#
	# The excursion below is now a genuine boundary one, which is what the
	# grace exists to absorb and what the comment above always described.
	_teleport(ball, player.global_position + Vector3(1.75, 0.3, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("A one-frame excursion outside the control radius does not drop possession", player.has_possession)

	# ...and the other half of that rule, new in v0.9.0: a ball that is
	# genuinely GONE stops being yours, grace or no grace.
	_teleport(ball, player.global_position + Vector3(4.0, 0.3, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("A ball four metres away is no longer this player's possession",
		not player.has_possession)

	# Left alone for real, possession genuinely ends.
	for i in range(30):
		_teleport(ball, player.global_position + Vector3(6.0, 0.3, 0))
		await get_tree().physics_frame
	_check("Possession does end once the ball is genuinely gone", not player.has_possession)

	player.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------- 6. the core oscillation assertion
#
# Exactly what the report describes: run an AI attacker for a long stretch
# with NO meaningful game-state change and verify its movement intent does
# not repeatedly alternate between opposing directions.

func _test_stable_game_state_produces_stable_movement_target() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	# A carrier holding the ball steadily, and the attacker we observe.
	var carrier_pair := _make_player("stable_carrier", 0, Vector3(-6, 1, 0))
	var attacker_pair := _make_player("stable_attacker", 0, Vector3(0, 1, 6))
	var carrier: FootballPlayer = carrier_pair[0]
	var attacker: FootballPlayer = attacker_pair[0]
	add_child(carrier)
	add_child(attacker)
	carrier.apply_player_data(carrier_pair[1])
	attacker.apply_player_data(attacker_pair[1])
	attacker.formation_role = "ST"
	carrier.set_match_context([carrier, attacker], [])
	attacker.set_match_context([carrier, attacker], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, attacker], ball)
	carrier.set_possession_manager(pm)
	attacker.set_possession_manager(pm)

	var opponent_goal := Vector3(26, 1, 0)
	var own_goal := Vector3(-26, 1, 0)
	var formation_target := Vector3(8, 1, 6)

	# Pin the ball to the carrier every frame so team possession is
	# genuinely, continuously stable for the whole run.
	var reversals := 0
	var prev_input := Vector2.ZERO
	var frames := 600
	for i in range(frames):
		_teleport(ball, carrier.global_position + Vector3(0.4, 0.3, 0))
		AIController.update_player(attacker, ball, pm, [carrier, attacker], [], own_goal, opponent_goal, formation_target, null, null, 1.0 / 60.0)
		await get_tree().physics_frame

		var inp: Vector2 = attacker.move_input
		if inp.length() > 0.3 and prev_input.length() > 0.3 and inp.normalized().dot(prev_input.normalized()) < -0.5:
			reversals += 1
		prev_input = inp

	_check("An AI attacker under a stable game state never reverses direction (%d reversals in %d frames)" % [reversals, frames], reversals == 0)
	_check("Team possession stayed stable for the whole run (the premise of the check above)", pm.last_team_with_possession == 0)

	carrier.queue_free()
	attacker.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------- 7. full-match state churn

func _test_full_match_ai_states_are_not_thrashing() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().physics_frame

	var tracked: Array = []
	for p in main.home_players:
		if p == main.player_controller.controlled_player or p.is_goalkeeper:
			continue
		tracked.append(p)

	var prev_state := {}
	var changes := {}
	for p in tracked:
		prev_state[p] = p.ai_state
		changes[p] = 0

	var frames := 600
	for i in range(frames):
		await get_tree().physics_frame
		for p in tracked:
			if p.ai_state != prev_state[p]:
				changes[p] += 1
				prev_state[p] = p.ai_state

	var total := 0
	for p in tracked:
		total += changes[p]
	var avg: float = float(total) / maxf(tracked.size(), 1)

	# Before the fix this measured ~19-21 state changes per player over
	# 900 frames (and every single observed movement reversal came from a
	# state change). After it, 4-7 over the same window. The bar here sits
	# between those, so it fails the old behavior and passes the new one
	# with real margin either way, without being brittle about exactly how
	# a given simulated match happens to unfold.
	_check("AI players are not thrashing between states in a live match (avg %.1f changes/player over %d frames)" % [avg, frames], avg < 12.0)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------- utils

func _make_possession_scenario() -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var home_pair := _make_player("osc_home", 0, Vector3(-4, 1, 0))
	var away_pair := _make_player("osc_away", 1, Vector3(4, 1, 0))
	var home_p: FootballPlayer = home_pair[0]
	var away_p: FootballPlayer = away_pair[0]
	add_child(home_p)
	add_child(away_p)
	home_p.apply_player_data(home_pair[1])
	away_p.apply_player_data(away_pair[1])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([home_p, away_p], ball)
	home_p.set_possession_manager(pm)
	away_p.set_possession_manager(pm)

	return {"field": field, "ball": ball, "home": home_p, "away": away_p, "pm": pm}


func _teardown(ctx: Dictionary) -> void:
	ctx["home"].queue_free()
	ctx["away"].queue_free()
	ctx["ball"].queue_free()
	ctx["pm"].queue_free()
	ctx["field"].queue_free()
	await get_tree().process_frame


## RigidBody3D teleports go through PhysicsServer3D -- a plain
## global_position write can be silently lost or, landing inside another
## collider, produce an explosive separation response (both seen for real
## in this project; see the run-uma-soccer skill's Gotchas).
func _teleport(ball: RigidBody3D, pos: Vector3) -> void:
	var xform: Transform3D = ball.global_transform
	xform.origin = pos
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)


## Caller add_child()s the returned player, then calls apply_player_data --
## it touches @onready nodes, so the node must be in the tree first.
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
