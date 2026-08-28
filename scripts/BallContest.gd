class_name BallContest
extends RefCounted

## v0.8.4: an actual contest for the ball between a carrier and a
## challenger, evaluated once per physics frame by PossessionManager.
##
## Before this existed there was no tackle mechanic of any kind. Possession
## was decided purely geometrically -- PossessionManager elected whichever
## player with the ball inside their control radius was *closest to it* --
## and two facts made that close to unwinnable for a defender:
##
##   1. The carrier's dribble spring actively holds the ball
##      `dribble_distance` (0.62m at a walk) in front of them, so the
##      carrier's distance to the ball is pinned low by construction.
##   2. Both players are 0.4m-radius capsules, so a challenger's centre can
##      never be closer than 0.8m to the carrier's. Except when attacking
##      the ball almost exactly head-on, the challenger is therefore
##      always further from the ball than the carrier is, forever.
##
## Measured in an isolated 1v1 before this change: a challenger driven
## straight at the ball beat a STATIONARY carrier from 7 of 8 approach
## angles, but the real AI challenger managed only 4 of 8 -- and the
## closest it ever physically got to the ball was 0.83m against a carrier
## sitting 0.50m from it. Standing still was close to a safe action.
##
## So possession now changes hands two ways. The old geometric election
## still applies (running onto a loose ball, winning a 50/50 head-on), and
## on top of it a challenger who stays in a genuine challenge for long
## enough wins the ball outright. The second path is what this class is.
##
## Deliberately NOT random. A challenge accumulates while the conditions
## for it hold and decays when they stop, so the outcome is a readable
## consequence of what both players did -- who closed in, how long they
## stayed, whether the carrier was moving, how good each is -- rather than
## a dice roll the player cannot see or influence.

## A challenger must be at least this close to the ball to be contesting
## it at all. Slightly wider than the control radius, so closing in starts
## applying pressure a moment before a tackle becomes possible.
##
## v0.8.7: widened only slightly with the dribble leash. Close control now
## puts the ball up to 1.7m in FRONT of the carrier on a sprint touch
## rather than pinned against their capsule, so a defender over the carrier
## can be further from the ball than they used to be.
##
## Deliberately NOT widened further: an earlier 2.9 here made things worse,
## not better. Proximity is scored as a ramp from this range down to
## CONTACT_DISTANCE, so stretching the range flattens the ramp and a
## defender at 1.5m scored 0.30 where they now score 0.50. Measured, that
## dropped the mean challenge rate against a human carrier rather than
## raising it.
const CHALLENGE_RANGE := 2.4
## Closest a challenger can physically get to the ball: their own capsule
## radius (0.40) plus the ball's (0.16). Proximity is scored against this,
## not against zero -- see challenge_rate.
##
## v0.8.7: was 0.9, derived from the old 0.35m ball resting against the
## carrier's capsule. The ball is now 0.16m, so a defender who genuinely
## gets to it stands at ~0.56m; leaving the floor at 0.9 meant a challenger
## who was physically ON the ball could never score full proximity.
const CONTACT_DISTANCE := 0.6

## Seconds of sustained, full-strength challenge needed to win the ball.
## Everything below scales the RATE at which this fills, so a good
## challenge on a vulnerable carrier resolves in a fraction of this and a
## poor one never completes at all.
const CHALLENGE_TIME_REQUIRED := 0.8

## Progress bleeds away this fast (as a multiple of real time) once a
## challenger stops meeting the conditions -- backing off, being shrugged
## away, or the carrier escaping. Faster than it fills, so breaking away
## from a challenge genuinely resets it rather than leaving a defender
## holding a nearly-complete tackle indefinitely.
const CHALLENGE_DECAY_RATE := 1.0

## How long the loser cannot re-establish control after being tackled.
## This is the part that actually breaks the sticky-ball problem: the
## dribble spring is gated on this same cooldown, so for this window the
## ball is genuinely free rather than being pulled straight back to the
## previous carrier's feet.
const TACKLE_DISPOSSESS_COOLDOWN := 0.45

## Speed the ball is knocked away at when a tackle lands. Small on purpose
## -- a tackle should shake the ball loose into a contestable area, not
## launch it like a clearance.
const TACKLE_KNOCK_SPEED := 3.2

## Carrier speed at or above which they count as fully "moving" for the
## vulnerability curve below.
const CARRIER_MOVING_SPEED := 3.0

## Vulnerability multipliers on the challenge rate.
##
## A STATIONARY carrier is the most vulnerable, which the playtest asked
## for explicitly ("a stationary carrier should be especially vulnerable").
## It is also good football: standing still over the ball with a defender
## on you is how you lose it. A carrier moving at a controlled pace is
## hardest to dispossess; a sprinting carrier has the ball pushed further
## ahead of them (see FootballPlayer.dribble_distance_sprint) and is
## exposed again.
const VULN_STATIONARY := 1.6
## Still the safest way to carry the ball, but no longer near-immunity:
## at 0.7 a moving carrier was effectively untacklable in a real match.
const VULN_CONTROLLED := 0.85
const VULN_SPRINTING := 1.25
## A carrier who has just taken a heavy touch (control_lost) has the ball
## running away from their feet -- by far the best moment to nick it.
const VULN_HEAVY_TOUCH := 2.2

## A ball this close to the carrier's feet is under full control and gets
## no extra exposure; by LOOSE_TOUCH_MAX_GAP it is a ball run out in front,
## and a defender arriving first should be rewarded. See
## carrier_vulnerability.
const LOOSE_TOUCH_MIN_GAP := 0.75
const LOOSE_TOUCH_MAX_GAP := 1.5
## Multiplier applied at a fully loose touch.
const LOOSE_TOUCH_VULN_SCALE := 3.2


## Evaluates every challenge against the current carrier and applies at
## most one successful tackle per frame. Returns the challenger who won the
## ball, or null.
static func resolve(carrier: FootballPlayer, players: Array, ball: RigidBody3D, delta: float) -> FootballPlayer:
	if carrier == null or not is_instance_valid(carrier) or ball == null:
		_decay_all(players, delta)
		return null

	var winner: FootballPlayer = null
	var best_progress := 0.0

	for p in players:
		if p == null or not is_instance_valid(p):
			continue
		if p == carrier or p.team_id == carrier.team_id or p.is_goalkeeper:
			# Teammates never tackle each other, and the keeper's own
			# behaviour is deliberately left untouched.
			p.challenge_progress = maxf(0.0, p.challenge_progress - CHALLENGE_DECAY_RATE * delta)
			continue

		var rate: float = challenge_rate(p, carrier, ball)
		if rate <= 0.0:
			p.challenge_progress = maxf(0.0, p.challenge_progress - CHALLENGE_DECAY_RATE * delta)
			continue

		p.challenge_progress += rate * delta
		if p.challenge_progress > best_progress:
			best_progress = p.challenge_progress
			winner = p

	if winner == null or best_progress < CHALLENGE_TIME_REQUIRED:
		return null

	_apply_tackle(carrier, winner, ball)
	return winner


## How fast `challenger` is filling their challenge against `carrier` right
## now, in progress-per-second. 0 means they are not meaningfully
## challenging at all. Every term is an observable game quantity -- there
## is no hidden randomness.
static func challenge_rate(challenger: FootballPlayer, carrier: FootballPlayer, ball: RigidBody3D) -> float:
	var to_ball: Vector3 = ball.global_position - challenger.global_position
	to_ball.y = 0.0
	var dist: float = to_ball.length()
	if dist > CHALLENGE_RANGE:
		return 0.0

	# 1. Proximity, measured against how close a challenger can PHYSICALLY
	#    get rather than against zero. Two 0.4m capsules cannot be nearer
	#    than 0.8m centre-to-centre, so a defender who is genuinely on top
	#    of the carrier still sits ~0.8-1.2m from the ball -- scoring that
	#    as "half a challenge" (which 1 - dist/CHALLENGE_RANGE did) meant a
	#    tackle needed about five uninterrupted seconds and effectively
	#    never completed. Measured in a rendered human-vs-AI match before
	#    this: the human carrier held the ball 95% of the time and
	#    challenges peaked at 0.81 of the 1.0 needed, never landing.
	var proximity: float = clampf((CHALLENGE_RANGE - dist) / maxf(CHALLENGE_RANGE - CONTACT_DISTANCE, 0.01), 0.0, 1.0)

	# 2. Commitment: are we actually going at the ball, or just standing
	#    near it? A defender jogging away from the ball is not tackling.
	# Floored rather than allowed to reach zero: a defender standing over
	# the ball is applying real pressure even on the frames they happen to
	# be drifting rather than driving. Letting this hit zero made the rate
	# zero, which handed the challenge straight to the decay term, so a
	# challenge that was physically ongoing kept being reset.
	var closing := 1.0
	var vel := Vector3(challenger.velocity.x, 0.0, challenger.velocity.z)
	if vel.length() > 0.4 and dist > 0.01:
		closing = clampf(0.30 + 0.70 * vel.normalized().dot(to_ball / dist), 0.15, 1.0)

	# 3. Carrier vulnerability -- see the VULN_* constants.
	var vulnerability: float = carrier_vulnerability(carrier)

	# 4. Skill. A strong defender beats a weak dribbler noticeably faster,
	#    but the spread is bounded so stats bias the duel without deciding
	#    it outright. Personality shades it further: an aggressive,
	#    competitive challenger commits harder; a composed carrier is
	#    steadier under pressure. Generic formulas over trait values only,
	#    never a per-character branch.
	var def_skill: float = challenger.player_data.defensive_ability if challenger.player_data else 50.0
	var drib_skill: float = carrier.player_data.dribbling if carrier.player_data else 50.0
	var challenger_bite: float = (challenger.personality.aggression + challenger.personality.competitiveness) * 0.5
	var carrier_calm: float = (carrier.personality.composure + carrier.personality.discipline) * 0.5
	var edge: float = ((def_skill + challenger_bite) - (drib_skill + carrier_calm)) / 200.0
	var skill: float = clampf(1.0 + edge, 0.45, 1.75)

	# 5. A tired challenger presses less effectively.
	var stamina_ratio: float = (challenger.current_stamina / challenger.max_stamina) if challenger.max_stamina > 0.0 else 1.0

	return proximity * closing * vulnerability * skill * lerp(0.6, 1.0, stamina_ratio)


## How exposed this carrier is right now, as a multiplier. Exposed as its
## own function so a test can assert the stationary-vs-moving relationship
## directly rather than inferring it from duel outcomes.
static func carrier_vulnerability(carrier: FootballPlayer) -> float:
	var base: float = _pace_vulnerability(carrier)
	# v0.8.7: how far the ball is from the carrier's own feet now matters,
	# and it has to. Close control is a series of touches (see
	# FootballPlayer's touch model), so between touches the ball genuinely
	# runs 1-2m ahead -- and a ball that far from a player is one a defender
	# can nip in front of. Without this term the new dribbling was close to
	# unstealable in a live match: the carrier simply moved faster than
	# before, so the pace terms above scored them as protected, while the
	# ball they were actually leaving out in front counted for nothing
	# (measured: human held 94% of carrier time, challenges peaked at 0.11
	# of the 0.80 needed).
	#
	# This is also what keeps a heavy first touch punishable, and it scales
	# smoothly rather than switching, so ordinary tight dribbling is
	# unaffected.
	var ball: RigidBody3D = carrier.ball_in_control_range
	if ball == null or not is_instance_valid(ball):
		return base
	var gap: float = Vector2(
		ball.global_position.x - carrier.global_position.x,
		ball.global_position.z - carrier.global_position.z).length()
	var loose: float = clampf(
		(gap - LOOSE_TOUCH_MIN_GAP) / maxf(LOOSE_TOUCH_MAX_GAP - LOOSE_TOUCH_MIN_GAP, 0.01), 0.0, 1.0)
	return base * lerp(1.0, LOOSE_TOUCH_VULN_SCALE, loose)


## Vulnerability from the carrier's pace alone -- the v0.8.6 behaviour,
## preserved exactly so the "stationary is most exposed, controlled pace is
## safest, sprinting is exposed again" ordering the brief relies on is
## untouched.
static func _pace_vulnerability(carrier: FootballPlayer) -> float:
	if carrier.is_heavy_touch():
		return VULN_HEAVY_TOUCH
	var speed: float = Vector2(carrier.velocity.x, carrier.velocity.z).length()
	if speed < 0.6:
		return VULN_STATIONARY
	if carrier.is_currently_sprinting:
		return VULN_SPRINTING
	# Between a standstill and a controlled running pace, vulnerability
	# falls off smoothly -- getting moving is what protects the ball.
	return lerp(VULN_STATIONARY, VULN_CONTROLLED, clampf(speed / CARRIER_MOVING_SPEED, 0.0, 1.0))


static func _apply_tackle(carrier: FootballPlayer, winner: FootballPlayer, ball: RigidBody3D) -> void:
	# Poke the ball toward the player who won it, not merely away from the
	# one who lost it.
	#
	# "Away from the carrier" sounds right but is actively wrong: the
	# dribble spring holds the ball IN FRONT of the carrier, so that
	# direction is the carrier's own running line. A challenger arriving
	# from behind or the side would knock the ball further up the pitch,
	# away from themselves and into the path of the player they just
	# tackled -- who, once the cooldown expires, is best placed to collect
	# it. The tackle would produce a loose ball that mostly favoured the
	# loser.
	var toward_winner: Vector3 = winner.global_position - ball.global_position
	toward_winner.y = 0.0
	# Blended with a small push off the carrier so the ball clears their
	# feet rather than being dragged back through them.
	var off_carrier: Vector3 = ball.global_position - carrier.global_position
	off_carrier.y = 0.0
	var dir: Vector3 = _safe_dir(toward_winner) * 0.75 + _safe_dir(off_carrier) * 0.25
	if dir.length() < 0.05:
		dir = Vector3.RIGHT
	ball.apply_central_impulse(dir.normalized() * TACKLE_KNOCK_SPEED * ball.mass)

	# The loser cannot simply re-attach to the ball on the next frame --
	# this cooldown also gates the dribble spring, so the ball is genuinely
	# loose for a moment.
	carrier.notify_dispossessed(TACKLE_DISPOSSESS_COOLDOWN)
	winner.challenge_progress = 0.0
	winner.notify_possession_won_from_opponent()


static func _safe_dir(v: Vector3) -> Vector3:
	return v.normalized() if v.length() > 0.01 else Vector3.ZERO


static func _decay_all(players: Array, delta: float) -> void:
	for p in players:
		if p != null and is_instance_valid(p):
			p.challenge_progress = maxf(0.0, p.challenge_progress - CHALLENGE_DECAY_RATE * delta)
