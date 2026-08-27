extends Node3D

# Regression tests for the V0.8.2 football-intelligence pass: ball
# close-control feel, the sticky-possession AI state model (forward/mid/
# defender shape, transitions), the omnidirectional AI pass search,
# ball-challenger hysteresis (no defender swarming), switch-target
# relevance, and the kickoff state machine. Run via:
#   godot --headless --path . tests/V0_8_2PlaytestFixesTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	await _test_close_control_then_loosens_while_sprinting()
	await _test_contest_gating_still_prevents_freeze()
	await _test_forward_holds_shape_through_brief_loose_ball()
	await _test_transition_defense_after_turnover()
	await _test_challenger_hysteresis_prevents_flicker()
	await _test_omnidirectional_pass_finds_teammate_behind()
	await _test_switch_prefers_relevant_over_distant()
	await _test_kickoff_then_playing()
	await _test_goal_scoring_after_kickoff()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# ------------------------------------------- 1. close control / sprint feel

func _test_close_control_then_loosens_while_sprinting() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pair := _make_player("closecontrol_p", 0, Vector3(0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0.3, 1, 0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)

	# Stand still with the ball and let the spring settle.
	for i in range(90):
		await get_tree().physics_frame
	_check("Player gains close control of a nearby loose ball", player.has_possession)
	var stationary_dist: float = player.global_position.distance_to(ball.global_position)
	_check("Ball settles close to the player's feet at a standstill (%.2fm)" % stationary_dist, stationary_dist < 1.0)

	# Now sprint in a straight line -- the leash should visibly lengthen.
	#
	# v0.8.6: settle for 120 frames rather than 40. The player needs ~0.6s
	# just to reach sprint speed, and the dribble spring then needs about as
	# long again to push the ball out to its longer sprint target -- so at 40
	# frames this was sampling the middle of the acceleration transient,
	# where the player has closed on a ball that has not been pushed ahead
	# yet, and calling that the steady-state leash. It only ever passed by a
	# rounding hair (measured on the v0.8.5 build it was asserting
	# 0.8299m > 0.8298m, with both figures pinned at the distance where the
	# two collision shapes touch), so it was not measuring the leash at all.
	# Same assertion, sampled where the quantity it names actually exists.
	player.move_input = Vector2(0, 1)
	player.sprint_requested = true
	for i in range(120):
		await get_tree().physics_frame
	var sprint_dist: float = player.global_position.distance_to(ball.global_position)
	_check("Sprinting still keeps the ball under close control (still following, %.2fm)" % sprint_dist, player.has_possession and sprint_dist < 2.0)
	_check("Sprinting loosens the leash versus standing still (%.2fm > %.2fm)" % [sprint_dist, stationary_dist], sprint_dist > stationary_dist)

	player.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------- 2. contest gating still prevents freeze

func _test_contest_gating_still_prevents_freeze() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	ball.position = Vector3(0, 1, 0)
	add_child(ball)

	var pm := PossessionManager.new()
	add_child(pm)

	var a_pair := _make_player("v82contest_a", 0, Vector3(-0.4, 1, -0.05))
	var b_pair := _make_player("v82contest_b", 1, Vector3(0.4, 1, 0.05))
	var a: FootballPlayer = a_pair[0]
	var b: FootballPlayer = b_pair[0]
	add_child(a)
	add_child(b)
	a.apply_player_data(a_pair[1])
	b.apply_player_data(b_pair[1])
	a.set_match_context([a], [b])
	b.set_match_context([b], [a])
	pm.setup([a, b], ball)
	a.set_possession_manager(pm)
	b.set_possession_manager(pm)

	for i in range(5):
		await get_tree().physics_frame

	a.move_input = Vector2(1, 0)
	b.move_input = Vector2(-1, 0)

	var start_pos: Vector3 = ball.global_position
	var max_disp := 0.0
	for i in range(150):
		await get_tree().physics_frame
		max_disp = maxf(max_disp, ball.global_position.distance_to(start_pos))
	_check("Retuned (gentler) dribble spring still never freezes a contested ball (moved %.2fm)" % max_disp, max_disp > 0.3)

	a.queue_free()
	b.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------- 3. forward holds shape through a loose ball

func _test_forward_holds_shape_through_brief_loose_ball() -> void:
	var pm := PossessionManager.new()
	add_child(pm)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pair := _make_player("v82fwd", 0, Vector3(15, 1, 0))
	var fwd: FootballPlayer = pair[0]
	add_child(fwd)
	fwd.apply_player_data(pair[1])
	fwd.formation_role = "ST"

	# Team 0 just had clear possession (a teammate carrier, not this
	# player) -- simulate via a second player who briefly holds the ball,
	# then let it go loose (nobody in range) for well under
	# AIController.TRANSITION_WINDOW.
	var carrier_pair := _make_player("v82fwd_carrier", 0, Vector3(0, 1, 0))
	var carrier: FootballPlayer = carrier_pair[0]
	add_child(carrier)
	carrier.apply_player_data(carrier_pair[1])
	pm.setup([fwd, carrier], ball)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), carrier.global_position + Vector3(0.4, 0.3, 0)))
	for i in range(10):
		await get_tree().physics_frame
	_check("Home team is recorded as the last team with possession", pm.last_team_with_possession == 0)

	# Ball goes loose (teleport far from both players so nobody's in range).
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, 1, 100)))
	for i in range(5):
		await get_tree().physics_frame
	_check("A brief loose ball does not reset last_team_with_possession", pm.last_team_with_possession == 0)

	var state: int = AIController._determine_state(fwd, pm, null, "FWD")
	_check("A forward is NOT forced into defensive recovery during a brief loose-ball moment mid-attack", state != AIController.AIState.RECOVERING_SHAPE and state != AIController.AIState.MARKING)

	fwd.queue_free()
	carrier.queue_free()
	ball.queue_free()
	pm.queue_free()
	await get_tree().process_frame


# ------------------------------------- 4. transition-defense after turnover

func _test_transition_defense_after_turnover() -> void:
	var pm := PossessionManager.new()
	add_child(pm)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var home_pair := _make_player("v82td_home", 0, Vector3(0, 1, 0))
	var away_pair := _make_player("v82td_away", 1, Vector3(3, 1, 0))
	var home_p: FootballPlayer = home_pair[0]
	var away_p: FootballPlayer = away_pair[0]
	add_child(home_p)
	add_child(away_p)
	home_p.apply_player_data(home_pair[1])
	away_p.apply_player_data(away_pair[1])
	pm.setup([home_p, away_p], ball)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), home_p.global_position + Vector3(0.4, 0.3, 0)))
	for i in range(10):
		await get_tree().physics_frame
	_check("Home has the ball first", pm.last_team_with_possession == 0)

	# Turnover: the ball moves to the away player instead, and stays there.
	# Held past PossessionManager.TEAM_POSSESSION_CONFIRM_TIME -- as of the
	# v0.8.2 oscillation hotfix a turnover must be sustained to count, so
	# that a glancing touch can't swing the whole team's shape (the ball is
	# re-pinned each frame here because a single teleport would drift out
	# of the away player's control radius before the confirm time elapses).
	for i in range(30):
		PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), away_p.global_position + Vector3(0.4, 0.3, 0)))
		PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		await get_tree().physics_frame
	_check("Possession genuinely changed to away", pm.last_team_with_possession == 1)
	_check("time_since_last_team_change resets on a real turnover", pm.time_since_last_team_change < AIController.TRANSITION_WINDOW)

	home_p.ai_state = -1
	var state: int = AIController._determine_state(home_p, pm, null, "MID")
	_check("Home player enters TRANSITION_DEFENSE right after losing the ball", state == AIController.AIState.TRANSITION_DEFENSE)

	home_p.queue_free()
	away_p.queue_free()
	ball.queue_free()
	pm.queue_free()
	await get_tree().process_frame


# ------------------------------------- 5. ball-challenger hysteresis

func _test_challenger_hysteresis_prevents_flicker() -> void:
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, 1, 0)))

	var a_pair := _make_player("v82chall_a", 0, Vector3(-2.0, 1, 0))
	var b_pair := _make_player("v82chall_b", 0, Vector3(2.05, 1, 0))
	var a: FootballPlayer = a_pair[0]
	var b: FootballPlayer = b_pair[0]
	add_child(a)
	add_child(b)
	a.apply_player_data(a_pair[1])
	b.apply_player_data(b_pair[1])

	var team := TeamController.new()
	add_child(team)
	team.team_id = 0
	team.setup([a, b], ball, null, Vector3(-26, 1, 0), Vector3(26, 1, 0))
	for i in range(3):
		await get_tree().physics_frame

	var first: FootballPlayer = team._pick_ball_challenger()
	_check("A designated challenger is picked from two similarly-placed players", first == a or first == b)

	# Nudge the ball a hair closer to the OTHER player -- a tiny jitter,
	# well under the hysteresis margin. Without hysteresis this alone used
	# to be enough to flip the challenger every frame (the actual cause of
	# "defenders swarm the ball").
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0.03, 1, 0)))
	for i in range(3):
		await get_tree().physics_frame
	var second: FootballPlayer = team._pick_ball_challenger()
	_check("A sub-hysteresis-margin jitter in ball position does not flip the challenger", second == first)

	a.queue_free()
	b.queue_free()
	ball.queue_free()
	team.queue_free()
	await get_tree().process_frame


# ------------------------------------- 6. omnidirectional AI pass search

func _test_omnidirectional_pass_finds_teammate_behind() -> void:
	var carrier_pair := _make_player("v82omni_carrier", 0, Vector3(0, 1, 0))
	var behind_pair := _make_player("v82omni_behind", 0, Vector3(-4.0, 1, 0.3))
	var carrier: FootballPlayer = carrier_pair[0]
	var behind: FootballPlayer = behind_pair[0]
	add_child(carrier)
	add_child(behind)
	carrier.apply_player_data(carrier_pair[1])
	behind.apply_player_data(behind_pair[1])
	carrier.set_match_context([carrier, behind], [])

	# The carrier is aiming forward (+x); a teammate positioned directly
	# BEHIND them (-x) is exactly what the old narrow forward-only cone
	# would have excluded outright.
	var aim_dir := Vector3(1, 0, 0)
	var narrow: FootballPlayer = carrier._find_pass_target(aim_dir)
	_check("The default (narrow, human-PASS-button) search does not find a teammate directly behind", narrow == null)

	var omni: FootballPlayer = carrier._find_pass_target(aim_dir, FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI)
	_check("The omnidirectional (AI) search finds that same teammate behind the carrier", omni == behind)

	carrier.queue_free()
	behind.queue_free()
	await get_tree().process_frame


# ------------------------------------- 7. switch relevance vs distance

func _test_switch_prefers_relevant_over_distant() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(5):
		await get_tree().physics_frame

	var controlled: FootballPlayer = main.player_controller.controlled_player
	var near_relevant: FootballPlayer = null
	var far_irrelevant: FootballPlayer = null
	for p in main.home_players:
		if p == controlled or p.is_goalkeeper:
			continue
		if near_relevant == null:
			near_relevant = p
		elif far_irrelevant == null:
			far_irrelevant = p
	_check("Found two distinct non-controlled, non-GK home players to test with", near_relevant != null and far_irrelevant != null)
	if near_relevant == null or far_irrelevant == null:
		main.queue_free()
		field.queue_free()
		return

	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, 1, 0)))
	for i in range(3):
		await get_tree().physics_frame

	near_relevant.global_position = Vector3(2.0, 1, 0.5)
	far_irrelevant.global_position = Vector3(45.0, 1, 15.0)

	var candidates: Array = [near_relevant, far_irrelevant]
	var target: FootballPlayer = main._select_switch_target(candidates)
	_check("Switching prefers a player near the current play over a genuinely distant one", target == near_relevant)

	main.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------- 8. kickoff -> playing

func _test_kickoff_then_playing() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame

	_check("Match starts in the KICKOFF phase, not straight into PLAYING", main.match_phase == main.MatchPhase.KICKOFF)

	var human: FootballPlayer = main.player_controller.controlled_player
	InputState.move_vector = Vector2(1, 0)
	# Horizontal-only distance: a freshly-spawned player settles a small,
	# normal amount vertically under gravity in the first few frames
	# regardless of kickoff (unrelated to movement_locked), so comparing
	# full 3D position would misread that as "moved".
	var pos_during_kickoff := Vector2(human.global_position.x, human.global_position.z)
	for i in range(10):
		await get_tree().physics_frame
	var horiz_now := Vector2(human.global_position.x, human.global_position.z)
	_check("Movement input is held/frozen during KICKOFF (human did not move horizontally)", horiz_now.distance_to(pos_during_kickoff) < 0.02)
	_check("Match timer does not advance during KICKOFF", main.match_time_elapsed < 0.001)

	for i in range(60):
		await get_tree().physics_frame
		if main.match_phase == main.MatchPhase.PLAYING:
			break
	_check("Match transitions to PLAYING on its own after the brief kickoff hold", main.match_phase == main.MatchPhase.PLAYING)

	for i in range(10):
		await get_tree().physics_frame
	var horiz_after := Vector2(human.global_position.x, human.global_position.z)
	_check("The human can move once PLAYING starts", horiz_after.distance_to(pos_during_kickoff) > 0.1)
	_check("The match timer starts advancing once PLAYING starts", main.match_time_elapsed > 0.05)

	InputState.move_vector = Vector2.ZERO
	main.queue_free()
	await get_tree().process_frame


# ------------------------------------- 9. goal scoring still works (post-kickoff)

func _test_goal_scoring_after_kickoff() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().physics_frame
	_check("Match has reached PLAYING before the scoring check", main.match_phase == main.MatchPhase.PLAYING)

	var goal_area: Area3D = main.get_node("Field/GoalAreaRight")
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), goal_area.global_position))
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)

	var scored := false
	for i in range(30):
		await get_tree().physics_frame
		if main.home_score == 1:
			scored = true
			break
	_check("Normal goal scoring still works after the kickoff sequence", scored)

	main.queue_free()
	await get_tree().process_frame


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
