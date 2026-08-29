extends Node3D

## v0.9.1.1 decision-quality suite (brief sections 5-10).
##
## The scenario battery as pass/fail. Its diagnostic twin,
## diag_decision_scenarios.gd, prints the full decision record for each of
## these situations -- read that when one of these disagrees with expectation,
## because it shows every candidate action, its utility, and why the losers
## lost.
##
## What is asserted is CONTEXTUAL CORRECTNESS, not a fixed action per
## scenario: the brief is explicit that a good chance should strongly (not
## absolutely) dominate a backward pass, that passing must still win when
## passing is better, and that backward passes must remain available when
## they are the right football.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

const FWD := Vector3(1, 0, 0)

var _passed := 0
var _failed := 0


func _ready() -> void:
	await _test_scenarios()
	await _test_opportunity_is_contextual()
	await _test_no_shot_spam_from_range()
	await _test_personality_does_not_override_football()
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


# ------------------------------------------------------- the seven scenarios

func _test_scenarios() -> void:
	# A: central, close, clear lane -- a chance that must be taken.
	var a: Dictionary = await _decide(Vector3(22, 1, 0), [], [])
	_check("A. A clear central chance is SHOT, not given away (chose %s, opportunity %.2f)"
		% [a.get("chosen"), a.get("opportunity", 0.0)], a.get("chosen") == "SHOOT")
	_check("A. ...and the chance is recognised as a good one (%.2f)" % a.get("opportunity", 0.0),
		a.get("opportunity", 0.0) > 0.4)

	# B: same position, defender directly in the lane, open teammate wide.
	var b: Dictionary = await _decide(Vector3(22, 1, 0), [Vector3(24.5, 1, 0)], [Vector3(21, 1, -7)])
	_check("B. A blocked lane is not shot through (chose %s)" % b.get("chosen"),
		b.get("chosen") != "SHOOT")

	# C: extreme angle near the byline, open central teammate.
	var c: Dictionary = await _decide(Vector3(27, 1, 13), [], [Vector3(22, 1, 0)])
	_check("C. A terrible angle is not shot from (chose %s, opportunity %.2f)"
		% [c.get("chosen"), c.get("opportunity", 0.0)], c.get("chosen") != "SHOOT")
	_check("C. ...and the situation is scored as a poor chance (%.2f)" % c.get("opportunity", 0.0),
		c.get("opportunity", 0.0) < 0.2)

	# D: only the keeper ahead. Shooting or running at them are both football;
	#    giving it backwards is not.
	var d: Dictionary = await _decide(Vector3(20, 1, 0), [], [])
	_check("D. A 1v1 is taken on -- shoot or run at them, never a pass back (chose %s)"
		% d.get("chosen"), d.get("chosen") == "SHOOT" or d.get("chosen") == "DRIBBLE")

	# E: two defenders on top of the carrier, a safe teammate available.
	var e: Dictionary = await _decide(Vector3(5, 1, 0),
		[Vector3(6.2, 1, 0.4), Vector3(5.4, 1, -1.2)], [Vector3(2, 1, -6)])
	_check("E. Under real pressure with an out, the ball is released (chose %s, pressure %.2f)"
		% [e.get("chosen"), e.get("pressure", 0.0)], e.get("chosen") == "PASS")

	# F: miles from goal with grass ahead.
	var f: Dictionary = await _decide(Vector3(-8, 1, 0), [], [Vector3(-10, 1, -8)])
	_check("F. In open field far from goal the AI carries, and does not shoot from absurd range (chose %s)"
		% f.get("chosen"), f.get("chosen") != "SHOOT")

	# G: forward lanes blocked, pressured, useful support behind. THE control
	#    case -- backward passes must not have been legislated away.
	var g: Dictionary = await _decide(Vector3(24, 1, 0),
		[Vector3(26, 1, 0), Vector3(25, 1, 3), Vector3(25, 1, -3)], [Vector3(17, 1, 0)])
	var g_progress: float = _progress_of(g)
	_check("G. A backward pass is still played when it is the right ball (chose %s, progress %+.2f)"
		% [g.get("chosen"), g_progress],
		g.get("chosen") == "PASS" and g_progress < 0.0)


# --------------------------------------------- opportunity is contextual

## The metric the brief asks for must actually respond to context rather than
## being a proxy for distance.
func _test_opportunity_is_contextual() -> void:
	var clear: Dictionary = await _decide(Vector3(22, 1, 0), [], [])
	var blocked: Dictionary = await _decide(Vector3(22, 1, 0), [Vector3(24.5, 1, 0)], [])
	var wide: Dictionary = await _decide(Vector3(22, 1, 14), [], [])

	_check("A blocked lane scores a worse chance than a clear one from the same spot (%.2f < %.2f)"
		% [blocked.get("opportunity", 0.0), clear.get("opportunity", 0.0)],
		blocked.get("opportunity", 1.0) < clear.get("opportunity", 0.0))
	_check("A wide angle scores a worse chance than a central one at the same range (%.2f < %.2f)"
		% [wide.get("opportunity", 0.0), clear.get("opportunity", 0.0)],
		wide.get("opportunity", 1.0) < clear.get("opportunity", 0.0))


# ------------------------------------------------------- no shot spam

## The brief's explicit warning: do not fix backward passes by making the AI
## shoot whenever it is near goal.
func _test_no_shot_spam_from_range() -> void:
	# Near goal but at a hopeless angle with a defender in the way.
	var bad: Dictionary = await _decide(Vector3(26, 1, 12), [Vector3(27, 1, 8)], [Vector3(22, 1, 0)])
	_check("Near goal but hopeless: still not a shot (chose %s, opportunity %.2f)"
		% [bad.get("chosen"), bad.get("opportunity", 0.0)], bad.get("chosen") != "SHOOT")

	# Well outside shooting range with nothing on.
	var far: Dictionary = await _decide(Vector3(0, 1, 0), [], [Vector3(-3, 1, -5)])
	_check("From 29m out the AI does not shoot (chose %s)" % far.get("chosen"),
		far.get("chosen") != "SHOOT")


# ------------------------------------------------- personality bounds

## Personality may shade a sensible decision; it must not replace football
## logic. Two extreme profiles in the same clear-chance situation must both
## still take the chance.
func _test_personality_does_not_override_football() -> void:
	var timid: Dictionary = await _decide(Vector3(22, 1, 0), [], [], {
		"confidence": 5.0, "risk_taking": 5.0, "competitiveness": 5.0})
	var bold: Dictionary = await _decide(Vector3(22, 1, 0), [], [], {
		"confidence": 95.0, "risk_taking": 95.0, "competitiveness": 95.0})
	# CORRECTED. This first demanded that BOTH profiles shoot, i.e. that
	# personality have no effect at all -- which contradicts the brief it was
	# written from: a conservative player is meant to be "slightly more
	# willing to retain/reset". Measured, the timid profile carries the ball
	# toward goal instead of striking it, which is retaining, not a failure.
	#
	# What the brief actually forbids is personality producing football
	# nonsense -- "open goal -> useless backward pass". So that is what is
	# asserted: both profiles must choose a FORWARD action, the bold one
	# takes the chance on, and neither gives the ball away backwards.
	_check("An extremely bold player takes a clear chance on (chose %s)" % bold.get("chosen"),
		bold.get("chosen") == "SHOOT")
	_check("An extremely cautious player still goes FORWARD, never backwards (chose %s)"
		% timid.get("chosen"),
		timid.get("chosen") == "SHOOT" or timid.get("chosen") == "DRIBBLE")
	_check("...and personality shifts the choice at most one step, never to a backward ball",
		timid.get("chosen") != "PASS" or _progress_of(timid) >= 0.0)

	# ...and neither shoots from a hopeless one.
	var bold_bad: Dictionary = await _decide(Vector3(27, 1, 14), [], [Vector3(22, 1, 0)], {
		"confidence": 95.0, "risk_taking": 95.0, "competitiveness": 95.0})
	_check("Even the boldest player does not shoot from a hopeless angle (chose %s)"
		% bold_bad.get("chosen"), bold_bad.get("chosen") != "SHOOT")


# ---------------------------------------------------------------- helpers

func _progress_of(d: Dictionary) -> float:
	for o in d.get("options", []):
		if o.get("action") == "PASS":
			return o.get("progress", 0.0)
	return 0.0


## Build the situation, run ONE real decision, return the decision record.
func _decide(carrier_pos: Vector3, opp_offsets: Array, mate_offsets: Array,
		traits: Dictionary = {}) -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier: FootballPlayer = _spawn(0, carrier_pos, "ST")
	await get_tree().physics_frame
	for k in traits.keys():
		carrier.personality.set(k, traits[k])
	var mates: Array = [carrier]
	for m in mate_offsets:
		mates.append(_spawn(0, m, "CM"))
		await get_tree().physics_frame
	var opps: Array = []
	for o in opp_offsets:
		opps.append(_spawn(1, o, "CB"))
		await get_tree().physics_frame
	var keeper: FootballPlayer = _spawn(1, Vector3(28.5, 1, 0), "GK")
	keeper.is_goalkeeper = true
	await get_tree().physics_frame
	opps.append(keeper)

	for m in mates:
		m.set_match_context(mates, opps)
	for o in opps:
		o.set_match_context(opps, mates)

	_seat(ball, carrier.global_position + FWD * 0.5 + Vector3(0, 0.35, 0))
	for i in range(30):
		carrier.move_input = Vector2.ZERO
		await get_tree().physics_frame

	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-29, 0, 0), Vector3(29, 0, 0))
	AIController._decide_possession_action(
		carrier, ball, Vector3(29, 0, 0), opps, FWD, plan, 1.0 / 60.0)
	var record: Dictionary = carrier.last_decision.duplicate(true)

	for n in ([field, ball] + mates + opps):
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	await get_tree().physics_frame
	return record


func _seat(ball: RigidBody3D, pos: Vector3) -> void:
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
	p.apply_player_data(TestRoster.home_team()[0] if team == 0 else TestRoster.away_team()[0])
	return p
