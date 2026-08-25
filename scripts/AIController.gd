class_name AIController
extends RefCounted

## Simple, stateless per-frame decision logic for AI-controlled players.
## TeamController calls these each physics frame for every player on its
## roster that isn't the current human target. No memory/planning between
## frames on purpose -- this is foundation-level AI, not tactics.

const SHOOT_RANGE := 9.0
const SPACING_RADIUS := 6.0
const ARRIVE_RADIUS := 0.6
const SPRINT_DISTANCE := 8.0

const GK_LATERAL_RANGE := 3.5
const GK_FORWARD_RANGE := 2.5
const GK_DANGER_DISTANCE := 7.0
const GK_ARRIVE_RADIUS := 0.25


static func update_player(
	player: FootballPlayer,
	ball: RigidBody3D,
	possession: PossessionManager,
	teammates: Array,
	opponents: Array,
	own_goal_pos: Vector3,
	opponent_goal_pos: Vector3,
	formation_target: Vector3
) -> void:
	var attacking: bool = possession.possessing_team == player.team_id
	var target: Vector3

	if attacking and player.has_possession:
		# I have the ball -- carry it toward goal, shoot once in range.
		target = opponent_goal_pos
		var dist_to_goal: float = player.global_position.distance_to(opponent_goal_pos)
		if dist_to_goal < SHOOT_RANGE:
			player.execute_shot(clampf(1.0 - dist_to_goal / SHOOT_RANGE, 0.35, 1.0))
	elif attacking:
		# Support: push the formation slot toward goal, keep spacing.
		var advance: Vector3 = _safe_normalize(opponent_goal_pos - formation_target) * 6.0
		target = formation_target + advance + _spacing_offset(player, teammates)
	else:
		# Opponent has it, or the ball is loose: nearest teammate presses
		# the most dangerous opponent (or the loose ball); everyone else
		# holds a defensive-leaning shape.
		var dangerous_opponent: Node3D = _find_dangerous_opponent(opponents, own_goal_pos)
		var press_point: Vector3 = dangerous_opponent.global_position if dangerous_opponent else ball.global_position
		var marker: FootballPlayer = _closest_to(teammates, press_point)

		if marker == player:
			target = press_point
		else:
			target = formation_target.lerp(own_goal_pos, 0.25)

	_move_toward(player, target, ARRIVE_RADIUS)
	player.sprint_requested = player.global_position.distance_to(target) > SPRINT_DISTANCE


static func update_goalkeeper(player: FootballPlayer, ball: RigidBody3D, own_goal_pos: Vector3) -> void:
	if player.has_possession:
		# Don't dribble around the box -- clear it upfield immediately.
		player.execute_shot(0.5)
		player.move_input = Vector2.ZERO
		player.sprint_requested = false
		return

	var center_dir_x: float = -signf(own_goal_pos.x) if own_goal_pos.x != 0.0 else 1.0

	var target := own_goal_pos
	target.z = clampf(ball.global_position.z, own_goal_pos.z - GK_LATERAL_RANGE, own_goal_pos.z + GK_LATERAL_RANGE)

	var dist_to_ball_x: float = absf(ball.global_position.x - own_goal_pos.x)
	if dist_to_ball_x < GK_DANGER_DISTANCE:
		var step: float = clampf(GK_DANGER_DISTANCE - dist_to_ball_x, 0.0, GK_FORWARD_RANGE)
		target.x = own_goal_pos.x + center_dir_x * step

	_move_toward(player, target, GK_ARRIVE_RADIUS)
	player.sprint_requested = dist_to_ball_x < GK_DANGER_DISTANCE


static func _move_toward(player: FootballPlayer, target: Vector3, arrive_radius: float) -> void:
	var to_target: Vector3 = target - player.global_position
	to_target.y = 0.0
	if to_target.length() > arrive_radius:
		player.move_input = Vector2(to_target.x, to_target.z).limit_length(1.0)
	else:
		player.move_input = Vector2.ZERO


static func _spacing_offset(player: FootballPlayer, teammates: Array) -> Vector3:
	var offset := Vector3.ZERO
	for mate in teammates:
		if mate == player or mate.is_goalkeeper:
			continue
		var diff: Vector3 = player.global_position - mate.global_position
		var dist := diff.length()
		if dist < SPACING_RADIUS and dist > 0.01:
			offset += diff.normalized() * (SPACING_RADIUS - dist) * 0.5
	return offset


static func _find_dangerous_opponent(opponents: Array, own_goal_pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for opp in opponents:
		if opp.is_goalkeeper:
			continue
		var d: float = opp.global_position.distance_to(own_goal_pos)
		if d < best_dist:
			best_dist = d
			best = opp
	return best


static func _closest_to(players: Array, pos: Vector3) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_dist := INF
	for p in players:
		if p.is_goalkeeper:
			continue
		var d: float = p.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = p
	return best


static func _safe_normalize(v: Vector3) -> Vector3:
	if v.length() < 0.001:
		return Vector3.FORWARD
	return v.normalized()
