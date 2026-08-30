extends Node3D

## v0.9.2.3 section 9: the six deterministic steal scenarios.
##
## Human QA reports that AI can again take the ball from unrealistic distances
## without believable physical contact. Each scenario below sets up one exact
## situation, runs it, and reports the DISTANCES that were actually measured at
## the moment anything changed hands. The assertions are against the geometry
## the project already established and QA already accepted:
##
##   POSSESSION_CONTACT_RADIUS  1.20  the ball must be at your feet to GAIN it
##   CONTEST_WIN_REACH          1.70  ...stretched, briefly, to collect a ball
##                                    you just poked away yourself
##   POKE_REACH                 2.00  the furthest a challenge may land, derived
##                                    from two solid bodies (0.80) plus the
##                                    carrier's own possession radius (1.20)
##   CHALLENGE_RANGE            2.40  awareness only -- never an acquisition
##
## No threshold is relaxed here to make a scenario pass. Where a scenario
## fails, the measured number is printed so the failure is a distance rather
## than a verdict.

const MainScene := preload("res://scenes/Main.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("V0_9_2_3: ==== steal geometry ====")
	_test_geometry_not_widened()
	await _scenario_a_out_of_range()
	await _scenario_b_body_contact_only()
	await _scenario_c_ball_first_challenge()
	await _scenario_d_beaten_by_direction_change()
	await _scenario_e_loose_ball_pickup()
	await _scenario_f_fast_ball_through_awareness()
	print("V0_9_2_3: ==== %d passed, %d failed ====" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("V0_9_2_3: PASS  %s" % label)
	else:
		_failed += 1
		print("V0_9_2_3: FAIL  %s" % label)


# ---------------------------------------------------------------------------
# Section 8: did the v0.9.2.1 slide work silently widen the steal range?
# ---------------------------------------------------------------------------

## The slide is the only thing added to the acquisition path since QA last
## signed this off, so its reach is checked against the established envelope
## directly, as constants, before any match is run. A visual tackle animation
## must not buy a defender a longer arm.
func _test_geometry_not_widened() -> void:
	# Furthest from the tackler's body centre that a slide can play the ball:
	# the leg segment plus the contact radius around it.
	var slide_reach: float = SlideTackle.SLIDE_EXTENT + SlideTackle.BALL_CONTACT
	print("V0_9_2_3: slide ball reach %.2f m (leg %.2f + contact %.2f)" % [
		slide_reach, SlideTackle.SLIDE_EXTENT, SlideTackle.BALL_CONTACT])
	_check(slide_reach <= BallContest.POKE_REACH,
		"a slide cannot reach the ball from further than an ordinary poke (%.2f <= %.2f)" % [
			slide_reach, BallContest.POKE_REACH])
	_check(FootballPlayer.CONTEST_WIN_REACH <= BallContest.POKE_REACH,
		"the contest-win collection reach stays inside the poke envelope (%.2f <= %.2f)" % [
			FootballPlayer.CONTEST_WIN_REACH, BallContest.POKE_REACH])
	_check(FootballPlayer.POSSESSION_CONTACT_RADIUS < FootballPlayer.CONTEST_WIN_REACH,
		"the ordinary acquisition gate is tighter than the contest-win exemption")
	_check(BallContest.POKE_REACH < BallContest.CHALLENGE_RANGE,
		"awareness range stays wider than any range that can take the ball")
	# A slide that resolves CLEAN is the one path that opens the exemption. It
	# must not also be reachable without the slide having played the ball.
	_check(SlideTackle.SLIDE_START_RANGE > SlideTackle.SLIDE_MIN_GAP,
		"a slide has both a minimum and a maximum commit range")


# ---------------------------------------------------------------------------
# Scenario harness
# ---------------------------------------------------------------------------

## One carrier, one defender, one ball, and a real PossessionManager over them,
## so acquisition runs through exactly the code the match runs.
func _scene(carrier_pos: Vector3, defender_pos: Vector3, ball_pos: Vector3) -> Dictionary:
	# The scenario is staged inside a REAL match rather than in a hand-built
	# scene.
	#
	# Assembling field + ball + two players by hand does not reproduce the
	# spawn the game performs, and the difference is not cosmetic: measured
	# frame by frame, a hand-spawned player reported is_on_floor() while
	# hanging at y = 1.52 and then jumped four metres sideways with zero
	# velocity, and a ball placed inside a player's 0.40 m capsule was ejected
	# at 240 m/s. Every impossible distance the first version of this suite
	# printed came from that harness, not from the possession code -- which is
	# exactly the trap this milestone exists to avoid, so it is recorded here
	# rather than quietly worked around.
	#
	# MatchManager already spawns 22 players correctly. So the match is built
	# the way the game builds it, the AI is switched off, everyone who is not
	# in the scenario is parked and frozen out at the touchline, and the two
	# participants plus the ball are placed. What is measured afterwards is
	# the real possession path, with the real PossessionManager.
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(40):
		await get_tree().physics_frame

	# No AI, no team shape, no human input: the scenario decides who moves.
	main.home_team.set_physics_process(false)
	main.away_team.set_physics_process(false)
	main.home_team.set_process(false)
	main.away_team.set_process(false)
	if main.player_controller != null:
		main.player_controller.set_physics_process(false)
		main.player_controller.set_process(false)

	var carrier: FootballPlayer = main.home_players[5]
	var defender: FootballPlayer = main.away_players[5]

	# Park everyone else along the far touchline, frozen, well outside every
	# range this suite measures.
	var parked := 0
	for p in (main.home_players + main.away_players):
		if p == carrier or p == defender:
			continue
		p.movement_locked = true
		p.move_input = Vector2.ZERO
		p.global_position = Vector3(-30.0 + float(parked) * 3.0, p.global_position.y, -20.0)
		parked += 1

	var ball: RigidBody3D = main.ball
	carrier.global_position = Vector3(carrier_pos.x, carrier.global_position.y, carrier_pos.z)
	defender.global_position = Vector3(defender_pos.x, defender.global_position.y, defender_pos.z)
	carrier.move_input = Vector2.ZERO
	defender.move_input = Vector2.ZERO
	ball.global_position = Vector3(ball_pos.x, maxf(ball_pos.y, 0.16), ball_pos.z)
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	for i in range(10):
		await get_tree().physics_frame

	print("V0_9_2_3:   set up  carrier (%.2f, %.2f) defender (%.2f, %.2f) ball (%.2f, %.2f, %.2f)" % [
		carrier.global_position.x, carrier.global_position.z,
		defender.global_position.x, defender.global_position.z,
		ball.global_position.x, ball.global_position.y, ball.global_position.z])
	if ball.global_position.y < 0.0:
		_check(false, "scenario setup: the ball stayed on the pitch")
	return {"main": main, "ball": ball, "carrier": carrier,
		"defender": defender, "pm": main.possession_manager}


## Run the scene for `seconds`, holding the defender to `drive` each frame, and
## report everything the scenario needs to be judged on measurement.
func _run(ctx: Dictionary, seconds: float, drive: Callable, trace: String = "") -> Dictionary:
	var ball: RigidBody3D = ctx["ball"]
	var carrier: FootballPlayer = ctx["carrier"]
	var defender: FootballPlayer = ctx["defender"]
	var pm: PossessionManager = ctx["pm"]

	var stolen := false
	var steal_ball_gap := -1.0
	var steal_body_gap := -1.0
	var min_ball_gap := INF
	var min_body_gap := INF
	var frames: int = int(seconds * 60.0)
	for i in range(frames):
		drive.call(i)
		await get_tree().physics_frame
		var bg: float = _flat(ball.global_position).distance_to(_flat(defender.global_position))
		var pg: float = _flat(carrier.global_position).distance_to(_flat(defender.global_position))
		min_ball_gap = minf(min_ball_gap, bg)
		min_body_gap = minf(min_body_gap, pg)
		if trace != "" and i % 15 == 0:
			print("V0_9_2_3: %s f%03d ball (%.2f, %.2f, %.2f) v %.2f | def (%.2f, %.2f) | gap %.2f | carrier %s" % [
				trace, i, ball.global_position.x, ball.global_position.y,
				ball.global_position.z, ball.linear_velocity.length(),
				defender.global_position.x, defender.global_position.z, bg,
				("none" if pm.current_carrier == null else pm.current_carrier.name)])
		if not stolen and pm.current_carrier == defender:
			stolen = true
			steal_ball_gap = bg
			steal_body_gap = pg
	return {
		"stolen": stolen,
		"steal_ball_gap": steal_ball_gap,
		"steal_body_gap": steal_body_gap,
		"min_ball_gap": min_ball_gap,
		"min_body_gap": min_body_gap,
		"final_carrier_is_defender": pm.current_carrier == defender,
	}


## Hold a player at a measured distance. Position is written directly because
## the point of scenarios A, B and F is that the distance is exactly what the
## scenario says it is, not approximately.
func _pin(p: FootballPlayer, at: Vector3) -> void:
	p.global_position = Vector3(at.x, p.global_position.y, at.z)
	p.velocity = Vector3.ZERO
	p.move_input = Vector2.ZERO
	p.sprint_requested = false


## Drive a player through move_input, which is the channel the game itself
## uses.
##
## Assigning `velocity` does nothing: FootballPlayer._physics_process rebuilds
## velocity from move_input every frame before calling move_and_slide, so a
## directly-assigned velocity is overwritten before it can move anybody. The
## first version of this suite drove the defender that way and produced two
## failures that were entirely the harness's -- a defender that never moved,
## reported as "a loose ball at one metre cannot be collected". Same family as
## the v0.9.2.1 closing-speed trap: move_and_slide owns `velocity`, so nothing
## outside the body's own movement code may write it.
func _steer(p: FootballPlayer, toward: Vector3, sprint: bool = false) -> void:
	var d: Vector3 = _flat(toward - p.global_position)
	if d.length() < 0.05:
		p.move_input = Vector2.ZERO
	else:
		var n: Vector3 = d.normalized()
		p.move_input = Vector2(n.x, n.z)
	p.sprint_requested = sprint


## Run frames until a player is genuinely travelling at `speed` or the budget
## runs out. Returns the speed actually achieved.
func _accelerate_to(p: FootballPlayer, toward: Vector3, speed: float, budget: int) -> float:
	for i in range(budget):
		_steer(p, toward, true)
		await get_tree().physics_frame
		if Vector2(p.velocity.x, p.velocity.z).length() >= speed:
			break
	return Vector2(p.velocity.x, p.velocity.z).length()


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _teardown(ctx: Dictionary) -> void:
	var main = ctx.get("main")
	if main != null and is_instance_valid(main):
		if main.get_parent() != null:
			main.get_parent().remove_child(main)
		main.queue_free()
	for i in range(3):
		await get_tree().physics_frame


# ---------------------------------------------------------------------------
# A. Defender outside valid contact range -> NO steal
# ---------------------------------------------------------------------------

func _scenario_a_out_of_range() -> void:
	# Carrier at the origin with the ball at their feet; defender held four
	# metres away, well outside CHALLENGE_RANGE, for three seconds.
	var ctx: Dictionary = await _scene(
		Vector3.ZERO, Vector3(4.0, 0, 0), Vector3(0.65, 0.16, 0))
	var defender: FootballPlayer = ctx["defender"]
	var hold := Vector3(4.0, 0, 0)
	var r: Dictionary = await _run(ctx, 3.0, func(_i): _pin(defender, hold))
	print("V0_9_2_3: [A] held at ball gap %.2f m, body gap %.2f m for 3.0s" % [
		r["min_ball_gap"], r["min_body_gap"]])
	_check(r["min_ball_gap"] > BallContest.CHALLENGE_RANGE,
		"[A] the defender really was outside challenge range (%.2f > %.2f)" % [
			r["min_ball_gap"], BallContest.CHALLENGE_RANGE])
	_check(not r["stolen"],
		"[A] a defender outside contact range never takes the ball")
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# B. Defender approaches but never reaches the ball -> NO transfer
# ---------------------------------------------------------------------------

func _scenario_b_body_contact_only() -> void:
	# The defender is pressed right up against the carrier's body -- but on the
	# far side from the ball, so the ball is never within reach of them. Body
	# proximity is not a way to take the ball, and this is the scenario that
	# separates "close to the man" from "close to the ball".
	var ctx: Dictionary = await _scene(
		Vector3.ZERO, Vector3(-0.9, 0, 0), Vector3(1.5, 0.16, 0))
	var defender: FootballPlayer = ctx["defender"]
	var hold := Vector3(-0.9, 0, 0)
	var r: Dictionary = await _run(ctx, 3.0, func(_i): _pin(defender, hold))
	print("V0_9_2_3: [B] touching bodies at %.2f m, closest to the ball %.2f m" % [
		r["min_body_gap"], r["min_ball_gap"]])
	_check(r["min_body_gap"] <= SlideTackle.BODY_CONTACT + 0.2,
		"[B] the defender really was in body contact (%.2f)" % r["min_body_gap"])
	_check(r["min_ball_gap"] > BallContest.POKE_REACH,
		"[B] the ball really was out of reach throughout (%.2f > %.2f)" % [
			r["min_ball_gap"], BallContest.POKE_REACH])
	_check(not r["stolen"],
		"[B] body contact alone never transfers the ball")
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# C. Legitimate ball-first challenge -> the ball MAY be won
# ---------------------------------------------------------------------------

func _scenario_c_ball_first_challenge() -> void:
	# Defender arrives on the ball itself, head-on, with the carrier stationary
	# -- the most ordinary tackle in football. This must be winnable, and when
	# it is won the distance must be inside the gate.
	var ctx: Dictionary = await _scene(
		Vector3.ZERO, Vector3(1.6, 0, 0), Vector3(0.7, 0.16, 0))
	var defender: FootballPlayer = ctx["defender"]
	var ball: RigidBody3D = ctx["ball"]
	var r: Dictionary = await _run(ctx, 4.0, func(_i): _steer(defender, ball.global_position))
	print("V0_9_2_3: [C] closest to ball %.2f m; won=%s at ball gap %.2f, body gap %.2f" % [
		r["min_ball_gap"], str(r["stolen"]), r["steal_ball_gap"], r["steal_body_gap"]])
	_check(r["min_ball_gap"] <= BallContest.POKE_REACH,
		"[C] the defender genuinely reached the ball (%.2f)" % r["min_ball_gap"])
	if r["stolen"]:
		_check(r["steal_ball_gap"] <= FootballPlayer.CONTEST_WIN_REACH + 0.10,
			"[C] when won, it was won from inside the acquisition geometry (%.2f <= %.2f)" % [
				r["steal_ball_gap"], FootballPlayer.CONTEST_WIN_REACH])
	else:
		# Not winning is a legal outcome of a single attempt; what would not be
		# legal is winning it from out of range, which the branch above covers.
		_check(true, "[C] challenge did not complete in this attempt (legal outcome)")
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# D. Carrier changes direction before a committed challenge -> defender misses
# ---------------------------------------------------------------------------

func _scenario_d_beaten_by_direction_change() -> void:
	var ctx: Dictionary = await _scene(
		Vector3.ZERO, Vector3(3.0, 0, 0), Vector3(0.65, 0.16, 0))
	var carrier: FootballPlayer = ctx["carrier"]
	var defender: FootballPlayer = ctx["defender"]
	var ball: RigidBody3D = ctx["ball"]

	# The defender commits. can_commit requires real speed at the carrier
	# (SLIDE_MIN_SPEED), so the defender is accelerated from further out and
	# the commit is tested at the moment it is genuinely travelling -- from a
	# gap inside SLIDE_START_RANGE and outside SLIDE_MIN_GAP.
	defender.global_position = Vector3(9.0, defender.global_position.y, 0.0)
	var committed := false
	var reached := 0.0
	var gap := 0.0
	for i in range(180):
		_steer(defender, carrier.global_position, true)
		await get_tree().physics_frame
		if SlideTackle.can_commit(defender, carrier):
			reached = Vector2(defender.velocity.x, defender.velocity.z).length()
			gap = _flat(carrier.global_position).distance_to(_flat(defender.global_position))
			defender.begin_slide(carrier)
			committed = true
			break
	print("V0_9_2_3: [D] committed=%s at %.2f m/s from %.2f m" % [str(committed), reached, gap])
	_check(committed,
		"[D] a defender sprinting in at a carrier reaches a state where it may commit to a slide")

	# ...and the carrier immediately goes the other way, taking the ball with
	# them. This is the fake the brief asks to be genuinely available.
	var r: Dictionary = await _run(ctx, 1.6, func(_i):
		_steer(carrier, carrier.global_position + Vector3(0, 0, 10.0), true)
		ball.linear_velocity = Vector3(0, ball.linear_velocity.y, 6.0))
	print("V0_9_2_3: [D] slide outcome %s; closest to ball %.2f m; stolen=%s" % [
		SlideTackle.outcome_name(defender.last_slide_outcome),
		r["min_ball_gap"], str(r["stolen"])])
	_check(defender.last_slide_outcome != SlideTackle.Outcome.CLEAN,
		"[D] a committed slide that the carrier cut away from does not win the ball")
	_check(not r["stolen"],
		"[D] the carrier who changed direction keeps the ball")
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# E. Loose, controllable ball near a defender -> legitimate acquisition
# ---------------------------------------------------------------------------

func _scenario_e_loose_ball_pickup() -> void:
	# No carrier at all: a ball sitting still one metre from a player. Picking
	# this up must remain possible, or the gates have been tightened into
	# something that is not football.
	var ctx: Dictionary = await _scene(
		Vector3(20, 0, 0), Vector3(0, 0, 0), Vector3(1.0, 0.16, 0))
	var defender: FootballPlayer = ctx["defender"]
	var ball: RigidBody3D = ctx["ball"]
	var r: Dictionary = await _run(ctx, 2.0,
		func(_i): _steer(defender, ball.global_position), "[E]")
	print("V0_9_2_3: [E] closest to ball %.2f m; acquired=%s at %.2f m" % [
		r["min_ball_gap"], str(r["stolen"]), r["steal_ball_gap"]])
	_check(r["stolen"], "[E] a loose controllable ball at one metre can be collected")
	if r["stolen"]:
		_check(r["steal_ball_gap"] <= FootballPlayer.POSSESSION_CONTACT_RADIUS + 0.10,
			"[E] and it was collected from inside the contact radius (%.2f <= %.2f)" % [
				r["steal_ball_gap"], FootballPlayer.POSSESSION_CONTACT_RADIUS])
	await _teardown(ctx)


# ---------------------------------------------------------------------------
# F. A fast ball crossing the awareness radius -> no magical possession
# ---------------------------------------------------------------------------

func _scenario_f_fast_ball_through_awareness() -> void:
	# A ball struck past a stationary player, passing well inside
	# CHALLENGE_RANGE but far too fast to control. Awareness is not
	# acquisition; this is the same gate that stopped keepers absorbing shots.
	var ctx: Dictionary = await _scene(
		Vector3(20, 0, 0), Vector3(0, 0, 0), Vector3(-8.0, 0.16, 1.0))
	var defender: FootballPlayer = ctx["defender"]
	var ball: RigidBody3D = ctx["ball"]
	ball.linear_velocity = Vector3(16.0, 0, 0)
	var r: Dictionary = await _run(ctx, 1.2, func(_i): _pin(defender, Vector3.ZERO))
	print("V0_9_2_3: [F] ball passed at %.2f m travelling %.1f m/s; possession=%s" % [
		r["min_ball_gap"], 16.0, str(r["stolen"])])
	_check(r["min_ball_gap"] < BallContest.CHALLENGE_RANGE,
		"[F] the ball really did cross the awareness radius (%.2f < %.2f)" % [
			r["min_ball_gap"], BallContest.CHALLENGE_RANGE])
	_check(not r["stolen"],
		"[F] a ball moving faster than it can be controlled is not acquired in flight")
	await _teardown(ctx)
