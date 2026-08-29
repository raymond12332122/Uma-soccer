extends Node3D

## v0.9.1.1: does the ball still COLLIDE with a player at all?
##
## v0.9.1 set FootballPlayer.tscn's mask to 3 (world + players, NOT the ball
## layer) and Ball.tscn's mask to 1 (world only). Godot's masks are
## directional -- body A is blocked by body B only if A's mask contains B's
## layer -- so if neither side lists the other, the two never interact.
##
## That would mean the ball passes straight THROUGH every player, which is
## exactly what human QA describes as "the keeper fails to attempt a block":
## there is nothing to block with.
##
## The v0.9.1 suite asserted the player is not FLUNG by a struck ball and got
## 0.00m, which is equally consistent with a clean deflection and with the
## ball never touching them. This asks the question that distinguishes those:
## what happens to the BALL?

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")


func _ready() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var p: FootballPlayer = PlayerScene.instantiate()
	add_child(p)
	p.global_position = Vector3(0, 1, 0)
	p.team_id = 0
	p.formation_role = "GK"
	p.is_goalkeeper = true
	await get_tree().physics_frame
	p.set_match_context([p], [])
	for i in range(20):
		await get_tree().physics_frame

	print("DIAG-BVP: player layer %d mask %d | ball layer %d mask %d" % [
		p.collision_layer, p.collision_mask, ball.collision_layer, ball.collision_mask])
	print("DIAG-BVP: player blocked by ball? %s   ball blocked by player? %s" % [
		(p.collision_mask & ball.collision_layer) != 0,
		(ball.collision_mask & p.collision_layer) != 0])

	# Fire the ball straight at the player's chest from 8m away.
	var start: Vector3 = p.global_position + Vector3(0, 0.4, 8.0)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(Basis(), start))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
		Vector3(0, 0, -18.0))
	await get_tree().physics_frame

	var passed_through := false
	var min_gap := 999.0
	var deflected := false
	var vz0: float = ball.linear_velocity.z
	var gained_possession := false
	var poss_frame := -1
	var speed_at_possession := 0.0
	for i in range(120):
		await get_tree().physics_frame
		p.move_input = Vector2.ZERO
		if p.has_possession and not gained_possession:
			gained_possession = true
			poss_frame = i
			speed_at_possession = ball.linear_velocity.length()
		var d: float = Vector2(ball.global_position.x - p.global_position.x,
			ball.global_position.z - p.global_position.z).length()
		min_gap = minf(min_gap, d)
		# Did the ball end up on the far side of the player?
		if ball.global_position.z < p.global_position.z - 0.5:
			passed_through = true
		if absf(ball.linear_velocity.z - vz0) > 1.0 and not passed_through:
			deflected = true
		if i < 45:
			print("DIAG-BVP:   f%02d ball z=%6.2f vz=%6.2f  gap=%.2f  poss=%s" % [
				i, ball.global_position.z, ball.linear_velocity.z, d, p.has_possession])

	if gained_possession:
		print("DIAG-BVP: the player ACQUIRED POSSESSION on frame %d, ball doing %.1f m/s" % [
			poss_frame, speed_at_possession])
		print("DIAG-BVP:   -> that grants a collision exception, so the ball then passes through.")
	else:
		print("DIAG-BVP: the player never acquired possession")
	print("DIAG-BVP: closest ball-to-player %.2fm (capsule 0.40 + ball 0.16 = 0.56 contact)" % min_gap)
	print("DIAG-BVP: ball ended at z=%.2f, player at z=%.2f" % [
		ball.global_position.z, p.global_position.z])
	if passed_through:
		print("DIAG-BVP: >>> THE BALL PASSED THROUGH THE PLAYER. Nothing can be blocked or saved.")
	else:
		print("DIAG-BVP: ball was stopped or deflected by the body (deflected=%s)" % deflected)
	get_tree().quit()
