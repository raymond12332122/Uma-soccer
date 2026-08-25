class_name PossessionManager
extends Node

## Single source of truth for "who has the ball right now," derived each
## physics frame from every FootballPlayer's own local has_possession
## flag (which is purely local -- based on that player's own control
## sensor and cooldown). When more than one player reports possession in
## the same frame (a contested 50/50), the one physically closest to the
## ball is treated as the carrier for AI/UI purposes; the underlying
## dribble-steering forces still resolve the physical duel naturally.

var current_carrier: FootballPlayer = null
var possessing_team: int = -1
var is_loose: bool = true

var _tracked_players: Array = []
var _ball: RigidBody3D = null


func setup(players: Array, ball: RigidBody3D) -> void:
	_tracked_players = players
	_ball = ball


func _physics_process(_delta: float) -> void:
	if _ball == null:
		return

	var best: FootballPlayer = null
	var best_dist := INF

	for p in _tracked_players:
		if p.has_possession:
			var d: float = p.global_position.distance_to(_ball.global_position)
			if d < best_dist:
				best_dist = d
				best = p

	if best != null and current_carrier != null and best != current_carrier and best.team_id != current_carrier.team_id:
		best.notify_possession_won_from_opponent()

	current_carrier = best
	possessing_team = best.team_id if best else -1
	is_loose = best == null
