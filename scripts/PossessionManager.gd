class_name PossessionManager
extends Node

## Single source of truth for "who has the ball right now," derived each
## physics frame from every FootballPlayer's own local has_possession
## flag (which is purely local -- based on that player's own control
## sensor and cooldown). When more than one player reports possession in
## the same frame (a contested 50/50), the one physically closest to the
## ball is treated as the carrier for AI/UI purposes; the underlying
## dribble-steering forces still resolve the physical duel naturally.

## At 22 players, a crowded box can put several teammates within a hair's
## breadth of "closest to the ball" simultaneously; without this, tiny
## per-frame distance jitter between them would flip current_carrier back
## and forth every frame even though nobody actually changed possession.
## The current carrier keeps the job as long as it's still within this
## margin of the best candidate, not just strictly closest.
const HYSTERESIS_MARGIN := 0.15

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

	if current_carrier != null and current_carrier.has_possession:
		var current_dist: float = current_carrier.global_position.distance_to(_ball.global_position)
		if current_dist <= best_dist + HYSTERESIS_MARGIN:
			best = current_carrier
			best_dist = current_dist

	if best != null and current_carrier != null and best != current_carrier and best.team_id != current_carrier.team_id:
		best.notify_possession_won_from_opponent()

	current_carrier = best
	possessing_team = best.team_id if best else -1
	is_loose = best == null
