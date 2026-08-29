extends Node3D

## v0.9.1.1 decision scenario battery (brief section 8).
##
## Seven deterministic football situations. These matter more than aggregate
## match statistics for this milestone: a match average cannot tell you
## whether the AI took the RIGHT action in the situation a human watched it
## get wrong.
##
## This is the DIAGNOSTIC form -- it prints the full decision record for each
## scenario (every candidate action, its utility, and why the losers lost)
## and asserts nothing. The pass/fail suite is v0_9_1_1_decision_test.gd; this
## is what gets read when that suite disagrees with expectation.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

## Attacking toward +x, so the opponent goal is at +29.
const FWD := Vector3(1, 0, 0)


func _ready() -> void:
	await _scenario("A  obvious shot",
		Vector3(22, 1, 0), [], [], "SHOOT strongly preferred")
	await _scenario("B  blocked shot, open mate",
		Vector3(22, 1, 0), [Vector3(24.5, 1, 0)], [Vector3(21, 1, -7)],
		"PASS or reposition preferred")
	await _scenario("C  terrible angle, open central mate",
		Vector3(27, 1, 13), [], [Vector3(22, 1, 0)], "PASS can beat SHOOT")
	await _scenario("D  1v1 with the keeper",
		Vector3(20, 1, 0), [], [], "progress or shoot by distance")
	await _scenario("E  under pressure, safe mate",
		Vector3(5, 1, 0), [Vector3(6.2, 1, 0.4), Vector3(5.4, 1, -1.2)],
		[Vector3(2, 1, -6)], "PASS more attractive")
	await _scenario("F  open field, far from goal",
		Vector3(-8, 1, 0), [], [Vector3(-10, 1, -8)], "DRIBBLE/progress, not a shot")
	await _scenario("G  legitimate backward pass",
		Vector3(24, 1, 0),
		[Vector3(26, 1, 0), Vector3(25, 1, 3), Vector3(25, 1, -3)],
		[Vector3(17, 1, 0)], "backward pass IS correct here")
	get_tree().quit()


func _scenario(label: String, carrier_pos: Vector3, opp_offsets: Array,
		mate_offsets: Array, expectation: String) -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier: FootballPlayer = _spawn(0, carrier_pos, "ST")
	await get_tree().physics_frame
	var mates: Array = [carrier]
	for m in mate_offsets:
		mates.append(_spawn(0, m, "CM"))
		await get_tree().physics_frame
	var opps: Array = []
	for o in opp_offsets:
		opps.append(_spawn(1, o, "CB"))
		await get_tree().physics_frame
	# Every scenario has an opposing keeper on the line -- the decision reads
	# their position, and a scenario without one is not a football situation.
	var keeper: FootballPlayer = _spawn(1, Vector3(28.5, 1, 0), "GK")
	keeper.is_goalkeeper = true
	await get_tree().physics_frame
	opps.append(keeper)

	for m in mates:
		m.set_match_context(mates, opps)
	for o in opps:
		o.set_match_context(opps, mates)

	# Ball at the carrier's feet, settled, and enough possession time that
	# the settle gate has elapsed.
	_seat(ball, carrier.global_position + FWD * 0.5 + Vector3(0, 0.35, 0))
	for i in range(30):
		carrier.move_input = Vector2.ZERO
		await get_tree().physics_frame

	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-29, 0, 0), Vector3(29, 0, 0))
	AIController._decide_possession_action(
		carrier, ball, Vector3(29, 0, 0), opps, FWD, plan, 1.0 / 60.0)

	_print_decision(label, expectation, carrier)

	var all: Array = [field, ball] + mates + opps
	for n in all:
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	await get_tree().physics_frame


func _print_decision(label: String, expectation: String, carrier: FootballPlayer) -> void:
	var d: Dictionary = carrier.last_decision
	print("DIAG-DEC: ============================================================")
	print("DIAG-DEC: %s" % label)
	print("DIAG-DEC:   expected: %s" % expectation)
	if d.is_empty():
		print("DIAG-DEC:   NO DECISION RECORDED (settle gate, or no action path reached)")
		return
	print("DIAG-DEC:   goal %.1fm away, angle %.0f deg, lane %s, %d defenders near, pressure %.2f" % [
		d.get("dist_to_goal", 0.0), d.get("angle_to_goal", 0.0),
		"BLOCKED" if d.get("shot_lane_blocked", false) else "clear",
		d.get("defenders_near", 0), d.get("pressure", 0.0)])
	print("DIAG-DEC:   SCORING OPPORTUNITY: %.3f" % d.get("opportunity", 0.0))
	for o in d.get("options", []):
		var extra := ""
		if o.get("action") == "PASS" and o.get("target", "") != "":
			extra = "  -> %s (progress %+.2f)" % [o.get("target"), o.get("progress", 0.0)]
		print("DIAG-DEC:     %-8s utility %.3f  bar %.3f   %s%s" % [
			o.get("action", "?"), o.get("utility", 0.0), o.get("threshold", 0.0),
			o.get("reason", ""), extra])
	print("DIAG-DEC:   >>> CHOSE %s -- %s" % [d.get("chosen", "?"), d.get("chosen_reason", "")])


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
