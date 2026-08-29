extends Node3D

## v0.9.1 diagnostic: how far from the ball is a defender who is genuinely
## challenging for it?
##
## POKE_REACH was derived from a STANDING player's geometry -- own capsule
## (0.40) + a leg (0.55) + the ball (0.16) = 1.11m centre-to-centre. That
## ignores the thing that actually makes a tackle hard: the carrier's body is
## usually between the challenger and the ball, and two capsules cannot
## interpenetrate, so the challenger's centre can never come within 0.80m of
## the carrier's centre in the first place.
##
## This measures the real distances in the exact duel the regression suites
## construct: a challenger placed a metre behind a stationary carrier, which
## is the canonical "he is right on top of me" tackle.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")


func _ready() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier: FootballPlayer = _spawn(0, Vector3(0, 1, 10), "CM")
	await get_tree().physics_frame
	var challenger: FootballPlayer = _spawn(1, Vector3(0, 1, 11.0), "CB")
	await get_tree().physics_frame
	carrier.set_match_context([carrier], [challenger])
	challenger.set_match_context([challenger], [carrier])

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(Basis(), carrier.global_position + Vector3(0, 0.3, -0.4)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(30):
		await get_tree().physics_frame

	print("DIAG-TCK: gates -- challenge range %.2fm, poke reach %.2fm, contact %.2fm" % [
		BallContest.CHALLENGE_RANGE, BallContest.POKE_REACH,
		FootballPlayer.POSSESSION_CONTACT_RADIUS])
	print("DIAG-TCK: two capsules of radius 0.40 cannot be closer than 0.80m centre-to-centre")

	var reported := 0
	for i in range(360):
		carrier.move_input = Vector2.ZERO
		challenger.move_input = Vector2.ZERO
		BallContest.resolve(carrier, [carrier, challenger], ball, 1.0 / 60.0)
		await get_tree().physics_frame

		var c_ball: float = _flat(ball.global_position - carrier.global_position)
		var x_ball: float = _flat(ball.global_position - challenger.global_position)
		var x_car: float = _flat(carrier.global_position - challenger.global_position)
		if i % 60 == 0 or (challenger.challenge_progress > 0.0 and reported < 6):
			reported += 1
			print("DIAG-TCK: f%3d  carrier->ball %.2f  challenger->ball %.2f  challenger->carrier %.2f  progress %.2f/%.2f  in envelope %s" % [
				i, c_ball, x_ball, x_car, challenger.challenge_progress,
				BallContest.CHALLENGE_TIME_REQUIRED,
				BallContest.within_poke_envelope(challenger, ball)])
		if not carrier.has_possession:
			print("DIAG-TCK: TACKLE COMPLETED on frame %d at challenger->ball %.2fm" % [i, x_ball])
			break

	if carrier.has_possession:
		print("DIAG-TCK: no tackle in 6s. challenger->ball settled at %.2fm, progress %.2f" % [
			_flat(ball.global_position - challenger.global_position),
			challenger.challenge_progress])
	get_tree().quit()


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
