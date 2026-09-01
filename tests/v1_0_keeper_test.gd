extends Node3D

## Blocker 2: the goalkeeper's save as a physical action.
##
## MEASURED before this existed (tests/diag_keeper_live.gd, 150 s matches):
##
##   the keeper was in POSITION on 98-99% of frames
##   at EVERY goal conceded they were already in SAVE
##   ...0.83 m to 3.10 m from the ball, half a second before it went in
##   save_left / save_right / catch clips had shipped since v0.9.2 and
##   AIController called play_action zero times
##
## The threat model was never the problem: the keeper reads the shot and goes
## to the right place. Nothing made their body stop the ball. These checks
## cover the committed dive that now does, and -- as importantly -- the cases
## where it must NOT fire, because a keeper who dives at everything or reaches
## further than a person can is worse than one who stays on the line.

const MainScene := preload("res://scenes/Main.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("V1_0_GK: ==== goalkeeper save ====")
	_test_reach_is_human()
	await _test_saves_a_reachable_shot()
	await _test_does_not_reach_the_unreachable()
	await _test_will_not_dive_at_a_ball_on_top_of_them()
	await _test_dive_is_committed()
	await _test_dive_costs_a_recovery()
	print("V1_0_GK: ==== %d passed, %d failed ====" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("V1_0_GK: PASS  %s" % label)
	else:
		_failed += 1
		print("V1_0_GK: FAIL  %s" % label)


## The reach has to be a person's, not a magnet's.
func _test_reach_is_human() -> void:
	var reach: float = GoalkeeperSave.DIVE_EXTENT + GoalkeeperSave.SAVE_CONTACT
	print("V1_0_GK: dive reach %.2f m (extent %.2f + contact %.2f)" % [
		reach, GoalkeeperSave.DIVE_EXTENT, GoalkeeperSave.SAVE_CONTACT])
	_check(reach <= 2.2, "a dive reaches about two metres, not across the goal (%.2f)" % reach)
	_check(GoalkeeperSave.COMMIT_MAX_GAP < 5.0,
		"the keeper will not launch at a ball metres away (%.2f)" % GoalkeeperSave.COMMIT_MAX_GAP)
	_check(GoalkeeperSave.STAND_REACH < GoalkeeperSave.DIVE_EXTENT,
		"...nor dive at a ball they could save standing up (%.2f m)" % GoalkeeperSave.STAND_REACH)
	_check(GoalkeeperSave.SAVE_COOLDOWN > 0.0, "and cannot dive again instantly")


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

## A keeper on their line, everyone else parked, and a ball we can fire.
func _stage() -> Dictionary:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(40):
		await get_tree().physics_frame
	main.home_team.set_physics_process(false)
	main.away_team.set_physics_process(false)
	if main.player_controller != null:
		main.player_controller.set_physics_process(false)

	var keeper: FootballPlayer = null
	for p in main.home_players:
		if p.is_goalkeeper:
			keeper = p
			break
	var i2 := 0
	for p in (main.home_players + main.away_players):
		if p == keeper:
			continue
		p.movement_locked = true
		p.move_input = Vector2.ZERO
		p.global_position = Vector3(-30.0 + float(i2) * 3.0, p.global_position.y, -21.0)
		i2 += 1
	for i in range(10):
		await get_tree().physics_frame
	return {"main": main, "keeper": keeper,
		"own_goal": main.home_team.own_goal_pos}


func _teardown(ctx: Dictionary) -> void:
	var main = ctx.get("main")
	if main != null and is_instance_valid(main):
		main.get_parent().remove_child(main)
		main.queue_free()
	for i in range(3):
		await get_tree().physics_frame


## Fire the ball at the goal from `from`, offset `lateral` metres across, and
## run until it is resolved. Reports what the keeper did.
func _shoot(ctx: Dictionary, lateral: float, speed: float, distance: float) -> Dictionary:
	var main: Node3D = ctx["main"]
	var keeper: FootballPlayer = ctx["keeper"]
	var goal: Vector3 = ctx["own_goal"]
	var ball: RigidBody3D = main.ball
	var inward: float = -signf(goal.x)

	var target := Vector3(goal.x, 0.16, goal.z + lateral)
	var from := Vector3(goal.x + inward * distance, 0.16, goal.z + lateral * 0.4)
	ball.global_position = from
	ball.linear_velocity = Vector3.ZERO
	await get_tree().physics_frame
	var dir: Vector3 = (target - from)
	dir.y = 0.0
	ball.linear_velocity = dir.normalized() * speed

	# The keeper's own AI has to be running for it to go anywhere near the
	# shot: with home_team's physics process off (so the scenario controls the
	# outfield), update_goalkeeper is never called and the keeper stands still.
	# The first version of this test measured a closest approach of 6.36 m and
	# read that as "the keeper does not commit", which was the harness, not the
	# game.
	var committed := false
	# A one-element Array, not a local int. GDScript lambdas capture locals BY
	# VALUE, so `outcome = ...` inside the callable would assign to a copy and
	# the caller would always see -1 -- which is exactly what the first version
	# of this reported while the dive was in fact resolving. An Array is an
	# object reference and mutates for real.
	var result: Array = [-1]
	keeper.save_resolved.connect(
		func(info): result[0] = int(info.get("outcome", -1)), CONNECT_ONE_SHOT)
	var min_gap := INF
	for f in range(180):
		AIController.update_goalkeeper(keeper, ball, goal)
		await get_tree().physics_frame
		if keeper.is_diving:
			committed = true
		min_gap = minf(min_gap, keeper.global_position.distance_to(ball.global_position))
		if result[0] >= 0:
			break
	var outcome: int = result[0]
	return {
		"committed": committed,
		"outcome": outcome,
		"outcome_name": GoalkeeperSave.outcome_name(outcome) if outcome >= 0 else "none",
		"min_gap": min_gap,
		"ball_speed_after": ball.linear_velocity.length(),
	}


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

## The commit DECISION, tested directly.
##
## Driving this through a live shot proved brittle: the keeper's own lateral
## positioning already covers +-GK_LATERAL_RANGE (3.5 m), so a constructed
## "reachable" shot kept landing in the band positioning handles and the dive
## was correctly never needed. Placing the ball at a known offset and asking
## can_commit() tests the rule itself rather than 180 frames of emergent
## movement that happen to produce it.
func _test_saves_a_reachable_shot() -> void:
	var ctx: Dictionary = await _stage()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["main"].ball
	var goal: Vector3 = ctx["own_goal"]
	var inward: float = -signf(goal.x)

	# A ball arriving fast, 1.4 m to the side: past a standing save, inside a
	# dive. This is the case the live measurements showed being conceded.
	var offsets := {
		0.2: false,   # straight at them -- stand up
		1.4: true,    # needs a dive, and can be reached
		3.4: false,   # beyond a dive's reach -- do not throw yourself at it
	}
	for lateral in offsets:
		keeper.global_position = Vector3(goal.x, keeper.global_position.y, goal.z)
		keeper.clear_recovery_state()
		ball.global_position = Vector3(goal.x + inward * 3.0, 0.16, goal.z + lateral)
		ball.linear_velocity = Vector3(-inward * 14.0, 0, 0)
		await get_tree().physics_frame
		var can: bool = GoalkeeperSave.can_commit(keeper, ball, AIController.GKIntent.SAVE)
		var miss: float = GoalkeeperSave._lateral_miss(keeper, ball)
		print("V1_0_GK: [commit] lateral %.1f m -> lateral miss %.2f, commit=%s (want %s)" % [
			lateral, miss, str(can), str(offsets[lateral])])
		_check(can == offsets[lateral],
			"a ball passing %.1f m to the side %s a dive" % [
				lateral, "needs" if offsets[lateral] else "does not need"])
	await _teardown(ctx)


## A committed dive stops a ball that crosses its reach, and the outcome is
## decided by the ball's speed rather than by having dived.
func _test_does_not_reach_the_unreachable() -> void:
	var ctx: Dictionary = await _stage()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["main"].ball
	var goal: Vector3 = ctx["own_goal"]
	var inward: float = -signf(goal.x)

	keeper.global_position = Vector3(goal.x, keeper.global_position.y, goal.z)
	keeper.clear_recovery_state()
	ball.global_position = Vector3(goal.x + inward * 3.0, 0.16, goal.z + 1.4)
	ball.linear_velocity = Vector3(-inward * 14.0, 0, 0)
	await get_tree().physics_frame

	var result: Array = [-1]
	keeper.save_resolved.connect(
		func(info): result[0] = int(info.get("outcome", -1)), CONNECT_ONE_SHOT)
	var dir: Vector3 = GoalkeeperSave.dive_direction(keeper, ball)
	keeper.begin_dive(dir)
	for f in range(120):
		await get_tree().physics_frame
		if result[0] >= 0:
			break
	print("V1_0_GK: [resolution] outcome=%s" % GoalkeeperSave.outcome_name(result[0]))
	_check(result[0] == GoalkeeperSave.Outcome.CAUGHT
		or result[0] == GoalkeeperSave.Outcome.PARRIED,
		"a dive across the ball's path stops it (%s)" % GoalkeeperSave.outcome_name(result[0]))
	await _teardown(ctx)


## A ball rolling gently onto the keeper is dealt with by standing there.
func _test_will_not_dive_at_a_ball_on_top_of_them() -> void:
	var ctx: Dictionary = await _stage()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["main"].ball
	ball.global_position = keeper.global_position + Vector3(0, 0.16 - keeper.global_position.y, 0.3)
	ball.linear_velocity = Vector3.ZERO
	await get_tree().physics_frame
	var can: bool = GoalkeeperSave.can_commit(keeper, ball,
		AIController.GKIntent.SAVE)
	print("V1_0_GK: [at their feet] can_commit=%s" % str(can))
	_check(not can, "no dive at a ball already at the keeper's feet")
	await _teardown(ctx)


## Commitment is what makes a keeper beatable: the direction is locked in.
func _test_dive_is_committed() -> void:
	var ctx: Dictionary = await _stage()
	var keeper: FootballPlayer = ctx["keeper"]
	keeper.begin_dive(Vector3(0, 0, 1))
	var first: Vector3 = keeper.dive_direction
	await get_tree().physics_frame
	# Ask it to go the other way mid-dive; a committed dive must ignore this.
	keeper.begin_dive(Vector3(0, 0, -1))
	await get_tree().physics_frame
	print("V1_0_GK: [commitment] locked (%.2f, %.2f), after re-request (%.2f, %.2f)" % [
		first.x, first.z, keeper.dive_direction.x, keeper.dive_direction.z])
	_check(keeper.dive_direction.z > 0.5,
		"a dive already in flight cannot be re-aimed")
	await _teardown(ctx)


## Diving has to cost something, or it is a free action to spam.
func _test_dive_costs_a_recovery() -> void:
	var ctx: Dictionary = await _stage()
	var keeper: FootballPlayer = ctx["keeper"]
	keeper.begin_dive(Vector3(0, 0, 1))
	var landed := false
	for f in range(240):
		await get_tree().physics_frame
		if not keeper.is_diving:
			landed = true
			break
	_check(landed, "the dive resolves rather than running forever")
	_check(keeper.is_recovering(),
		"a keeper who has dived is on the floor afterwards")
	_check(keeper.save_cooldown > 0.0, "...and cannot immediately dive again")
	var up := false
	for f in range(600):
		await get_tree().physics_frame
		if not keeper.is_recovering():
			up = true
			break
	_check(up, "...but does get back up (no permanent freeze)")
	await _teardown(ctx)
