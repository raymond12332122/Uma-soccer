class_name TeamPlan
extends RefCounted

## v0.8.3: the TEAM-LEVEL layer that was missing. One instance per team,
## owned and ticked once per physics frame by TeamController, BEFORE any
## individual player is updated.
##
## Before this existed, every player independently re-derived "what phase
## are we in / should I go at the ball / where should I stand" from the
## same global inputs, which is why 22 players behaved like 22 agents all
## reacting to the ball rather than like two teams: nothing anywhere
## allocated responsibilities, so any job that looked attractive to one
## player looked equally attractive to every similar player at once.
##
## This class answers the four team-level questions exactly once per frame
## and hands each player a single named DUTY:
##   - who has the ball / what phase are we in  -> attack_intent
##   - how urgent is the current moment         -> transition_urgency
##   - who is allowed to contest the ball       -> the CONTEST/PRESS_SUPPORT slots
##   - what is everybody else's job             -> the remaining allocated slots
##
## Duties are ALLOCATED (a fixed number of slots, filled by the best-suited
## candidate) rather than independently chosen. That is the structural
## reason a duty like RUN_BEHIND can only ever be held by two players at
## once no matter how many forwards would individually enjoy it -- the
## previous design had no such ceiling, so all three forwards plus the
## nearer midfielders converged on the same "push forward toward the ball"
## intent simultaneously.


## The complete set of jobs a non-goalkeeper, non-carrier player can hold.
## AIController turns each of these into a position (see _duty_target);
## nothing here computes positions itself -- this layer only assigns
## responsibility.
## v0.8.6 adds the two that were missing, and their absence is the direct
## cause of two of the three biggest reported problems. Every OTHER duty
## here describes a job you do *because of where the ball is*; there was
## nothing at all for "I just played it" or "I am nowhere near it", and
## players in those two situations therefore fell through to COVER_SPACE,
## the leftover -- which resolved to their static formation anchor. That is
## why a player "returns to formation" the moment they pass, and why
## midfielders went inert whenever play was elsewhere.
enum Duty {
	CONTEST,        ## the single nominated ball-winner
	PRESS_SUPPORT,  ## second man: covers the carrier's forward option
	SUPPORT_SHORT,  ## square/slightly-behind outlet for our own carrier
	SUPPORT_WIDE,   ## stretches the pitch on a flank, offers the switch
	RUN_BEHIND,     ## runs in behind the opponent's last line
	MARK,           ## picks up one specific opponent
	COVER_SPACE,    ## holds shape between the ball and our own goal
	FOLLOW_UP,      ## just played the ball -- stay in the move you started
	PUSH_UP,        ## off the ball: advance into space, offer a lane
}

## How fast attack_intent slews between fully-defending and fully-attacking.
## This is the single most important anti-oscillation mechanism in v0.8.3
## and it is NOT a cooldown: the team's phase is a continuous scalar that
## RAMPS, so a change of possession moves every downstream target smoothly
## across ~1.2s instead of teleporting it to the opposite side of the
## player on one frame. The old enum phase made TRANSITION_ATTACK and
## TRANSITION_DEFENSE produce targets ~20m apart, so any flicker in the
## underlying possession signal became a full-speed direction reversal --
## measured at 59% of all observed reversals.
const INTENT_SLEW_RATE := 1.6

## A duty a player already holds scores this much higher than one they
## don't. Pure tie-breaking in favour of continuity -- it never delays a
## genuinely better assignment (a candidate who is decisively better still
## wins immediately), it only stops two near-identical candidates from
## trading jobs back and forth on distance jitter.
## v0.8.3: raised from 1.5 after measuring 0.43 duty changes per player
## per second in a live match -- roughly 19 job changes per player per 45
## seconds. Each one moves that player's target several metres, and the
## resulting movement reversal lands a few frames LATER (after the smoothed
## target has travelled), which is why frame-exact attribution kept
## reporting those reversals as "unexplained". This is assignment
## hysteresis, not a cooldown: a decisively better candidate still takes
## the job on the very next frame. It only stops near-equal candidates
## trading jobs on positional noise.
## v0.8.6: raised from 4.0. This milestone adds two more duties (FOLLOW_UP
## and PUSH_UP), and the second of those sits right next to COVER_SPACE in
## suitability for exactly the players who are candidates for both -- so the
## number of near-ties this bonus exists to settle went up, and with it the
## churn. Measured over a 30s settled passage: 0.234 duty changes per player
## per second before this milestone, 0.307 after adding the new duties, and
## back to within the pre-existing rate at 6.0. Same tie-break rule, sized
## for the larger duty set.
const DUTY_RETENTION_BONUS := 6.0

## Slot ceilings. These numbers ARE the "not every player should contest /
## not every player should make the same run" rule, expressed structurally.
const MAX_RUN_BEHIND := 2
const MAX_SUPPORT_WIDE := 2
const MAX_SUPPORT_SHORT := 2
const MAX_MARKERS := 3

## v0.8.6. Count the attacking ceilings above: 2+2+2 = six jobs for ten
## outfielders, so four to six players per side were ALWAYS leftovers, and
## the leftover job resolved to a near-static formation anchor. Measured in
## the v0.8.5 rendered playtest: midfielders idle 75-76% of all frames. The
## ceilings were doing their job (not every forward should make the same
## run) but there was no second tier of off-ball work underneath them, so
## "not selected for a run" and "nothing to do" were the same thing.
##
## PUSH_UP is that second tier: advance into your own channel ahead of the
## ball and hold a lane. It is deliberately generous, because on a real
## pitch there is no such thing as an outfield player with no job while
## their team is on the ball.
const MAX_PUSH_UP := 3

## Ceiling on players simultaneously staying in a move they just played.
## Bounded only so a flurry of quick passes cannot hand the entire side a
## follow-up job at once; in practice one or two hold it.
const MAX_FOLLOW_UP := 3

## An opponent must be at least this far into our half (measured toward our
## own goal from the halfway line) to be worth assigning a dedicated marker.
const MARK_THREAT_DEPTH := 2.0

## Ideal distance from the ball for the short support option -- close
## enough to be a real pass, far enough not to crowd the carrier. The old
## code allowed supporting players as close as 3.2m, which is inside the
## carrier's own dribbling space.
const SUPPORT_SHORT_DISTANCE := 9.0

var team_id: int = 0

## -1.0 = fully defending, +1.0 = fully attacking. Continuous and slewed
## (see INTENT_SLEW_RATE). Every positional decision downstream reads this
## as a scalar, so team shape breathes between attacking and defending
## rather than snapping between two opposed layouts.
var attack_intent: float = 0.0
## 1.0 immediately after possession changes hands, decaying to 0. Scales
## sprint willingness and how hard players commit to a recovery/push.
var transition_urgency: float = 0.0

## Where the team's SHAPE should react to, as opposed to where the ball
## physically is this instant. A ball being contested by two players is a
## rigid body jittering several centimetres a frame, and every off-ball
## player's target is derived from it -- so that jitter was being amplified
## into 20 players' movement intents at once. Measured: with the ball's raw
## position driving shape, reversals clustered at 1-3m from target and were
## dominated by the hold-shape duty, i.e. players hovering next to a target
## that would not sit still.
##
## The player going to WIN the ball still uses its true position -- you
## cannot tackle a smoothed average.
var shape_ball_pos: Vector3 = Vector3.ZERO
const SHAPE_BALL_SMOOTH_TIME := 0.25

## An even slower reference, used ONLY for how deep a player holding shape
## sits (see AIController._cover_space_target).
##
## v0.8.5: shape_ball_pos smooths per-frame jitter, but it still tracks a
## genuine change of the ball's direction closely -- right for a supporting
## run, wrong for a whole line's depth. Once shape-holders were made to
## track play at all (they previously stood still while their own team
## attacked), coupling them to the 0.25s reference passed the ball's every
## switch of direction straight into ten players' targets: measured
## reversals per 1000 moving frames rose from 3.19 to 4.65. Lagging this
## far means a line drops and pushes with the FLOW of play rather than with
## the ball itself.
var slow_ball_pos: Vector3 = Vector3.ZERO
const SLOW_BALL_SMOOTH_TIME := 0.9

var carrier: FootballPlayer = null
var we_have_ball: bool = false
## The opponents' deepest outfield player (their last line). RUN_BEHIND
## targets are anchored just beyond this rather than at a fixed distance,
## so a run in behind is actually in behind something.
var opponent_last_line_x: float = 0.0

var duties: Dictionary = {}       ## instance_id -> Duty
var mark_targets: Dictionary = {} ## instance_id -> FootballPlayer being marked

var _own_goal: Vector3 = Vector3.ZERO
var _opponent_goal: Vector3 = Vector3.ZERO
var _forward_axis: Vector3 = Vector3.RIGHT

## Sticky contester (moved here from TeamController -- "who contests" is a
## team-level decision, and it now has to coexist with the other slots).
var _contester: FootballPlayer = null
const CONTEST_HYSTERESIS_MARGIN := 1.2


func setup(p_team_id: int, own_goal: Vector3, opponent_goal: Vector3) -> void:
	team_id = p_team_id
	_own_goal = own_goal
	_opponent_goal = opponent_goal
	_forward_axis = Vector3(signf(opponent_goal.x - own_goal.x), 0.0, 0.0)


func forward_axis() -> Vector3:
	return _forward_axis


func duty_of(player: FootballPlayer) -> int:
	return duties.get(player.get_instance_id(), Duty.COVER_SPACE)


func mark_target_of(player: FootballPlayer) -> FootballPlayer:
	return mark_targets.get(player.get_instance_id(), null)


func update(players: Array, opponents: Array, ball: RigidBody3D, possession: PossessionManager, delta: float) -> void:
	if shape_ball_pos == Vector3.ZERO:
		shape_ball_pos = ball.global_position
		slow_ball_pos = ball.global_position
	else:
		var blend: float = clampf(1.0 - exp(-delta / SHAPE_BALL_SMOOTH_TIME), 0.0, 1.0)
		shape_ball_pos = shape_ball_pos.lerp(ball.global_position, blend)
		var slow_blend: float = clampf(1.0 - exp(-delta / SLOW_BALL_SMOOTH_TIME), 0.0, 1.0)
		slow_ball_pos = slow_ball_pos.lerp(ball.global_position, slow_blend)

	_update_phase(possession, delta)
	_update_opponent_last_line(opponents, delta)

	carrier = possession.current_carrier
	# Two DIFFERENT questions, deliberately answered by two different
	# signals -- conflating them was the v0.8.2 oscillation bug, and using
	# the instantaneous one for shape would have reintroduced it one layer
	# up:
	#   * "is the ball under our control right this instant?" is reactive,
	#     and correctly uses the instantaneous carrier -- somebody has to go
	#     and win a ball that just broke loose.
	#   * "are we the team attacking?" is a shape question, and uses the
	#     sticky signal, which does not drop out for the single frame a
	#     ball bounces off a teammate's foot.
	# Note there is deliberately no longer a boolean "are we the attacking
	# team" used anywhere in slot allocation -- see the comment on the slot
	# counts below. attack_intent, which is slewed, is the only phase input.
	we_have_ball = carrier != null and carrier.team_id == team_id

	var previous: Dictionary = duties
	# Keep the previous marking assignments too -- the retention check in
	# _assign_markers compares against them, and clearing mark_targets
	# before running it made that check compare against an empty dictionary
	# and therefore ALWAYS fail, so every marker was re-picked from scratch
	# every single frame.
	var previous_marks: Dictionary = mark_targets
	duties = {}
	mark_targets = {}

	var available: Array = []
	for p in players:
		if p.is_goalkeeper or not is_instance_valid(p):
			continue
		if p == carrier and we_have_ball:
			continue  # the carrier's job is decided by the ball-carrier layer
		available.append(p)

	# 1. Contest. Exactly one player, and ONLY when the ball is not already
	#    under our own control -- a teammate running at our own carrier is
	#    not a challenge, it is crowding. Note this is gated on the
	#    INSTANTANEOUS signal: if the ball breaks loose mid-attack, one man
	#    goes to win it back while everybody else keeps the attacking shape.
	if not we_have_ball:
		var contester: FootballPlayer = _pick_contester(available, ball)
		if contester != null:
			_assign(contester, Duty.CONTEST)
			available.erase(contester)

		# 2. Press support. Only when we are genuinely the defending team
		#    and an opponent is actually carrying it -- a second man closing
		#    down on a loose ball in our own attacking phase just abandons
		#    the attack.
		var ball_depth: float = (ball.global_position.x - _own_goal.x) * signf(_forward_axis.x)
		# Gated on the SLEWED intent rather than the raw phase flag for the
		# same reason as the slot counts below: read off the phase directly,
		# this slot blinked in and out on the frame the phase changed.
		if attack_intent < 0.0 and carrier != null and ball_depth < FormationManager.FIELD_HALF_LENGTH:
			var supporter: FootballPlayer = _best_for(available, Duty.PRESS_SUPPORT, previous, ball, opponents)
			if supporter != null:
				_assign(supporter, Duty.PRESS_SUPPORT)
				available.erase(supporter)

	# 3/4. Attacking and defensive slots, allocated CONTINUOUSLY.
	#
	# v0.8.5, and the single most important change in this milestone. This
	# used to be `if attacking_shape: <attacking slots> else: <markers>` --
	# a hard binary swap between two disjoint slot sets. v0.8.3 had already
	# made the DEPTH layer continuous (attack_intent slews over ~1.2s), but
	# left this layer, fed by the same phase signal, as a switch.
	#
	# Measured across three 60s AI-vs-AI matches: the number of duty-set
	# flips equalled the number of tactical phase changes EXACTLY in every
	# run (1/1, 9/9, 13/13), and on the single frame of each flip the
	# players who got a new duty saw their movement target jump 8.10m,
	# 9.47m and 10.27m on average -- against a 0.01-0.13m baseline on every
	# other frame. That ~100x one-frame discontinuity, applied to the whole
	# outfield simultaneously, is the "movement earthquake": not the phase
	# changing too often (it changed only 0.02-0.22 times per second), but
	# every phase change reorganising all ten players at once.
	#
	# Slot COUNTS are now a function of attack_intent, which is already
	# smoothly slewed. A team at full attacking intent gets the full
	# attacking set; at full defensive intent, the full marking set; and in
	# between it genuinely holds a transitional shape -- one runner still
	# committed, one marker already picked up. Because the slots appear and
	# disappear at different points along the ramp, players change job a
	# couple at a time over more than a second instead of all together on
	# one frame. That is also just better football than a team that is
	# either wholly attacking or wholly defending with nothing between.
	# 2b. Stay in the play you just made.
	#
	# v0.8.6, and the fix for the single biggest reported problem ("AI
	# abandons the play"). This is an ALLOCATED DUTY, not a blend applied
	# afterwards, and that distinction is the whole point. Previously a
	# player who had just passed was still put through the ordinary
	# allocation, where they are 0m from the ball -- which scores badly for
	# SUPPORT_SHORT (it wants ~9m) and is explicitly penalised for
	# RUN_BEHIND -- so they reliably fell through to COVER_SPACE and were
	# sent back toward their formation anchor. A decaying follow-up weight
	# was then blended on top of that, i.e. the system spent 2.5s partially
	# cancelling a "go home" instruction it had just issued.
	#
	# Deciding it here instead means the player never receives that
	# instruction at all: for as long as the move they started is live,
	# their job IS the move.
	_fill_follow_up(available, ball)

	var attacking_weight: float = clampf((attack_intent + 1.0) * 0.5, 0.0, 1.0)
	_fill(available, Duty.SUPPORT_SHORT, _slots(MAX_SUPPORT_SHORT, attacking_weight), previous, ball, opponents)
	_fill(available, Duty.RUN_BEHIND, _slots(MAX_RUN_BEHIND, attacking_weight), previous, ball, opponents)
	_fill(available, Duty.SUPPORT_WIDE, _slots(MAX_SUPPORT_WIDE, attacking_weight), previous, ball, opponents)
	_assign_markers(available, opponents, previous, previous_marks,
		_slots(MAX_MARKERS, 1.0 - attacking_weight))
	# 4b. Off-ball advancement -- see MAX_PUSH_UP. Counted from the same
	#     slewed intent as every other slot, so it migrates over the ramp
	#     rather than switching on the frame the phase changes.
	_fill(available, Duty.PUSH_UP, _slots(MAX_PUSH_UP, attacking_weight), previous, ball, opponents)

	# 5. Everyone left holds shape. This is a real job, not a leftover --
	#    see AIController's COVER_SPACE target, which stays ball-relative
	#    (the old fallback resolved to a near-static point, which is why
	#    defenders measured 40% of frames completely stationary).
	for p in available:
		_assign(p, Duty.COVER_SPACE)


## Anyone whose last kick is still in the air, in priority of how recently
## they played it. Not scored against other candidates like the allocated
## slots are -- having just played the ball is a fact about this player, not
## a competition they can lose to a better-placed teammate.
func _fill_follow_up(available: Array, _ball: RigidBody3D) -> void:
	var recent: Array = []
	for p in available:
		if p.post_action_involvement() > 0.0:
			recent.append(p)
	if recent.is_empty():
		return
	recent.sort_custom(func(a, b): return a.post_action_involvement() > b.post_action_involvement())
	for i in range(mini(recent.size(), MAX_FOLLOW_UP)):
		_assign(recent[i], Duty.FOLLOW_UP)
		available.erase(recent[i])


## How many of `max_slots` a phase this committed should fill. Rounding
## (rather than truncating) means a slot survives to the midpoint of the
## ramp, so the two sides' slot counts cross over gradually rather than
## both changing at the same instant.
static func _slots(max_slots: int, weight: float) -> int:
	return int(round(max_slots * clampf(weight, 0.0, 1.0)))


func _assign(player: FootballPlayer, duty: int) -> void:
	duties[player.get_instance_id()] = duty
	player.ai_duty = duty


func _update_phase(possession: PossessionManager, delta: float) -> void:
	var target_intent := 0.0
	if possession.last_team_with_possession == team_id:
		target_intent = 1.0
	elif possession.last_team_with_possession != -1:
		target_intent = -1.0
	attack_intent = move_toward(attack_intent, target_intent, INTENT_SLEW_RATE * delta)

	transition_urgency = clampf(1.0 - possession.time_since_last_team_change / TRANSITION_WINDOW, 0.0, 1.0)


## A short burst of extra urgency right after a turnover in either
## direction. Owned by PossessionManager along with the clock it is
## measured against, so the readers cannot drift apart.
const TRANSITION_WINDOW := PossessionManager.TRANSITION_WINDOW


func _update_opponent_last_line(opponents: Array, delta: float) -> void:
	# Their deepest outfielder, measured along our attacking direction.
	var deepest := INF
	for o in opponents:
		if o == null or not is_instance_valid(o) or o.is_goalkeeper:
			continue
		var along: float = o.global_position.x * signf(_forward_axis.x)
		if along < deepest:
			deepest = along
	if deepest == INF:
		deepest = 0.0
	var raw: float = deepest * signf(_forward_axis.x)
	# Smoothed for the same reason as shape_ball_pos: this is a MIN over a
	# changing set of players, so it steps discontinuously the moment a
	# different defender becomes the deepest one -- and it anchors every
	# run-in-behind target.
	if opponent_last_line_x == 0.0:
		opponent_last_line_x = raw
	else:
		var blend: float = clampf(1.0 - exp(-delta / SHAPE_BALL_SMOOTH_TIME), 0.0, 1.0)
		opponent_last_line_x = lerp(opponent_last_line_x, raw, blend)


func _pick_contester(candidates: Array, ball: RigidBody3D) -> FootballPlayer:
	var nearest: FootballPlayer = null
	var nearest_dist := INF
	for p in candidates:
		var d: float = p.global_position.distance_to(ball.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = p
	if nearest == null:
		_contester = null
		return null

	if _contester == null or not is_instance_valid(_contester) or not candidates.has(_contester):
		_contester = nearest
		return _contester
	if _contester == nearest:
		return _contester

	var current_dist: float = _contester.global_position.distance_to(ball.global_position)
	if nearest_dist + CONTEST_HYSTERESIS_MARGIN < current_dist:
		_contester = nearest
	return _contester


func _fill(available: Array, duty: int, count: int, previous: Dictionary, ball: RigidBody3D, opponents: Array) -> void:
	for _i in range(count):
		var best: FootballPlayer = _best_for(available, duty, previous, ball, opponents)
		if best == null:
			return
		_assign(best, duty)
		available.erase(best)


func _assign_markers(available: Array, opponents: Array, previous: Dictionary, previous_marks: Dictionary, max_markers: int = MAX_MARKERS) -> void:
	if max_markers <= 0:
		return
	var threats: Array = []
	for o in opponents:
		if o == null or not is_instance_valid(o) or o.is_goalkeeper:
			continue
		# How far into our half are they? Positive = inside our half.
		var depth: float = (o.global_position.x - _own_goal.x) * signf(_forward_axis.x)
		if depth > FormationManager.FIELD_HALF_LENGTH - MARK_THREAT_DEPTH:
			continue
		threats.append({"opponent": o, "depth": depth})
	threats.sort_custom(func(a, b): return a["depth"] < b["depth"])

	var assigned := 0
	for t in threats:
		if assigned >= max_markers or available.is_empty():
			return
		var opponent: FootballPlayer = t["opponent"]
		var best: FootballPlayer = null
		var best_score := -INF
		for p in available:
			var cat: String = FormationManager.role_category(p.formation_role)
			var score: float = -p.global_position.distance_to(opponent.global_position)
			if cat == "DEF":
				score += 4.0
			elif cat == "MID":
				score += 1.5
			# Marking is tighter work for a disciplined character.
			score += (p.personality.discipline - 50.0) * 0.02
			if previous.get(p.get_instance_id(), -1) == Duty.MARK and previous_marks.get(p.get_instance_id()) == opponent:
				score += DUTY_RETENTION_BONUS
			if score > best_score:
				best_score = score
				best = p
		if best == null:
			return
		_assign(best, Duty.MARK)
		mark_targets[best.get_instance_id()] = opponent
		available.erase(best)
		assigned += 1


## Suitability of one player for one duty. Deliberately generic -- role
## category, formation slot, geometry and personality traits only; never a
## specific character, and never which team this is.
func _best_for(available: Array, duty: int, previous: Dictionary, ball: RigidBody3D, opponents: Array) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_score := -INF
	for p in available:
		var score: float = _score_for(p, duty, ball, opponents)
		if previous.get(p.get_instance_id(), -1) == duty:
			score += DUTY_RETENTION_BONUS
		if score > best_score:
			best_score = score
			best = p
	return best


func _score_for(p: FootballPlayer, duty: int, ball: RigidBody3D, opponents: Array) -> float:
	var cat: String = FormationManager.role_category(p.formation_role)
	var dist_to_ball: float = p.global_position.distance_to(ball.global_position)
	var advancement: float = p.global_position.x * signf(_forward_axis.x)

	match duty:
		Duty.PRESS_SUPPORT:
			# Second-nearest, but weighted toward players who are already
			# goal-side of the ball rather than chasing back past it.
			var score: float = -dist_to_ball * 0.6
			if advancement < ball.global_position.x * signf(_forward_axis.x):
				score += 3.0
			if cat == "MID":
				score += 2.0
			elif cat == "DEF":
				score += 1.0
			score += (p.personality.aggression - 50.0) * 0.02
			return score

		Duty.SUPPORT_SHORT:
			# Wants to be a realistic passing distance from the ball --
			# neither on top of the carrier nor out of range.
			var score: float = -absf(dist_to_ball - SUPPORT_SHORT_DISTANCE) * 0.7
			if cat == "MID":
				score += 3.0
			elif cat == "DEF":
				score += 0.5
			score += (p.personality.teamwork - 50.0) * 0.02
			return score

		Duty.RUN_BEHIND:
			# The most advanced, most adventurous attackers only.
			var score: float = advancement * 0.25
			if cat == "FWD":
				score += 4.0
			elif cat == "MID":
				score += 0.5
			else:
				score -= 6.0  # defenders do not make runs in behind
			score += (p.personality.aggression + p.personality.risk_taking - 100.0) * 0.02
			# Prefer someone not already tight to the ball -- a run in
			# behind starts away from the ball, not on top of it.
			if dist_to_ball < 6.0:
				score -= 2.0
			return score

		Duty.PUSH_UP:
			# Whoever has the most useful room to advance INTO. A player
			# already level with or beyond the ball has nowhere to push, and a
			# player standing on the ball is supporting it, not pushing past
			# it -- both are better used elsewhere.
			var score: float = 0.0
			if cat == "MID":
				score += 3.5
			elif cat == "FWD":
				score += 2.5
			else:
				# A full-back overlapping is real football, just not the
				# first choice, and never at the expense of the last line.
				score -= 3.0
			var ball_advancement: float = ball.global_position.x * signf(_forward_axis.x)
			score += clampf((ball_advancement - advancement) * 0.20, -2.0, 3.0)
			if dist_to_ball < 5.0:
				score -= 2.5
			score += (p.personality.aggression + p.personality.risk_taking - 100.0) * 0.015
			return score

		Duty.SUPPORT_WIDE:
			# Natural width comes from the formation slot itself, so this
			# works unchanged for any future formation.
			var score: float = absf(p.formation_slot.y) * 5.0
			# Prefer the flank away from the ball -- that is the switch
			# option, and it is what actually stops the team collapsing
			# into one corner of the pitch around the carrier. Uses the
			# SMOOTHED play position: keyed off the raw ball, this +2.5
			# flipped for every candidate at once each time the ball
			# crossed the halfway line laterally.
			if signf(p.global_position.z) != signf(shape_ball_pos.z):
				score += 2.5
			if cat == "FWD" or cat == "DEF":
				score += 1.0
			return score

	return 0.0
