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
	RECEIVE,        ## a pass is on its way to me -- go and meet it
	## ---- AI 2.0; appended so previously stored duty ints keep their meaning
	INTERCEPT,      ## stand in the pass they want to play, not next to the ball
	REST_DEFENCE,   ## deliberately does NOT engage: holds the line behind everything
}


## ---- Defending as a unit rather than as ten ball-chasers ----
##
## CONTEST, PRESS_SUPPORT, MARK and COVER_SPACE already gave the side a
## presser, a second man, man-markers and a shape. Two things a defending side
## does were missing, and both are things a player does INSTEAD of going near
## the ball -- which is exactly the behaviour QA describes as absent.
##
##   INTERCEPT     occupy the lane the carrier wants to play, so the pass is
##                 not on. It is a midfielder's job and it is the most visible
##                 single piece of "the midfield is participating".
##   REST_DEFENCE  the deepest players stay deep ON PURPOSE. Without it the
##                 whole back line is eligible to be pulled forward by any
##                 duty that scores on proximity, which is what makes a
##                 defence look like it is chasing.
##
## Both are capped hard. A side with four players standing in lanes has nobody
## pressing, which is a different kind of bad football.
const MAX_INTERCEPT := 2
const MAX_REST_DEFENCE := 2
## Test-only lever: allocate neither of the two new defensive duties, restoring
## the pre-AI-2.0 defensive shape. It exists so their effect can be measured as
## a paired A/B on the same build rather than argued from a single run of a
## noisy live-match statistic. Always true in normal play.
static var unit_defending_enabled := true
## An interceptor only exists while the opposition genuinely has the ball --
## there is no lane to cut on a ball nobody controls. Deliberately loose: the
## block already only runs when we do NOT have the ball, so this only has to
## exclude the moments we are still committed to attacking.
const INTERCEPT_MIN_INTENT := 0.25
## What a lane in open midfield is worth relative to the same lane into our own
## box. Not zero: cutting a pass out before it becomes dangerous is the whole
## job. See the measured correction in _fill_intercept.
const DANGER_FLOOR := 0.40
## How far along a candidate lane the interceptor stands, as a fraction.
## Nearer the receiver than the passer: standing on the carrier's toes is
## pressing, not intercepting.
const INTERCEPT_LANE_FRACTION := 0.62
## A lane is only worth cutting if it actually threatens us.
const INTERCEPT_MIN_THREAT := 0.18
## Below this the ball is not going anywhere and there is no line to cut; it is
## a loose ball for CONTEST to go and win.
const TRAVELLING_MIN_SPEED := 3.0
## How near the ball's projected arrival an opponent has to be before we treat
## the ball as running TO them rather than merely rolling.
const TRAVELLING_RECEIVER_RADIUS := 6.0

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
##
## v0.8.7: raised again, 6.0 -> 7.5, for the same reason and by the same
## measurement. Duty suitability is scored largely on where players ARE, and
## lane-aware support positioning now moves them a few metres to open a
## passing lane -- which feeds straight back into those distances and puts
## more near-ties in front of this tie-break. Measured over a settled
## passage: 0.348 duty changes per player per second against a 0.30 ceiling,
## and back under it at 7.5. The rule is unchanged; it is sized for how much
## its inputs now move.
const DUTY_RETENTION_BONUS := 7.5

## Slot ceilings. These numbers ARE the "not every player should contest /
## not every player should make the same run" rule, expressed structurally.
const MAX_RUN_BEHIND := 2
const MAX_SUPPORT_WIDE := 2
const MAX_SUPPORT_SHORT := 2
const MAX_MARKERS := 3

## The squad size those ceilings are written for -- see _squad_scaled.
const NOMINAL_SQUAD := 11

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

## Floors applied while this side actually holds the ball, independent of
## the slewed attack_intent -- see the allocation. Kept small on purpose:
## a short outlet, one runner stretching the last line, and one wide option
## is enough to give a carrier somewhere to play, without the whole side
## abandoning shape the moment they win possession.
## One short outlet, not two: at two, the floor both crowded the carrier
## (1.48 teammates inside 5m, against a test that wants them given space)
## and used up a player who would otherwise hold the attacking line, which
## left the forward line hovering either side of its 80% requirement. One
## guaranteed outlet is all a carrier needs to have somewhere to play.
const MIN_SUPPORT_SHORT_WHEN_HOLDING := 1
const MIN_SUPPORT_WIDE_WHEN_HOLDING := 1
const MIN_RUN_BEHIND_WHEN_HOLDING := 1

## Where on the holding ramp each of those floors arrives. Staggered so
## settling on the ball does not reassign three players in the same frame --
## see _holding_ramp and the allocation. At INTENT_SLEW_RATE the three land
## roughly 0.16s apart.
const FLOOR_RAMP_BEHIND := 0.25
const FLOOR_RAMP_SHORT := 0.50
const FLOOR_RAMP_WIDE := 0.75

## Ceiling on players simultaneously staying in a move they just played.
## Bounded only so a flurry of quick passes cannot hand the entire side a
## follow-up job at once; in practice one or two hold it.
## v0.8.8: 3 -> 2. The comment above says "in practice one or two hold it",
## and that was true when it was written; v0.8.8's passing rate (49/min in a
## rendered match) reaches the cap far more often. Measured as the largest
## single contributor to teammates crowding their own carrier -- 0.46 of the
## 1.33 average inside 5m -- because a follow-up player is by definition
## still near where the ball was played from. Two keeps the give-and-go the
## duty exists for.
const MAX_FOLLOW_UP := 2

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
## Sticky "this is our possession" -- see the assignment in update() and the
## support floors in the allocation.
var _settled_possession_ours: bool = false
## 0..1 ramp toward "we are holding the ball", slewed at INTENT_SLEW_RATE so
## the possession floors migrate in and out instead of switching on one
## frame -- see where it is updated.
var _holding_ramp: float = 0.0
## The opponents' deepest outfield player (their last line). RUN_BEHIND
## targets are anchored just beyond this rather than at a fixed distance,
## so a run in behind is actually in behind something.
var opponent_last_line_x: float = 0.0

var duties: Dictionary = {}       ## instance_id -> Duty
var mark_targets: Dictionary = {} ## instance_id -> FootballPlayer being marked
## instance_id -> world point an INTERCEPT player is cutting off. Stored rather
## than recomputed in the movement layer so the lane a player is standing in
## does not change identity between the frame it was chosen and the frame it
## is walked to.
var intercept_points: Dictionary = {}

## The shared read of the pitch this plan is reasoning from, rebuilt once per
## team per frame by TeamController. Everything below that asks a football
## question -- how pressured, how open, which lane, where is the ball going --
## asks it here rather than working out its own answer.
var perception: FootballPerception = null

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
	# v0.8.8: the STICKY answer to "is this our possession", for the support
	# floors in the allocation below. It has to be this signal and not
	# `we_have_ball`: the instantaneous one drops out every time the ball
	# bobbles loose, so a floor keyed on it toggled the support slots on and
	# off with it and churned duties -- measured at 0.341 changes per player
	# per second against a 0.30 ceiling, which is the very oscillation the
	# comment above warns about, reintroduced one layer up.
	_settled_possession_ours = possession.last_team_with_possession == team_id
	# ...and the floors it drives RAMP rather than switch.
	#
	# v0.8.8, second correction. Making the signal sticky stopped it
	# flapping, but it is still a STEP: on the frame possession settles, all
	# three floors appear at once, several players are reassigned in the
	# same instant, and each of their targets jumps several metres. That is
	# a whole-team about-face triggered by a phase change -- precisely what
	# v0.8.5 exists to prevent, and it measured exactly there: reversals
	# landing within half a second of a phase change rose to 25%, 25%, 22%
	# against a 22% ceiling the v0.8.7 build cleared on every run.
	#
	# The fix is the one this file already uses everywhere else: slew, do
	# not switch (see INTENT_SLEW_RATE). The floors are gated on a ramp at
	# the same rate, and each floor is gated at a DIFFERENT point on it, so
	# the three slots arrive spread across the ramp instead of together --
	# the same staggering _slots() gets for free by rounding different
	# ceilings against a moving weight.
	_holding_ramp = move_toward(
		_holding_ramp, 1.0 if _settled_possession_ours else 0.0, INTENT_SLEW_RATE * delta)

	var previous: Dictionary = duties
	# Keep the previous marking assignments too -- the retention check in
	# _assign_markers compares against them, and clearing mark_targets
	# before running it made that check compare against an empty dictionary
	# and therefore ALWAYS fail, so every marker was re-picked from scratch
	# every single frame.
	var previous_marks: Dictionary = mark_targets
	duties = {}
	mark_targets = {}
	intercept_points = {}

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

		# 2c. Cut the pass, and hold the line.
		#
		# Allocated here, before the shape slots, because both are jobs a
		# player takes INSTEAD of joining the shape -- and both have to be
		# taken by somebody the shape would otherwise have sent toward the
		# ball. Gated on the slewed intent like every other defensive slot so
		# they migrate in and out rather than appearing on one frame.
		# Deliberately NOT gated on there being a carrier: _fill_intercept
		# handles both a carrier's pass lane and a ball already travelling, and
		# the second case is the common one (measured: an opponent is carrying
		# on 5.8% of team-frames).
		if unit_defending_enabled and attack_intent < INTERCEPT_MIN_INTENT:
			_fill_intercept(available, opponents, previous)
			_fill_rest_defence(available, previous)

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

	# v0.9.1: ...and the OTHER half of a pass, which did not exist.
	#
	# FOLLOW_UP gave the passer a job once the ball had left them. Nothing
	# ever gave the intended RECEIVER one. CONTEST is the only duty in the
	# game that actively goes to the ball, and it is assigned by proximity
	# on both sides -- so while a pass was in flight the defending team's
	# contester ran at it and the man it was played to stood on his support
	# position waiting. Measured over 90 seconds of AI play: 90 passes, 61
	# collected by an opponent, FOUR reaching the intended receiver. That is
	# the "bots pass straight to the enemy" QA reported; the evaluator never
	# selected an opponent even once (measured: 0), it simply played to a
	# team-mate who had not been told to come and get it.
	# Assigned LAST, after every other duty has been allocated -- see the
	# call at the end of this function. It used to be filled here, and that
	# was a measured regression rather than a style point.
	var attacking_weight: float = clampf((attack_intent + 1.0) * 0.5, 0.0, 1.0)

	# v0.8.8: a side that ACTUALLY HAS THE BALL always offers a couple of
	# outlets, whatever the slewed intent currently believes.
	#
	# This is the root cause of "teammates move but I have nobody to pass
	# to". Every attacking slot count is derived from attack_intent, which
	# ramps over ~1.2s and only reaches full commitment after a side has
	# held the ball for that long. With turnovers running at ~44/min the
	# intent essentially never arrives: measured while a side had the ball,
	# attacking_weight sat around 0.47, which allocated COVER_SPACE to 3.0
	# players and MARK to 1.6 -- nearly half the outfield holding defensive
	# shape during their own attack, leaving the carrier ~3.6 teammates on
	# any duty that offers a pass at all.
	#
	# Possession of the ball is a FACT, not a slewed opinion, so the floor
	# below keys off it directly. It is deliberately small: the brief warns
	# against everyone running forward, and this only guarantees a short
	# outlet and one runner -- the rest of the shape still follows intent.
	var holding: bool = _settled_possession_ours
	var short_slots: int = _slots(_squad_scaled(MAX_SUPPORT_SHORT, players.size()), attacking_weight)
	var wide_slots: int = _slots(_squad_scaled(MAX_SUPPORT_WIDE, players.size()), attacking_weight)
	var behind_slots: int = _slots(_squad_scaled(MAX_RUN_BEHIND, players.size()), attacking_weight)
	if holding:
		# The floor is a guarantee sized for a real side, and it has to
		# SCALE with the squad rather than be an absolute count.
		#
		# `AIController.update_player` builds a TRANSIENT one-player plan
		# whenever a caller supplies no team plan -- unit tests and the
		# debug overlay both do -- so this allocation also runs for pools of
		# one or two. An absolute floor there is not a guarantee, it is
		# conscription: it put the only available player on a run in behind
		# no matter who they were, a covering centre-back included.
		# Measured in v0_7_match_test that turned "a non-challenger defender
		# falls back into its own shape" into "it advances up the pitch",
		# and flattened a winger's and a central midfielder's support onto
		# the same point -- RUN_BEHIND takes its width from the formation
		# slot the caller supplies, and both were supplied the same one, so
		# conscripting both into it erased the role difference the shape
		# system exists to produce.
		#
		# Budgeted at a third of the SQUAD (not of the remaining pool, which
		# varies with how many are already on a contest or a follow-up), a
		# real eleven still gets all three outlets exactly as before, and a
		# pool too small to spare anyone gets none.
		#
		# Each floor is also gated at a DIFFERENT point on the holding ramp
		# (see _holding_ramp), so the three of them arrive spread across it
		# rather than all on the frame possession settles. Depth first,
		# because it is the scarcest job and the one the fill order below
		# already prioritises; the wide option last, because it is the one a
		# side can most afford to be late to.
		var budget: int = players.size() / 3
		var b: int = mini(MIN_RUN_BEHIND_WHEN_HOLDING, budget) if _holding_ramp >= FLOOR_RAMP_BEHIND else 0
		behind_slots = maxi(behind_slots, b)
		budget -= b
		var s: int = mini(MIN_SUPPORT_SHORT_WHEN_HOLDING, budget) if _holding_ramp >= FLOOR_RAMP_SHORT else 0
		short_slots = maxi(short_slots, s)
		budget -= s
		if _holding_ramp >= FLOOR_RAMP_WIDE:
			wide_slots = maxi(wide_slots, mini(MIN_SUPPORT_WIDE_WHEN_HOLDING, budget))
	# RUN_BEHIND is filled FIRST. Slots are filled in order from a shrinking
	# pool, so whichever duty goes first gets the pick of the squad -- and
	# the best candidate for a short outlet and the best candidate for a run
	# in behind are often the same advanced player. With SUPPORT_SHORT
	# first, the floors above consumed the forwards into a duty that sits
	# ~9m off the ball, and the attacking line dropped with them: the share
	# of frames where the forwards held a clearly advanced line fell to 73%
	# against an 80% requirement. Depth is the scarcer, more specialised
	# job, so it picks first; a short outlet can be filled by a midfielder.
	_fill(available, Duty.RUN_BEHIND, behind_slots, previous, ball, opponents)
	_fill(available, Duty.SUPPORT_SHORT, short_slots, previous, ball, opponents)
	_fill(available, Duty.SUPPORT_WIDE, wide_slots, previous, ball, opponents)
	_assign_markers(available, opponents, previous, previous_marks,
		_slots(MAX_MARKERS, 1.0 - attacking_weight))
	# 4b. Off-ball advancement -- see MAX_PUSH_UP. Counted from the same
	#     slewed intent as every other slot, so it migrates over the ramp
	#     rather than switching on the frame the phase changes.
	_fill(available, Duty.PUSH_UP, _slots(_squad_scaled(MAX_PUSH_UP, players.size()), attacking_weight), previous, ball, opponents)

	# 5. Everyone left holds shape. This is a real job, not a leftover --
	#    see AIController's COVER_SPACE target, which stays ball-relative
	#    (the old fallback resolved to a near-static point, which is why
	#    defenders measured 40% of frames completely stationary).
	for p in available:
		_assign(p, Duty.COVER_SPACE)

	# 6. ...and only NOW, the man the ball was actually played to.
	#
	# v0.9.1. This ran before the allocation above and erased the receiver
	# from `available`, which meant every pass in flight removed one player
	# from the pool and shifted every duty downstream of them by one -- twice
	# per pass, once as the ball left and once as it was collected. It also
	# bypassed DUTY_RETENTION_BONUS entirely, since that only applies inside
	# _best_for and this assigns directly.
	#
	# Measured over a settled passage (V0_8_5PossessionPhaseTest, paired runs
	# against a v0.9.0 baseline worktree):
	#
	#   v0.9.0 baseline                     0.162  0.173  0.173  0.203
	#   v0.9.1 with RECEIVE filled early    0.446  0.422
	#   v0.9.1 with RECEIVE disabled        0.242  0.263  0.311
	#   v0.9.1 with player collision off    0.436          <-- not the cause
	#
	# against a 0.30 changes/player/second ceiling. The collision change was
	# the intuitive suspect and the isolation run cleared it: turning solid
	# bodies off left churn at 0.436, essentially unchanged. It was this.
	#
	# Filling it last makes it an OVERRIDE rather than a reallocation: the
	# ten other players keep whatever they were already doing, and the one
	# man the ball is travelling to swaps his job for going to get it. That
	# is also the more honest model of what happens on a pitch.
	# Overriding a POSITIONAL duty is the point. Overriding one of the two
	# duties that are themselves FACTS about a player is not: CONTEST is the
	# man going to win the ball and FOLLOW_UP is the man who just played it,
	# and neither stops being true because a pass is in the air. Passing the
	# whole squad in without this filter clobbered them -- measured, it broke
	# v0_8_6's "a player who just shot is allocated FOLLOW_UP" and its
	# involvement-decay follow-up, which had been green a moment earlier.
	var receive_candidates: Array = []
	for p in players:
		var d: int = duty_of(p)
		if d != Duty.CONTEST and d != Duty.FOLLOW_UP:
			receive_candidates.append(p)
	if possession.is_loose:
		_fill_receive(receive_candidates, players, ball)


## Anyone whose last kick is still in the air, in priority of how recently
## they played it. Not scored against other candidates like the allocated
## slots are -- having just played the ball is a fact about this player, not
## a competition they can lose to a better-placed teammate.
## The intended receiver of a pass that is currently in the air.
##
## Gated on the ball actually being loose by the caller: a pass that has
## already been collected is over, and keeping the duty alive for the rest
## of the post-action window left a player running at a ball somebody was
## already carrying -- which shows up directly as teammates crowding the
## carrier (measured 2.01 within 5m against a 1.4 ceiling) and as fewer of
## them left at a passable distance (0.8 clear options against 1.0).
##
## Like FOLLOW_UP this is a FACT about the player rather than a slot they
## compete for: the ball is on its way to them.
##
## Applied LAST, as an override on top of a completed allocation -- see the
## call site for the churn measurement that forced that ordering. `candidates`
## and `players` are the same array now; the parameter is kept so the
## "the receiver must be one of ours" invariant below still reads as a check
## against the squad rather than against whatever pool happened to be left.
func _fill_receive(candidates: Array, players: Array, _ball: RigidBody3D) -> void:
	# Whose pass is still live? post_action_involvement decays over
	# POST_ACTION_WINDOW, which is exactly "the ball I played is still in
	# play", so no new bookkeeping is needed.
	var receiver: FootballPlayer = null
	var freshest := 0.0
	for p in players:
		if p == null or not is_instance_valid(p):
			continue
		if p.last_kick_kind != FootballPlayer.KickKind.PASS:
			continue
		var live: float = p.post_action_involvement()
		if live <= freshest:
			continue
		var t: FootballPlayer = p.last_kick_target
		if t == null or not is_instance_valid(t) or t == p:
			continue
		# Never the goalkeeper. Their positioning is deliberately owned by
		# AIController.update_goalkeeper rather than by the duty system, and
		# conscripting them into a run at the ball took them 19.4m off their
		# line -- caught by v0_8_5's "goalkeepers still hold their line".
		if t.is_goalkeeper:
			continue
		# ...and never a FORWARD.
		#
		# v0.9.1. A forward is the most advanced player on the side, so the
		# ball is nearly always behind them: standing one down to go and
		# collect a pass costs the run they were making, and because a pass
		# is in the air almost continuously it cost the attacking line
		# outright. Measured on v0_8_3's "forwards hold a clearly advanced
		# line", 3 runs per build:
		#
		#   v0.9.0 baseline                  63%  (failed 1 of 4)
		#   RECEIVE for every role       0-48%, then 20% with a retreat cap
		#   RECEIVE excluding forwards   68%, 78%, 68%
		#
		# Capping how far back the duty could pull them (RECEIVE_MAX_DROP)
		# was tried first and moved the line by one point, because the
		# problem is not WHERE the duty aims a forward but that it stands
		# them down from an advancing run at all.
		#
		# It also delivers MORE passes, which is the opposite of the trade
		# this looked like (diag_pass_receiver, 90s of AI play):
		#
		#   RECEIVE for every role      15 of 59 reached the intended man (25%)
		#   RECEIVE excluding forwards  20 of 46 reached the intended man (43%)
		#
		# Pulling the striker back removed the outlet and crowded the middle,
		# so more passes were cut out. The duty keeps doing its job for the
		# midfielders and defenders it was written for; a forward still
		# receives passes, they simply are not taken off their run to do it.
		if FormationManager.role_category(t.formation_role) == "FWD":
			continue
		# The invariant this milestone asks for, enforced where the duty is
		# handed out as well as where the pass is chosen: a receiver is on
		# our side, or there is no receiver.
		if t.team_id != p.team_id or not (t in players):
			continue
		if not (t in candidates):
			continue
		freshest = live
		receiver = t
	if receiver != null:
		# An override, not an allocation: nobody is removed from any pool,
		# so no other player's duty moves as a side effect of this one.
		_assign(receiver, Duty.RECEIVE)


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


## The slot ceilings above are absolute counts describing a FULL SIDE: "two
## runners in behind" is a rule about an eleven. This scales them to the
## squad actually present, so the proportion they express survives a smaller
## pool.
##
## v0.8.8. `AIController.update_player` builds a TRANSIENT plan whenever a
## caller supplies no team plan -- unit tests and the debug overlay both do
## -- and that plan contains one or two players. Against a pool of two,
## "up to two runners in behind" is not a ceiling at all: it conscripts
## everybody. Measured in v0_7_match_test, that put a covering centre-back
## on a run in behind (the assertion that a non-challenger defender falls
## back into its own shape), and flattened a winger's and a central
## midfielder's support onto the same point, because RUN_BEHIND takes its
## width from the caller's formation slot and the test deliberately supplies
## both the same slot to isolate role from position.
##
## Floored rather than rounded, so a duty only exists once the squad can
## genuinely spare somebody for it. A full side is unchanged by design:
## 11 players returns each ceiling untouched.
static func _squad_scaled(max_slots: int, squad: int) -> int:
	if squad >= NOMINAL_SQUAD:
		return max_slots
	return int(floor(float(max_slots) * float(squad) / float(NOMINAL_SQUAD)))


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


## Put somebody in the pass the carrier wants to play.
##
## The lane worth cutting is not "the nearest opponent" -- it is the one whose
## receiver would hurt us most, weighted by whether the ball can actually get
## there. Both halves matter: a dangerous receiver behind three defenders is
## not a threat, and a wide-open receiver going nowhere is not either.
##
## The interceptor stands ON the lane rather than next to the receiver, which
## is the difference between intercepting and marking, and is why this is a
## separate duty from MARK.
func _fill_intercept(available: Array, opponents: Array, previous: Dictionary) -> void:
	if perception == null:
		return
	# MEASURED (tests/diag_intercept_gate.gd, 5400 team-frames): requiring a
	# settled opposition carrier collapses this duty to nothing. We do not have
	# the ball on 87.9% of frames, attack intent allows an interceptor on 45.0%
	# -- but an opponent is actually CARRYING on only 5.8%. The ball in this
	# game is loose far more often than it is held, so a duty that only exists
	# during build-up play exists 0.1% of the time, which is what the first
	# version measured.
	#
	# A ball travelling toward an opponent is the same football problem: there
	# is a line the ball is going down, and standing in it is the job. So the
	# lane is the carrier's best pass when there is a carrier, and the ball's
	# own projected path when there is not.
	if carrier == null or not is_instance_valid(carrier):
		_fill_intercept_travelling(available, opponents, previous)
		return
	var from: Vector3 = carrier.global_position
	var lanes: Array = []
	for o in opponents:
		if o == null or not is_instance_valid(o) or o == carrier or o.is_goalkeeper:
			continue
		var to: Vector3 = o.global_position
		# How much would this pass advance THEM? Their attack runs against our
		# forward axis, so progression(receiver, carrier) is their gain.
		var gain: float = perception.progression(to, from)
		if gain <= 0.0:
			continue  # a backward pass for them is not a threat worth a body
		# MEASURED CORRECTION. The first version of this multiplied straight by
		# danger_at(receiver), which is zero beyond 22 m from our goal -- so a
		# lane only counted once the opposition were already in our third, and
		# the duty was allocated on 0.0% of sampled frames across a 75-second
		# match. A pass that is not yet dangerous is exactly the pass a midfield
		# is supposed to cut out.
		#
		# Progression is therefore the primary term and danger is a multiplier
		# with a floor: a ten-metre forward pass through the middle of the pitch
		# is worth standing in, and the same pass into our box is worth more.
		var advance: float = clampf(gain / 15.0, 0.0, 1.0)
		var danger: float = lerpf(DANGER_FLOOR, 1.0, perception.danger_at(to))
		var threat: float = advance * danger
		# Only lanes the ball could actually travel down are worth standing in.
		threat *= perception.lane_quality(from, to)
		if threat < INTERCEPT_MIN_THREAT:
			continue
		lanes.append({"threat": threat, "point":
			from.lerp(to, INTERCEPT_LANE_FRACTION), "receiver": o})
	if lanes.is_empty():
		return
	lanes.sort_custom(func(a, b): return a["threat"] > b["threat"])

	var taken := 0
	for lane in lanes:
		if taken >= MAX_INTERCEPT or available.is_empty():
			return
		var point: Vector3 = lane["point"]
		var best: FootballPlayer = null
		var best_score := -INF
		for p in available:
			var cat: String = FormationManager.role_category(p.formation_role)
			# Whoever can actually get into the lane, preferring midfielders --
			# this is their job, and it is the participation QA cannot see.
			var score: float = -p.global_position.distance_to(point)
			if cat == "MID":
				score += 4.0
			elif cat == "DEF":
				score += 1.0
			else:
				score -= 3.0  # a forward standing in a midfield lane is not defending
			score += (p.personality.discipline - 50.0) * 0.02
			if previous.get(p.get_instance_id(), -1) == Duty.INTERCEPT:
				score += DUTY_RETENTION_BONUS
			if score > best_score:
				best_score = score
				best = p
		if best == null:
			return
		_assign(best, Duty.INTERCEPT)
		intercept_points[best.get_instance_id()] = point
		available.erase(best)
		taken += 1


## A ball already travelling toward an opponent.
##
## The CONTEST duty sends exactly one player AT the ball. This is deliberately
## a different job: get in FRONT of where the ball is going, on its line,
## between it and the opponent it is running to. One player chasing and one
## player cutting the line off is a defensive unit; two players chasing the
## same ball is the swarm this milestone is trying to remove.
##
## Capped at one, because the second body is worth more holding shape.
func _fill_intercept_travelling(available: Array, opponents: Array, previous: Dictionary) -> void:
	if available.is_empty():
		return
	var ball_dir := Vector3(perception.ball_vel.x, 0.0, perception.ball_vel.z)
	if ball_dir.length() < TRAVELLING_MIN_SPEED:
		return
	# Who is the ball actually running to? The opponent nearest to where it
	# will be, not the one nearest to where it is.
	var arrival: Vector3 = perception.ball_future
	var receiver: FootballPlayer = null
	var best_gap := INF
	for o in opponents:
		if o == null or not is_instance_valid(o) or o.is_goalkeeper:
			continue
		var gap: float = o.global_position.distance_to(arrival)
		if gap < best_gap:
			best_gap = gap
			receiver = o
	if receiver == null or best_gap > TRAVELLING_RECEIVER_RADIUS:
		return
	# The point to stand on: short of the arrival, on the ball's own line.
	var from := Vector3(perception.ball_pos.x, 0.0, perception.ball_pos.z)
	var point: Vector3 = from.lerp(arrival, INTERCEPT_LANE_FRACTION)
	point.y = receiver.global_position.y

	var best: FootballPlayer = null
	var best_score := -INF
	for p in available:
		var cat: String = FormationManager.role_category(p.formation_role)
		var score: float = -p.global_position.distance_to(point)
		if cat == "MID":
			score += 3.0
		elif cat == "DEF":
			score += 1.5
		else:
			score -= 3.0
		if previous.get(p.get_instance_id(), -1) == Duty.INTERCEPT:
			score += DUTY_RETENTION_BONUS
		if score > best_score:
			best_score = score
			best = p
	if best == null:
		return
	_assign(best, Duty.INTERCEPT)
	intercept_points[best.get_instance_id()] = point
	available.erase(best)


## Keep the deepest players deep.
##
## This duty's entire content is "do not go to the ball". A back line that is
## always eligible for a proximity-scored duty gets dragged up the pitch one
## player at a time, and the space it leaves is where goals come from. Somebody
## has to be told to stay, and it has to be a real assignment rather than a
## bias, or the next duty with a better score simply takes them.
func _fill_rest_defence(available: Array, previous: Dictionary) -> void:
	if MAX_REST_DEFENCE <= 0 or available.is_empty():
		return
	var fwd: float = signf(_forward_axis.x)
	var candidates: Array = []
	for p in available:
		if FormationManager.role_category(p.formation_role) != "DEF":
			continue
		candidates.append(p)
	if candidates.is_empty():
		return
	# Deepest first: the ones already holding the line are the ones to keep
	# there, which also means this assignment barely moves anybody.
	candidates.sort_custom(func(a, b):
		return a.global_position.x * fwd < b.global_position.x * fwd)
	var want: int = mini(MAX_REST_DEFENCE, maxi(1, candidates.size() / 2))
	for i in range(mini(want, candidates.size())):
		var p: FootballPlayer = candidates[i]
		_assign(p, Duty.REST_DEFENCE)
		available.erase(p)


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
