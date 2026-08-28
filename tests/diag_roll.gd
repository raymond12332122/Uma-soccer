extends Node3D

## v0.8.8 diagnostic: re-measure the ball roll model.
##
## PassEvaluator.speed_for_distance() inverts a fitted model
##   roll_distance ~= ROLL_PER_SPEED * launch_speed - ROLL_OFFSET
## to decide how hard every pass is struck. That fit was taken in v0.8.3,
## and v0.8.7 changed the ball itself (radius 0.35 -> 0.16). If the fit is
## stale, every pass in the game is struck at the wrong weight -- which is
## what "the ball still feels heavy" would look like from the outside.
##
## This kicks a ball at known speeds across the real pitch and reports the
## distance it actually travels, so the constants can be re-fitted from
## data instead of adjusted by feel.

const BallScene := preload("res://scenes/Ball.tscn")
const FieldScene := preload("res://scenes/Field.tscn")

const SPEEDS := [4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.5, 15.0]
## Stop measuring once the ball is essentially at rest.
const REST_SPEED := 0.35
const MAX_FRAMES := 600


func _ready() -> void:
	add_child(FieldScene.instantiate())
	await get_tree().physics_frame
	var results: Array = []
	for speed in SPEEDS:
		var roll: float = await _roll_for(speed)
		results.append([speed, roll])
		print("DIAG-ROLL: launch %5.1f m/s -> rolled %6.2f m" % [speed, roll])

	# Least-squares fit of roll = a * speed + b over the PASS band only --
	# that is the range speed_for_distance() is ever asked to invert.
	var n := 0
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for r in results:
		if r[0] < PassEvaluator.PASS_SPEED_MIN or r[0] > PassEvaluator.PASS_SPEED_MAX:
			continue
		n += 1
		sx += r[0]
		sy += r[1]
		sxx += r[0] * r[0]
		sxy += r[0] * r[1]
	if n > 1:
		var denom: float = n * sxx - sx * sx
		var a: float = (n * sxy - sx * sy) / denom
		var b: float = (sy - a * sx) / n
		print("DIAG-ROLL: fit over the pass band -> ROLL_PER_SPEED = %.3f, ROLL_OFFSET = %.3f" % [a, -b])
		print("DIAG-ROLL: currently in code   -> ROLL_PER_SPEED = %.3f, ROLL_OFFSET = %.3f" % [
			PassEvaluator.ROLL_PER_SPEED, PassEvaluator.ROLL_OFFSET])

	# What the CURRENT model promises versus what the ball actually does.
	print("DIAG-ROLL: pass model in code -- does the ball ARRIVE with pace?")
	for dist in [4.0, 6.0, 8.0, 10.0, 12.0, 14.0]:
		var speed: float = PassEvaluator.speed_for_distance(dist)
		var arrival: float = await _speed_at(speed, dist)
		print("DIAG-ROLL:   %5.1fm pass -> struck at %5.2f m/s -> arrives at %5.2f m/s" % [
			dist, speed, arrival])
	print("DIAG-ROLL: pass band %.1f-%.1f m/s, shot floor %.1f m/s -- separated: %s" % [
		PassEvaluator.PASS_SPEED_MIN, PassEvaluator.PASS_SPEED_MAX,
		FootballPlayer.SHOT_SPEED_MIN,
		"yes" if PassEvaluator.PASS_SPEED_MAX < FootballPlayer.SHOT_SPEED_MIN else "NO"])

	get_tree().quit()


func _roll_for(speed: float) -> float:
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	ball.global_position = Vector3(-20.0, 0.35, 0.0)
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	# Let it settle onto the turf first, so we measure a roll and not a drop.
	for i in range(30):
		await get_tree().physics_frame
	var start: Vector3 = ball.global_position
	# The same launch a pass applies: horizontal speed plus the small lift.
	ball.linear_velocity = Vector3(speed, FootballPlayer.PASS_LIFT, 0.0)
	var travelled := 0.0
	for i in range(MAX_FRAMES):
		await get_tree().physics_frame
		var horizontal := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
		if horizontal.length() < REST_SPEED:
			break
	travelled = Vector2(ball.global_position.x - start.x, ball.global_position.z - start.z).length()
	ball.queue_free()
	await get_tree().process_frame
	return travelled


## Speed the ball still has after travelling `dist` from a `speed` launch.
func _speed_at(speed: float, dist: float) -> float:
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	ball.global_position = Vector3(-20.0, 0.35, 0.0)
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame
	var start: Vector3 = ball.global_position
	ball.linear_velocity = Vector3(speed, FootballPlayer.PASS_LIFT, 0.0)
	var arrival := 0.0
	for i in range(MAX_FRAMES):
		await get_tree().physics_frame
		var travelled: float = Vector2(ball.global_position.x - start.x,
			ball.global_position.z - start.z).length()
		var v: float = Vector2(ball.linear_velocity.x, ball.linear_velocity.z).length()
		if travelled >= dist:
			arrival = v
			break
		if v < REST_SPEED:
			break
	ball.queue_free()
	await get_tree().process_frame
	return arrival
