class_name AIController
extends RefCounted

## Simple, stateless per-frame decision logic for AI-controlled players.
## TeamController calls these each physics frame for every player on its
## roster that isn't the current human target (and, since v0.6, that
## doesn't have an active personality event driving it -- see
## PersonalityEventSystem). No memory/planning between frames on purpose --
## this is foundation-level AI, not tactics.
##
## Decision hierarchy per non-carrier player, in priority order:
##   1. immediate danger / 2. possession opportunity -- the team's single
##      nominated ball_challenger (nearest suitable teammate, computed once
##      per team per frame by TeamController -- see find_ball_challenger)
##      goes straight at the ball, whether it's loose or an opponent has it
##      (the ball's own position already tracks the carrier via the
##      dribble-steering force, so "press the carrier" and "chase the loose
##      ball" collapse into the same target).
##   3. defensive responsibility -- everyone else recovers toward
##      defensive shape, pulled harder for defenders, moderately for
##      midfielders, lightly for forwards (limited defensive support),
##      with a slight bias toward covering the most advanced opponent
##      (dangerous_opponent, also computed once per team per frame).
##   4. attacking opportunity / 5. formation positioning -- when the ball
##      carrier is a teammate, everyone else pushes into useful space
##      ahead of their formation slot (see _advance_distance) while
##      holding spacing from each other.
##
## Formation role (player.formation_role, via FormationManager.role_category)
## is a generic GK/DEF/MID/FWD bucket -- never a specific character -- so
## "defenders hold depth, wingers stretch wide, strikers push higher" comes
## from the role a character is currently playing, not who they are.
##
## Personality (player.personality) continuously modifies these decisions
## on top of role/stats via generic formulas reading trait values -- no
## per-character branches here. A disciplined/tactically-aware character
## holds tighter formation and marks tighter; a high-aggression/risk-taking
## character makes bigger forward runs, sprints more readily, and shoots
## from further out; better teamwork keeps tighter spacing. Every
## character's data alone accounts for the behavioral differences.

## v0.8.2: named high-level state per player per frame -- "decisions based
## on WHO HAS THE BALL, not just WHERE IS THE BALL". Still fully stateless/
## recomputed fresh every frame (see _determine_state); the "memory" that
## makes TRANSITION_* meaningful lives on PossessionManager
## (time_since_last_team_change), which already needs to persist for other
## reasons. Behavior differences between states are described inline in
## update_player() below.
enum AIState {
	HOLDING_POSSESSION,   ## this player personally has the ball
	ATTACKING_RUN,        ## FWD, team has it, staying advanced/making a run
	SUPPORTING_ATTACK,    ## DEF/MID, team has it, offering support
	TRANSITION_ATTACK,    ## team just won the ball -- push forward with urgency
	PRESSING,             ## the team's single nominated ball_challenger
	SEEKING_BALL,         ## ball is loose, not the challenger -- cover space around it
	MARKING,              ## opponent has it, covering shape/a dangerous opponent
	TRANSITION_DEFENSE,   ## team just lost the ball -- recover with urgency
	RECOVERING_SHAPE,     ## opponent has it, limited defensive duty (mainly FWD)
}

## A short window after last_team_with_possession changes counts as a
## genuine transition -- not just an ordinary loose-ball moment.
##
## v0.8.2 hotfix: shortened from 1.5s. With team possession genuinely
## changing hands every second or two in a 22-player match, a 1.5s window
## meant players were in a TRANSITION_* state almost permanently and
## essentially never reached the stable ATTACKING_RUN / SUPPORTING_ATTACK /
## MARKING states they're supposed to spend most of the match in --
## measured at only 1.8% of player-frames in ATTACKING_RUN. A transition
## should be a brief burst of urgency right after a turnover, not the
## default condition.
const TRANSITION_WINDOW := 0.8

## Minimum time a *shape-level* AI state must be held before a different
## shape-level state can replace it (see _determine_state).
##
## The second half of the oscillation fix. Even with a stable team
## possession signal, _determine_state is recomputed from scratch every
## single frame off instantaneous inputs, and several of its states have
## directly opposing movement targets (TRANSITION_ATTACK pushes upfield,
## TRANSITION_DEFENSE pulls back toward our own goal, SEEKING_BALL leans
## toward the ball). Any flicker in an input therefore became a full
## reversal of the player's movement intent -- diagnostics attributed
## 47 out of 47 observed direction reversals to a state change, and zero
## to anything else.
##
## Holding a shape-level state briefly does NOT freeze the player: the
## target within a held state is still recomputed every frame (the
## formation reference is ball-reactive, spacing and support-distance keep
## updating), so movement stays continuous and natural -- it just stays
## committed to one intention long enough to actually get somewhere.
const MIN_SHAPE_STATE_DWELL := 0.7

## Within this distance of the ball, a pressing player is treated as
## already in contact with it rather than still chasing it -- see the
## CONTEST branch in _duty_target().
##
## v0.8.4: cut from 1.6m. That radius existed to stop a press target and a
## carry target flipping through a ~40m swing as has_possession toggled,
## and it still does -- but 1.6m is most of a challenge, and blending the
## target toward the GOAL across it meant the contester spent the entire
## final approach aimed somewhere other than the ball. Measured in an
## isolated 1v1: a challenger hand-steered straight at the ball beat a
## STATIONARY carrier from 7 of 8 approach angles, while the real
## AIController-driven challenger managed only 4 of 8 -- it arced past a
## ball that was not moving. At 0.8m the blend still does its original job
## (the two intents agree once the ball is genuinely underfoot) without
## eating the challenge itself.
const PRESS_CONTACT_RANGE := 0.8
## Sprint threshold multiplier during a transition -- react with urgency
## to a turnover in either direction rather than casually strolling back.
const TRANSITION_SPRINT_MULT := 0.5

## v0.8.3: raised from 9.0. On a 52m pitch that put the shooting decision
## essentially inside the six-yard box, and a live match measured a carrier
## reaching it 0% of the time (closest approach over 45 seconds: 13.4m).
## The personality spread around it is unchanged.
const SHOOT_RANGE := 13.0
const SPACING_RADIUS := 6.0
## v0.8.3: widened from 0.6m. A target that is itself derived from live
## match geometry always carries a little residual motion; a deadband
## narrower than that motion means a player who has genuinely arrived still
## receives a fresh direction every frame.
const ARRIVE_RADIUS := 0.9
## Deadband for players holding a shape position rather than chasing the
## ball -- see the call site in update_player.
const SHAPE_ARRIVE_RADIUS := 1.6
## Deadband for a player actively challenging for the ball -- effectively
## none, so they press onto it rather than parking beside it.
const CONTEST_ARRIVE_RADIUS := 0.15
const SPRINT_DISTANCE := 8.0

const GK_LATERAL_RANGE := 3.5
const GK_FORWARD_RANGE := 2.5
const GK_DANGER_DISTANCE := 7.0
const GK_ARRIVE_RADIUS := 0.25


## An opponent closer than this to the ball carrier counts as real
## pressure -- pushes the release-the-ball decision below instead of
## holding it indefinitely. Roughly a lunging-tackle distance.
const PRESSURE_DISTANCE := 3.0

## Formation-role-category multipliers -- generic positional tendencies,
## not character-specific. Forwards make the biggest attacking runs and
## give the least defensive recovery ("limited defensive support");
## defenders are the mirror image (hold depth attacking, recover hardest
## defending); midfielders sit in between ("track dangerous areas" /
## "provide passing options").
const ROLE_ATTACK_MULT := {"GK": 0.0, "DEF": 0.45, "MID": 0.85, "FWD": 1.25}
const ROLE_DEFENSE_MULT := {"GK": 0.0, "DEF": 1.25, "MID": 0.9, "FWD": 0.55}

## Below this stamina ratio, positioning gets a small amount of random
## noise -- fatigue affecting "decision quality slightly" per the brief,
## without ever disabling the player (still moves, still presses, still
## defends; just a little less precise).
const FATIGUE_DECISION_THRESHOLD := 0.3
const FATIGUE_NOISE_SCALE := 1.5


## How quickly a player's steered-toward point catches up with the raw
## intent AIController just computed. This is a low-pass filter on the
## TARGET, not a delay on the DECISION: the decision is still made fresh
## every frame, the point simply cannot teleport. It exists to absorb
## per-frame numerical jitter (the spacing repulsion below, fatigue drift,
## a duty handover) that would otherwise show up as a full direction
## reversal, without the player ever pausing or waiting.
const TARGET_SMOOTH_TIME := 0.18

## Depth each role holds, in metres along the attacking axis, at full
## defensive intent (x) and full attacking intent (y). Interpolated
## continuously by TeamPlan.attack_intent -- this is what makes the whole
## team shuffle up and down the pitch together as possession changes,
## instead of every player snapping between two fixed layouts.
const ROLE_DEPTH_BAND := {
	"GK": Vector2(0.0, 0.0),
	"DEF": Vector2(-4.0, 3.0),
	"MID": Vector2(-3.0, 7.0),
	"FWD": Vector2(-2.0, 11.0),
}

## Duty geometry.
const PRESS_SUPPORT_GOALSIDE := 4.5   ## metres goal-side of the ball
const SUPPORT_SHORT_BACK_BIAS := 0.35 ## how much a short outlet sits behind the carrier
const SUPPORT_WIDE_TOUCHLINE := 0.85  ## fraction of half-width to hold
const RUN_BEHIND_DEPTH := 3.0         ## metres beyond the opponents' last line
const RUN_BEHIND_MAX_AHEAD := 16.0    ## never further ahead of the ball than a ball can travel
const MARK_GOALSIDE := 2.0

## Spacing repulsion is now a small correction on top of real duty
## geometry, not the main thing keeping players apart -- the duty slots do
## that structurally. Left strong, it fought the geometry and produced its
## own oscillation between two players repelling each other.
const SPACING_STRENGTH := 0.5
const SPACING_MAX_OFFSET := 1.5

## Once stopped at a target, a player will not start moving again until
## they are this multiple of the arrive radius away from it. Without the
## gap, a player parked exactly on their target twitched in and out of the
## deadzone forever.
const ARRIVE_RELEASE_MULT := 1.8
## Slowest approach a player will creep in at, as a fraction of full speed.
const MIN_APPROACH_SCALE := 0.18

## Carrier decision thresholds (see _decide_possession_action).
## Calibrated against the measured distribution of option scores in a live
## match (mean 0.79). At the original 0.62 the bar sat well BELOW the
## average available option, so a carrier passed roughly every 0.45s and
## the ball was recycled sideways forever -- 34 passes in 45s and not one
## carrier ever reached shooting range. The bar now sits above the typical
## option, so a pass is played when one is genuinely better than carrying,
## which is what makes the pass/dribble choice legible on screen.
const PASS_SCORE_BASE_THRESHOLD := 0.86
const PASS_THRESHOLD_PRESSURE_RELIEF := 0.22
const PASS_THRESHOLD_HOLD_RELIEF := 0.18
const HOLD_TOO_LONG_SECONDS := 2.5
const MIN_SETTLE_BEFORE_ACTION := 0.15

## How strongly a just-shot/just-passed player is pulled toward staying in
## the play, at full involvement. Not 1.0 -- they keep some of their normal
## shape, so this reads as "follow it in" rather than "abandon your post".
const MAX_FOLLOW_UP_WEIGHT := 0.8
## A player who has just shot holds a rebound position this far off the
## goal, on the ball's side of it.
const REBOUND_STANDOFF := 7.0
## An unpressured carrier takes at least this long on the ball before
## looking for a pass at all -- long enough to actually be dribbling.
##
## v0.8.4: cut from 0.45s. That figure was chosen in v0.8.3, when a carrier
## kept the ball until they chose to give it up; with a real ball contest
## (see BallContest) they are frequently dispossessed before 0.45s has even
## elapsed, so the gate was silently suppressing most passes -- measured AI
## passing in a live 30s match fell from 13-45 to 5. A quicker release is
## also the correct football answer once the ball can actually be taken off
## you.
const MIN_CARRY_BEFORE_PASS := 0.25
## How much clear space ahead raises the bar a pass has to clear.
const CARRY_SPACE_BONUS := 0.20
## How much easier a pass becomes as the carrier closes on the opponent
## goal -- the final ball is worth playing.
const FINAL_THIRD_RELEASE := 0.22
## Space ahead is measured out to this distance.
const FORWARD_SPACE_RANGE := 12.0
## How much an in-progress tackle against us lowers the bar for passing.
const CHALLENGE_RELEASE_RELIEF := 0.30
## Fraction of a completed tackle at which the carrier stops waiting for
## the minimum carry time and looks to release immediately.
const CHALLENGE_RELEASE_TRIGGER := 0.12


static func update_player(
	player: FootballPlayer,
	ball: RigidBody3D,
	possession: PossessionManager,
	teammates: Array,
	opponents: Array,
	own_goal_pos: Vector3,
	opponent_goal_pos: Vector3,
	formation_target: Vector3,
	ball_challenger: FootballPlayer = null,
	dangerous_opponent: Node3D = null,
	delta: float = 1.0 / 60.0,
	plan: TeamPlan = null
) -> void:
	var category: String = FormationManager.role_category(player.formation_role)
	# A player whose AI state was explicitly reset (-1) has no previous
	# intent to smooth from -- a switch, a match restart, or a first-ever
	# update. Smoothing across that boundary would drag a stale target from
	# before the reset into the new situation.
	var discontinuous: bool = player.ai_state < 0
	var state: int = _determine_state(player, possession, ball_challenger, category, delta)

	# In a real match TeamController hands us the team's plan, computed once
	# for the whole side (see TeamPlan). Isolated callers -- unit tests, the
	# debug overlay -- can omit it; we then build a throwaway one for this
	# player alone so there is exactly ONE positioning code path rather than
	# a legacy branch quietly drifting away from the real one.
	var effective_plan: TeamPlan = plan
	if effective_plan == null:
		effective_plan = _transient_plan(player, ball, possession, teammates, opponents, own_goal_pos, opponent_goal_pos, ball_challenger)

	var forward_axis: Vector3 = effective_plan.forward_axis()
	var target: Vector3

	if player.has_possession:
		# The ball-carrier layer. Carry at goal by default; the decision
		# hierarchy below may instead release the ball this frame (which
		# clears has_possession immediately, so there is no stale target to
		# act on afterwards).
		target = opponent_goal_pos
		_decide_possession_action(player, ball, opponent_goal_pos, opponents, forward_axis, effective_plan, delta)
	else:
		target = _duty_target(player, ball, effective_plan, formation_target, own_goal_pos, opponent_goal_pos, category)
		target += _spacing_offset(player, teammates)

	# v0.8.4: stay in the play you just made. Measured over a live match,
	# a player who had just SHOT closed 0.86m back toward their own
	# formation slot in the following second (a passer, by contrast,
	# already moved 0.92m further away -- so this was specific to shooting,
	# and it is exactly the reported "shoots, then immediately returns to
	# formation" behaviour). The cause is that a shot hands the ball to the
	# keeper, which flips team possession, which slews attack_intent
	# negative and drops the whole forward line -- including the player
	# who is standing in the six-yard box where a rebound will land.
	#
	# Blended by a decaying weight rather than switched on and off, so the
	# player drifts back into normal shape instead of snapping out of the
	# follow-up.
	var involvement: float = player.post_action_involvement()
	if involvement > 0.0 and not player.has_possession:
		var follow_up: Vector3 = _follow_up_target(player, ball, effective_plan, opponent_goal_pos)
		target = target.lerp(follow_up, involvement * MAX_FOLLOW_UP_WEIGHT)

	target += _fatigue_noise(player)
	target.x = clampf(target.x, -FormationManager.FIELD_HALF_LENGTH - 2.0, FormationManager.FIELD_HALF_LENGTH + 2.0)
	target.z = clampf(target.z, -FormationManager.FIELD_HALF_WIDTH - 1.0, FormationManager.FIELD_HALF_WIDTH + 1.0)

	player.ai_state = state
	player.ai_target = target

	# Smooth the point actually steered toward (see TARGET_SMOOTH_TIME).
	if discontinuous or not player._ai_target_initialized:
		player.ai_smoothed_target = target
		player._ai_target_initialized = true
	else:
		var blend: float = 1.0 - exp(-delta / maxf(TARGET_SMOOTH_TIME, 0.001))
		player.ai_smoothed_target = player.ai_smoothed_target.lerp(target, clampf(blend, 0.0, 1.0))

	# A player chasing the ball needs to be precise about it; a player
	# holding shape does not, and demanding 0.9m precision from them just
	# means reacting to noise in a target that is derived from live match
	# geometry. Deadband is therefore a property of the job.
	var duty_now: int = effective_plan.duty_of(player)
	var arrive: float = ARRIVE_RADIUS
	if player.has_possession:
		pass
	elif duty_now == TeamPlan.Duty.CONTEST or duty_now == TeamPlan.Duty.PRESS_SUPPORT:
		# v0.8.4: a player challenging for the ball keeps pressing right
		# onto it. At the normal 0.9m arrive radius the contester parked
		# just short of the ball and stopped -- which reads as backing off,
		# and (because BallContest scores how hard a challenger is closing)
		# let a challenge decay instead of completing. Measured: the real
		# AI challenger peaked at 0.32 of the 1.0 progress a tackle needs,
		# while the same challenger hand-steered into the ball reached a
		# full 1.00. They are stopped by the carrier's capsule either way;
		# the difference is whether they are still pressing into it.
		arrive = CONTEST_ARRIVE_RADIUS
	else:
		arrive = SHAPE_ARRIVE_RADIUS
	_move_toward(player, player.ai_smoothed_target, arrive)

	var sprint_threshold: float = _sprint_threshold(player)
	# Urgency comes from the team layer now: a turnover in either direction
	# makes the whole side move with intent for a beat.
	if effective_plan.transition_urgency > 0.0:
		sprint_threshold *= lerp(1.0, TRANSITION_SPRINT_MULT, effective_plan.transition_urgency)
	player.sprint_requested = player.global_position.distance_to(player.ai_smoothed_target) > sprint_threshold


## The PLAYER LEVEL of the hierarchy: turn one allocated duty into one
## position. Every branch derives from the same continuous inputs (the
## ball, the team's attack_intent, the player's own formation anchor), so a
## duty handover moves the target a few metres rather than swinging it to
## the opposite side of the pitch. That property -- not a dwell timer -- is
## what stops a changed decision from becoming a visible direction reversal.
static func _duty_target(
	player: FootballPlayer,
	ball: RigidBody3D,
	plan: TeamPlan,
	formation_target: Vector3,
	own_goal_pos: Vector3,
	opponent_goal_pos: Vector3,
	category: String
) -> Vector3:
	var fwd: Vector3 = plan.forward_axis()
	var duty: int = plan.duty_of(player)
	# Shape reads the smoothed "where is play" point; anyone actually going
	# at the ball reads its true position (see TeamPlan.shape_ball_pos).
	var ball_pos: Vector3 = plan.shape_ball_pos
	if duty == TeamPlan.Duty.CONTEST or duty == TeamPlan.Duty.PRESS_SUPPORT:
		ball_pos = ball.global_position

	# Continuous team shape: the anchor is already ball-reactive
	# (FormationManager.get_dynamic_position), and role depth breathes with
	# attack_intent rather than switching between opposed layouts.
	var band: Vector2 = ROLE_DEPTH_BAND.get(category, Vector2(-3.0, 7.0))
	var depth: float = lerp(band.x, band.y, clampf((plan.attack_intent + 1.0) * 0.5, 0.0, 1.0))
	# Personality still moves how far forward a character pushes when their
	# team is on the ball -- an adventurous player advances further than a
	# disciplined one from the identical formation slot (see
	# _advance_distance), scaled by how attacking the moment actually is.
	if plan.attack_intent > 0.0:
		depth += (_advance_distance(player) - 6.0) * 0.5 * plan.attack_intent
	var shape: Vector3 = formation_target + fwd * depth
	shape.y = formation_target.y

	match duty:
		TeamPlan.Duty.CONTEST:
			# Go win the ball -- but once we are standing on it, "run at the
			# ball" is a meaningless instruction that points somewhere
			# entirely different from the carrier's "take it forward". The
			# two intents are blended continuously by closeness so they
			# agree at contact and there is nothing to flip between.
			var closeness: float = clampf(1.0 - player.global_position.distance_to(ball_pos) / PRESS_CONTACT_RANGE, 0.0, 1.0)
			return ball_pos.lerp(opponent_goal_pos, closeness)

		TeamPlan.Duty.PRESS_SUPPORT:
			# Second man: stand between the ball and our goal, cutting the
			# forward option rather than doubling up on the tackle.
			var goalward: Vector3 = (own_goal_pos - ball_pos)
			goalward.y = 0.0
			var spot: Vector3 = ball_pos + _safe_normalize(goalward) * PRESS_SUPPORT_GOALSIDE
			spot.y = shape.y
			return shape.lerp(spot, 0.75)

		TeamPlan.Duty.SUPPORT_SHORT:
			# A real outlet: a passing distance off the ball, on the side
			# this player's formation slot already puts them, and a little
			# behind the carrier so the pass is playable.
			#
			# The angle is taken from the player's SHAPE ANCHOR, never from
			# their live position. Deriving it from where the player
			# currently stands makes the target a function of the player who
			# is chasing it: once they arrive it sits exactly on them, every
			# small perturbation rotates it around them, and they chase it
			# in a different direction every frame without ever converging.
			# Measured directly -- 136 of 150 movement reversals in a live
			# match happened with the player already within 2.5m of their
			# own target, i.e. this exact degenerate attractor, not the
			# arrival overshoot that had already been fixed.
			var from_ball: Vector3 = shape - ball_pos
			from_ball.y = 0.0
			var dir: Vector3 = _safe_normalize(_safe_normalize(from_ball) - fwd * SUPPORT_SHORT_BACK_BIAS)
			var spot: Vector3 = ball_pos + dir * TeamPlan.SUPPORT_SHORT_DISTANCE
			spot.y = shape.y
			return shape.lerp(spot, 0.7)

		TeamPlan.Duty.SUPPORT_WIDE:
			# Stretch the pitch. Width comes from the player's own formation
			# slot, so this works for any future formation unchanged.
			# Side comes from the formation slot (fixed for the match). A
			# central player with no natural side takes the flank away from
			# the ball -- the switch option -- which is stable in the ball's
			# position rather than in their own.
			var side: float = signf(player.formation_slot.y)
			if absf(player.formation_slot.y) <= 0.05:
				side = -signf(ball_pos.z) if absf(ball_pos.z) > 0.5 else 1.0
			if side == 0.0:
				side = 1.0
			var spot := Vector3(
				ball_pos.x + fwd.x * 3.0,
				shape.y,
				side * FormationManager.FIELD_HALF_WIDTH * SUPPORT_WIDE_TOUCHLINE)
			return shape.lerp(spot, 0.65)

		TeamPlan.Duty.RUN_BEHIND:
			# Get beyond their last line, but never further ahead of the
			# ball than a pass could actually reach -- a striker standing
			# 30m clear is not making a run, he is out of the game.
			var beyond: float = plan.opponent_last_line_x + fwd.x * RUN_BEHIND_DEPTH
			var cap: float = ball_pos.x + fwd.x * RUN_BEHIND_MAX_AHEAD
			var x: float = minf(beyond, cap) if fwd.x > 0.0 else maxf(beyond, cap)
			# Never run past the goal line itself.
			var limit: float = opponent_goal_pos.x - fwd.x * 2.0
			x = minf(x, limit) if fwd.x > 0.0 else maxf(x, limit)
			return Vector3(x, shape.y, shape.z)

		TeamPlan.Duty.MARK:
			var opponent: FootballPlayer = plan.mark_target_of(player)
			if opponent == null or not is_instance_valid(opponent):
				return _cover_space_target(shape, ball_pos, own_goal_pos, plan, category)
			var goalward: Vector3 = (own_goal_pos - opponent.global_position)
			goalward.y = 0.0
			var spot: Vector3 = opponent.global_position + _safe_normalize(goalward) * MARK_GOALSIDE
			spot.y = shape.y
			return shape.lerp(spot, 0.7)

	return _cover_space_target(shape, ball_pos, own_goal_pos, plan, category)


## Where a player who has just played the ball should be while the move
## they started is still live.
##
## After a SHOT: follow it in. Hold a rebound position between the ball and
## the goal rather than turning for home -- if the keeper parries, that is
## where the ball comes back to.
## After a PASS: keep going. Continue past the ball's new position on the
## attacking axis, which is what makes a give-and-go possible at all.
static func _follow_up_target(player: FootballPlayer, ball: RigidBody3D, plan: TeamPlan, opponent_goal_pos: Vector3) -> Vector3:
	var fwd: Vector3 = plan.forward_axis()
	var ball_pos: Vector3 = ball.global_position

	if player.post_action_kind == FootballPlayer.KickKind.SHOT:
		var from_goal: Vector3 = player.global_position - opponent_goal_pos
		from_goal.y = 0.0
		var spot: Vector3 = opponent_goal_pos + _safe_normalize(from_goal) * REBOUND_STANDOFF
		spot.y = player.global_position.y
		return spot

	# A pass: push on beyond where the ball now is, staying in our own lane
	# so this is a supporting run rather than a chase after our own pass.
	var spot := Vector3(
		ball_pos.x + fwd.x * TeamPlan.SUPPORT_SHORT_DISTANCE,
		player.global_position.y,
		player.global_position.z)
	return spot


## Holding shape is a real job, not "nothing to do". The point is always
## derived from where the ball currently is, so it keeps moving as play
## moves -- the old fallback resolved to a near-static formation point,
## which is exactly why defenders measured 40% of all frames completely
## stationary and midfielders "became inactive when the ball was far away".
static func _cover_space_target(shape: Vector3, ball_pos: Vector3, own_goal_pos: Vector3, plan: TeamPlan, category: String) -> Vector3:
	var defend_weight: float = clampf(-plan.attack_intent, 0.0, 1.0) * ROLE_DEFENSE_MULT.get(category, 1.0)
	var cover_point: Vector3 = own_goal_pos.lerp(ball_pos, 0.55)
	cover_point.y = shape.y
	return shape.lerp(cover_point, clampf(0.12 + 0.28 * defend_weight, 0.0, 0.6))


## A single-player stand-in TeamPlan for isolated callers (see
## update_player). Phase is snapped rather than slewed -- there are no
## previous frames to slew from.
static func _transient_plan(
	player: FootballPlayer,
	ball: RigidBody3D,
	possession: PossessionManager,
	teammates: Array,
	opponents: Array,
	own_goal_pos: Vector3,
	opponent_goal_pos: Vector3,
	ball_challenger: FootballPlayer
) -> TeamPlan:
	var plan := TeamPlan.new()
	plan.setup(player.team_id, own_goal_pos, opponent_goal_pos)
	# One big step so attack_intent lands fully on its target this frame.
	plan.update(teammates, opponents, ball, possession, 10.0)
	# Respect an explicitly-supplied challenger: callers that nominate one
	# are asserting "this player is the designated ball-winner".
	if ball_challenger != null:
		plan.duties[ball_challenger.get_instance_id()] = TeamPlan.Duty.CONTEST
		ball_challenger.ai_duty = TeamPlan.Duty.CONTEST
	return plan


## team_has_ball uses PossessionManager's *sticky* last_team_with_possession
## rather than the instantaneous possessing_team (which drops to -1 on
## every single loose-ball tick, even a one-frame bounce) -- see that
## field's doc comment for why: without it, a forward's advanced run (and
## every other attacking player's shape) instantly, visibly collapsed back
## to defensive recovery on any brief loose touch mid-attack, then
## re-advanced a moment later, reading as "gave up the run".
## Resolves the ONE authoritative state for this player this frame:
## _desired_state() picks by priority, then a dwell rule decides whether
## we're allowed to act on that yet (see MIN_SHAPE_STATE_DWELL).
##
## delta defaults to 0 so this can be called as a pure query (tests, the
## debug overlay) without advancing the dwell clock.
static func _determine_state(player: FootballPlayer, possession: PossessionManager, ball_challenger: FootballPlayer, category: String, delta: float = 0.0) -> int:
	var desired: int = _desired_state(player, possession, ball_challenger, category)
	var current: int = player.ai_state

	player.ai_state_time += delta

	if current < 0 or desired == current:
		return desired

	# Priority 1, immediate ball interaction: having the ball, or being
	# the one nominated to go win it, is never delayed in either
	# direction. These are unambiguous "the ball is right here" facts
	# rather than shape opinions, and they're already individually
	# stabilized (possession by PossessionManager's hysteresis, pressing
	# by TeamController's sticky challenger), so they can't flicker the
	# way the shape states could.
	if _is_ball_interaction(desired) or _is_ball_interaction(current):
		player.ai_state_time = 0.0
		return desired

	# Priorities 2-5 (defensive responsibility / attacking support /
	# formation shape / recovery) are all shape-level opinions about where
	# to stand. Committing to one for a beat is what stops the whiplash.
	if player.ai_state_time < MIN_SHAPE_STATE_DWELL:
		return current

	player.ai_state_time = 0.0
	return desired


static func _is_ball_interaction(state: int) -> bool:
	return state == AIState.HOLDING_POSSESSION or state == AIState.PRESSING


static func _desired_state(player: FootballPlayer, possession: PossessionManager, ball_challenger: FootballPlayer, category: String) -> int:
	var team_has_ball: bool = possession.last_team_with_possession == player.team_id
	var in_transition: bool = possession.time_since_last_team_change < TRANSITION_WINDOW

	# 1. Immediate ball interaction.
	if player.has_possession:
		return AIState.HOLDING_POSSESSION
	if player == ball_challenger:
		return AIState.PRESSING

	# Nobody has claimed the ball yet at all (kickoff, or straight after a
	# reset) -- there is no attacking/defending phase to be in, so everyone
	# shapes up around the ball itself.
	if possession.last_team_with_possession == -1:
		return AIState.SEEKING_BALL

	if team_has_ball:
		# 3. Active attacking / support movement.
		if in_transition:
			return AIState.TRANSITION_ATTACK
		if category == "FWD":
			return AIState.ATTACKING_RUN
		return AIState.SUPPORTING_ATTACK

	# 2. Active defensive responsibility.
	#
	# Deliberately does NOT branch on possession.is_loose. Once a team has
	# claimed the ball, whether it is loose *this instant* is the wrong
	# question for a player who isn't the one going to win it -- exactly
	# one player presses (PRESSING, above), and everyone else holds shape.
	# Branching on is_loose here previously produced two bad behaviors at
	# once: it was the remaining source of movement oscillation after the
	# possession-confirm fix (SEEKING_BALL leans toward the ball while
	# MARKING pulls back toward our own goal, so a flickering is_loose
	# reversed a defender's direction), and it was itself the "defenders
	# are ball-obsessed / swarm the ball" behavior. Shape follows WHO has
	# the ball, not where it momentarily bounced.
	if in_transition:
		return AIState.TRANSITION_DEFENSE
	if category == "DEF" or category == "MID":
		return AIState.MARKING
	# 5. Idle / recovery positioning.
	return AIState.RECOVERING_SHAPE


## v0.8.1: the actual decision hierarchy for an AI player currently in
## possession -- before this existed, update_player()'s attacking branch
## only ever checked "am I in shooting range," so an AI player who never
## got that close simply carried the ball forever; nothing here ever
## called execute_pass() for an AI player at all. Evaluated in priority
## order, self-limiting by construction: execute_shot()/execute_pass()
## both clear has_possession immediately, so once either fires this
## player exits the "attacking and has_possession" branch entirely on the
## very next frame -- there is no separate re-entrancy guard needed.
##
## Both shoot and pass are gated by a per-second *rate* (scaled by delta,
## not a flat per-frame probability) so the eventual decision is
## frame-rate independent and, for a genuinely good chance, fires within
## roughly a second or two rather than instantly on the very first
## qualifying frame or never at all -- it reads as "decided", not as
## "rolled a die every tick". Stats (shooting/passing) and personality
## (confidence/risk_taking/competitiveness for shooting; tactical_awareness/
## teamwork for passing) bias the rate per player, so different characters
## genuinely behave differently -- never a hard-coded per-character branch.
static func _decide_possession_action(
	player: FootballPlayer,
	ball: RigidBody3D,
	opponent_goal_pos: Vector3,
	opponents: Array,
	forward_axis: Vector3,
	plan: TeamPlan,
	_delta: float
) -> void:
	# A player who has only just got the ball under control gets a beat to
	# settle before doing anything with it -- otherwise a tackle winner can
	# fire a shot on the same frame they touched it, which reads as a
	# deflection rather than a decision.
	if player.possession_time < MIN_SETTLE_BEFORE_ACTION:
		return

	var p: PersonalityData = player.personality
	var stats: PlayerData = player.player_data
	var nearest_opp: float = _nearest_opponent_distance(player, opponents)
	var pressure: float = clampf(1.0 - nearest_opp / PRESSURE_DISTANCE, 0.0, 1.0)
	# The goalkeeper does not count as "pressure" on a shot. A keeper 2m
	# away is the reason to shoot, not a reason to hesitate -- counting them
	# meant the closer a striker got to goal, the less willing they became
	# to have a go, which is exactly backwards.
	var shot_pressure: float = clampf(1.0 - _nearest_opponent_distance(player, opponents, true) / PRESSURE_DISTANCE, 0.0, 1.0)

	# 1. Shoot. Deterministic quality, not a per-frame dice roll: from a
	#    genuinely good position a striker shoots now, and from a poor one
	#    they never do. The old rate-based roll meant an open striker in
	#    front of goal could spend a second "deciding" and then pass the
	#    chance away instead -- and it made shooting statistically
	#    indistinguishable from passing to anyone watching.
	var shoot_range: float = _shoot_range(player)
	var dist_to_goal: float = player.global_position.distance_to(opponent_goal_pos)
	if dist_to_goal < shoot_range:
		var to_goal: Vector3 = opponent_goal_pos - player.global_position
		to_goal.y = 0.0
		var goal_dir: Vector3 = _safe_normalize(to_goal)
		# Being inside your own shooting range at all is worth something --
		# the previous formula was a bare (1 - d/range), so a shot taken
		# from the edge of the very range that permits it scored ~0 and was
		# never taken. Measured over a live match: 25 frames spent in
		# shooting range, average shot score 0.07 against a 0.37 threshold,
		# and consequently zero shots in 45 seconds.
		var closeness: float = clampf(1.0 - dist_to_goal / shoot_range, 0.0, 1.0)
		var range_quality: float = lerp(0.35, 1.0, closeness)
		# Shooting from a tight angle is a bad chance even from close in.
		var angle_quality: float = clampf(absf(goal_dir.dot(forward_axis)), 0.0, 1.0)
		angle_quality = lerp(0.45, 1.0, angle_quality)
		var shoot_score: float = range_quality * angle_quality * lerp(1.0, 0.45, shot_pressure)
		# The keeper is deliberately NOT counted as blocking the lane: they
		# are standing in it by definition, and requiring a clear line to
		# the goal past a goalkeeper means never shooting.
		if _shot_lane_blocked(player, goal_dir, dist_to_goal, opponents):
			shoot_score *= 0.55
		var shoot_skill: float = stats.shooting if stats else 50.0
		var boldness: float = (p.confidence + p.risk_taking + p.competitiveness) / 3.0
		# A confident, skilled shooter pulls the trigger from further out;
		# nobody shoots from a genuinely bad position.
		var shoot_threshold: float = lerp(0.55, 0.26, clampf((shoot_skill + boldness) / 200.0, 0.0, 1.0))
		player.last_shoot_score = shoot_score
		player.last_shoot_threshold = shoot_threshold
		if shoot_score >= shoot_threshold:
			player.execute_shot(clampf(0.45 + range_quality * 0.55, 0.0, 1.0))
			return

	# 2/3. Pass. A real evaluation with a real threshold, so the decision is
	#      legible: play the ball when a genuinely better option exists.
	#      The threshold falls under pressure (release it) and the longer
	#      the ball is held (stop dribbling into trouble) -- which is the
	#      direct fix for "AI ball carriers frequently keep possession too
	#      long" without resorting to randomness.
	var option: PassEvaluator.Option = PassEvaluator.best_option(
		player, player._get_aim_direction(), forward_axis, plan, FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI)
	if option != null:
		var pass_skill: float = stats.passing if stats else 50.0
		var pass_will: float = (p.tactical_awareness + p.teamwork) / 2.0
		var threshold: float = PASS_SCORE_BASE_THRESHOLD
		threshold -= PASS_THRESHOLD_PRESSURE_RELIEF * pressure
		threshold -= PASS_THRESHOLD_HOLD_RELIEF * clampf(player.possession_time / HOLD_TOO_LONG_SECONDS, 0.0, 1.0)
		# A better, more team-minded passer sees the pass a little earlier.
		threshold -= 0.10 * clampf((pass_skill + pass_will) / 200.0, 0.0, 1.0)
		# Carrying is the DEFAULT, not the leftover. A carrier with clear
		# grass in front of them has to be offered something genuinely
		# better before giving the ball up -- without this the AI released
		# it after ~0.17s every time (measured: 45 passes in 45s, and not
		# one carrier ever got within shooting range of a goal, because
		# nobody ever actually ran at one).
		threshold += CARRY_SPACE_BONUS * _forward_space(player, opponents, forward_axis)
		# v0.8.4: a carrier who can feel a tackle coming gets rid of it.
		# Without this the new ball-contest system and the pass decision
		# worked against each other -- challenges took the ball off carriers
		# before they had held it long enough to even look for a pass, and
		# measured AI passing in a live match fell from ~13-45 per 30s to 5.
		# Reacting to the challenge is both the fix and the realistic
		# behaviour: under a genuine challenge you play the ball early.
		var challenge_ratio: float = _incoming_challenge(player, opponents)
		threshold -= CHALLENGE_RELEASE_RELIEF * challenge_ratio
		# ...but inside the final third, keep the ball moving. A carrier who
		# is nearly in shooting range should be looking for the killer ball,
		# not holding it because there happens to be grass ahead.
		var goal_proximity: float = clampf(1.0 - (player.global_position.distance_to(opponent_goal_pos) - _shoot_range(player)) / 14.0, 0.0, 1.0)
		threshold -= FINAL_THIRD_RELEASE * goal_proximity
		var must_release: bool = pressure > 0.5 or player.possession_time > HOLD_TOO_LONG_SECONDS \
			or challenge_ratio > CHALLENGE_RELEASE_TRIGGER
		if not must_release and player.possession_time < MIN_CARRY_BEFORE_PASS:
			return
		player.last_pass_score = option.score
		player.last_pass_threshold = threshold
		if option.score >= threshold:
			player.execute_pass(FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI, forward_axis, plan)
			return

	# 4. Dribble: update_player() already left the target pointed at goal.


## Like PassEvaluator's lane check, but ignores the goalkeeper (who is
## always between a shooter and the goal) and only counts defenders in the
## first stretch of the flight, where a block is actually plausible.
static func _shot_lane_blocked(player: FootballPlayer, dir: Vector3, dist: float, opponents: Array) -> bool:
	for opp in opponents:
		if opp == null or not is_instance_valid(opp) or opp.is_goalkeeper:
			continue
		var to_opp: Vector3 = opp.global_position - player.global_position
		to_opp.y = 0.0
		var along: float = to_opp.dot(dir)
		if along <= 0.4 or along >= dist * 0.7:
			continue
		if (to_opp - dir * along).length() < 1.2:
			return true
	return false


## How far through a tackle the most advanced challenge against this player
## is, as a fraction of a completed one (see BallContest). 0 when nobody is
## challenging.
static func _incoming_challenge(player: FootballPlayer, opponents: Array) -> float:
	var worst := 0.0
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		worst = maxf(worst, opp.challenge_progress)
	return clampf(worst / maxf(BallContest.CHALLENGE_TIME_REQUIRED, 0.001), 0.0, 1.0)


## 0.0 = an opponent is directly in front of us, 1.0 = clear grass ahead
## out to FORWARD_SPACE_RANGE. Only counts opponents actually in the way,
## not ones alongside or behind.
static func _forward_space(player: FootballPlayer, opponents: Array, forward_axis: Vector3) -> float:
	var fwd: Vector3 = _safe_normalize(forward_axis)
	var nearest := FORWARD_SPACE_RANGE
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		var to_opp: Vector3 = opp.global_position - player.global_position
		to_opp.y = 0.0
		var along: float = to_opp.dot(fwd)
		if along <= 0.0 or along > FORWARD_SPACE_RANGE:
			continue
		if (to_opp - fwd * along).length() > 3.0:
			continue
		nearest = minf(nearest, along)
	return clampf(nearest / FORWARD_SPACE_RANGE, 0.0, 1.0)


static func _nearest_opponent_distance(player: FootballPlayer, opponents: Array, skip_goalkeeper: bool = false) -> float:
	var best := INF
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		if skip_goalkeeper and opp.is_goalkeeper:
			continue
		var d: float = player.global_position.distance_to(opp.global_position)
		if d < best:
			best = d
	return best


static func update_goalkeeper(player: FootballPlayer, ball: RigidBody3D, own_goal_pos: Vector3) -> void:
	if player.has_possession:
		# Don't dribble around the box -- clear it upfield immediately.
		player.execute_shot(0.5)
		player.move_input = Vector2.ZERO
		player.sprint_requested = false
		return

	var center_dir_x: float = -signf(own_goal_pos.x) if own_goal_pos.x != 0.0 else 1.0

	var target := own_goal_pos
	target.z = clampf(ball.global_position.z, own_goal_pos.z - GK_LATERAL_RANGE, own_goal_pos.z + GK_LATERAL_RANGE)

	var dist_to_ball_x: float = absf(ball.global_position.x - own_goal_pos.x)
	if dist_to_ball_x < GK_DANGER_DISTANCE:
		var step: float = clampf(GK_DANGER_DISTANCE - dist_to_ball_x, 0.0, GK_FORWARD_RANGE)
		target.x = own_goal_pos.x + center_dir_x * step

	_move_toward(player, target, GK_ARRIVE_RADIUS)
	player.sprint_requested = dist_to_ball_x < GK_DANGER_DISTANCE


## Nearest suitable teammate to the ball -- the single player who presses/
## challenges for it this frame (see the decision-hierarchy note above).
## Computed once per team per frame by TeamController rather than
## redundantly inside every single player's update, which used to be an
## O(team_size * opponents) waste repeated once per non-marking player;
## now it's O(team_size) once.
static func find_ball_challenger(teammates: Array, ball: RigidBody3D) -> FootballPlayer:
	return _closest_to(teammates, ball.global_position)


## The most advanced opponent (closest to our own goal) -- a cheap proxy
## for "who's making the dangerous run," used to bias non-challenging
## defenders' fallback shape toward covering them. Also computed once per
## team per frame by TeamController, for the same reason as
## find_ball_challenger above.
static func find_dangerous_opponent(opponents: Array, own_goal_pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for opp in opponents:
		if opp.is_goalkeeper:
			continue
		var d: float = opp.global_position.distance_to(own_goal_pos)
		if d < best_dist:
			best_dist = d
			best = opp
	return best


## v0.8.3: approach speed now ramps down as a player nears their target,
## and the deadzone they stop in is wider than the deadzone they restart
## from.
##
## The previous version drove at FULL input right up to a 0.6m radius and
## then cut to zero. A player decelerates at 20 m/s^2, so from base speed
## that needs 0.63m and from a sprint 1.8m -- they therefore always coasted
## straight through the target, found it behind them, and drove back. That
## is a self-sustaining limit cycle with no external trigger at all, and it
## accounted for 31% of every direction reversal measured in a live match
## (43 of 140 over 45 seconds). It is also exactly the reported symptom of
## a player who "becomes stiff or stops moving" and then reverses: the
## reversals cluster precisely where a player has arrived somewhere.
static func _move_toward(player: FootballPlayer, target: Vector3, arrive_radius: float) -> void:
	var to_target: Vector3 = target - player.global_position
	to_target.y = 0.0
	var dist: float = to_target.length()

	# Hysteresis: having stopped, do not set off again for a few
	# centimetres of drift.
	var stop_radius: float = arrive_radius
	if player.move_input == Vector2.ZERO:
		stop_radius = arrive_radius * ARRIVE_RELEASE_MULT
	if dist <= stop_radius:
		player.move_input = Vector2.ZERO
		return

	var speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	var stopping_distance: float = (speed * speed) / (2.0 * maxf(player.deceleration, 0.01))
	var slow_radius: float = maxf(arrive_radius * 2.0, stopping_distance + 0.35)
	var scale: float = clampf(dist / slow_radius, MIN_APPROACH_SCALE, 1.0)
	player.move_input = Vector2(to_target.x, to_target.z).normalized() * scale


static func _spacing_offset(player: FootballPlayer, teammates: Array) -> Vector3:
	# v0.8.3: pulled in hard. Duty geometry now spreads the team out
	# structurally, so this only has to stop two players standing on each
	# other. Left at its old 4-8m it was a mutual repulsion between every
	# nearby pair -- each player shoving the other's target, which moved
	# them, which shoved it back: an oscillator in its own right, and one
	# that operated at exactly the scale of normal team spacing.
	var spacing_radius: float = lerp(2.5, 4.0, player.personality.teamwork / 100.0)
	var offset := Vector3.ZERO
	for mate in teammates:
		if mate == player or mate.is_goalkeeper:
			continue
		var diff: Vector3 = player.global_position - mate.global_position
		diff.y = 0.0
		var dist := diff.length()
		if dist < spacing_radius and dist > 0.01:
			offset += diff.normalized() * (spacing_radius - dist) * SPACING_STRENGTH
	# Clamped: spacing is a nudge on top of real duty geometry now, and an
	# unbounded repulsion between two players standing close was its own
	# oscillator (each shoved the other's target, which moved them, which
	# shoved it back).
	return offset.limit_length(SPACING_MAX_OFFSET)


## Higher aggression/risk-taking/impulsiveness -> bigger forward runs when
## supporting an attack; higher discipline pulls that back in slightly so
## a disciplined-but-aggressive character doesn't fully abandon shape.
static func _advance_distance(player: FootballPlayer) -> float:
	var p: PersonalityData = player.personality
	var eagerness: float = (p.aggression + p.risk_taking) / 2.0
	var distance: float = lerp(3.0, 9.0, eagerness / 100.0)
	distance -= (p.discipline - 50.0) * 0.02
	return clampf(distance, 2.0, 10.0)


## Higher aggression/risk-taking/impulsiveness -> sprints from further
## away (more eager); higher stamina_management/composure -> waits until
## closer (doesn't waste energy / stays composed).
static func _sprint_threshold(player: FootballPlayer) -> float:
	var p: PersonalityData = player.personality
	var eagerness: float = (p.aggression + p.risk_taking + p.impulsiveness) / 3.0
	var restraint: float = (p.stamina_management + p.composure) / 2.0
	var threshold: float = SPRINT_DISTANCE - (eagerness - 50.0) * 0.06 + (restraint - 50.0) * 0.04
	return clampf(threshold, 4.0, 14.0)


## Higher confidence/risk-taking -> willing to shoot from further out.
static func _shoot_range(player: FootballPlayer) -> float:
	var p: PersonalityData = player.personality
	var boldness: float = (p.confidence + p.risk_taking) / 2.0
	var range_val: float = SHOOT_RANGE + (boldness - 50.0) * 0.1
	return clampf(range_val, 6.0, 14.0)


## Small positional imprecision once a player is significantly fatigued --
## "decision quality slightly" affected by stamina, never enough to stop
## them moving/pressing/defending normally.
static func _fatigue_noise(player: FootballPlayer) -> Vector3:
	var stamina_ratio: float = (player.current_stamina / player.max_stamina) if player.max_stamina > 0.0 else 1.0
	if stamina_ratio >= FATIGUE_DECISION_THRESHOLD:
		return Vector3.ZERO
	var magnitude: float = (FATIGUE_DECISION_THRESHOLD - stamina_ratio) * FATIGUE_NOISE_SCALE
	# v0.8.3: a smooth per-player drift rather than a fresh random offset
	# every physics frame. The old version re-rolled the target up to 1.5m
	# in an arbitrary direction 60 times a second, which for a tired player
	# is a direction reversal generator -- the effect was meant to be
	# "slightly imprecise positioning", not a tremor. Deterministic (seeded
	# off the instance id), so it is also reproducible in tests.
	var phase: float = float(player.get_instance_id() % 997)
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	return Vector3(sin(t * 0.7 + phase) * magnitude, 0.0, cos(t * 0.9 + phase * 1.7) * magnitude)


static func _closest_to(players: Array, pos: Vector3) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_dist := INF
	for p in players:
		if p.is_goalkeeper:
			continue
		var d: float = p.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = p
	return best


static func _safe_normalize(v: Vector3) -> Vector3:
	if v.length() < 0.001:
		return Vector3.FORWARD
	return v.normalized()
