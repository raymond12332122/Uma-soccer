extends Node3D

## v0.9.1 diagnostic: player-vs-player phasing, and ball-vs-player flinging.
##
## Two QA reports that the collision configuration explains on its own:
##
##   FootballPlayer.tscn  collision_layer = 2, collision_mask = 5
##   Ball.tscn            collision_layer = 4, collision_mask = 3
##
## with layer 1 = world, 2 = players, 4 = ball. The player mask (5 = 1 + 4)
## covers the world and the ball but NOT layer 2 -- so players have never
## collided with one another, and a defender walking through the carrier is
## the configured behaviour rather than a glitch.
##
## The same mask is the likely source of the flinging: players DO mask the
## ball, so move_and_slide resolves a contact against a small, fast rigid
## body and deflects the character. A football player should not be moved by
## a ball.
##
## PHASE A drives two players head-on at each other and reports the closest
## their centres ever come; two 0.4m capsules cannot legitimately be closer
## than 0.8m, so anything well under that is passing through.
##
## PHASE B fires the ball at a stationary player at increasing speeds and
## reports the largest single-frame change in the player's velocity. A
## player struck by a ball should barely register it.

const FieldScene := preload("res://scenes/Field.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const BallScene := preload("res://scenes/Ball.tscn")

const CAPSULE_RADIUS := 0.4


func _ready() -> void:
	add_child(FieldScene.instantiate())
	await get_tree().physics_frame
	await _phase_head_on()
	await _phase_ball_impact()
	get_tree().quit()


func _phase_head_on() -> void:
	var a: FootballPlayer = _mk(Vector3(-6, 1, 0), 0)
	var b: FootballPlayer = _mk(Vector3(6, 1, 0), 1)
	for i in range(20):
		await get_tree().physics_frame

	var closest := INF
	var passed_through := false
	for i in range(180):
		a.move_input = Vector2(1, 0)
		b.move_input = Vector2(-1, 0)
		a.sprint_requested = true
		b.sprint_requested = true
		await get_tree().physics_frame
		var gap: float = Vector2(a.global_position.x - b.global_position.x,
			a.global_position.z - b.global_position.z).length()
		closest = minf(closest, gap)
		# They started with a at -x and b at +x. If a ends up beyond b, they
		# went through one another.
		if a.global_position.x > b.global_position.x + 0.5:
			passed_through = true

	print("DIAG-COL: head-on -- closest centre-to-centre %.2fm (two %.1fm capsules cannot be closer than %.2fm)" % [
		closest, CAPSULE_RADIUS, CAPSULE_RADIUS * 2.0])
	print("DIAG-COL: head-on -- did they swap sides (phase through)? %s" % str(passed_through))
	print("DIAG-COL: player mask=%d layer=%d  (world=1 players=2 ball=4)" % [
		a.collision_mask, a.collision_layer])
	a.queue_free()
	b.queue_free()
	await get_tree().process_frame


func _phase_ball_impact() -> void:
	var p: FootballPlayer = _mk(Vector3(0, 1, 0), 0)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	for i in range(30):
		await get_tree().physics_frame

	print("DIAG-COL: ball mask=%d layer=%d" % [ball.collision_mask, ball.collision_layer])
	for speed in [6.0, 12.0, 20.0, 30.0]:
		# Stand the player still and fire the ball straight at them.
		p.move_input = Vector2.ZERO
		p.sprint_requested = false
		ball.global_position = p.global_position + Vector3(-4.0, 0.05, 0)
		ball.linear_velocity = Vector3(speed, 0, 0)
		var before := Vector2(p.velocity.x, p.velocity.z)
		var worst_delta := 0.0
		var worst_speed := 0.0
		for i in range(60):
			await get_tree().physics_frame
			var now := Vector2(p.velocity.x, p.velocity.z)
			worst_delta = maxf(worst_delta, (now - before).length())
			worst_speed = maxf(worst_speed, now.length())
			before = now
		print("DIAG-COL: ball at %5.1f m/s -> player's worst one-frame velocity change %.2f m/s, peak speed %.2f m/s" % [
			speed, worst_delta, worst_speed])
	p.queue_free()
	ball.queue_free()
	await get_tree().process_frame


func _mk(pos: Vector3, team: int) -> FootballPlayer:
	var p: FootballPlayer = PlayerScene.instantiate()
	p.position = pos
	p.team_id = team
	add_child(p)
	p.apply_player_data(TestRoster.home_team()[9] if team == 0 else TestRoster.away_team()[9])
	p.set_match_context([], [])
	return p
