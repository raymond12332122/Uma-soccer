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

## v0.8.2: unlike possessing_team (which drops to -1 the instant the ball
## is loose, even for a single physics tick), this only ever updates when
## a player genuinely takes clear possession -- it stays put through a
## brief bounce/50-50/contest. AIController's team-shape decisions read
## this instead of possessing_team: without it, "opponent has it" and "the
## ball momentarily bounced loose off my own teammate's foot" were
## indistinguishable, so the whole team's attacking shape (forwards'
## advanced runs especially) instantly, jarringly collapsed back to
## defensive recovery on every single loose touch, then re-advanced a
## moment later -- read as "gave up the run" even mid-attack. Reactive
## things (who presses, individual has_possession) still use the true
## instantaneous state; only shape/positioning smooths over this.
var last_team_with_possession: int = -1
## Seconds since last_team_with_possession actually changed -- a short
## window after it does is a genuine transition (see AIController.AIState
## TRANSITION_ATTACK/TRANSITION_DEFENSE), not just an ordinary loose ball.
var time_since_last_team_change: float = 0.0

## v0.8.2 hotfix: how long the *other* team must hold the ball continuously
## before it counts as a genuine change of team possession.
##
## Without this, a single physics frame of a player having the ball inside
## their control radius flipped the whole team's attacking/defending phase
## -- including a ball merely rolling past someone's feet. Measured
## directly during a real match: last_team_with_possession was flipping
## every 11-17 frames (~0.2s) in scrappy passages, and because
## AIController's TRANSITION_ATTACK target (forward, upfield) and
## TRANSITION_DEFENSE target (back toward our own goal) sit on opposite
## sides of the player, every flip swung all 10 outfielders' movement
## targets 10-21m in the opposite direction. That is the actual mechanism
## behind the reported "forward -> backward -> forward -> backward"
## oscillation, and it was visibly synchronized across the whole team
## because the signal driving it is team-level, not per-player.
##
## Deliberately shorter than a real pass flight time, so a genuine
## interception still registers promptly -- it only filters out contact
## too brief to be possession at all.
const TEAM_POSSESSION_CONFIRM_TIME := 0.3

var _pending_team: int = -1
var _pending_team_timer: float = 0.0

var _tracked_players: Array = []
var _ball: RigidBody3D = null


func setup(players: Array, ball: RigidBody3D) -> void:
	_tracked_players = players
	_ball = ball


func _physics_process(delta: float) -> void:
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

	# v0.8.4: a real challenge for the ball, on top of the geometric
	# election above. See BallContest for why the election alone made a
	# carrier close to impossible to dispossess. Run AFTER the election so
	# it always evaluates against the carrier the rest of the frame agrees
	# on; a successful tackle takes effect from the next frame, when the
	# loser's fresh possession cooldown removes them from contention.
	var tackler: FootballPlayer = BallContest.resolve(current_carrier, _tracked_players, _ball, delta)
	if tackler != null:
		current_carrier = null
		possessing_team = -1
		is_loose = true

	time_since_last_team_change += delta
	_update_team_possession(best, delta)


## See TEAM_POSSESSION_CONFIRM_TIME. A loose ball never clears or resets
## anything here -- last_team_with_possession is sticky by design (that's
## the whole point of it existing alongside possessing_team), so only a
## *different* team actually holding the ball long enough can change it.
func _update_team_possession(carrier: FootballPlayer, delta: float) -> void:
	if carrier == null or carrier.team_id == last_team_with_possession:
		_pending_team = -1
		_pending_team_timer = 0.0
		return

	if carrier.team_id == _pending_team:
		_pending_team_timer += delta
	else:
		_pending_team = carrier.team_id
		_pending_team_timer = 0.0

	# The very first possession of a match is applied immediately -- there
	# is no previous team whose shape we'd be protecting from whiplash.
	if _pending_team_timer >= TEAM_POSSESSION_CONFIRM_TIME or last_team_with_possession == -1:
		last_team_with_possession = carrier.team_id
		time_since_last_team_change = 0.0
		_pending_team = -1
		_pending_team_timer = 0.0
