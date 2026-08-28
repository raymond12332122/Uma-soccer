class_name PassEvaluator
extends RefCounted

## v0.8.3: real pass-target evaluation, shared by the AI carrier and the
## human PASS button's aim assist.
##
## The previous scoring lived inside FootballPlayer._find_pass_target and
## had two defects that made AI passing close to useless in play:
##
##  1. It considered teammates out to PASS_ASSIST_MAX_DISTANCE = 26m, but a
##     pass was kicked at a FIXED impulse that (measured: ball roll distance
##     is ~1.66 * launch speed - 1.4m) carried the ball about 8-11m. So the
##     AI routinely picked a "best" teammate it could not physically reach
##     and rolled the ball into open space, where the nearest opponent
##     collected it. Range is now a hard input to the decision, and pass
##     power is solved from the distance instead of being constant.
##
##  2. The chosen teammate then only got 70% of the aim (PASS_ASSIST_BLEND),
##     blended against the carrier's facing -- which for an AI carrier is
##     "toward the opponent goal". A teammate 90 degrees off the carrier's
##     run therefore received a ball aimed ~27 degrees away from them. That
##     is the "passes do not feel properly directional" report. The human's
##     button keeps the blend (their aim is a real intent); the AI now aims
##     dead-on at a LEAD point ahead of a moving receiver.
##
## Nothing here special-cases the human-controlled player. They are scored
## exactly like any other teammate, which is the fix for "AI does not
## reliably pass to the human-controlled teammate" -- the old code did not
## special-case them either, it simply preferred unreachable targets.

## Furthest a pass is allowed to be attempted. Derived from the measured
## ball roll model above at PASS_SPEED_MAX, with a little margin: past this
## the ball cannot arrive with anything left on it.
const MAX_PASS_DISTANCE := 14.0
## Below this a "pass" is really just a touch -- not worth giving the ball
## away for, and it reads on screen as the carrier kicking it at someone
## standing next to them.
const MIN_PASS_DISTANCE := 3.5

## An opponent within this perpendicular distance of the straight line to a
## teammate is treated as blocking the lane.
const LANE_BLOCK_RADIUS := 1.5
## No opponent within this radius of a receiver = fully open.
const OPENNESS_FULL_RADIUS := 6.0

## Distance band a pass is most useful over. Scores taper either side.
const IDEAL_MIN_DISTANCE := 7.0
const IDEAL_MAX_DISTANCE := 14.0

## Score weights. They sum to ~1.0 so the resulting score reads as a 0..1
## quality and can be compared against a plain threshold.
const W_OPENNESS := 0.26
## v0.8.3: raised over openness. With openness dominant the AI recycled the
## ball sideways to whoever happened to be least marked, and a measured
## 45-second match never advanced past midfield (average carrier distance
## to the opponent goal: 29m on a 26m half-pitch). A pass should have a
## purpose, and forward progression is the main one.
const W_PROGRESSION := 0.34
const W_DISTANCE := 0.14
const W_RELIEF := 0.12
const W_ALIGNMENT := 0.08
const W_ROLE := 0.10

## v0.8.6: a completely separate weighting for a HUMAN-AIMED pass, and the
## reason the PASS button did not do what the player told it to.
##
## The weights above are right for an AI carrier, whose "aim" is just
## whichever way they happen to be running -- there, alignment deserves to
## be a tiebreak worth 0.08. They are badly wrong for a human who has
## deliberately pointed the stick at a teammate and pressed PASS: alignment
## was 8% of a decision that openness (0.26), progression (0.34), distance
## (0.14) and role (0.10) between them owned outright, so the ball went to
## whichever teammate the evaluator liked best among everyone inside a
## 75-degree cone. Aiming barely participated.
##
## Aimed passes therefore score alignment on the RAW dot product rather than
## a remapped 0..1 (so a teammate off to the side loses most of the term
## rather than half of it) and weight it above everything else combined. The
## other factors still break ties between two teammates in roughly the same
## direction -- which is the useful part of assistance -- but they can no
## longer overrule where the player pointed.
const W_ALIGNMENT_AIMED := 0.60
const W_OPENNESS_AIMED := 0.16
const W_PROGRESSION_AIMED := 0.12
const W_DISTANCE_AIMED := 0.10
const W_ROLE_AIMED := 0.04

## An aimed pass reaches further and closer than the AI's own search does.
## A teammate 3m away that the player is pointing directly at is a pass they
## meant to make; refusing it (MIN_PASS_DISTANCE is 3.5) just swallowed the
## button press. The far end stays inside what the ball can actually carry
## at PASS_SPEED_MAX.
const AIMED_MIN_PASS_DISTANCE := 2.0
const AIMED_MAX_PASS_DISTANCE := 18.0

## A teammate on a run in behind is the pass every coach wants played.
const DUTY_RUN_BEHIND_BONUS := 0.14
const ROLE_BONUS := {"FWD": 1.0, "MID": 0.6, "DEF": 0.25, "GK": -1.0}

## A blocked lane is not disqualifying (a firm pass can still beat a
## covering opponent) but it must lose to any clear alternative.
const BLOCKED_LANE_PENALTY := 0.45
## Softer for an aimed pass: the player can see the covering defender and
## chose to play it anyway. Still enough that a clear teammate in the same
## direction is preferred, never enough to send the ball somewhere else.
const BLOCKED_LANE_PENALTY_AIMED := 0.18

## Ball roll model, fitted to measured data (see the class doc):
##   roll_distance ~= ROLL_PER_SPEED * launch_speed - ROLL_OFFSET
## Inverted below to solve for the launch speed a given pass needs.
const ROLL_PER_SPEED := 1.66
const ROLL_OFFSET := 1.4
## Aim the ball to roll somewhat past the receiver so it arrives with pace
## still on it rather than dying at their feet.
const OVERRUN_FACTOR := 1.35
## Ceiling on how far a moving receiver may be led, as a fraction of the
## pass distance -- see _lead_point.
const MAX_LEAD_FRACTION := 0.35

## Launch-speed band for passes. Held strictly below FootballPlayer's shot
## band so a pass and a shot are never the same event with different
## labels -- see FootballPlayer.SHOT_SPEED_MIN.
const PASS_SPEED_MIN := 4.0
const PASS_SPEED_MAX := 11.0


## One evaluated option. `score` is 0..1 quality; `aim_point` already
## includes lead for a moving receiver; `speed` is the launch speed needed.
class Option extends RefCounted:
	var target: FootballPlayer = null
	var score: float = 0.0
	var aim_point: Vector3 = Vector3.ZERO
	var speed: float = 0.0
	var distance: float = 0.0


## Best available pass for `passer`, or null if nothing is worth playing.
## `aim_dir` is the passer's own intended direction (used only as a small
## alignment preference, never as a hard cone -- an AI carrier's facing is
## almost always "at the goal", and a tight cone around that was silently
## excluding most of the team).
## `min_alignment` is a hard cone around `aim_dir`, used only by the human
## PASS button (whose aim is a real expressed intent). The AI passes -1.0,
## meaning "consider every direction" -- alignment then still contributes to
## the score, it just stops excluding teammates outright.
## `aimed` marks a pass the HUMAN deliberately aimed with the stick, which
## is scored on an entirely different weighting -- see W_ALIGNMENT_AIMED.
static func best_option(
	passer: FootballPlayer,
	aim_dir: Vector3,
	forward_axis: Vector3,
	plan: TeamPlan = null,
	min_alignment: float = -1.0,
	aimed: bool = false
) -> Option:
	var best: Option = null
	var aim_n: Vector3 = aim_dir.normalized() if aim_dir.length() > 0.01 else Vector3.ZERO
	var fwd_n: Vector3 = forward_axis.normalized() if forward_axis.length() > 0.01 else Vector3.ZERO
	var passer_pressure: float = _pressure_on(passer.global_position, passer.opponents)
	var min_dist: float = AIMED_MIN_PASS_DISTANCE if aimed else MIN_PASS_DISTANCE
	var max_dist: float = AIMED_MAX_PASS_DISTANCE if aimed else MAX_PASS_DISTANCE

	for mate in passer.teammates:
		if mate == passer or mate == null or not is_instance_valid(mate):
			continue
		# Never pass to a teammate who cannot legally be in the play.
		if FormationManager.is_behind_goal_line(mate.global_position):
			continue
		var to_mate: Vector3 = mate.global_position - passer.global_position
		to_mate.y = 0.0
		var dist: float = to_mate.length()
		if dist < min_dist or dist > max_dist:
			continue
		var dir: Vector3 = to_mate / dist
		if aim_n != Vector3.ZERO and min_alignment > -1.0 and aim_n.dot(dir) < min_alignment:
			continue

		var score := 0.0
		if aimed:
			# Where the player pointed decides this, and the rest only
			# separates teammates who are in roughly that direction.
			var alignment: float = clampf(aim_n.dot(dir), 0.0, 1.0) if aim_n != Vector3.ZERO else 0.0
			score += W_ALIGNMENT_AIMED * alignment
			score += W_OPENNESS_AIMED * _openness(mate.global_position, passer.opponents)
			if fwd_n != Vector3.ZERO:
				score += W_PROGRESSION_AIMED * clampf((fwd_n.dot(dir) + 1.0) * 0.5, 0.0, 1.0)
			score += W_DISTANCE_AIMED * _distance_quality(dist)
			score += W_ROLE_AIMED * ROLE_BONUS.get(FormationManager.role_category(mate.formation_role), 0.0)
			if _lane_blocked(passer.global_position, dir, dist, passer.opponents):
				score -= BLOCKED_LANE_PENALTY_AIMED
		else:
			score += W_OPENNESS * _openness(mate.global_position, passer.opponents)
			if fwd_n != Vector3.ZERO:
				score += W_PROGRESSION * clampf((fwd_n.dot(dir) + 1.0) * 0.5, 0.0, 1.0)
			score += W_DISTANCE * _distance_quality(dist)
			# Is the receiver in less trouble than we are? That is the whole
			# point of releasing the ball under pressure.
			var relief: float = clampf(_pressure_on(mate.global_position, passer.opponents) - passer_pressure, -1.0, 1.0)
			score += W_RELIEF * (0.5 - relief * 0.5)
			if aim_n != Vector3.ZERO:
				score += W_ALIGNMENT * clampf((aim_n.dot(dir) + 1.0) * 0.5, 0.0, 1.0)
			score += W_ROLE * ROLE_BONUS.get(FormationManager.role_category(mate.formation_role), 0.0)
			if plan != null and plan.duty_of(mate) == TeamPlan.Duty.RUN_BEHIND:
				score += DUTY_RUN_BEHIND_BONUS
			if _lane_blocked(passer.global_position, dir, dist, passer.opponents):
				score -= BLOCKED_LANE_PENALTY

		if best == null or score > best.score:
			var opt := Option.new()
			opt.target = mate
			opt.score = score
			opt.distance = dist
			opt.aim_point = _lead_point(passer.global_position, mate, dist)
			# v0.8.7: weight is solved from the distance to the RECEIVER, not
			# to the lead point. This is the root cause of "the PASS button
			# behaves like a small/weak kick", and it was a feedback loop
			# running the wrong way:
			#
			#   receiver runs toward the passer
			#     -> the lead point lands well SHORT of them
			#     -> the pass is solved for that shorter distance, so it is
			#        struck softer
			#     -> a softer pass has a longer flight time
			#     -> which leads it even further short.
			#
			# Measured on six identical 9m passes (diag_v087): the solved
			# distance collapsed to 4.3m and the ball was struck at 4.3 m/s,
			# rolling 5.7m -- dying over three metres short of a teammate the
			# player had aimed directly at. Leading the AIM is right; leading
			# the WEIGHT is not, because the ball still has to cover the real
			# ground between the two players.
			opt.speed = speed_for_distance(dist)
			best = opt

	return best


## Launch speed needed for the ball to reach `distance` with pace still on
## it. Inverse of the measured roll model.
static func speed_for_distance(distance: float) -> float:
	var wanted_roll: float = distance * OVERRUN_FACTOR
	var speed: float = (wanted_roll + ROLL_OFFSET) / ROLL_PER_SPEED
	return clampf(speed, PASS_SPEED_MIN, PASS_SPEED_MAX)


## Where to actually aim, accounting for the receiver still running. Flight
## time is estimated from the roll model's average speed over the distance.
static func _lead_point(from: Vector3, mate: FootballPlayer, distance: float) -> Vector3:
	var launch: float = speed_for_distance(distance)
	# The ball decelerates, so its average speed over the leg is well below
	# its launch speed; 0.7 matches the measured profile closely enough.
	var flight_time: float = distance / maxf(launch * 0.7, 0.01)
	var lead: Vector3 = Vector3(mate.velocity.x, 0.0, mate.velocity.z) * clampf(flight_time, 0.0, 1.2)
	# v0.8.7: and the lead itself is bounded to a fraction of the pass. At up
	# to 1.2s of flight, a receiver running at 5 m/s was being led by 6m on a
	# 9m pass -- the aim point ended up nearer the passer than the receiver
	# was, or (running the other way) half again beyond them. A lead is a
	# refinement of where to put the ball, so it is capped relative to the
	# pass it is refining rather than allowed to dominate it.
	lead = lead.limit_length(distance * MAX_LEAD_FRACTION)
	var point: Vector3 = mate.global_position + lead
	point.y = from.y
	return point


static func _distance_quality(dist: float) -> float:
	if dist >= IDEAL_MIN_DISTANCE and dist <= IDEAL_MAX_DISTANCE:
		return 1.0
	if dist < IDEAL_MIN_DISTANCE:
		return clampf((dist - MIN_PASS_DISTANCE) / maxf(IDEAL_MIN_DISTANCE - MIN_PASS_DISTANCE, 0.01), 0.0, 1.0)
	return clampf(1.0 - (dist - IDEAL_MAX_DISTANCE) / maxf(MAX_PASS_DISTANCE - IDEAL_MAX_DISTANCE, 0.01), 0.0, 1.0)


static func _openness(pos: Vector3, opponents: Array) -> float:
	return clampf(_nearest_opponent_distance(pos, opponents) / OPENNESS_FULL_RADIUS, 0.0, 1.0)


## 1.0 = an opponent is right on top of this position, 0.0 = nobody near.
static func _pressure_on(pos: Vector3, opponents: Array) -> float:
	return 1.0 - _openness(pos, opponents)


static func _nearest_opponent_distance(pos: Vector3, opponents: Array) -> float:
	var nearest := INF
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		var d: float = pos.distance_to(opp.global_position)
		if d < nearest:
			nearest = d
	return nearest if nearest != INF else OPENNESS_FULL_RADIUS


static func _lane_blocked(from: Vector3, dir: Vector3, dist: float, opponents: Array) -> bool:
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		var to_opp: Vector3 = opp.global_position - from
		to_opp.y = 0.0
		var along: float = to_opp.dot(dir)
		if along <= 0.4 or along >= dist - 0.4:
			continue
		if (to_opp - dir * along).length() < LANE_BLOCK_RADIUS:
			return true
	return false
