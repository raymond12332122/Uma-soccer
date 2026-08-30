extends Node3D

## AI 2.0 deterministic checks.
##
## Covers the perception layer's football concepts and the two defensive duties
## added in this milestone. Scenarios are staged inside a REAL match -- the
## v0.9.2.3 suite established that a hand-built scene does not reproduce the
## game's own spawn and produces impossible geometry -- with the AI switched
## off so the scenario, not the match, decides where everyone stands.

const MainScene := preload("res://scenes/Main.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("V1_0_AI: ==== perception and defensive duties ====")
	_test_constants_agree()
	await _test_pressure()
	await _test_space_and_crowding()
	await _test_lane_quality()
	await _test_anticipation()
	await _test_intercept_stands_in_the_lane()
	await _test_rest_defence_refuses_to_be_pulled()
	await _test_camera_stays_inside_the_bowl()
	print("V1_0_AI: ==== %d passed, %d failed ====" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("V1_0_AI: PASS  %s" % label)
	else:
		_failed += 1
		print("V1_0_AI: FAIL  %s" % label)


# ---------------------------------------------------------------------------
# The shared picture has to agree with the systems it claims to mirror
# ---------------------------------------------------------------------------

func _test_constants_agree() -> void:
	_check(is_equal_approx(FootballPerception.PRESSURE_RANGE, BallContest.CHALLENGE_RANGE),
		"perception's pressure range is the same number as the challenge range (%.2f)" % [
			FootballPerception.PRESSURE_RANGE])
	_check(FootballPerception.BALL_HORIZON <= 1.5,
		"anticipation stays a short read, not a physics oracle (%.2f s)" % [
			FootballPerception.BALL_HORIZON])
	_check(TeamPlan.MAX_INTERCEPT + TeamPlan.MAX_REST_DEFENCE <= 5,
		"the two new defensive duties can never take more than a few players")


# ---------------------------------------------------------------------------
# Scenario harness
# ---------------------------------------------------------------------------

func _match() -> Dictionary:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(40):
		await get_tree().physics_frame
	main.home_team.set_physics_process(false)
	main.away_team.set_physics_process(false)
	if main.player_controller != null:
		main.player_controller.set_physics_process(false)
	for p in (main.home_players + main.away_players):
		p.movement_locked = true
		p.move_input = Vector2.ZERO
	return {"main": main}


func _park(main: Node3D, keep: Array) -> void:
	var i := 0
	for p in (main.home_players + main.away_players):
		if p in keep:
			continue
		p.global_position = Vector3(-30.0 + float(i) * 3.0, p.global_position.y, -21.0)
		i += 1


func _perception(main: Node3D, team_id: int) -> FootballPerception:
	var us: Array = main.home_players if team_id == 0 else main.away_players
	var them: Array = main.away_players if team_id == 0 else main.home_players
	var own: Vector3 = main.home_team.own_goal_pos if team_id == 0 else main.away_team.own_goal_pos
	var opp: Vector3 = main.home_team.opponent_goal_pos if team_id == 0 else main.away_team.opponent_goal_pos
	return FootballPerception.new(team_id, us, them, main.ball, main.possession_manager, own, opp)


func _teardown(ctx: Dictionary) -> void:
	var main = ctx.get("main")
	if main != null and is_instance_valid(main):
		main.get_parent().remove_child(main)
		main.queue_free()
	for i in range(3):
		await get_tree().physics_frame


# ---------------------------------------------------------------------------
# Perception
# ---------------------------------------------------------------------------

func _test_pressure() -> void:
	var ctx: Dictionary = await _match()
	var main: Node3D = ctx["main"]
	var a: FootballPlayer = main.home_players[5]
	var b: FootballPlayer = main.away_players[5]
	_park(main, [a, b])

	a.global_position = Vector3(0, a.global_position.y, 0)
	b.global_position = Vector3(12, b.global_position.y, 0)
	await get_tree().physics_frame
	var far: float = _perception(main, 0).pressure_on(a)

	b.global_position = Vector3(1.2, b.global_position.y, 0)
	await get_tree().physics_frame
	var near: float = _perception(main, 0).pressure_on(a)

	print("V1_0_AI: pressure at 12 m = %.2f, at 1.2 m = %.2f" % [far, near])
	_check(far <= 0.01, "an opponent twelve metres away applies no pressure")
	_check(near > 0.5, "an opponent at 1.2 m applies real pressure (%.2f)" % near)
	await _teardown(ctx)


func _test_space_and_crowding() -> void:
	var ctx: Dictionary = await _match()
	var main: Node3D = ctx["main"]
	var a: FootballPlayer = main.home_players[5]
	var o1: FootballPlayer = main.away_players[4]
	var o2: FootballPlayer = main.away_players[5]
	var mate: FootballPlayer = main.home_players[6]
	_park(main, [a, o1, o2, mate])

	a.global_position = Vector3(0, a.global_position.y, 0)
	o1.global_position = Vector3(25, o1.global_position.y, 0)
	o2.global_position = Vector3(26, o2.global_position.y, 3)
	mate.global_position = Vector3(2.0, mate.global_position.y, 0)
	await get_tree().physics_frame
	var per: FootballPerception = _perception(main, 0)
	var open: float = per.space_at(Vector3(0, 0, 0))
	var crowded: float = per.space_at(Vector3(25.5, 0, 1.5))
	var mates: int = per.teammates_near(Vector3(0, 0, 0), 4.0, a)

	print("V1_0_AI: space open %.2f, crowded %.2f, teammates within 4 m %d" % [
		open, crowded, mates])
	_check(open > crowded, "open grass scores higher than a crowded spot")
	_check(open > 0.6, "genuinely open space scores high (%.2f)" % open)
	_check(mates == 1, "a teammate two metres away is counted, so runs are not duplicated")
	await _teardown(ctx)


func _test_lane_quality() -> void:
	var ctx: Dictionary = await _match()
	var main: Node3D = ctx["main"]
	var passer: FootballPlayer = main.home_players[5]
	var receiver: FootballPlayer = main.home_players[6]
	var blocker: FootballPlayer = main.away_players[5]
	_park(main, [passer, receiver, blocker])

	passer.global_position = Vector3(0, passer.global_position.y, 0)
	receiver.global_position = Vector3(12, receiver.global_position.y, 0)
	blocker.global_position = Vector3(25, blocker.global_position.y, 20)
	await get_tree().physics_frame
	var clear: float = _perception(main, 0).lane_quality(
		passer.global_position, receiver.global_position)

	blocker.global_position = Vector3(6, blocker.global_position.y, 0)
	await get_tree().physics_frame
	var blocked: float = _perception(main, 0).lane_quality(
		passer.global_position, receiver.global_position)

	# ...and an opponent BEHIND the passer cannot intercept what has gone past.
	blocker.global_position = Vector3(-3, blocker.global_position.y, 0)
	await get_tree().physics_frame
	var behind: float = _perception(main, 0).lane_quality(
		passer.global_position, receiver.global_position)

	print("V1_0_AI: lane clear %.2f, blocked %.2f, opponent behind passer %.2f" % [
		clear, blocked, behind])
	_check(clear > 0.95, "an empty lane is clean (%.2f)" % clear)
	_check(blocked < 0.25, "an opponent standing in it blocks it (%.2f)" % blocked)
	_check(behind > 0.95, "an opponent behind the passer does not block it (%.2f)" % behind)
	await _teardown(ctx)


func _test_anticipation() -> void:
	var ctx: Dictionary = await _match()
	var main: Node3D = ctx["main"]
	var ball: RigidBody3D = main.ball
	_park(main, [])
	ball.global_position = Vector3(0, 0.16, 0)
	ball.linear_velocity = Vector3(10, 0, 0)
	await get_tree().physics_frame
	var per: FootballPerception = _perception(main, 0)

	print("V1_0_AI: ball at (%.1f, %.1f) doing %.1f m/s -> future (%.2f, %.2f), settles in %.2f s" % [
		ball.global_position.x, ball.global_position.z, ball.linear_velocity.length(),
		per.ball_future.x, per.ball_future.z, per.ball_settle_time])
	_check(per.ball_future.x > ball.global_position.x + 3.0,
		"the read is ahead of the ball, not on it (%.2f m ahead)" % [
			per.ball_future.x - ball.global_position.x])
	_check(per.ball_future.x - ball.global_position.x < 12.0,
		"...and bounded, not a full extrapolation")
	_check(per.ball_settle_time > 0.0 and per.ball_settle_time <= FootballPerception.BALL_HORIZON,
		"a fast ball has a finite, bounded time before it is controllable")

	# A player who runs at where the ball IS arrives behind it; the intercept
	# point has to lead.
	var meet: Vector3 = per.intercept_point(Vector3(14, 0, 6), 6.0)
	_check(meet.x > ball.global_position.x,
		"the interception point leads the ball (%.2f vs %.2f)" % [meet.x, ball.global_position.x])
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# The two new defensive duties
# ---------------------------------------------------------------------------

## Brief scenario I: the opposition attacks centrally, and the midfield should
## visibly protect the dangerous central lane rather than converge on the ball.
func _test_intercept_stands_in_the_lane() -> void:
	var ctx: Dictionary = await _match()
	var main: Node3D = ctx["main"]
	var plan: TeamPlan = main.home_team.plan

	# Away carry the ball centrally in home's half, with a forward option ahead
	# of them. Home are defending.
	var carrier: FootballPlayer = main.away_players[5]
	var target_mate: FootballPlayer = main.away_players[9]
	_park(main, [carrier, target_mate])
	var fwd: float = signf(main.away_team.opponent_goal_pos.x - main.away_team.own_goal_pos.x)
	carrier.global_position = Vector3(fwd * 6.0, carrier.global_position.y, 0.0)
	target_mate.global_position = Vector3(fwd * 18.0, target_mate.global_position.y, 0.0)
	main.ball.global_position = carrier.global_position + Vector3(fwd * 0.6, 0.16 - carrier.global_position.y, 0)
	main.ball.linear_velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame

	# Drive the home plan directly with the away side carrying.
	plan.perception = _perception(main, 0)
	plan.attack_intent = -1.0
	plan.update(main.home_players, main.away_players, main.ball,
		main.possession_manager, 1.0 / 60.0)

	var interceptors: Array = []
	for p in main.home_players:
		if plan.duty_of(p) == TeamPlan.Duty.INTERCEPT:
			interceptors.append(p)
	print("V1_0_AI: [I] home interceptors allocated: %d" % interceptors.size())
	_check(interceptors.size() >= 1,
		"a defending side puts somebody in the pass the carrier wants to play")
	if not interceptors.is_empty():
		var who: FootballPlayer = interceptors[0]
		var point: Vector3 = plan.intercept_points.get(who.get_instance_id(), Vector3.INF)
		var on_lane: float = _distance_to_segment(point,
			carrier.global_position, target_mate.global_position)
		print("V1_0_AI: [I] the point they were given is %.2f m off the carrier->receiver line" % on_lane)
		_check(on_lane < 1.0,
			"...and the point they are given is ON that line, not next to the ball")
		var to_ball: float = point.distance_to(main.ball.global_position)
		_check(to_ball > BallContest.CHALLENGE_RANGE,
			"...and is not simply the ball again (%.2f m away)" % to_ball)
	await _teardown(ctx)


## A defender on rest defence does NOT get pulled up the pitch, which is the
## entire content of the duty.
func _test_rest_defence_refuses_to_be_pulled() -> void:
	var ctx: Dictionary = await _match()
	var main: Node3D = ctx["main"]
	var plan: TeamPlan = main.home_team.plan
	var carrier: FootballPlayer = main.away_players[5]
	_park(main, [carrier])
	var fwd: float = signf(main.home_team.opponent_goal_pos.x - main.home_team.own_goal_pos.x)
	# Put the ball a long way up the pitch, where a proximity-scored duty would
	# happily drag the whole back line after it.
	carrier.global_position = Vector3(fwd * 20.0, carrier.global_position.y, 0.0)
	main.ball.global_position = carrier.global_position + Vector3(fwd * 0.6, 0.16 - carrier.global_position.y, 0)
	main.ball.linear_velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame

	plan.perception = _perception(main, 0)
	plan.attack_intent = -1.0
	plan.update(main.home_players, main.away_players, main.ball,
		main.possession_manager, 1.0 / 60.0)

	var resting: Array = []
	for p in main.home_players:
		if plan.duty_of(p) == TeamPlan.Duty.REST_DEFENCE:
			resting.append(p)
	print("V1_0_AI: [rest] players held back: %d" % resting.size())
	_check(not resting.is_empty(), "somebody is told to hold the line")
	_check(resting.size() <= TeamPlan.MAX_REST_DEFENCE,
		"...and no more than the cap (%d)" % TeamPlan.MAX_REST_DEFENCE)
	for p in resting:
		_check(FormationManager.role_category(p.formation_role) == "DEF",
			"rest defence is a defender's job, not a forward's")
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# The camera containment that fixed the visual artifact
# ---------------------------------------------------------------------------

## Does the SHIPPED follow logic ever leave the bowl?
##
## The pose sweep proved the clamp works when it is applied; this proves the
## follow logic actually applies it, over a real match, with the real ball and
## the real player switching. It runs HEADLESS on purpose: CameraController
## works on idle frames, which run without a renderer, so what would have been
## an hours-long rendered capture is a minute of simulation -- and it becomes a
## permanent regression test rather than a one-off diagnostic.
##
## The second assertion matters as much as the first. A camera that satisfies
## its limits by refusing to follow the ball is not a fix, so this also checks
## the ball stays within a sane distance of the camera's focus.
func _test_camera_stays_inside_the_bowl() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().physics_frame

	var rig: Node3D = main.get_node("CameraRig")
	var cam: Camera3D = rig.get_node("Camera3D")
	var ball: RigidBody3D = main.ball

	# The camera follows lerp(controlled player, ball, 0.28), so it only
	# approaches the limits when the PLAYER does. Headless, the controlled
	# player receives no input and stands still: a first version of this test
	# measured the camera reaching x 17.38 while the ball reached 28.84, so the
	# clamp never bit and the assertion passed without testing anything.
	#
	# So the controlled player is driven to each byline in turn, which is
	# exactly what a human does and exactly when the artifact appeared.
	var human: FootballPlayer = main.player_controller.controlled_player
	main.player_controller.set_physics_process(false)

	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var worst_ball_gap := 0.0
	var ball_reach_x := 0.0
	var human_reach_x := 0.0
	var frames: int = 45 * 60
	for i in range(frames):
		# Quarter of the run at each extreme, so both bylines and the far
		# touchline are visited.
		var phase: int = (i * 4) / frames
		match phase:
			0: human.move_input = Vector2(1.0, 0.0)
			1: human.move_input = Vector2(-1.0, 0.0)
			2: human.move_input = Vector2(1.0, -0.6)
			_: human.move_input = Vector2(-1.0, -0.6)
		human.sprint_requested = true
		await get_tree().physics_frame
		var p: Vector3 = cam.global_position
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z)
		human_reach_x = maxf(human_reach_x, absf(human.global_position.x))
		ball_reach_x = maxf(ball_reach_x, absf(ball.global_position.x))
		worst_ball_gap = maxf(worst_ball_gap,
			Vector2(ball.global_position.x - p.x, ball.global_position.z - p.z).length())

	var limit: float = CameraController.CAMERA_X_LIMIT
	var zlimit: float = CameraController.CAMERA_Z_FORWARD_LIMIT
	print("V1_0_AI: [camera] reached x %.2f..%.2f, z min %.2f over 45 s" % [
		min_x, max_x, min_z])
	print("V1_0_AI: [camera] limits |x| <= %.2f, z >= %.2f; player reached |x| = %.2f, ball |x| = %.2f" % [
		limit, zlimit, human_reach_x, ball_reach_x])
	# The clamp only bites near the ends, so the FOLLOW TARGET has to actually
	# get there or the containment assertion means nothing. This guard is what
	# caught the first version of this test passing vacuously.
	_check(human_reach_x > limit + 1.0,
		"the controlled player genuinely ran past the camera limit (|x| %.2f > %.2f)" % [
			human_reach_x, limit])
	_check(max_x <= limit + 0.01 and min_x >= -limit - 0.01,
		"...and the shipped follow logic still never left the bowl along the goal axis")
	_check(min_z >= zlimit - 0.01,
		"...nor pushed into the stand it is facing (z min %.2f)" % min_z)
	_check(worst_ball_gap < 40.0,
		"...while the ball stayed in a sane relationship to the camera (worst %.1f m)" % worst_ball_gap)

	main.get_parent().remove_child(main)
	main.queue_free()
	for i in range(3):
		await get_tree().physics_frame


func _distance_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var pp := Vector2(p.x, p.z)
	var aa := Vector2(a.x, a.z)
	var bb := Vector2(b.x, b.z)
	var ab: Vector2 = bb - aa
	var len_sq: float = ab.length_squared()
	if len_sq < 0.000001:
		return pp.distance_to(aa)
	var t: float = clampf((pp - aa).dot(ab) / len_sq, 0.0, 1.0)
	return pp.distance_to(aa + ab * t)
