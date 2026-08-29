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
## ---- Lead pass (v0.9.0) ----
## How far ahead of a receiver a lead pass is played, along the attacking
## axis. About the distance a running player covers in a second -- far
## enough to be a ball into space rather than a pass at their feet, close
## enough that they can genuinely get there.
const LEAD_SPACE := 4.5
## A lead pass is only worth playing to somebody who is actually going
## somewhere. Below this forward speed, play it to their feet instead.
const LEAD_MIN_FORWARD_SPEED := 1.8
## The space played into must be at least this clear of any opponent, or the
## pass is just a gift.
const LEAD_MIN_SPACE_CLEARANCE := 3.0
## Playing a runner into space is the more valuable ball when it is on, and
## this tips a close decision toward it rather than overriding the scoring.
const W_LEAD_BONUS := 0.08

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
##
## v0.8.8: RE-FITTED, and this was the root cause of "the ball physics still
## feel heavy". The ball is not heavy -- it was being struck far too hard on
## every pass in the game. These constants were fitted in v0.8.3, and v0.8.7
## then changed the ball itself (radius 0.35 -> 0.16, which changes both its
## rolling inertia and its contact with the turf). Nothing re-fitted the
## model afterwards, so the equation the game used to decide pass weight no
## longer described the ball the game actually had.
##
## Re-measured across the pass band on the real pitch (tests/diag_roll.gd).
## The relationship is very cleanly linear -- this fit reproduces every
## sampled point to within 0.02m:
##   launch  4.0 m/s -> 5.85m     launch  9.0 m/s -> 14.27m
##   launch  6.0 m/s -> 9.20m     launch 11.0 m/s -> 17.67m
##
## The old error was one-directional and grew with distance, which is why
## longer passes read as launches: under the previous constants a wanted 8m
## pass actually travelled 11.5m and a wanted 12m pass travelled 17.0m --
## overshooting by 3.5m and 5.0m, on top of the deliberate overrun.
const ROLL_PER_SPEED := 1.689
const ROLL_OFFSET := 0.924

## v0.9.0: how fast a pass should still be travelling WHEN IT ARRIVES, in
## m/s. This replaces the overrun above as what actually sizes a pass, and
## it is the root cause of the human playtest's "the pass is too weak to be
## useful" -- a complaint the v0.8.8 tests could not see, because they
## asserted the ball reached the right PLACE and never asked how fast it was
## going when it got there.
##
## Sizing a pass by where the ball STOPS necessarily makes it arrive dead:
## aiming to halt 2m beyond the receiver meant a 4m pass launched at the
## 4.0 m/s floor and reached the target at walking pace. A real pass is
## judged by how it arrives, and a receiver wants it firm enough to control
## and run onto.
##
## The roll model inverts for this exactly. With roll = ROLL_PER_SPEED * v -
## ROLL_OFFSET, a ball still doing `va` at distance `d` satisfies
##   ROLL_PER_SPEED * v - ROLL_OFFSET = d + ROLL_PER_SPEED * va - ROLL_OFFSET
## so the launch speed is simply d / ROLL_PER_SPEED + va -- the offset
## cancels, and there is no fitting left to do.
##
## This is the TARGET the solve is written against; the ball actually
## arrives at ~2.85 m/s, because the linear roll fit describes total
## distance rather than the whole velocity profile, and the solve treats it
## as if it did. The number that matters is not the absolute value but that
## it is now CONSTANT with distance instead of decaying to nothing:
## measured, 4m arrives at 2.85 m/s, 8m at 2.85, 10m at 2.86, 12m at 2.78.
##
## Launch speeds, before -> after: 4m 4.10 -> 5.77, 8m 6.47 -> 8.14, 10m
## 7.65 -> 9.32, 12m 8.84 -> 10.50. Firmer everywhere and most of all on
## the short passes that felt worst (+41% at 4m), while staying strictly
## inside the pass band: PASS_SPEED_MAX (11.0) remains clear of
## FootballPlayer.SHOT_SPEED_MIN (12.5), so a pass can never become a weak
## shot. A 14m pass clamps and arrives at 1.93 m/s -- the honest limit of
## what this band can carry.
##
## SIZED AGAINST DEFENSIVE SHAPE, not chosen. A faster ball gets behind a
## defensive line more often, which is real football but also collides with
## a stated non-negotiable: v0_8_3 asserts defenders stay goal-side of the
## ball. The v0.8.8 build passes that 5 of 5 at 100%. Measured against this
## constant, with two runs per point and five at the endpoints:
##
##   arrival  4m pass   8m pass   defenders goal-side
##      1.2    3.57      5.94     100, 100, 100     (~the old, too-weak model)
##      2.0    4.37      6.74     100, 100
##      2.8    5.17      7.54     100, 96
##      3.4    5.77      8.14     100 x5            <-- chosen
##      4.0    6.37      8.74     100, 84, 84, 85, 84
##
## There is a cliff between 3.4 and 4.0, and 3.4 sits on the right side of
## it: essentially all of the pass-power gain, none of the measured cost to
## defensive shape. 4.0 was the first value tried and it broke that
## assertion 4 runs in 5 -- kept here so the trade is visible rather than
## rediscovered.
##
## v0.9.1 RE-MEASURED END TO END, and left alone. The brief asks for the
## arrival to be checked across the whole range and for a distance-sensitive
## model if one constant cannot serve it. It already is one -- the launch
## speed is solved per pass, above -- and measured live rather than
## predicted (diag_human_pass, ball tracked from the boot to the receiver's
## contact radius):
##
##   scenario              launch   arrives   in control
##    4m lateral            5.8      4.8       yes
##    9m forward            8.7      3.3       yes
##    9m lateral            8.7      3.3       yes
##    9m diagonal           8.7      3.3       yes
##    9m forward, pressed   8.7      3.3       yes
##   16m forward           11.0      3.8       yes
##   16m diagonal          11.0      3.8       yes
##   16m forward, pressed  11.0      4.0       yes
##
## Arrival sits in a 3.3-4.8 m/s band across a 4x spread of distances, with
## no dependence on direction and none on whether the passer was pressed,
## and the receiver controlled the ball in every case. Note the two numbers
## above that are NOT what the solve asked for: 16m wants 12.9 m/s and gets
## PASS_SPEED_MAX, yet still arrives at 3.8 -- the clamp is not costing
## anything at this range, because the roll model says an 11 m/s ball runs
## 17.7m. That is why the cap is left where it is instead of being raised
## into the shot band to satisfy an equation.
const PASS_ARRIVAL_SPEED := 3.4
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
## v0.9.0: the KIND of pass an option represents.
##
## Deliberately an enum on the option rather than a separate code path, so
## adding a type later (through-ball, chip, switch) means adding a candidate
## generator and a scoring tweak -- not a new branch through every caller.
## Everything downstream takes an Option and plays it; nothing needs to know
## which kind it is unless it wants to.
enum PassKind {
	NORMAL,  ## played AT a teammate, with lead for their motion
	LEAD,    ## played INTO SPACE ahead of a teammate, for them to run onto
}

class Option extends RefCounted:
	var target: FootballPlayer = null
	var score: float = 0.0
	var aim_point: Vector3 = Vector3.ZERO
	var speed: float = 0.0
	var distance: float = 0.0
	var kind: int = PassKind.NORMAL


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
## v0.9.1: `trace`, when a non-null Array is supplied, is filled with one
## Dictionary per teammate considered -- name, distance, alignment with the
## aim, openness, whether the lane is blocked, the score, and (for anyone
## rejected) the reason. It is a pure out-parameter: nothing in the scoring
## reads it, and passing nothing leaves this function byte-for-byte the same
## decision it was. It exists because the brief asks for the human pass chain
## to be visible end to end, and "which teammates were even in the running"
## cannot be reconstructed from the chosen option alone.
static func best_option(
	passer: FootballPlayer,
	aim_dir: Vector3,
	forward_axis: Vector3,
	plan: TeamPlan = null,
	min_alignment: float = -1.0,
	aimed: bool = false,
	trace: Array = []
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
		# INVARIANT (v0.9.1): a pass candidate is a TEAMMATE. `passer.teammates`
		# is wired once by MatchManager and never rebuilt, but a stale or
		# mis-wired context would otherwise turn straight into a pass to an
		# opponent -- the exact defect this milestone exists to make
		# impossible. Checked here, at generation, rather than as a late veto
		# on the chosen option, so an opponent never enters the candidate set
		# to be scored in the first place.
		if mate.team_id != passer.team_id:
			_trace_drop(trace, mate, "not a teammate (team %d vs %d)" % [mate.team_id, passer.team_id])
			continue
		# Never pass to a teammate who cannot legally be in the play.
		if FormationManager.is_behind_goal_line(mate.global_position):
			_trace_drop(trace, mate, "behind the goal line")
			continue
		var to_mate: Vector3 = mate.global_position - passer.global_position
		to_mate.y = 0.0
		var dist: float = to_mate.length()
		if dist < min_dist or dist > max_dist:
			_trace_drop(trace, mate, "distance %.2fm outside [%.1f, %.1f]" % [dist, min_dist, max_dist])
			continue
		var dir: Vector3 = to_mate / dist
		if aim_n != Vector3.ZERO and min_alignment > -1.0 and aim_n.dot(dir) < min_alignment:
			_trace_drop(trace, mate, "outside the aim cone (dot %.2f < %.2f)" % [aim_n.dot(dir), min_alignment])
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

		if trace != null:
			trace.append({
				"name": mate.name,
				"team_id": mate.team_id,
				"role": mate.formation_role,
				"kept": true,
				"distance": dist,
				"alignment": aim_n.dot(dir) if aim_n != Vector3.ZERO else 0.0,
				"openness": _openness(mate.global_position, passer.opponents),
				"lane_blocked": _lane_blocked(passer.global_position, dir, dist, passer.opponents),
				"score": score,
			})

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
			opt.kind = PassKind.NORMAL
			best = opt

		# v0.9.0: the same teammate may also be worth playing INTO SPACE.
		# Scored as its own candidate against the same weights, so a lead
		# ball wins only when it is genuinely the better option -- see
		# _lead_option.
		var lead_opt: Option = _lead_option(passer, mate, fwd_n, aim_n, score, min_alignment, aimed)
		if lead_opt != null and (best == null or lead_opt.score > best.score):
			best = lead_opt

	# INVARIANT (v0.9.1): whatever comes out of here is on the passer's team.
	# The generation loop above already guarantees it; this is the assertion
	# that says so out loud, and it covers _lead_option too -- a lead ball
	# aims at a POINT, and the point must still belong to a teammate. If this
	# ever trips, the bug is upstream in the candidate set or in the match
	# context, and the trace tells you which.
	if best != null and best.target != null and is_instance_valid(best.target) \
		and best.target.team_id != passer.team_id:
		push_error("PassEvaluator: chose an opponent as receiver (%s, team %d, passer team %d)" % [
			best.target.name, best.target.team_id, passer.team_id])
		return null

	return best


static func _trace_drop(trace: Array, mate: FootballPlayer, reason: String) -> void:
	if trace == null:
		return
	trace.append({
		"name": mate.name,
		"team_id": mate.team_id,
		"role": mate.formation_role,
		"kept": false,
		"reason": reason,
	})


## A pass played into the space AHEAD of `mate` rather than at their feet.
##
## Returns null unless this is genuinely on: the receiver has to be running
## forward (a ball into space behind a stationary player is just a giveaway),
## the space has to be clear, and it still has to be a pass the ball can
## physically make.
##
## Scored from the same base as the normal option for this teammate, plus a
## small bonus, so it competes rather than overrides -- the carrier plays a
## runner in only when that beats the simple ball.
static func _lead_option(
	passer: FootballPlayer,
	mate: FootballPlayer,
	fwd_n: Vector3,
	aim_n: Vector3,
	base_score: float,
	min_alignment: float,
	aimed: bool
) -> Option:
	if fwd_n == Vector3.ZERO:
		return null
	# Only for a player actually making a run.
	var mate_vel := Vector3(mate.velocity.x, 0.0, mate.velocity.z)
	if mate_vel.dot(fwd_n) < LEAD_MIN_FORWARD_SPEED:
		return null

	var spot: Vector3 = mate.global_position + fwd_n * LEAD_SPACE
	spot.y = passer.global_position.y
	if FormationManager.is_behind_goal_line(spot):
		return null
	# The space has to be space.
	if _nearest_opponent_distance(spot, passer.opponents) < LEAD_MIN_SPACE_CLEARANCE:
		return null

	var to_spot: Vector3 = spot - passer.global_position
	to_spot.y = 0.0
	var d: float = to_spot.length()
	var min_dist: float = AIMED_MIN_PASS_DISTANCE if aimed else MIN_PASS_DISTANCE
	var max_dist: float = AIMED_MAX_PASS_DISTANCE if aimed else MAX_PASS_DISTANCE
	if d < min_dist or d > max_dist:
		return null
	var dir: Vector3 = to_spot / d
	# A human who aimed somewhere else did not ask for this ball.
	if aim_n != Vector3.ZERO and min_alignment > -1.0 and aim_n.dot(dir) < min_alignment:
		return null

	var score: float = base_score + W_LEAD_BONUS
	if _lane_blocked(passer.global_position, dir, d, passer.opponents):
		score -= BLOCKED_LANE_PENALTY_AIMED if aimed else BLOCKED_LANE_PENALTY

	var opt := Option.new()
	opt.target = mate
	opt.score = score
	opt.distance = d
	opt.aim_point = spot
	opt.speed = speed_for_distance(d)
	opt.kind = PassKind.LEAD
	return opt


## Launch speed needed for the ball to reach `distance` with pace still on
## it. Inverse of the measured roll model.
static func speed_for_distance(distance: float) -> float:
	# v0.9.0: sized by ARRIVAL SPEED, not by where the ball stops -- see
	# PASS_ARRIVAL_SPEED. The ROLL_OFFSET term cancels out of this solve.
	var speed: float = distance / ROLL_PER_SPEED + PASS_ARRIVAL_SPEED
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
