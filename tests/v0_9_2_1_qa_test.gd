extends Node3D

## v0.9.2.1 QA-fix suite.
##
## Every check here corresponds to a specific thing human QA reported, or to a
## specific way the fix for it could silently stop working. Nothing asserts
## that something "looks right"; each names a failure and fails only on it.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("V0_9_2_1: ==== QA fixes ====")
	_test_role_table()
	await _test_role_refusals()
	await _test_render_bounds()
	await _test_slide_clean()
	await _test_slide_foul()
	await _test_slide_missed()
	await _test_slide_avoided()
	await _test_animation_does_not_decide()
	await _test_live_match_safety()
	print("V0_9_2_1: ==== %d passed, %d failed ====" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("V0_9_2_1: PASS  %s" % label)
	else:
		_failed += 1
		print("V0_9_2_1: FAIL  %s" % label)


# ---------------------------------------------------------------------------
# Role separation (brief sections 2, 3)
# ---------------------------------------------------------------------------

## The database itself, before any player exists.
func _test_role_table() -> void:
	var keeper_intents: Array = []
	var outfield_intents: Array = []
	var roleless: Array = []
	for intent in AnimationSet.INTENTS:
		var entry: Dictionary = AnimationSet.INTENTS[intent]
		if not entry.has("role") or not entry.has("category"):
			roleless.append(intent)
			continue
		match entry["role"]:
			AnimationSet.Role.GOALKEEPER: keeper_intents.append(intent)
			AnimationSet.Role.OUTFIELD: outfield_intents.append(intent)
	_check(roleless.is_empty(), "every intent declares a role and a category: %s" % [roleless])
	_check(keeper_intents.size() >= 10,
		"the keeper has a real vocabulary of its own (%d intents)" % keeper_intents.size())
	# Counted as what an outfield player can actually USE -- its own intents
	# plus the any-role ones -- rather than as OUTFIELD-tagged intents alone.
	# v0.9.2.2 removed two of those (the standing challenge, which was a
	# grounded clip misfiled, and the bicycle kick), and the count that
	# matters did not change in kind: an outfield player still has a full
	# vocabulary.
	var outfield_usable: int = outfield_intents.size()
	for intent in AnimationSet.INTENTS:
		if AnimationSet.INTENTS[intent]["role"] == AnimationSet.Role.ANY:
			outfield_usable += 1
	_check(outfield_usable >= 10,
		"so does an outfield player (%d usable intents)" % outfield_usable)

	# The actual QA complaint, stated as a property of the data.
	var leaks: Array = []
	for intent in keeper_intents:
		if AnimationSet.allowed(intent, AnimationSet.Role.OUTFIELD):
			leaks.append(intent)
	_check(leaks.is_empty(),
		"NO goalkeeper intent is selectable by an outfield role: %s" % [leaks])

	var reverse: Array = []
	for intent in outfield_intents:
		if AnimationSet.allowed(intent, AnimationSet.Role.GOALKEEPER):
			reverse.append(intent)
	_check(reverse.is_empty(),
		"and no outfield intent is selectable by a keeper: %s" % [reverse])


## The same property through the controller, which is what call sites hit.
func _test_role_refusals() -> void:
	var striker := AnimationController.new()
	add_child(striker)
	striker.set_visual("gold_ship")
	striker.set_keeper(false)
	var keeper := AnimationController.new()
	add_child(keeper)
	keeper.set_visual("tokai_teio")
	keeper.set_keeper(true)
	await get_tree().process_frame

	var played_by_striker: Array = []
	for intent in AnimationSet.INTENTS:
		if AnimationSet.INTENTS[intent]["role"] != AnimationSet.Role.GOALKEEPER:
			continue
		var before: int = striker.actions_fired
		striker.play_action(intent)
		if striker.actions_fired != before:
			played_by_striker.append(intent)
	_check(played_by_striker.is_empty(),
		"a striker asked for every keeper intent plays none of them: %s" % [played_by_striker])
	_check(striker.refusals > 0, "...and the refusals are counted (%d)" % striker.refusals)

	var played_by_keeper: Array = []
	# Genuinely outfield-only skills. "tripped"/"get_up" are Role.ANY: being
	# knocked over is not a position's skill.
	for intent in ["challenge_slide", "shoot_running", "trap", "header"]:
		var before: int = keeper.actions_fired
		keeper.play_action(intent)
		if keeper.actions_fired != before:
			played_by_keeper.append(intent)
	_check(played_by_keeper.is_empty(),
		"and a keeper cannot slide-tackle or volley: %s" % [played_by_keeper])

	# The keeper must still be able to do its own job.
	var before_save: int = keeper.actions_fired
	keeper.play_action("save_left")
	_check(keeper.actions_fired == before_save + 1 and keeper.last_action == "save_left",
		"a keeper CAN still dive ('%s')" % keeper.last_action)

	striker.queue_free()
	keeper.queue_free()


# ---------------------------------------------------------------------------
# The visual artifact (brief section 1)
# ---------------------------------------------------------------------------

## Root cause: skinned meshes reported ~190m bounds because an AABB is never
## skinned, so the 0.01 bind-pose scale never reached it and the 7.38x height
## normalisation multiplied the error. The renderer fitted the directional
## shadow around those bounds.
func _test_render_bounds() -> void:
	var ac := AnimationController.new()
	add_child(ac)
	ac.set_visual("gold_ship")
	await get_tree().process_frame

	var visual: Node3D = ac.get_child(0)
	var skel: Skeleton3D = _find_skel(visual)
	_check(skel != null, "the model has a skeleton")
	if skel == null:
		ac.queue_free()
		return

	var checked := 0
	var worst := 0.0
	for c in skel.get_children():
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		checked += 1
		if mi.custom_aabb.size.length() < 0.0001:
			worst = INF
			continue
		worst = maxf(worst, (mi.global_transform.basis * mi.custom_aabb.size).length())
	_check(checked > 0, "the model has skinned meshes (%d)" % checked)
	_check(is_finite(worst), "every skinned mesh has explicit render bounds")
	# A 1.6m character. Generous, but three orders of magnitude below the
	# 190m that caused the artifact.
	_check(worst < 8.0,
		"render bounds are character-sized, not stadium-sized (%.2fm)" % worst)
	ac.queue_free()


# ---------------------------------------------------------------------------
# Slide tackles (brief sections 5-10)
# ---------------------------------------------------------------------------

## Ball on the tackler's approach line and short of the carrier, so the leg
## reaches it before the bodies meet: a clean tackle.
##
## The ball is deliberately NOT parked at the carrier's feet. A carrier who
## has possession runs the dribble spring, which holds the ball in front of
## THEM -- so a ball placed at 0.5m simply gets carried off the tackler's line
## and the slide arrives at a body instead. That produced FOUL_CONTACT, which
## is the correct answer to the situation that actually existed and the wrong
## answer to the one being tested.
func _test_slide_clean() -> void:
	var ctx: Dictionary = await _duel(Vector3(0, 0, 0), Vector3(-3.0, 0, 0), Vector3(-1.1, 0.16, 0))
	var tackler: FootballPlayer = ctx["tackler"]
	var ball: RigidBody3D = ctx["ball"]
	var start_speed: float = ball.linear_velocity.length()
	var outcome: int = await _run_slide(ctx)

	_check(outcome == SlideTackle.Outcome.CLEAN,
		"a slide onto the ball wins it cleanly (got %s)" % SlideTackle.outcome_name(outcome))
	_check(tackler.slide_played_ball, "...because the leg actually reached the ball")
	_check(ball.linear_velocity.length() > start_speed + 0.5,
		"...and the ball is knocked (%.2f m/s)" % ball.linear_velocity.length())
	_teardown(ctx)


## Ball far away, bodies converging: no ball was played, so significant
## contact is a foul rather than a tackle.
func _test_slide_foul() -> void:
	var ctx: Dictionary = await _duel(Vector3(0, 0, 0), Vector3(-3.0, 0, 0), Vector3(0, 0.16, 14.0))
	var tackler: FootballPlayer = ctx["tackler"]
	var carrier: FootballPlayer = ctx["carrier"]
	var fouls: Array = []
	carrier.fouled.connect(func(info): fouls.append(info))
	var outcome: int = await _run_slide(ctx)

	_check(outcome == SlideTackle.Outcome.FOUL,
		"a slide that hits the player and not the ball is a foul (got %s)" % SlideTackle.outcome_name(outcome))
	_check(not tackler.slide_played_ball, "...the ball was never played")
	_check(tackler.slide_hit_player, "...and the bodies really made contact")
	_check(fouls.size() == 1, "a foul event is emitted exactly once (%d)" % fouls.size())
	_check(carrier.stumble_time > 0.0, "...and the fouled player goes down")

	# Section 9: nothing may permanently freeze a player.
	for i in range(int((SlideTackle.STUMBLE_TIME + 1.0) * 60.0)):
		await get_tree().physics_frame
	_check(carrier.stumble_time <= 0.0, "...and gets back up again (%.2fs left)" % carrier.stumble_time)
	_check(not tackler.is_sliding and tackler.slide_recovery <= 0.0,
		"the tackler also recovers rather than staying on the floor")
	_teardown(ctx)


## Aimed at nothing: the slide runs its course and produces a miss.
func _test_slide_missed() -> void:
	var ctx: Dictionary = await _duel(Vector3(0, 0, 0), Vector3(-3.0, 0, 0), Vector3(0, 0.16, 14.0))
	var tackler: FootballPlayer = ctx["tackler"]
	var carrier: FootballPlayer = ctx["carrier"]
	# Point the slide away from everything.
	tackler.begin_slide(carrier)
	tackler.slide_direction = Vector3(0, 0, 1)
	var outcome: int = await _await_slide(tackler)

	_check(outcome == SlideTackle.Outcome.MISSED,
		"a slide into empty space simply misses (got %s)" % SlideTackle.outcome_name(outcome))
	_check(not tackler.slide_played_ball and not tackler.slide_hit_player,
		"...touching neither ball nor player")
	_check(carrier.stumble_time <= 0.0, "...and the carrier is untouched")
	_teardown(ctx)


## Section 10: a carrier who cuts away beats a committed slide.
func _test_slide_avoided() -> void:
	var ctx: Dictionary = await _duel(Vector3(0, 0, 0), Vector3(-3.0, 0, 0), Vector3(0.5, 0.16, 0))
	var tackler: FootballPlayer = ctx["tackler"]
	var carrier: FootballPlayer = ctx["carrier"]
	var ball: RigidBody3D = ctx["ball"]

	tackler.begin_slide(carrier)
	var locked: Vector3 = tackler.slide_direction
	# The carrier cuts away, taking the ball with them, AFTER the commitment.
	carrier.time_since_turn_touch = 0.0
	for i in range(3):
		await get_tree().physics_frame
	carrier.global_position += Vector3(0, 0, 3.2)
	ball.global_position += Vector3(0, 0, 3.2)
	var outcome: int = await _await_slide(tackler)

	_check(tackler.slide_direction.distance_to(locked) < 0.001,
		"a committed slide cannot re-aim at a carrier who moved")
	_check(outcome == SlideTackle.Outcome.AVOIDED or outcome == SlideTackle.Outcome.MISSED,
		"...so the carrier beats it (got %s)" % SlideTackle.outcome_name(outcome))
	_check(not tackler.slide_played_ball, "...and the ball is not won")
	_teardown(ctx)


## The animation must never be what decides the outcome.
func _test_animation_does_not_decide() -> void:
	var ctx: Dictionary = await _duel(Vector3(0, 0, 0), Vector3(-3.0, 0, 0), Vector3(0, 0.16, 14.0))
	var tackler: FootballPlayer = ctx["tackler"]
	var carrier: FootballPlayer = ctx["carrier"]

	# Play the slide-tackle clip with no slide underneath it at all.
	var before: int = tackler.last_slide_outcome
	tackler.animation_controller.play_action("challenge_slide")
	for i in range(30):
		await get_tree().physics_frame
	_check(tackler.last_slide_outcome == before,
		"playing the tackle animation on its own resolves no tackle")
	_check(not tackler.is_sliding, "...and does not put the player into a slide")
	_check(carrier.stumble_time <= 0.0, "...and knocks nobody over")
	_teardown(ctx)


# ---------------------------------------------------------------------------
# A whole match (brief sections 14, 16, 17)
# ---------------------------------------------------------------------------

func _test_live_match_safety() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var outcomes := {}
	for p in players:
		p.slide_resolved.connect(func(info): outcomes[info["outcome_name"]] = outcomes.get(info["outcome_name"], 0) + 1)

	for i in range(60 * 60):
		await get_tree().physics_frame

	# Role leakage, measured over a real match rather than argued about.
	var refusals := 0
	var refused_what: Array = []
	var keeper_clip_on_outfield: Array = []
	for p in players:
		var ac: AnimationController = p.animation_controller
		if ac == null:
			continue
		refusals += ac.refusals
		if ac.refusals > 0:
			# Name it, so a recurrence is diagnosable instead of just a count.
			refused_what.append("%s(%s) x%d wanted '%s'" % [
				p.name, "GK" if p.is_goalkeeper else "OUT", ac.refusals, ac.last_refusal])
		if not p.is_goalkeeper and ac.last_action != "" \
			and AnimationSet.INTENTS.has(ac.last_action) \
			and AnimationSet.INTENTS[ac.last_action]["role"] == AnimationSet.Role.GOALKEEPER:
			keeper_clip_on_outfield.append(p.name)
	_check(refusals == 0, "over a match, nothing asked for an intent of the wrong role (%d) %s" % [
		refusals, refused_what])
	_check(keeper_clip_on_outfield.is_empty(),
		"and no outfield player ended on a keeper clip: %s" % [keeper_clip_on_outfield])

	# Nobody stuck (section 14).
	var stuck: Array = []
	for p in players:
		if p.is_sliding and p.slide_time > SlideTackle.SLIDE_DURATION + 0.5:
			stuck.append("%s sliding %.1fs" % [p.name, p.slide_time])
		if p.stumble_time > SlideTackle.STUMBLE_TIME + 0.1:
			stuck.append("%s stumbling %.1fs" % [p.name, p.stumble_time])
		if not is_finite(p.global_position.x) or p.global_position.y < -5.0:
			stuck.append("%s left the world at %s" % [p.name, p.global_position])
	_check(stuck.is_empty(), "no player is stuck in a state or off the map: %s" % [stuck])

	var total := 0
	for k in outcomes:
		total += outcomes[k]
	print("V0_9_2_1: slide outcomes over 60s: %s" % [outcomes])
	_check(total > 0, "slide tackles actually happen in a match (%d)" % total)

	var ball: RigidBody3D = main.ball
	_check(is_finite(ball.global_position.x) and ball.global_position.y > -5.0,
		"the ball is still in the world (%s)" % ball.global_position)
	main.queue_free()


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

## Two opposed players and a ball, with the tackler running at the carrier.
func _duel(carrier_pos: Vector3, tackler_pos: Vector3, ball_pos: Vector3) -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	ball.global_position = ball_pos
	await get_tree().physics_frame

	var carrier: FootballPlayer = PlayerScene.instantiate()
	add_child(carrier)
	carrier.global_position = carrier_pos + Vector3(0, 1, 0)
	carrier.team_id = 0
	carrier.formation_role = "CM"

	var tackler: FootballPlayer = PlayerScene.instantiate()
	add_child(tackler)
	tackler.global_position = tackler_pos + Vector3(0, 1, 0)
	tackler.team_id = 1
	tackler.formation_role = "CB"
	await get_tree().physics_frame
	carrier.set_match_context([carrier], [tackler])
	tackler.set_match_context([tackler], [carrier])

	# The tackler is running at the carrier, which is a precondition for
	# committing to a slide at all.
	var toward: Vector3 = (carrier.global_position - tackler.global_position).normalized()
	tackler.velocity = toward * SlideTackle.SLIDE_SPEED
	for i in range(4):
		await get_tree().physics_frame
	return {"field": field, "ball": ball, "carrier": carrier, "tackler": tackler}


## Commit and run to resolution.
func _run_slide(ctx: Dictionary) -> int:
	var tackler: FootballPlayer = ctx["tackler"]
	tackler.begin_slide(ctx["carrier"])
	return await _await_slide(tackler)


func _await_slide(tackler: FootballPlayer) -> int:
	var limit: int = int((SlideTackle.SLIDE_DURATION + 1.0) * 60.0)
	for i in range(limit):
		SlideTackle.update([tackler], _ball_of(tackler), get_physics_process_delta_time())
		await get_tree().physics_frame
		if not tackler.is_sliding:
			return tackler.last_slide_outcome
	return SlideTackle.Outcome.NONE


func _ball_of(_p: FootballPlayer) -> RigidBody3D:
	for c in get_children():
		if c is RigidBody3D:
			return c
	return null


func _teardown(ctx: Dictionary) -> void:
	for k in ["field", "ball", "carrier", "tackler"]:
		var n = ctx.get(k)
		if n != null and is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find_skel(c)
		if r != null:
			return r
	return null
