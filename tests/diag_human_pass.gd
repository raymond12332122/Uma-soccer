extends Node3D

## v0.9.1 diagnostic: the WHOLE human pass chain, one line per stage.
##
## The QA complaint is "the human PASS still does not feel right", which is
## not a number. This walks a controlled pass through every stage between the
## stick and the receiver's first touch and prints what each stage did, so the
## stage that is actually wrong can be named instead of guessed at:
##
##   aim  ->  candidates  ->  filtering  ->  score  ->  selected target
##        ->  lead point  ->  kick direction  ->  kick speed
##        ->  trajectory  ->  receiver
##
## Two things it is specifically built to answer:
##
##   1. Does human intent dominate? `angular error` is the angle between the
##      raw stick direction and the direction the ball actually left in. A
##      large number here is aim assist overriding the player.
##   2. Does the ball ARRIVE usefully? A pass is judged by how it turns up:
##      too slow and it is cut out, too fast and it cannot be controlled. So
##      launch speed, arrival speed, travel distance and time are all
##      reported per scenario, across the whole distance range.
##
## Nothing here asserts. It measures, and the numbers decide what to change.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

## distance, label, receiver offset direction, marker offset (ZERO = unmarked)
const SCENARIOS := [
	[4.0, "SHORT   forward  clear", Vector3(0, 0, -1), Vector3.ZERO],
	[4.0, "SHORT   lateral  clear", Vector3(1, 0, 0), Vector3.ZERO],
	[9.0, "MEDIUM  forward  clear", Vector3(0, 0, -1), Vector3.ZERO],
	[9.0, "MEDIUM  lateral  clear", Vector3(1, 0, 0), Vector3.ZERO],
	[9.0, "MEDIUM  diagonal clear", Vector3(0.7, 0, -0.7), Vector3.ZERO],
	[16.0, "LONG    forward  clear", Vector3(0, 0, -1), Vector3.ZERO],
	[16.0, "LONG    diagonal clear", Vector3(0.7, 0, -0.7), Vector3.ZERO],
	[22.0, "V.LONG  forward  clear", Vector3(0, 0, -1), Vector3.ZERO],
	[9.0, "MEDIUM  forward  PRESSED", Vector3(0, 0, -1), Vector3(1.4, 0, 0.4)],
	[16.0, "LONG    forward  PRESSED", Vector3(0, 0, -1), Vector3(1.4, 0, 0.4)],
]

## How far off the aim a teammate may sit and still be passed to. The decoy
## is parked at a fixed angle from the aim and is the ONLY candidate in
## range, so whatever comes back is the widest assist the cone permits --
## which is the number the brief's "human intent must dominate" is about.
const OFFSET_ANGLES := [20.0, 40.0, 60.0, 72.0, 80.0]

var _record: Dictionary = {}


func _ready() -> void:
	# Warm-up. The FIRST scenario used to come out with its teammate stacked
	# on top of the decoy 6m from where it was placed: on a freshly
	# instantiated Field nothing has a settled transform yet, so the bodies
	# spawned into it were resolved against each other before the ground
	# existed. Every later scenario set up exactly as written. Discarding one
	# throwaway scenario is cheaper than making the harness's first run a
	# special case, and it is a harness artifact either way -- nothing here
	# is a gameplay finding.
	await _run_scenario(9.0, "(warm-up, discarded)", Vector3(0, 0, -1), Vector3.ZERO, true)

	print("DIAG-HP: scenario                | cand | tgt | ang.err | req  | actual | arrive | travel | t     | control")
	print("DIAG-HP: ---------------------------------------------------------------------------------------------------")
	for s in SCENARIOS:
		await _run_scenario(s[0], s[1], s[2], s[3])

	# How wide is the assist? One teammate, parked at a known angle off the
	# aim, in range and unmarked -- so the only thing deciding whether the
	# ball goes to them is the aim cone.
	print("DIAG-HP:")
	print("DIAG-HP: aim cone: the only candidate sits N degrees off the aim (cone = %.2f, i.e. %.0f deg)" % [
		FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT,
		rad_to_deg(acos(FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT))])
	for a in OFFSET_ANGLES:
		await _run_offset(a)
	get_tree().quit()


## One teammate at `angle` degrees off a dead-forward aim, nothing else in
## range. Prints whether the pass went to them (assist) or fell through to
## the aimed knock (intent preserved).
func _run_offset(angle: float) -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var aim := Vector3(0, 0, -1)
	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 8), "CM")
	await get_tree().physics_frame
	var off: Vector3 = aim.rotated(Vector3.UP, deg_to_rad(angle))
	var mate: FootballPlayer = _spawn(0, passer.global_position + off * 9.0, "ST")
	await get_tree().physics_frame
	var mates: Array = [passer, mate]
	for p in mates:
		p.set_match_context(mates, [])

	var feet: Vector3 = passer.global_position + aim * 0.5 + Vector3(0, 0.35, 0)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), feet))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(12):
		await get_tree().physics_frame

	_record = {}
	passer.pass_attempted.connect(_on_pass)
	passer.move_input = Vector2(aim.x, aim.z)
	await get_tree().physics_frame
	passer.pass_requested = true
	for i in range(6):
		await get_tree().physics_frame

	var real_angle: float = rad_to_deg(aim.angle_to(
		(mate.global_position - passer.global_position) * Vector3(1, 0, 1)))
	if _record.is_empty():
		print("DIAG-HP:   %5.1f deg off aim -> NO PASS EMITTED" % angle)
	else:
		print("DIAG-HP:   %5.1f deg off aim (actual %5.1f) -> %-12s  ball left %5.1f deg off the aim, %.1f m/s" % [
			angle, real_angle,
			"PASSED to him" if _record.get("target") != null else "knock (no target)",
			_record.get("angular_error", 0.0), _record.get("requested_speed", 0.0)])

	_teardown([field, ball, passer, mate])
	await get_tree().physics_frame


func _run_scenario(distance: float, label: String, dir: Vector3, marker_off: Vector3, quiet: bool = false) -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var aim: Vector3 = dir.normalized()
	# Set up AWAY from the centre spot. The 4m-forward scenario used to put
	# its receiver exactly on (0, y, 0), where it came to rest 1.19m in the
	# air and then slid 6m off whatever it was standing on -- the origin has
	# something under it that the rest of the pitch does not. Nothing about
	# the pass depends on where on the pitch it happens, so the scenario
	# simply moves off that spot.
	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 10), "CM")
	await get_tree().physics_frame
	var mate: FootballPlayer = _spawn(0, passer.global_position + aim * distance, "ST")
	await get_tree().physics_frame
	# A second teammate off to the side, so "which candidate won" is a real
	# question rather than a foregone conclusion.
	var decoy: FootballPlayer = _spawn(0, passer.global_position + Vector3(-6, 0, -2), "LW")
	await get_tree().physics_frame
	var mates: Array = [passer, mate, decoy]
	var opps: Array = []
	if marker_off != Vector3.ZERO:
		var marker: FootballPlayer = _spawn(1, passer.global_position + marker_off, "CB")
		await get_tree().physics_frame
		opps.append(marker)
		marker.set_match_context(opps, mates)
	for p in mates:
		p.set_match_context(mates, opps)

	# Seat the ball at the passer's feet, stationary, so this measures the
	# PASS and not whether a dribble survived.
	var feet: Vector3 = passer.global_position + aim * 0.5 + Vector3(0, 0.35, 0)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), feet))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(12):
		await get_tree().physics_frame

	if not quiet:
		print("DIAG-HP:   setup '%s': passer %s(%s)  mate %s(%s) d=%.2f  decoy %s(%s) d=%.2f" % [
		label, passer.name, passer.global_position, mate.name, mate.global_position,
		_flat(mate.global_position - passer.global_position),
		decoy.name, decoy.global_position,
		_flat(decoy.global_position - passer.global_position)])

	_record = {}
	passer.pass_attempted.connect(_on_pass)
	passer.move_input = Vector2(aim.x, aim.z)
	await get_tree().physics_frame
	var launch_from: Vector3 = ball.global_position
	passer.pass_requested = true

	var travel_frames := 0
	var arrival_speed := -1.0
	var controlled := false
	var closest_gap := 999.0
	for i in range(300):
		await get_tree().physics_frame
		if _record.is_empty():
			continue
		travel_frames += 1
		var gap: float = _flat(ball.global_position - mate.global_position)
		closest_gap = minf(closest_gap, gap)
		if arrival_speed < 0.0 and gap <= FootballPlayer.POSSESSION_CONTACT_RADIUS:
			arrival_speed = _flat(ball.linear_velocity)
		if mate.has_possession:
			controlled = true
			break
		if _flat(ball.linear_velocity) < 0.3 and travel_frames > 30:
			break

	var travel: float = _flat(ball.global_position - launch_from)
	if quiet:
		pass
	elif _record.is_empty():
		print("DIAG-HP: %-24s | NO PASS EMITTED" % label)
	else:
		print("DIAG-HP: %-24s | %4d | %3s | %6.1fd | %4.1f | %5.1f  | %5.1f  | %5.1f  | %4.2fs | %s" % [
			label,
			_record.get("considered", 0),
			"yes" if _record.get("target") != null else "NO",
			_record.get("angular_error", 0.0),
			_record.get("requested_speed", 0.0),
			_record.get("actual_speed", 0.0),
			arrival_speed if arrival_speed >= 0.0 else -1.0,
			travel,
			travel_frames / 60.0,
			"yes" if controlled else "no (closest %.2fm)" % closest_gap,
		])
		if _record.get("target") == null or _record.get("angular_error", 0.0) > 12.0 or not controlled:
			_dump_candidates(label)

	_teardown([field, ball, passer, mate, decoy] + opps)
	await get_tree().physics_frame


func _dump_candidates(label: String) -> void:
	print("DIAG-HP:    ^ chain for '%s':" % label)
	print("DIAG-HP:      aim %s  aimed=%s  chosen=%s (team %d)  kind=%d  score %.3f  dist %.2f" % [
		_record.get("aim", Vector3.ZERO), _record.get("aimed", false),
		_record.get("target_name", "-"), _record.get("target_team_id", -1),
		_record.get("kind", -1), _record.get("score", 0.0), _record.get("distance", 0.0)])
	print("DIAG-HP:      aim_point %s  kick_dir %s" % [
		_record.get("aim_point", Vector3.ZERO), _record.get("kick_direction", Vector3.ZERO)])
	for c in _record.get("candidates", []):
		if c.get("kept", false):
			print("DIAG-HP:      + %-14s d %5.2f  align %5.2f  open %4.2f  lane %s  score %.3f" % [
				c["name"], c["distance"], c["alignment"], c["openness"],
				"BLOCKED" if c["lane_blocked"] else "clear  ", c["score"]])
		else:
			print("DIAG-HP:      - %-14s dropped: %s" % [c["name"], c["reason"]])


## Take the previous scenario's bodies OUT OF THE TREE before the next one
## builds, rather than trusting queue_free.
##
## queue_free is deferred: the node -- and its collision shape -- is still
## live for the rest of the frame. Measured: the first scenario's teammate
## was placed correctly at (0, 0.99, 0), then on the next physics step was
## lifted to y=1.52 by a leftover body from the run before and slid 6.3m off
## it, ending up stacked on the decoy. Every downstream number for that
## scenario was then describing a player who was not where the scenario put
## them. remove_child unregisters the body immediately, so the next scenario
## is built into an empty world.
func _teardown(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()


func _on_pass(info: Dictionary) -> void:
	_record = info


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _spawn(team: int, pos: Vector3, role: String) -> FootballPlayer:
	var p: FootballPlayer = PlayerScene.instantiate()
	add_child(p)
	p.global_position = pos
	p.team_id = team
	p.formation_role = role
	p.formation_slot = Vector2(0.5, 0.5)
	return p
