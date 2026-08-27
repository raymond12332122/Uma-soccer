extends Node3D

# Regression tests for the V0.8.4 playtest bugfix pass.
#
# Two reported bugs were reproduced and measured before anything was
# changed; the rest of the report described v0.8.2 behaviour that v0.8.3
# had already reworked but that had never been built into an APK, so this
# suite also pins those so they cannot regress.
#
# Measured root causes:
#
#   1. STICKY POSSESSION. There was no tackle mechanic at all -- possession
#      went to whichever player with the ball in their control radius was
#      closest to it. The carrier's dribble spring pins the ball 0.62m in
#      front of them, and 0.4m-radius capsules mean a challenger's centre
#      can never be nearer than 0.8m to the carrier's, so outside a head-on
#      challenge the carrier was closer to the ball by construction, always.
#      On top of that the contester's own target blended toward the GOAL
#      across the final 1.6m, so it arced past a stationary ball: measured
#      1v1, a hand-steered challenger beat a stationary carrier from 7 of 8
#      approach angles while the real AI managed 4 of 8.
#
#   2. POST-SHOT SNAP-BACK. Measured over a live match: in the second after
#      kicking, a player who had SHOT closed 0.86m back toward its own
#      formation slot, while a player who had PASSED moved 0.92m further
#      away. So the reported "shoots, then instantly returns to formation"
#      was real and specific to shooting -- a shot hands the ball to the
#      keeper, which flips team possession, which slews attack_intent
#      negative and drops the entire forward line.
#
# Run via: godot --headless --path . tests/V0_8_4PlaytestFixesTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	await _test_stationary_carrier_can_be_dispossessed()
	await _test_moving_carrier_is_harder_than_a_stationary_one()
	await _test_challenge_needs_sustained_commitment()
	await _test_tackle_completes_from_a_sustained_challenge()
	await _test_tackle_actually_frees_the_ball()
	await _test_teammates_and_keepers_never_tackle()
	await _test_challenge_rate_responds_to_stats_and_traits()
	await _test_shooter_does_not_snap_back_to_formation()
	await _test_passer_keeps_supporting_the_attack()
	await _test_follow_up_decays_rather_than_snapping()
	await _test_live_match_produces_turnovers()
	await _test_live_match_human_carrier_is_contestable()
	await _test_goalkeepers_still_unaffected()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# =============================================== 1. the contest itself

func _test_stationary_carrier_can_be_dispossessed() -> void:
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]
	var challenger: FootballPlayer = ctx["challenger"]
	var pm: PossessionManager = ctx["pm"]

	_check("The carrier starts in possession", pm.current_carrier == carrier)

	var dispossessed := false
	for i in range(360):
		carrier.move_input = Vector2.ZERO  # standing still over the ball
		_drive_at_ball(challenger, ctx["ball"])
		await get_tree().physics_frame
		if pm.current_carrier != carrier:
			dispossessed = true
			break

	_check("A challenger can take the ball off a STATIONARY carrier (peak challenge %.2f of %.2f)" % [
		challenger.challenge_progress, BallContest.CHALLENGE_TIME_REQUIRED], dispossessed)

	await _teardown(ctx)


func _test_moving_carrier_is_harder_than_a_stationary_one() -> void:
	# The relationship the playtest asked for, asserted directly on the
	# vulnerability curve rather than inferred from duel outcomes.
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]

	carrier.velocity = Vector3.ZERO
	var still: float = BallContest.carrier_vulnerability(carrier)

	carrier.velocity = Vector3(BallContest.CARRIER_MOVING_SPEED, 0, 0)
	var moving: float = BallContest.carrier_vulnerability(carrier)

	carrier.velocity = Vector3(8.5, 0, 0)
	carrier.is_currently_sprinting = true
	var sprinting: float = BallContest.carrier_vulnerability(carrier)
	carrier.is_currently_sprinting = false

	_check("A stationary carrier is more vulnerable than one moving at a controlled pace (%.2f vs %.2f)" % [still, moving], still > moving)
	_check("A sprinting carrier is more exposed again than a controlled one (%.2f vs %.2f)" % [sprinting, moving], sprinting > moving)
	_check("...but still not as exposed as standing completely still (%.2f vs %.2f)" % [sprinting, still], sprinting < still)

	await _teardown(ctx)


func _test_challenge_needs_sustained_commitment() -> void:
	# Asserted on the challenge itself rather than on who ends up with the
	# ball, because possession has a second, entirely legitimate path: a
	# challenger attacking a stationary ball HEAD-ON can simply end up
	# nearer to it than the carrier and win it geometrically in a moment.
	# That is not the tackle system, and mixing the two makes it impossible
	# to tell whether a challenge is behaving correctly.
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]
	var challenger: FootballPlayer = ctx["challenger"]
	var ball: BallController = ctx["ball"]

	# Alongside the carrier, inside challenge range but NOT nearer the ball
	# than the carrier is -- a real challenge, not a head-on 50/50.
	challenger.global_position = Vector3(carrier.global_position.x, challenger.global_position.y, carrier.global_position.z + 1.0)
	challenger.velocity = Vector3.ZERO
	carrier.velocity = Vector3.ZERO
	await get_tree().physics_frame

	var rate: float = BallContest.challenge_rate(challenger, carrier, ball)
	_check("A challenger alongside a stationary carrier is building a challenge (%.2f/s)" % rate, rate > 0.0)
	_check("...and it takes real time rather than landing instantly (%.2fs of it needed at full rate)" % BallContest.CHALLENGE_TIME_REQUIRED,
		BallContest.CHALLENGE_TIME_REQUIRED / maxf(rate, 0.001) > 0.3)

	# Accumulate for a fraction of what a tackle needs, then break off.
	challenger.challenge_progress = 0.0
	for i in range(int(BallContest.CHALLENGE_TIME_REQUIRED * 60.0 * 0.5)):
		carrier.move_input = Vector2.ZERO
		challenger.move_input = Vector2.ZERO
		await get_tree().physics_frame
	var partial: float = challenger.challenge_progress
	_check("A sustained challenge accumulates toward a tackle (%.2f of %.2f)" % [partial, BallContest.CHALLENGE_TIME_REQUIRED],
		partial > 0.0 and partial < BallContest.CHALLENGE_TIME_REQUIRED)

	for i in range(90):
		carrier.move_input = Vector2.ZERO
		challenger.move_input = Vector2(0, 1)
		challenger.sprint_requested = true
		await get_tree().physics_frame
	_check("Breaking off the challenge decays it back toward zero (%.2f -> %.2f)" % [partial, challenger.challenge_progress],
		challenger.challenge_progress < partial)

	await _teardown(ctx)


## A completed tackle, driven purely by the contest system with the
## geometric path deliberately excluded -- the challenger never gets nearer
## the ball than the carrier, so the ONLY way it can win possession here is
## by completing a challenge.
func _test_tackle_completes_from_a_sustained_challenge() -> void:
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]
	var challenger: FootballPlayer = ctx["challenger"]
	var pm: PossessionManager = ctx["pm"]

	challenger.global_position = Vector3(carrier.global_position.x, challenger.global_position.y, carrier.global_position.z + 1.0)
	await get_tree().physics_frame
	_check("The carrier is nearer the ball than the challenger, so no geometric win is available",
		carrier.global_position.distance_to(ctx["ball"].global_position) < challenger.global_position.distance_to(ctx["ball"].global_position))

	var tackled := false
	for i in range(300):
		carrier.move_input = Vector2.ZERO
		challenger.move_input = Vector2.ZERO
		await get_tree().physics_frame
		if not carrier.has_possession:
			tackled = true
			break

	_check("A sustained challenge on a stationary carrier completes as a tackle", tackled)
	_check("...and the tackle put the loser on a cooldown so the ball is genuinely free", carrier._possession_cooldown_timer > 0.0)

	await _teardown(ctx)


func _test_tackle_actually_frees_the_ball() -> void:
	# The tackle must do something physical, and the loser must not simply
	# re-attach on the next frame -- that cooldown is what breaks the
	# sticky-ball problem, because the dribble spring is gated on it.
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]
	var ball: BallController = ctx["ball"]

	var before: float = ball.global_position.distance_to(carrier.global_position)
	carrier.notify_dispossessed(BallContest.TACKLE_DISPOSSESS_COOLDOWN)
	_check("Being tackled ends possession immediately", not carrier.has_possession)

	for i in range(10):
		carrier.move_input = Vector2.ZERO
		await get_tree().physics_frame
	_check("A dispossessed carrier cannot re-acquire the ball during the cooldown", not carrier.has_possession)

	# And once the cooldown expires they are allowed back into the contest.
	for i in range(45):
		carrier.move_input = Vector2.ZERO
		await get_tree().physics_frame
	_check("...but the cooldown does expire (possession is not permanently denied)", carrier.has_possession)

	await _teardown(ctx)


func _test_teammates_and_keepers_never_tackle() -> void:
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]
	var challenger: FootballPlayer = ctx["challenger"]

	# Same team -> no challenge, however close they stand.
	challenger.team_id = carrier.team_id
	challenger.global_position = carrier.global_position + Vector3(0.9, 0, 0)
	for i in range(60):
		carrier.move_input = Vector2.ZERO
		await get_tree().physics_frame
	_check("A teammate standing on top of the carrier never builds a challenge (%.3f)" % challenger.challenge_progress,
		challenger.challenge_progress == 0.0)

	challenger.team_id = 1
	challenger.is_goalkeeper = true
	for i in range(60):
		carrier.move_input = Vector2.ZERO
		_drive_at_ball(challenger, ctx["ball"])
		await get_tree().physics_frame
	_check("A goalkeeper never builds an outfield challenge either (%.3f)" % challenger.challenge_progress,
		challenger.challenge_progress == 0.0)
	challenger.is_goalkeeper = false

	await _teardown(ctx)


func _test_challenge_rate_responds_to_stats_and_traits() -> void:
	var ctx := await _duel_scenario()
	var carrier: FootballPlayer = ctx["carrier"]
	var challenger: FootballPlayer = ctx["challenger"]
	var ball: BallController = ctx["ball"]

	challenger.global_position = ball.global_position + Vector3(0.9, 0, 0)
	challenger.velocity = Vector3.ZERO
	carrier.velocity = Vector3.ZERO
	await get_tree().physics_frame

	challenger.player_data.defensive_ability = 95.0
	carrier.player_data.dribbling = 20.0
	var strong: float = BallContest.challenge_rate(challenger, carrier, ball)

	challenger.player_data.defensive_ability = 20.0
	carrier.player_data.dribbling = 95.0
	var weak: float = BallContest.challenge_rate(challenger, carrier, ball)

	_check("A strong defender challenges a poor dribbler faster than the reverse (%.2f vs %.2f)" % [strong, weak], strong > weak)
	_check("...but even a poor challenge still makes some progress rather than being impossible (%.2f)" % weak, weak > 0.0)

	# Distance must matter, and out of range must mean no challenge at all.
	challenger.global_position = ball.global_position + Vector3(BallContest.CHALLENGE_RANGE + 1.0, 0, 0)
	await get_tree().physics_frame
	_check("A challenger out of range is not challenging at all",
		BallContest.challenge_rate(challenger, carrier, ball) == 0.0)

	await _teardown(ctx)


# =============================================== 2. post-action behaviour

func _test_shooter_does_not_snap_back_to_formation() -> void:
	var ctx := await _follow_up_scenario()
	var player: FootballPlayer = ctx["player"]
	player.post_action_kind = FootballPlayer.KickKind.SHOT
	player.post_action_timer = FootballPlayer.POST_ACTION_WINDOW

	var slot := Vector3(-14, 1, 0)
	var start_to_slot: float = player.global_position.distance_to(slot)
	for i in range(60):
		AIController.update_player(player, ctx["ball"], ctx["pm"], [player], [],
			Vector3(-26, 1, 0), Vector3(26, 1, 0), slot, null, null, 1.0 / 60.0)
		await get_tree().physics_frame
	var end_to_slot: float = player.global_position.distance_to(slot)

	_check("A player who has just SHOT does not head straight back to its formation slot (%.2fm -> %.2fm)" % [start_to_slot, end_to_slot],
		end_to_slot >= start_to_slot - 0.5)
	_check("...and stays in the attacking area near the goal it just shot at (%.1fm from goal)" % player.global_position.distance_to(Vector3(26, 1, 0)),
		player.global_position.distance_to(Vector3(26, 1, 0)) < 16.0)

	await _teardown_follow_up(ctx)


func _test_passer_keeps_supporting_the_attack() -> void:
	var ctx := await _follow_up_scenario()
	var player: FootballPlayer = ctx["player"]
	player.post_action_kind = FootballPlayer.KickKind.PASS
	player.post_action_timer = FootballPlayer.POST_ACTION_WINDOW

	var slot := Vector3(-14, 1, 0)
	var start_x: float = player.global_position.x
	for i in range(60):
		AIController.update_player(player, ctx["ball"], ctx["pm"], [player], [],
			Vector3(-26, 1, 0), Vector3(26, 1, 0), slot, null, null, 1.0 / 60.0)
		await get_tree().physics_frame

	_check("A player who has just PASSED keeps moving up the pitch rather than retreating (x %.1f -> %.1f)" % [start_x, player.global_position.x],
		player.global_position.x > start_x)

	await _teardown_follow_up(ctx)


func _test_follow_up_decays_rather_than_snapping() -> void:
	var pair := _make_player("decay", 0, Vector3.ZERO)
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])

	player.post_action_kind = FootballPlayer.KickKind.SHOT
	player.post_action_timer = FootballPlayer.POST_ACTION_WINDOW
	_check("Involvement is full immediately after the kick (%.2f)" % player.post_action_involvement(),
		player.post_action_involvement() > 0.99)

	var previous: float = player.post_action_involvement()
	var monotonic := true
	for i in range(int(FootballPlayer.POST_ACTION_WINDOW * 60.0) + 10):
		await get_tree().physics_frame
		var now: float = player.post_action_involvement()
		if now > previous + 0.0001:
			monotonic = false
		previous = now

	_check("Involvement decays smoothly rather than switching off (never increases)", monotonic)
	_check("Involvement reaches zero once the window expires (%.2f)" % previous, previous == 0.0)

	player.queue_free()
	await get_tree().process_frame


# =============================================== 3. live 22-player match

func _test_live_match_produces_turnovers() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var turnovers := 0
	var peak_challenge := 0.0
	var challenging_frames := 0
	var previous_carrier: FootballPlayer = null
	var frames := 1800
	for i in range(frames):
		await get_tree().physics_frame
		var c: FootballPlayer = main.possession_manager.current_carrier
		if c != null and previous_carrier != null and c.team_id != previous_carrier.team_id:
			turnovers += 1
		if c != null:
			previous_carrier = c
		for p in main.home_players + main.away_players:
			if p.challenge_progress > 0.0:
				challenging_frames += 1
			peak_challenge = maxf(peak_challenge, p.challenge_progress)

	var per_minute: float = turnovers * 60.0 / (frames / 60.0)
	_check("A live 22-player match produces regular turnovers (%d in %.0fs, %.1f/min)" % [turnovers, frames / 60.0, per_minute],
		turnovers >= 5)
	# A completed tackle resets progress to zero on the frame it lands, so
	# sampling for "nearly complete" almost never catches one -- peak
	# progress across the match is the honest measure that challenges are
	# genuinely being contested rather than the system lying dormant.
	# Deliberately a modest bar. In AI-vs-AI play possession is already very
	# volatile -- measured above at roughly 40 changes per minute -- so the
	# ball usually changes hands the geometric way (a loose ball reaching
	# somebody else) well before any single challenge has time to complete.
	# The tackle path matters most in the situation the playtest actually
	# reported: a carrier deliberately holding the ball, which is covered
	# by the controlled duel tests and by the human-carrier test below.
	# What this asserts is that the system is live and accumulating in real
	# play rather than lying dormant.
	_check("Challenges genuinely build during a live match (peak %.2f of %.2f, %d player-frames challenging)" % [
		peak_challenge, BallContest.CHALLENGE_TIME_REQUIRED, challenging_frames],
		peak_challenge > 0.05 and challenging_frames > 100)

	main.queue_free()
	await get_tree().process_frame


## The reported bug in the situation it was reported in, measured the way
## a rendered playtest measures it: a human who plays normally (chases the
## ball, sprints for it) must not end up monopolising possession.
##
## An earlier version of this test placed the human on the ball and waited
## for a specific opponent to take it. That was fragile -- it depended on
## where a loose ball happened to roll -- and it also missed the real
## problem: measured in a rendered match, the human held the ball 95% of
## the time, which is the sticky-possession complaint even though
## individual turnovers did occur.
func _test_live_match_human_carrier_is_contestable() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var frames := 1800
	var human_carrier_frames := 0
	var carrier_frames := 0
	var peak_challenge := 0.0
	for i in range(frames):
		var human: FootballPlayer = main.player_controller.controlled_player
		# Play like a human would: go and get the ball.
		var to_ball: Vector3 = main.ball.global_position - human.global_position
		to_ball.y = 0.0
		InputState.move_vector = Vector2(to_ball.x, to_ball.z).limit_length(1.0)
		InputState.sprint_held = to_ball.length() > 6.0
		await get_tree().physics_frame
		var c: FootballPlayer = main.possession_manager.current_carrier
		if c != null:
			carrier_frames += 1
			if c == main.player_controller.controlled_player:
				human_carrier_frames += 1
		for p in main.home_players + main.away_players:
			peak_challenge = maxf(peak_challenge, p.challenge_progress)
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false

	var share: float = 100.0 * human_carrier_frames / maxf(carrier_frames, 1)
	_check("Sampled a real passage of human play (%d carrier frames)" % carrier_frames, carrier_frames > 300)
	_check("A human who chases the ball does not monopolise possession (%.0f%% of carrier time)" % share, share < 75.0)
	_check("Opponents genuinely challenge the human carrier (peak %.2f of %.2f)" % [peak_challenge, BallContest.CHALLENGE_TIME_REQUIRED],
		peak_challenge > BallContest.CHALLENGE_TIME_REQUIRED * 0.5)

	main.queue_free()
	await get_tree().process_frame


func _test_goalkeepers_still_unaffected() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var worst := 0.0
	var keeper_challenges := 0.0
	for i in range(600):
		await get_tree().physics_frame
		for p in main.home_players + main.away_players:
			if not p.is_goalkeeper:
				continue
			var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), p.team_id)
			worst = maxf(worst, p.global_position.distance_to(own_goal))
			keeper_challenges = maxf(keeper_challenges, p.challenge_progress)

	_check("Goalkeepers still hold their line (max %.1fm from own goal)" % worst, worst < 8.0)
	_check("Goalkeepers are never drawn into the outfield tackle system (%.3f)" % keeper_challenges, keeper_challenges == 0.0)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------- utils

func _drive_at_ball(p: FootballPlayer, ball: RigidBody3D) -> void:
	var to_ball: Vector3 = ball.global_position - p.global_position
	to_ball.y = 0.0
	p.move_input = Vector2(to_ball.x, to_ball.z).limit_length(1.0)
	p.sprint_requested = true


func _duel_scenario() -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var cp := _make_player("v084_carrier", 0, Vector3(0, 1, 0))
	var gp := _make_player("v084_challenger", 1, Vector3(3.0, 1, 0))
	var carrier: FootballPlayer = cp[0]
	var challenger: FootballPlayer = gp[0]
	add_child(carrier)
	add_child(challenger)
	carrier.apply_player_data(cp[1])
	challenger.apply_player_data(gp[1])
	carrier.set_match_context([carrier], [challenger])
	challenger.set_match_context([challenger], [carrier])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, challenger], ball)
	carrier.set_possession_manager(pm)
	challenger.set_possession_manager(pm)

	# Let both players fall onto the pitch FIRST, then put the ball at the
	# settled carrier's feet. The ControlArea sphere is centred 0.5m above
	# the player origin while a resting ball sits at y=0.35, so the vertical
	# separation eats most of the sphere's radius -- placing the ball
	# relative to an un-settled spawn height leaves it outside the sphere
	# entirely and the "carrier" never actually gains possession.
	for i in range(30):
		await get_tree().physics_frame
	_teleport(ball, Vector3(carrier.global_position.x + 0.5, 0.35, carrier.global_position.z))
	for i in range(10):
		carrier.move_input = Vector2.ZERO
		await get_tree().physics_frame

	return {"field": field, "ball": ball, "carrier": carrier, "challenger": challenger, "pm": pm}


func _teardown(ctx: Dictionary) -> void:
	ctx["carrier"].queue_free()
	ctx["challenger"].queue_free()
	ctx["pm"].queue_free()
	ctx["ball"].queue_free()
	ctx["field"].queue_free()
	await get_tree().process_frame


func _follow_up_scenario() -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pair := _make_player("v084_follow", 0, Vector3(14, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])
	player.formation_role = "ST"
	player.formation_slot = Vector2(0.55, 0.0)
	player.set_match_context([player], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([player], ball)
	player.set_possession_manager(pm)
	# The ball has left -- it is on its way to the keeper.
	_teleport(ball, Vector3(23, 0.35, 0))
	await get_tree().physics_frame

	return {"field": field, "ball": ball, "player": player, "pm": pm}


func _teardown_follow_up(ctx: Dictionary) -> void:
	ctx["player"].queue_free()
	ctx["pm"].queue_free()
	ctx["ball"].queue_free()
	ctx["field"].queue_free()
	await get_tree().process_frame


func _teleport(ball: RigidBody3D, pos: Vector3) -> void:
	var xf: Transform3D = ball.global_transform
	xf.origin = pos
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)


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
