extends Node3D

## v0.9.1.1 goalkeeper scenarios.
##
## Deterministic situations, not aggregate match statistics. The brief's
## requirement is a BELIEVABLE ATTEMPT, not a save every time -- so what is
## asserted is that the keeper recognises the threat, commits, and gets
## meaningfully closer to the ball than a keeper who ignored it would.
##
## Every scenario reports its measurements even when it passes, because "the
## keeper reacted" is a claim about reaction delay and closest approach, not
## a boolean.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	await _test_ball_is_blockable_at_all()
	await _test_close_shot()
	await _test_loose_ball_near_keeper()
	await _test_keeper_ignores_harmless_ball()
	await _test_keeper_does_not_abandon_goal()
	print("TEST_SUMMARY: %s (%d passed, %d failed)" % [
		"ALL GREEN" if _failed == 0 else "FAILURES PRESENT", _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("[PASS] %s" % label)
	else:
		_failed += 1
		print("[FAIL] %s" % label)


# ---------------------------------------------------------------- physics

## The precondition for every save: a body must be able to stop a ball.
##
## v0.9.1 set the ball's mask to world-only and the player's mask to exclude
## the ball, so the ball passed through everyone -- goalkeepers included.
## Human QA reported it as "the keeper does not attempt a save"; it was
## literally impossible for any save to occur. This is the check that was
## missing.
func _test_ball_is_blockable_at_all() -> void:
	var ctx := await _keeper_scene()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["ball"]

	_check("A player is on the ball's collision mask, so a body can stop it",
		(ball.collision_mask & keeper.collision_layer) != 0)
	_check("...and the ball is NOT on the player's mask, so it never pushes them",
		(keeper.collision_mask & ball.collision_layer) == 0)

	# Fire it at a keeper who is not allowed to move, so this measures the
	# COLLISION and nothing else.
	var start: Vector3 = keeper.global_position + Vector3(6.0, 0.4, 0)
	_seat(ball, start)
	ball.linear_velocity = Vector3(-16.0, 0, 0)
	var min_gap := 999.0
	for i in range(120):
		keeper.move_input = Vector2.ZERO
		keeper.velocity = Vector3.ZERO
		await get_tree().physics_frame
		min_gap = minf(min_gap, _flat(ball.global_position - keeper.global_position))
	var side: float = ball.global_position.x - keeper.global_position.x
	print("   ...ball ended %.2fm on the %s side, closest approach %.2fm"
		% [absf(side), "near" if side > 0.0 else "FAR", min_gap])
	_check("A ball fired at a stationary keeper does not pass through them", side > 0.0)

	_teardown(ctx)


# ------------------------------------------------------- scenario: close shot

## Attacker near goal, keeper correctly positioned, shot toward a reachable
## part of the goal. Required: a believable attempt.
func _test_close_shot() -> void:
	var ctx := await _keeper_scene()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["ball"]
	var goal: Vector3 = ctx["goal"]

	# Ball struck from 10m out, aimed just inside the keeper's side of the
	# goal so it is reachable but not straight at their chest.
	var from: Vector3 = goal + Vector3(-10.0, 0.3, 1.5)
	_seat(ball, from)
	await get_tree().physics_frame
	var aim: Vector3 = (goal + Vector3(0, 0, 2.2)) - from
	aim.y = 0.0
	ball.linear_velocity = aim.normalized() * 14.0

	var start_pos: Vector3 = keeper.global_position
	var reacted_frame := -1
	var saw_save_intent := false
	var closest := 999.0
	for i in range(150):
		await get_tree().physics_frame
		AIController.update_goalkeeper(keeper, ball, goal)
		if keeper.gk_intent == AIController.GKIntent.SAVE \
			or keeper.gk_intent == AIController.GKIntent.BLOCK:
			saw_save_intent = true
		if reacted_frame < 0 and _flat(keeper.global_position - start_pos) > 0.25:
			reacted_frame = i
		closest = minf(closest, _flat(ball.global_position - keeper.global_position))

	var conceded: bool = absf(ball.global_position.x) > absf(goal.x)
	print("   ...intent SAVE/BLOCK seen: %s | reaction %s | closest approach %.2fm | ball %s"
		% [saw_save_intent,
		   "frame %d (%.2fs)" % [reacted_frame, reacted_frame / 60.0] if reacted_frame >= 0 else "NONE",
		   closest, "past the line" if conceded else "kept out"])

	_check("The keeper recognises a close shot as a save/block situation", saw_save_intent)
	_check("The keeper actually moves for it (reaction %s)"
		% ("%.2fs" % (reacted_frame / 60.0) if reacted_frame >= 0 else "none"),
		reacted_frame >= 0 and reacted_frame < 45)
	_check("The keeper gets within a body's reach of the ball (%.2fm)" % closest, closest < 2.0)

	_teardown(ctx)


# ------------------------------------------------- scenario: loose ball

## A loose ball in a dangerous, reachable area. The keeper should decide to
## claim it rather than stand still -- but only when they can win the race.
func _test_loose_ball_near_keeper() -> void:
	var ctx := await _keeper_scene()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["ball"]
	var goal: Vector3 = ctx["goal"]

	# Loose, nearly stationary, 4m off the line, no attacker anywhere near.
	_seat(ball, goal + Vector3(-4.0, 0.2, 0.8))
	ball.linear_velocity = Vector3(-0.4, 0, 0)
	for i in range(5):
		await get_tree().physics_frame

	var intent_claim := false
	var start_pos: Vector3 = keeper.global_position
	var closest := 999.0
	for i in range(120):
		await get_tree().physics_frame
		AIController.update_goalkeeper(keeper, ball, goal)
		if keeper.gk_intent == AIController.GKIntent.ATTACK_LOOSE_BALL:
			intent_claim = true
		closest = minf(closest, _flat(ball.global_position - keeper.global_position))
	var moved: float = _flat(keeper.global_position - start_pos)

	print("   ...claim intent: %s | keeper travelled %.2fm | closest %.2fm | possession %s"
		% [intent_claim, moved, closest, keeper.has_possession])
	_check("The keeper decides to claim an uncontested loose ball", intent_claim)
	_check("...and actually goes for it (travelled %.2fm)" % moved, moved > 1.0)
	_check("...reaching it (closest %.2fm)" % closest, closest < 1.5)
	# ...without turning into a chase. The first version of the claim rule
	# keyed danger off keeper-to-ball rather than ball-to-goal, so after
	# claiming and clearing, the keeper followed its own clearance 13.26m
	# upfield and the "travelled" check above passed for entirely the wrong
	# reason.
	var ended_from_goal: float = _flat(keeper.global_position - goal)
	_check("...and does not follow the ball upfield afterwards (%.2fm from goal)"
		% ended_from_goal, ended_from_goal < AIController.GK_CLAIM_RANGE * 1.5)

	_teardown(ctx)


# -------------------------------------- scenario: keeper is not a ball magnet

## The counter-case. A ball going nowhere near the goal must NOT drag the
## keeper off their line -- that is how a keeper who "reacts" becomes worse
## than one who does not.
func _test_keeper_ignores_harmless_ball() -> void:
	var ctx := await _keeper_scene()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["ball"]
	var goal: Vector3 = ctx["goal"]

	# 25m upfield, running further away, well outside any danger.
	_seat(ball, goal + Vector3(-25.0, 0.2, 6.0))
	ball.linear_velocity = Vector3(-6.0, 0, 1.0)
	var start_pos: Vector3 = keeper.global_position
	var chased := false
	for i in range(120):
		await get_tree().physics_frame
		AIController.update_goalkeeper(keeper, ball, goal)
		if keeper.gk_intent == AIController.GKIntent.SAVE \
			or keeper.gk_intent == AIController.GKIntent.ATTACK_LOOSE_BALL:
			chased = true
	var drift: float = _flat(keeper.global_position - start_pos)
	var from_goal: float = _flat(keeper.global_position - goal)

	print("   ...intent stayed passive: %s | drift %.2fm | ended %.2fm from goal"
		% [not chased, drift, from_goal])
	_check("A harmless ball 25m away does not trigger a save or a charge", not chased)
	_check("...and the keeper stays near their line (%.2fm from goal)" % from_goal,
		from_goal < AIController.GK_CLAIM_RANGE)

	_teardown(ctx)


# ------------------------------------- the v0.8.5 guarantee must survive

## v0.8.5 asserts keepers hold their line; the threat model must not undo it.
func _test_keeper_does_not_abandon_goal() -> void:
	var ctx := await _keeper_scene()
	var keeper: FootballPlayer = ctx["keeper"]
	var ball: RigidBody3D = ctx["ball"]
	var goal: Vector3 = ctx["goal"]

	var worst := 0.0
	# Walk the ball around the attacking half; the keeper should track it
	# without ever setting off after it.
	for i in range(240):
		var t: float = i / 240.0
		_seat(ball, goal + Vector3(-18.0 - 8.0 * t, 0.2, lerpf(-12.0, 12.0, t)))
		await get_tree().physics_frame
		AIController.update_goalkeeper(keeper, ball, goal)
		worst = maxf(worst, _flat(keeper.global_position - goal))

	print("   ...keeper's furthest excursion from goal: %.2fm" % worst)
	_check("The keeper never abandons the goal to track a distant ball (%.2fm)" % worst,
		worst < AIController.GK_CLAIM_RANGE)

	_teardown(ctx)


# ---------------------------------------------------------------- helpers

func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _seat(ball: RigidBody3D, pos: Vector3) -> void:
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(Basis(), pos))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
		Vector3.ZERO)


func _keeper_scene() -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var goal := Vector3(FormationManager.GOAL_LINE_X, 0.0, 0.0)
	var keeper: FootballPlayer = PlayerScene.instantiate()
	add_child(keeper)
	keeper.global_position = goal + Vector3(0, 1, 0)
	keeper.team_id = 0
	keeper.formation_role = "GK"
	keeper.is_goalkeeper = true
	keeper.formation_slot = Vector2(0.0, 0.5)
	await get_tree().physics_frame
	keeper.set_match_context([keeper], [])
	for i in range(20):
		await get_tree().physics_frame
	return {"field": field, "ball": ball, "keeper": keeper, "goal": goal}


func _teardown(ctx: Dictionary) -> void:
	for k in ["field", "ball", "keeper"]:
		var n = ctx.get(k)
		if n != null and is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
