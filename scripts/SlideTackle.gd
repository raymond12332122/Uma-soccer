class_name SlideTackle
extends RefCounted

## v0.9.2.1: the slide tackle as a physical event (brief sections 5-10).
##
## Human QA saw defenders sliding near the ball with nothing meaningful
## happening -- sliding through an opponent, or winning the ball anyway
## because a slide animation had played. Both are the same mistake: the
## animation was the event.
##
## Here the slide is a COMMITTED GAMEPLAY ACTION with a duration, and what it
## produces is decided every frame by measured geometry between three bodies:
## the tackler's capsule, the carrier's capsule, and the ball. The animation
## is triggered BY the outcome and never decides it.
##
## Four outcomes, all reachable:
##
##   CLEAN    the extended leg reaches the ball, and either no significant
##            body contact happened or the ball was reached first. The ball
##            is knocked and the tackler may win it.
##   FOUL     significant body contact with the carrier WITHOUT having played
##            the ball first. The carrier goes down; a foul event is emitted.
##   MISSED   the slide runs its course touching neither.
##   AVOIDED  a MISSED slide where the carrier changed direction while the
##            tackler was already committed -- recorded separately because it
##            is the outcome section 10 asks to be genuinely achievable.
##
## COMMITMENT is what makes avoidance possible. Once a slide starts the
## tackler travels along the direction they committed to and cannot re-aim,
## so a carrier who cuts away is gone. Without that, a slide is a homing
## missile and dribbling cannot beat it.

enum Outcome { NONE, CLEAN, MISSED, FOUL, AVOIDED }

## How long a committed slide lasts. Long enough to be a real commitment the
## carrier can exploit, short enough that a beaten defender is not out of the
## game -- 'soccer tackle (2)' runs 1.77s and reads as roughly this.
const SLIDE_DURATION := 0.85

## Speed the tackler carries into the slide, and how fast it bleeds off.
const SLIDE_SPEED := 7.5
const SLIDE_DRAG := 5.5

## How far in front of their body centre a sliding player's leading foot
## reaches. The contact test measures the ball against the SEGMENT from the
## body centre to this point, not against a radius around the centre -- a
## slide is a long thin thing and treating it as a sphere is exactly the
## centre-distance hack the brief rules out.
const SLIDE_EXTENT := 1.25

## Capsule radii from the scene files: players 0.40, ball 0.16.
const PLAYER_RADIUS := 0.40
const BALL_RADIUS := 0.16

## Ball is played when it comes within this of the leg segment.
const BALL_CONTACT := PLAYER_RADIUS + BALL_RADIUS + 0.10

## Bodies are in contact when their capsule axes are this close. Two 0.40
## capsules touch at 0.80; the margin covers a frame of overlap resolution.
const BODY_CONTACT := PLAYER_RADIUS * 2.0 + 0.12

## Below this closing speed a touch between bodies is players brushing past
## each other, not a challenge worth calling anything.
const FOUL_MIN_CLOSING_SPEED := 2.2

## When a defender may commit, MEASURED against what defenders near a carrier
## actually do (tests/diag_slide_window.gd, 2600+ defender-frames per match).
##
## The first cut also required accumulated challenge progress, on the theory
## that a slide is the end of a duel. The data killed it: progress is at or
## near zero on 75% of those frames and cleared the bar on 1.4% of them, so
## the combined rule fired ZERO times in a 60-second match. It was also the
## wrong idea -- a slide is a defender closing fast on a carrier they cannot
## reach by pressing, not the culmination of a long contest.
##
## What replaced it is stricter where it matters. The lunge has to be nearly
## straight at the carrier (0.65, against 0.35 before) and carry real speed
## (4.0, against 3.4), and there is a minimum range as well as a maximum:
## from closer than SLIDE_MIN_GAP a defender should simply put a foot in.
## Together these fire on 9.6% of defender-frames, and the per-player cooldown
## does the rest.
const SLIDE_START_RANGE := 3.6
const SLIDE_MIN_GAP := 2.0
const SLIDE_MIN_SPEED := 4.0
const SLIDE_MIN_APPROACH := 0.65

## How hard a clean slide knocks the ball.
const SLIDE_KNOCK_SPEED := 4.2

## How long a fouled carrier is out of the play. They are down, then they get
## up; nothing about this is permanent (section 9).
const STUMBLE_TIME := 1.30

## Cooldown after any slide before the same player may commit to another, so a
## defender cannot chain slides down the pitch.
const SLIDE_COOLDOWN := 1.60


## May this player commit to a slide at the carrier right now?
##
## Deliberately strict. A slide is a commitment with a real cost, and one that
## can be thrown at any moment from any angle is not a tackle, it is a
## teleport with a costume.
static func can_commit(tackler: FootballPlayer, carrier: FootballPlayer) -> bool:
	if tackler == null or carrier == null or not is_instance_valid(carrier):
		return false
	# is_recovering() rather than stumble_time alone: a player on the floor OR
	# getting up off it cannot launch a slide.
	if tackler.is_sliding or tackler.slide_cooldown > 0.0 or tackler.is_recovering():
		return false
	if tackler.is_goalkeeper or tackler.team_id == carrier.team_id:
		return false
	var to_carrier: Vector3 = carrier.global_position - tackler.global_position
	to_carrier.y = 0.0
	var gap: float = to_carrier.length()
	if gap > SLIDE_START_RANGE or gap < SLIDE_MIN_GAP:
		return false
	var vel := Vector3(tackler.velocity.x, 0.0, tackler.velocity.z)
	if vel.length() < SLIDE_MIN_SPEED:
		return false
	return vel.normalized().dot(to_carrier / gap) >= SLIDE_MIN_APPROACH


## Advance every active slide by one physics frame and resolve any that
## produce an outcome. Returns the number of slides resolved this frame.
static func update(players: Array, ball: RigidBody3D, delta: float) -> int:
	var resolved := 0
	for p in players:
		if p == null or not is_instance_valid(p):
			continue
		p.slide_cooldown = maxf(0.0, p.slide_cooldown - delta)
		# stumble_time and slide_recovery are counted down by the player
		# itself (see _drive_committed_body), so a player who is down gets up
		# on their own clock rather than depending on this being called.
		if not p.is_sliding:
			continue
		if _advance(p, ball, delta) != Outcome.NONE:
			resolved += 1
	return resolved


## One sliding player, one frame.
static func _advance(tackler: FootballPlayer, ball: RigidBody3D, delta: float) -> int:
	tackler.slide_time += delta

	var target: FootballPlayer = tackler.slide_target
	var target_valid: bool = target != null and is_instance_valid(target)

	# --- geometry, measured fresh every frame ---
	var leg_tip: Vector3 = tackler.global_position + tackler.slide_direction * SLIDE_EXTENT
	var ball_gap: float = INF
	if ball != null and is_instance_valid(ball):
		ball_gap = _point_to_segment(
			ball.global_position, tackler.global_position, leg_tip)
	var body_gap: float = INF
	var closing := 0.0
	if target_valid:
		var a := Vector3(tackler.global_position.x, 0.0, tackler.global_position.z)
		var b := Vector3(target.global_position.x, 0.0, target.global_position.z)
		body_gap = a.distance_to(b)
		# Closing speed from the slide's COMMITTED momentum, not from
		# `velocity`.
		#
		# move_and_slide overwrites velocity with what the body actually
		# achieved, and what it achieves on the frame it runs into another
		# player is close to zero -- the two capsules collide. Reading it
		# there measures the collision having already happened and reports
		# every hard challenge as a gentle one: the foul scenario resolved as
		# MISSED_TACKLE with the bodies visibly touching. The same trap
		# v0.9.1 documented for the ball shove.
		var axis: Vector3 = b - a
		if axis.length() > 0.01:
			var committed: Vector3 = tackler.slide_direction * tackler.slide_speed
			var rel: Vector3 = committed - Vector3(target.velocity.x, 0.0, target.velocity.z)
			closing = rel.dot(axis.normalized())

	# --- the ball first, because playing the ball is what makes it legal ---
	if ball_gap <= BALL_CONTACT and not tackler.slide_played_ball:
		tackler.slide_played_ball = true

	# --- body contact ---
	var real_contact: bool = target_valid \
		and body_gap <= BODY_CONTACT \
		and closing >= FOUL_MIN_CLOSING_SPEED
	if real_contact and not tackler.slide_hit_player:
		tackler.slide_hit_player = true

	# A foul resolves immediately: the contact IS the event, and letting the
	# slide run on afterwards would let a foul also win the ball.
	if tackler.slide_hit_player and not tackler.slide_played_ball:
		_finish(tackler, ball, Outcome.FOUL)
		return Outcome.FOUL

	# Playing the ball resolves as soon as the leg reaches it.
	if tackler.slide_played_ball:
		_finish(tackler, ball, Outcome.CLEAN)
		return Outcome.CLEAN

	if tackler.slide_time >= SLIDE_DURATION:
		# Did the carrier beat the commitment by changing direction? Recorded
		# separately from a plain miss because it is a different thing having
		# happened: the defender was going the right way and the carrier
		# moved.
		var avoided: bool = target_valid and target.time_since_turn_touch < 0.6
		_finish(tackler, ball, Outcome.AVOIDED if avoided else Outcome.MISSED)
		return Outcome.AVOIDED if avoided else Outcome.MISSED

	return Outcome.NONE


## Apply the consequences of a resolved slide.
##
## The tackler always ends up on the floor and has to get up -- that is the
## cost of committing, and it is what makes a missed slide a real mistake
## rather than a free attempt.
static func _finish(tackler: FootballPlayer, ball: RigidBody3D, outcome: int) -> void:
	var target: FootballPlayer = tackler.slide_target
	tackler.is_sliding = false
	tackler.slide_cooldown = SLIDE_COOLDOWN
	tackler.slide_recovery = SLIDE_DURATION - minf(tackler.slide_time, SLIDE_DURATION) + 0.45

	match outcome:
		Outcome.CLEAN:
			if ball != null and is_instance_valid(ball):
				# Knocked along the slide, away from the carrier's feet.
				var dir: Vector3 = tackler.slide_direction
				if dir.length() < 0.05:
					dir = Vector3.RIGHT
				ball.apply_central_impulse(dir.normalized() * SLIDE_KNOCK_SPEED * ball.mass)
			if target != null and is_instance_valid(target):
				target.notify_dispossessed(BallContest.TACKLE_DISPOSSESS_COOLDOWN)
		Outcome.FOUL:
			if target != null and is_instance_valid(target):
				target.begin_stumble(STUMBLE_TIME)
				target.notify_dispossessed(BallContest.TACKLE_DISPOSSESS_COOLDOWN)

	tackler.notify_slide_resolved(outcome, target)


## Distance from a point to a line segment, on the ground plane.
##
## This is what makes the contact test geometry rather than a radius check: a
## sliding player's reach is a long thin volume swept by an outstretched leg,
## so the ball is measured against that whole line, not against a bubble
## centred on the body.
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


static func outcome_name(outcome: int) -> String:
	match outcome:
		Outcome.CLEAN: return "CLEAN_TACKLE"
		Outcome.MISSED: return "MISSED_TACKLE"
		Outcome.FOUL: return "FOUL_CONTACT"
		Outcome.AVOIDED: return "AVOIDED"
		_: return "NONE"
