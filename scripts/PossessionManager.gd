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

## v0.8.5: the explicit possession PHASE, distinct from "who touched it".
##
## BALL CONTACT IS NOT A POSSESSION CHANGE. Measured over three 60s
## AI-vs-AI matches, 67-100% of all ball contacts lasted under 0.3s --
## those are touches, deflections and challenges, not turnovers. Naming the
## states makes that distinction something the code can actually reason
## about instead of something each reader has to infer from two int fields.
enum Phase {
	LOOSE,      ## nobody has it -- a bouncing/rolling ball with no controller
	CONTESTED,  ## somebody has it but an opponent is genuinely challenging
	SETTLED,    ## somebody has it under uncontested control
}

## Current phase, and whose it is (-1 while LOOSE).
var phase: int = Phase.LOOSE
var phase_team: int = -1

## True during the brief window after a confirmed turnover -- the team level
## reads this as "transition" rather than as a steady attacking/defending
## phase. Derived, not stored separately, so it can never disagree with
## time_since_last_team_change.
func is_in_transition() -> bool:
	return last_team_with_possession != -1 and time_since_last_team_change < TRANSITION_WINDOW


const TRANSITION_WINDOW := 0.8

## v0.8.2 hotfix, retuned in v0.8.5: how long the *other* team must hold the
## ball before it counts as a genuine change of team possession.
##
## Without this, a single physics frame of a player having the ball inside
## their control radius flipped the whole team's attacking/defending phase
## -- including a ball merely rolling past someone's feet.
##
## v0.8.5 splits it in two, because one threshold cannot express the
## difference the playtest actually complained about. Coming out of a
## challenge WITH the ball is a turnover; still being in the challenge is
## not. So an uncontested hold confirms quickly (a clean interception should
## register promptly), while a hold that is still being fought over has to
## last long enough to prove somebody actually won it.
const CONFIRM_TIME_SETTLED := 0.30
const CONFIRM_TIME_CONTESTED := 0.85

## An opponent this close to the ball while somebody carries it makes the
## possession CONTESTED. Matches the range at which BallContest considers a
## challenge to be under way at all, so "contested" means the same thing to
## the phase model and to the tackle system.
const CONTEST_RANGE := BallContest.CHALLENGE_RANGE

## How fast a pending claim bleeds away while the ball is loose, as a
## multiple of real time.
##
## The v0.8.4 code hard-RESET the pending timer on any frame with no
## carrier, which made confirmation require 0.3s of strictly unbroken
## control. A genuine turnover whose first touch bounces (i.e. most of them)
## therefore kept restarting from zero, while a scrappy passage where one
## side happened to hold on cleanly for 0.3s flipped the phase immediately.
## Decaying instead means a bobbled-but-real turnover still converges, and a
## ball that keeps breaking loose never does.
const PENDING_DECAY_RATE := 1.5

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

	# v0.9.2.1: committed slides advance and resolve on their own measured
	# geometry, independently of the progress-based challenge above. Run
	# unconditionally -- outside the "there is a carrier" branch -- because a
	# slide already in flight has to finish, and the slide/stumble timers have
	# to keep counting down, whether or not anyone currently has the ball.
	# A player left mid-slide because possession changed would never stand up.
	if SlideTackle.update(_tracked_players, _ball, delta) > 0:
		if current_carrier != null and current_carrier.stumble_time > 0.0:
			current_carrier = null
			possessing_team = -1
			is_loose = true

	# v1.0: committed goalkeeper dives resolve on the same unconditional
	# footing, for the same reason -- a dive already in flight has to finish
	# and its cooldown has to keep counting whoever has the ball. A save that
	# lands takes the ball off whoever nominally had it: a caught ball is the
	# keeper's, a parried one is nobody's.
	if GoalkeeperSave.update(_tracked_players, _ball, delta) > 0:
		current_carrier = null
		possessing_team = -1
		is_loose = true

	time_since_last_team_change += delta
	_update_phase(current_carrier)
	_update_team_possession(current_carrier, delta)


## Classifies the current instant into one of the three named phases. This
## is a pure description of right now -- it deliberately has no memory,
## because the memory belongs to last_team_with_possession below.
func _update_phase(carrier: FootballPlayer) -> void:
	if carrier == null:
		phase = Phase.LOOSE
		phase_team = -1
		return
	phase_team = carrier.team_id
	phase = Phase.CONTESTED if _is_contested(carrier) else Phase.SETTLED


## Is an opponent of `carrier` genuinely challenging for this ball? Uses the
## opponent's distance to the BALL rather than to the carrier, for the same
## reason BallContest does: the ball is what is being contested.
func _is_contested(carrier: FootballPlayer) -> bool:
	for p in _tracked_players:
		if p == null or not is_instance_valid(p):
			continue
		if p == carrier or p.team_id == carrier.team_id or p.is_goalkeeper:
			continue
		if p.global_position.distance_to(_ball.global_position) <= CONTEST_RANGE:
			return true
	return false


## The sticky team signal that the whole team-shape layer reads.
##
## last_team_with_possession is sticky by design (that is the point of it
## existing alongside possessing_team): a LOOSE or CONTESTED moment never
## hands the phase to the other side on its own. Only a team that has
## actually established control long enough -- longer, if they are still
## being fought for it -- takes it.
func _update_team_possession(carrier: FootballPlayer, delta: float) -> void:
	if carrier != null and carrier.team_id == last_team_with_possession:
		# We still have it. Any partial claim the other side had built up is
		# spent.
		_pending_team = -1
		_pending_team_timer = 0.0
		return

	if carrier == null:
		# Loose. Decay rather than reset -- see PENDING_DECAY_RATE.
		_pending_team_timer = maxf(0.0, _pending_team_timer - PENDING_DECAY_RATE * delta)
		if _pending_team_timer <= 0.0:
			_pending_team = -1
		return

	if carrier.team_id == _pending_team:
		_pending_team_timer += delta
	else:
		_pending_team = carrier.team_id
		_pending_team_timer = 0.0

	var required: float = CONFIRM_TIME_CONTESTED if phase == Phase.CONTESTED else CONFIRM_TIME_SETTLED
	# The very first possession of a match is applied immediately -- there
	# is no previous team whose shape we'd be protecting from whiplash.
	if _pending_team_timer >= required or last_team_with_possession == -1:
		last_team_with_possession = carrier.team_id
		time_since_last_team_change = 0.0
		_pending_team = -1
		_pending_team_timer = 0.0
