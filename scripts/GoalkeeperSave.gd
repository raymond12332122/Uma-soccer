class_name GoalkeeperSave
extends RefCounted

## The keeper's save as a physical event (blocker 2).
##
## MEASURED before this existed (tests/diag_keeper_live.gd, 150 s matches):
##
##   the keeper is in POSITION           98-99% of frames
##   at every goal conceded they were already in SAVE
##   ...between 0.83 m and 3.10 m from the ball, 0.5 s before it went in
##   BLOCK fired on 0.0-0.1% of frames, CLOSE_ANGLE on 0.0%
##
## So the threat model was not the problem: the keeper reads the shot and goes
## to the right place. What was missing is that NOTHING made their body stop
## the ball. `save_left`, `save_right` and `catch` clips have shipped since
## v0.9.2 and AIController never called play_action once -- the keeper walked
## toward an interception point and hoped the physics capsule happened to be
## in the way. At 0.83 m from a ball travelling 13.7 m/s, with contact needing
## 0.56 m, it was not.
##
## A save is now a COMMITTED ACTION with a duration and a reach, resolved by
## measured geometry, exactly like SlideTackle:
##
##   the keeper commits to a direction and cannot re-aim
##   their reach is the SEGMENT swept by an outstretched dive, not a bubble
##   the ball is saved if it comes within contact of that segment
##   the animation is chosen BY the outcome and never decides it
##
## The dive costs something: the keeper ends up on the floor and recovers
## through the ordinary fall/recovery phase, so a keeper who dives at nothing
## is out of the play for a moment, which is what makes diving a decision.

enum Outcome { NONE, CAUGHT, PARRIED, MISSED }

## How long a committed dive lasts. About the length of the dive clips (1.60 s
## tail) minus the part that is the keeper already on the ground.
const DIVE_DURATION := 0.62

## How far the keeper travels along the dive. A dive is a lunge, not a sprint.
const DIVE_SPEED := 6.2
const DIVE_DRAG := 4.0

## How far past their body centre a diving keeper reaches. The contact test
## measures the ball against the SEGMENT from the body centre to this point --
## a dive is a long thin thing, and treating it as a sphere is the
## centre-distance hack this project has removed everywhere else.
const DIVE_EXTENT := 1.30

## Capsule radii from the scene files: players 0.40, ball 0.16.
const PLAYER_RADIUS := 0.40
const BALL_RADIUS := 0.16
## Ball is reached when it comes within this of the dive segment. Total
## effective reach is therefore DIVE_EXTENT + SAVE_CONTACT = 1.96 m from the
## keeper's centre, which covers the 0.83-2.00 m misses measured above and
## does not cover the 3.10 m one -- a keeper who is three metres out of
## position should still concede.
const SAVE_CONTACT := PLAYER_RADIUS + BALL_RADIUS + 0.10

## Ball speed at or below which a save is CAUGHT rather than parried. Above it
## the keeper gets a hand to it and it runs loose, which is a real outcome and
## keeps rebounds in the game.
const CATCH_MAX_SPEED := 11.0

## How hard a parry pushes the ball away from goal.
const PARRY_SPEED := 6.5

## Minimum time-to-arrival before the keeper will commit. Diving early is how
## a keeper is beaten by a change of direction; this is the commitment cost.
const COMMIT_MAX_TIME := 0.85
## ...and the keeper will not dive at a ball they could simply stand in front
## of. Below this gap they hold their ground and the capsule does the work.
const COMMIT_MIN_GAP := 0.75
## Nor at one they could never reach.
const COMMIT_MAX_GAP := 4.2
## How far to the side a keeper can save STANDING UP -- body plus a step. A
## ball passing closer than this needs no dive, and diving at it is worse than
## standing there: measured, that was a committed dive missing a ball the
## keeper was already in front of.
const STAND_REACH := 0.95

## Cooldown after a dive before another may be committed.
const SAVE_COOLDOWN := 0.9


## May this keeper commit to a dive right now?
##
## Deliberately strict. A keeper who dives at everything is worse than one who
## stays on their line, and the brief is explicit that they must not become
## suicidal.
static func can_commit(keeper: FootballPlayer, ball: RigidBody3D, intent: int) -> bool:
	if keeper == null or ball == null or not is_instance_valid(ball):
		return false
	if not keeper.is_goalkeeper:
		return false
	if keeper.is_diving or keeper.save_cooldown > 0.0 or keeper.is_recovering():
		return false
	if intent != AIController.GKIntent.SAVE and intent != AIController.GKIntent.BLOCK:
		return false
	var flat_gap: float = _flat(ball.global_position).distance_to(_flat(keeper.global_position))
	if flat_gap < COMMIT_MIN_GAP or flat_gap > COMMIT_MAX_GAP:
		return false
	var closing: float = _closing_speed(keeper, ball)
	if closing <= 0.5:
		return false
	if flat_gap / closing > COMMIT_MAX_TIME:
		return false

	# ...and only if a dive is actually NEEDED.
	#
	# The gap above is the distance to the ball, which is large for a ball
	# coming straight at the keeper -- who should simply stand up and let it
	# hit them. What decides a dive is the LATERAL offset: how far to the side
	# the ball will pass. Measured, a constructed shot 1.7 m across goal had
	# the keeper committing at a 0.89 m closest approach and missing, because
	# they threw themselves at a ball they were already in front of.
	var miss: float = _lateral_miss(keeper, ball)
	return miss > STAND_REACH and miss <= DIVE_EXTENT + SAVE_CONTACT


## How far to the side of the keeper the ball is going to pass, on the ground
## plane. Zero means straight at them.
static func _lateral_miss(keeper: FootballPlayer, ball: RigidBody3D) -> float:
	var vel := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	if vel.length() < 0.01:
		return 0.0
	var dir: Vector3 = vel.normalized()
	var to_keeper: Vector3 = _flat(keeper.global_position) - _flat(ball.global_position)
	# Perpendicular component of the keeper's offset from the ball's line.
	return (to_keeper - dir * to_keeper.dot(dir)).length()


## Where the keeper should throw themselves: at where the ball WILL be, not
## where it is.
static func dive_direction(keeper: FootballPlayer, ball: RigidBody3D) -> Vector3:
	var vel := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	var here := _flat(keeper.global_position)
	var gap: float = _flat(ball.global_position).distance_to(here)
	var closing: float = maxf(_closing_speed(keeper, ball), 0.5)
	var lead: float = clampf(gap / closing, 0.0, COMMIT_MAX_TIME)
	var meet: Vector3 = _flat(ball.global_position) + vel * lead
	var dir: Vector3 = meet - here
	if dir.length() < 0.05:
		return Vector3.ZERO
	return dir.normalized()


## Advance every committed dive by one frame. Returns how many resolved.
static func update(keepers: Array, ball: RigidBody3D, delta: float) -> int:
	var resolved := 0
	for k in keepers:
		if k == null or not is_instance_valid(k) or not k.is_goalkeeper:
			continue
		k.save_cooldown = maxf(0.0, k.save_cooldown - delta)
		if not k.is_diving:
			continue
		if _advance(k, ball, delta) != Outcome.NONE:
			resolved += 1
	return resolved


static func _advance(keeper: FootballPlayer, ball: RigidBody3D, delta: float) -> int:
	keeper.dive_time += delta
	if ball == null or not is_instance_valid(ball):
		_finish(keeper, ball, Outcome.MISSED)
		return Outcome.MISSED

	# The reach, measured fresh every frame: body centre to fingertips.
	var tip: Vector3 = keeper.global_position + keeper.dive_direction * DIVE_EXTENT
	var gap: float = _point_to_segment(ball.global_position, keeper.global_position, tip)
	if gap <= SAVE_CONTACT:
		var speed: float = ball.linear_velocity.length()
		var outcome: int = Outcome.CAUGHT if speed <= CATCH_MAX_SPEED else Outcome.PARRIED
		_finish(keeper, ball, outcome)
		return outcome

	if keeper.dive_time >= DIVE_DURATION:
		_finish(keeper, ball, Outcome.MISSED)
		return Outcome.MISSED
	return Outcome.NONE


static func _finish(keeper: FootballPlayer, ball: RigidBody3D, outcome: int) -> void:
	keeper.is_diving = false
	keeper.save_cooldown = SAVE_COOLDOWN
	# The keeper is on the floor now. They get up through the ordinary
	# fall/recovery phase, which is what makes a dive a real commitment rather
	# than a free attempt.
	keeper.slide_recovery = maxf(keeper.slide_recovery,
		DIVE_DURATION - minf(keeper.dive_time, DIVE_DURATION) + 0.25)
	keeper.last_save_outcome = outcome

	if ball != null and is_instance_valid(ball):
		match outcome:
			Outcome.CAUGHT:
				ball.linear_velocity = Vector3.ZERO
				ball.angular_velocity = Vector3.ZERO
			Outcome.PARRIED:
				# Away from goal and to the side -- a parry puts the ball into
				# a contestable area, it does not clear the danger.
				var away: Vector3 = keeper.dive_direction
				away.y = 0.0
				if away.length() < 0.05:
					away = Vector3.RIGHT
				ball.linear_velocity = away.normalized() * PARRY_SPEED + Vector3(0, 1.5, 0)
	keeper.save_resolved.emit({
		"outcome": outcome,
		"outcome_name": outcome_name(outcome),
		"position": keeper.global_position,
	})


## Distance from a point to a line segment, on the ground plane. Same geometry
## as SlideTackle's leg segment, for the same reason.
static func _point_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var pp := Vector2(p.x, p.z)
	var aa := Vector2(a.x, a.z)
	var bb := Vector2(b.x, b.z)
	var ab: Vector2 = bb - aa
	var len_sq: float = ab.length_squared()
	if len_sq < 0.000001:
		return pp.distance_to(aa)
	var t: float = clampf((pp - aa).dot(ab) / len_sq, 0.0, 1.0)
	return pp.distance_to(aa + ab * t)


## How fast the ball is closing on the keeper, along the line between them.
static func _closing_speed(keeper: FootballPlayer, ball: RigidBody3D) -> float:
	var to_keeper: Vector3 = _flat(keeper.global_position) - _flat(ball.global_position)
	if to_keeper.length() < 0.01:
		return 0.0
	var vel := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	return vel.dot(to_keeper.normalized())


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


static func outcome_name(outcome: int) -> String:
	match outcome:
		Outcome.CAUGHT: return "CAUGHT"
		Outcome.PARRIED: return "PARRIED"
		Outcome.MISSED: return "MISSED"
		_: return "NONE"
