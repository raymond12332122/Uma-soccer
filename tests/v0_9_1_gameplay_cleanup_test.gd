extends Node3D

## v0.9.1 regression suite -- pre-animation gameplay cleanup.
##
## One block per QA complaint in the milestone brief. Every threshold here is
## a number that was MEASURED before anything was changed (the diagnostics
## are in tests/diag_*.gd and the measurements are quoted in the messages),
## so a future failure reads as a specific claim about the game rather than
## a bare boolean.
##
## Deliberately NOT here: anything about animation content. The brief says
## the pack is not integrated yet; what is asserted is that the EVENTS an
## animation layer will need exist and fire.

const MainScene := preload("res://scenes/Main.tscn")
const FieldScene := preload("res://scenes/Field.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const BallScene := preload("res://scenes/Ball.tscn")

## The furthest a challenger's centre can be from the ball and still be
## making a real tackle.
##
## NOT "capsule + leg + ball". That models reaching for a ball lying in open
## space, and it is what the first version of POKE_REACH got wrong -- in a
## tackle the carrier's body is IN THE WAY, and bodies are solid as of
## v0.9.1, so the challenger cannot get closer than two capsule radii to the
## carrier in the first place. Derived from the geometry instead:
##
##   0.80  two 0.4m capsules touching -- the closest two players can be
## + 1.20  POSSESSION_CONTACT_RADIUS, the furthest the ball can be from the
##         carrier and still be theirs to take
const PHYSICAL_REACH := 0.80 + 1.20

var _passed := 0
var _failed := 0


func _ready() -> void:
	await _test_pass_never_targets_an_opponent()
	await _test_human_intent_dominates_the_pass()
	await _test_pass_arrival_across_the_range()
	await _test_players_are_solid()
	await _test_ball_does_not_fling_players()
	await _test_action_radius_is_physical()
	await _test_animation_event_surface()
	await _test_live_match()
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


# ------------------------------------------------- 2. passing to opponents

## The milestone's "critical bug": bots playing the ball to the other team as
## though they were valid receivers.
##
## The fix is at candidate GENERATION -- an opponent never enters the set to
## be scored -- with an invariant at the exit as the assertion of last
## resort. So this feeds the evaluator a deliberately poisoned squad (every
## opponent listed as a teammate, which is exactly what a stale or
## mis-wired match context looks like) and requires the answer to still be
## a teammate or nothing at all.
func _test_pass_never_targets_an_opponent() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	await get_tree().physics_frame

	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 10), "CM")
	await get_tree().physics_frame
	var mate: FootballPlayer = _spawn(0, Vector3(0, 1, 1), "ST")
	await get_tree().physics_frame
	var opp_near: FootballPlayer = _spawn(1, Vector3(1.0, 1, 5), "CB")
	await get_tree().physics_frame
	var opp_open: FootballPlayer = _spawn(1, Vector3(-4, 1, 3), "CB")
	await get_tree().physics_frame

	# The poisoned context: opponents presented as teammates.
	passer.set_match_context([passer, mate, opp_near, opp_open], [])

	var trace: Array = []
	var opt: PassEvaluator.Option = PassEvaluator.best_option(
		passer, Vector3(0, 0, -1), Vector3(0, 0, -1), null,
		FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true, trace)

	_check("With opponents wrongly listed as teammates, the evaluator still refuses them",
		opt == null or opt.target == null or opt.target.team_id == passer.team_id)
	var dropped_for_team := 0
	for c in trace:
		if not c.get("kept", true) and String(c.get("reason", "")).begins_with("not a teammate"):
			dropped_for_team += 1
	_check("...and it rejects them at candidate generation, not as a late veto (%d dropped)"
		% dropped_for_team, dropped_for_team == 2)

	# The honest control: with a correct context the same geometry produces a
	# real pass, so the check above is not passing merely by refusing
	# everything.
	passer.set_match_context([passer, mate], [opp_near, opp_open])
	var good: PassEvaluator.Option = PassEvaluator.best_option(
		passer, Vector3(0, 0, -1), Vector3(0, 0, -1), null,
		FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
	_check("With a correct context the same position still finds its teammate",
		good != null and good.target == mate)

	_teardown([field, passer, mate, opp_near, opp_open])


# ------------------------------------------------ 1. human pass aim/intent

## "Human intent must dominate; no extreme aim assist."
##
## Measured before the change (diag_human_pass, aim-cone sweep): holding the
## stick dead forward with the only in-range teammate 72 degrees off to the
## left, the ball left the boot 66 degrees away from the aim. The cone is
## what decides whether the player pointed at that man at all.
func _test_human_intent_dominates_the_pass() -> void:
	_check("The aim cone is a cone, not a hemisphere (%.0f deg)"
		% rad_to_deg(acos(FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT)),
		FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT >= 0.5)

	for angle in [20.0, 45.0]:
		var r: Dictionary = await _aimed_pass_at_offset(angle)
		_check("A teammate %.0f deg off the aim is selected and struck accurately (ball %.1f deg off aim)"
			% [angle, r.get("angular_error", 999.0)],
			r.get("target") != null and r.get("angular_error", 999.0) < angle + 1.0)

	for angle in [70.0, 85.0]:
		var r: Dictionary = await _aimed_pass_at_offset(angle)
		_check("A teammate %.0f deg off the aim does NOT capture the pass; the ball goes where it was aimed (%.1f deg off)"
			% [angle, r.get("angular_error", 999.0)],
			r.get("target") == null and r.get("angular_error", 999.0) < 1.0)


## Fires one aimed human pass with a single teammate `angle` degrees off a
## dead-forward aim, and returns the emitted pass record.
func _aimed_pass_at_offset(angle: float) -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var aim := Vector3(0, 0, -1)
	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 10), "CM")
	await get_tree().physics_frame
	var off: Vector3 = aim.rotated(Vector3.UP, deg_to_rad(angle))
	var mate: FootballPlayer = _spawn(0, passer.global_position + off * 9.0, "ST")
	await get_tree().physics_frame
	passer.set_match_context([passer, mate], [])
	mate.set_match_context([passer, mate], [])

	_seat_ball(ball, passer.global_position + aim * 0.5 + Vector3(0, 0.35, 0))
	for i in range(12):
		await get_tree().physics_frame

	var rec: Array = []
	passer.pass_attempted.connect(func(info): rec.append(info))
	passer.move_input = Vector2(aim.x, aim.z)
	await get_tree().physics_frame
	passer.pass_requested = true
	for i in range(6):
		await get_tree().physics_frame

	_teardown([field, ball, passer, mate])
	return rec[0] if not rec.is_empty() else {}


# --------------------------------------------- 3. pass power and arrival

## A pass is judged by how it ARRIVES. One global launch speed cannot serve
## 4m and 16m, so the weight is solved from the distance -- this pins that
## the solve still lands the ball on the receiver at a controllable pace
## across the whole band, which is what stops a pass reading as either a
## weak scuff or a shot.
func _test_pass_arrival_across_the_range() -> void:
	for d in [4.0, 9.0, 16.0]:
		var v: float = PassEvaluator.speed_for_distance(d)
		var rolls: float = PassEvaluator.ROLL_PER_SPEED * v - PassEvaluator.ROLL_OFFSET
		_check("A %.0fm pass is struck at %.1f m/s and rolls %.1fm -- it reaches, without running away"
			% [d, v, rolls], rolls >= d - 0.5 and rolls <= d + 6.0)

	_check("Launch speed rises with distance rather than being one constant (%.1f -> %.1f m/s)"
		% [PassEvaluator.speed_for_distance(4.0), PassEvaluator.speed_for_distance(16.0)],
		PassEvaluator.speed_for_distance(16.0) > PassEvaluator.speed_for_distance(4.0) + 3.0)

	# Measured (diag_human_pass): arrival speed at the receiver was 4.8 m/s
	# over 4m, 3.3 over 9m and 3.8 over 16m -- a band a receiver can take,
	# and the reason the target is an ARRIVAL speed rather than a launch one.
	_check("The model aims for an arrival speed a receiver can control (%.1f m/s)"
		% PassEvaluator.PASS_ARRIVAL_SPEED,
		PassEvaluator.PASS_ARRIVAL_SPEED >= 2.0 and PassEvaluator.PASS_ARRIVAL_SPEED <= 5.0)

	_check("The whole pass band still sits below the shot band (%.1f < %.1f m/s)"
		% [PassEvaluator.PASS_SPEED_MAX * 1.1, FootballPlayer.SHOT_SPEED_MIN],
		PassEvaluator.PASS_SPEED_MAX * 1.1 < FootballPlayer.SHOT_SPEED_MIN)


# --------------------------------------------- 4. players phasing through

## "Defenders run through players." Root cause: FootballPlayer.tscn's
## collision mask was 5 (world + ball) and omitted layer 2, so twenty-two
## bodies passed straight through one another.
func _test_players_are_solid() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	await get_tree().physics_frame

	var a: FootballPlayer = _spawn(0, Vector3(-6, 1, 10), "CM")
	await get_tree().physics_frame
	var b: FootballPlayer = _spawn(1, Vector3(6, 1, 10), "CB")
	await get_tree().physics_frame
	a.set_match_context([a], [b])
	b.set_match_context([b], [a])

	_check("A player's collision mask includes the player layer",
		(a.collision_mask & 2) != 0)

	# Run them head-on into each other and watch whether either ends up on
	# the far side of the other.
	var closest := 999.0
	var crossed := false
	for i in range(180):
		a.move_input = Vector2(1, 0)
		b.move_input = Vector2(-1, 0)
		await get_tree().physics_frame
		closest = minf(closest, a.global_position.distance_to(b.global_position))
		if a.global_position.x > b.global_position.x:
			crossed = true

	_check("Two players running head-on do not pass through one another", not crossed)
	_check("...and they are stopped at roughly two body widths, not overlapped (%.2fm)" % closest,
		closest > 0.6)

	_teardown([field, a, b])


# ------------------------------------------------ 7. the ball flinging people

## "The ball sometimes flings players." A 0.45kg ball must never meaningfully
## move an ~70kg body. Fixed by making the interaction one-way: the ball's
## mask no longer includes the player layer, so the ball is deflected by
## players (they are on its layer's radar via their own mask) without the
## solver ever pushing a CharacterBody3D back.
func _test_ball_does_not_fling_players() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame
	var p: FootballPlayer = _spawn(0, Vector3(0, 1, 10), "CB")
	await get_tree().physics_frame
	p.set_match_context([p], [])

	_check("The ball's collision mask does not include the player layer",
		(ball.collision_mask & 2) == 0)

	var start: Vector3 = p.global_position
	# Fire the ball at the player as hard as the game can strike one.
	_seat_ball(ball, p.global_position + Vector3(0, 0.3, 8))
	await get_tree().physics_frame
	ball.linear_velocity = Vector3(0, 0, -FootballPlayer.SHOT_SPEED_MIN * 2.0)
	var max_shift := 0.0
	for i in range(120):
		await get_tree().physics_frame
		p.move_input = Vector2.ZERO
		max_shift = maxf(max_shift, Vector2(
			p.global_position.x - start.x, p.global_position.z - start.z).length())

	_check("A ball struck at %.0f m/s does not launch the player it hits (moved %.2fm)"
		% [FootballPlayer.SHOT_SPEED_MIN * 2.0, max_shift], max_shift < 0.5)

	_teardown([field, ball, p])


# ---------------------------------------- 5. unrealistic near kicks/pokes

## "Awareness radius may be large; ACTION radius must be physical."
##
## Measured over a 180s match (diag_contact_envelope): pokes landed at a
## maximum of 0.42m centre-to-ball, and acquisitions capped at 1.30m against
## a physical reach of 1.11m. What this pins is the separation of the layers
## -- a defender may notice the ball from 2.4m and close it down, but the
## moment they can DO something to it is bounded by a leg.
func _test_action_radius_is_physical() -> void:
	_check("Awareness reaches further than action (%.2fm vs %.2fm)"
		% [BallContest.CHALLENGE_RANGE, BallContest.POKE_REACH],
		BallContest.CHALLENGE_RANGE > BallContest.POKE_REACH)
	# Measured (diag_tackle_reach): in the canonical duel -- challenger 1.00m
	# behind a stationary carrier whose ball is 0.40m in front of them -- the
	# challenger sits 1.40m from the ball. A gate that excludes THAT excludes
	# the most ordinary tackle in football, which is exactly what the first
	# 1.11m version did, for six seconds and 5.33 of banked progress.
	_check("A completed challenge is bounded by the body geometry of a tackle (%.2fm vs a derived %.2fm)"
		% [BallContest.POKE_REACH, PHYSICAL_REACH],
		BallContest.POKE_REACH <= PHYSICAL_REACH + 0.01)
	_check("...and that bound still admits a defender pressed against the carrier (1.40m duel)",
		BallContest.POKE_REACH >= 1.40)
	_check("A stalled challenge cannot bank progress indefinitely (cap %.2fx)"
		% BallContest.PROGRESS_OVERFILL, BallContest.PROGRESS_OVERFILL <= 1.5)
	_check("A poke also requires facing the ball, not merely being near it (dot >= %.2f)"
		% BallContest.POKE_MIN_FACING, BallContest.POKE_MIN_FACING > -0.5)
	_check("Taking possession is bounded by contact, not by awareness (%.2fm)"
		% FootballPlayer.POSSESSION_CONTACT_RADIUS,
		FootballPlayer.POSSESSION_CONTACT_RADIUS <= BallContest.CHALLENGE_RANGE * 0.6)

	# The envelope is geometry, so it can be checked directly rather than
	# inferred from a match: a challenger beyond a leg's reach is not in it.
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame
	var d: FootballPlayer = _spawn(1, Vector3(0, 1, 10), "CB")
	await get_tree().physics_frame

	# In front of the defender: within_poke_envelope also asks whether they
	# are facing the ball. A stationary player's facing lives in
	# _facing_angle (the body itself never rotates), so it has to come from
	# facing_direction() -- reading the body basis is the bug this block
	# exists to catch.
	var facing: Vector3 = d.facing_direction()

	_seat_ball(ball, d.global_position + facing * 0.8 + Vector3(0, 0.2, 0))
	for i in range(5):
		await get_tree().physics_frame
	var near_ok: bool = BallContest.within_poke_envelope(d, ball)

	# Inside the 2.40m awareness radius but outside the tackle envelope --
	# the whole point of having two separate numbers.
	_seat_ball(ball, d.global_position + facing * 2.3 + Vector3(0, 0.2, 0))
	for i in range(5):
		await get_tree().physics_frame
	var far_ok: bool = BallContest.within_poke_envelope(d, ball)

	# Behind, and MOVING away -- the facing gate is deliberately only asked
	# of a challenger who is moving, because a stationary player's facing is
	# not maintained. See within_poke_envelope.
	_seat_ball(ball, d.global_position - facing * 0.8 + Vector3(0, 0.2, 0))
	d.velocity = facing * 4.0
	for i in range(5):
		d.velocity = facing * 4.0
		await get_tree().physics_frame
	var behind_ok: bool = BallContest.within_poke_envelope(d, ball)

	_check("A ball 0.8m in front is inside the poke envelope", near_ok)
	_check("A ball 2.3m away -- inside the awareness radius -- is NOT", not far_ok)
	_check("A ball 0.8m BEHIND a defender running away from it is not pokeable", not behind_ok)

	_teardown([field, ball, d])


# ------------------------------------------- 10. animation event readiness

## The pack is NOT integrated in this milestone. What is required is that
## every moment an animation layer will need to hook already exists as an
## event carrying enough context to drive a clip.
func _test_animation_event_surface() -> void:
	var p: FootballPlayer = PlayerScene.instantiate()
	for sig in ["ball_touched", "action_started", "action_released",
			"challenge_started", "possession_changed", "pass_attempted"]:
		_check("FootballPlayer exposes a `%s` event" % sig, p.has_signal(sig))
	p.free()

	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame
	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 10), "CM")
	await get_tree().physics_frame
	var mate: FootballPlayer = _spawn(0, Vector3(0, 1, 1), "ST")
	await get_tree().physics_frame
	passer.set_match_context([passer, mate], [])
	mate.set_match_context([passer, mate], [])

	var touches: Array = []
	var starts: Array = []
	var releases: Array = []
	var poss: Array = []
	passer.ball_touched.connect(func(i): touches.append(i))
	passer.action_started.connect(func(i): starts.append(i))
	passer.action_released.connect(func(i): releases.append(i))
	passer.possession_changed.connect(func(i): poss.append(i))

	_seat_ball(ball, passer.global_position + Vector3(0, 0.35, -0.5))
	for i in range(15):
		await get_tree().physics_frame
	_check("Winning the ball raises a possession event",
		poss.any(func(i): return i.get("kind") == "gained"))

	passer.move_input = Vector2(0, -1)
	await get_tree().physics_frame
	passer.pass_requested = true
	for i in range(8):
		await get_tree().physics_frame

	_check("A pass raises a wind-up event before contact", not starts.is_empty())
	_check("A pass raises a contact event", touches.any(
		func(i): return i.get("kind") == FootballPlayer.TouchKind.PASS))
	_check("A pass raises a release event once the ball has gone", not releases.is_empty())
	_check("Losing the ball raises a possession event",
		poss.any(func(i): return i.get("kind") == "lost"))

	if not touches.is_empty():
		var t: Dictionary = touches[touches.size() - 1]
		_check("A contact event carries everything a foot plant needs (point/direction/strength/velocity/foot)",
			t.has("point") and t.has("direction") and t.has("strength")
			and t.has("player_velocity") and t.has("foot"))

	_teardown([field, ball, passer, mate])


# ---------------------------------------------------------- live match

## The complaints are about a match, so the last block is a match. Nothing
## here is tuned; these are the things that must remain true while everything
## above is going on.
func _test_live_match() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var ball: RigidBody3D = main.ball
	var opponent_targets := 0
	var passes := 0
	var kick_seen := {}
	var worst_overlap := 999.0
	var pile_max := 0
	var acquisitions := 0
	var acquire_beyond_reach := 0
	var prev_has := {}

	for i in range(60 * 60):
		await get_tree().physics_frame

		for p in players:
			var seen: int = kick_seen.get(p, -1)
			if seen >= 0 and p.kick_count > seen and p.last_kick_kind == FootballPlayer.KickKind.PASS:
				passes += 1
				var t: FootballPlayer = p.last_kick_target
				if t != null and is_instance_valid(t) and t.team_id != p.team_id:
					opponent_targets += 1
			kick_seen[p] = p.kick_count

			var had: bool = prev_has.get(p, false)
			if p.has_possession and not had:
				acquisitions += 1
				if _flat(ball.global_position - p.global_position) > FootballPlayer.CONTEST_WIN_REACH:
					acquire_beyond_reach += 1
			prev_has[p] = p.has_possession

		# Body presence: nobody standing inside somebody else.
		if i % 10 == 0:
			for a in players:
				var near := 0
				for b in players:
					if a == b:
						continue
					var d: float = _flat(a.global_position - b.global_position)
					worst_overlap = minf(worst_overlap, d)
					if d < 3.0:
						near += 1
				pile_max = maxi(pile_max, near)

	_check("A real passage of play happened (%d passes)" % passes, passes > 5)
	_check("Not one pass was aimed at an opponent (%d of %d)" % [opponent_targets, passes],
		opponent_targets == 0)
	_check("No possession was gained from beyond a contest's reach (%d of %d)"
		% [acquire_beyond_reach, acquisitions], acquire_beyond_reach == 0)
	_check("Players keep their own space -- closest pair all match %.2fm" % worst_overlap,
		worst_overlap > 0.5)
	_check("No ten-player pile-up: most players within 3m of any one player was %d" % pile_max,
		pile_max <= 6)

	main.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- helpers

func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _seat_ball(ball: RigidBody3D, pos: Vector3) -> void:
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(Basis(), pos))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
		Vector3.ZERO)


func _spawn(team: int, pos: Vector3, role: String) -> FootballPlayer:
	var p: FootballPlayer = PlayerScene.instantiate()
	add_child(p)
	p.global_position = pos
	p.team_id = team
	p.formation_role = role
	p.formation_slot = Vector2(0.5, 0.5)
	return p


## Remove bodies from the tree BEFORE freeing them. queue_free is deferred,
## so the collision shapes of a torn-down block are still live while the next
## one is being built -- measured in diag_human_pass, a player placed on a
## clean pitch was lifted 1.19m by a leftover body and slid 6m off it.
func _teardown(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	await get_tree().physics_frame
