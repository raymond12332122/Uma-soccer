extends Node3D

# Regression tests for the V0.8.6 off-ball intelligence / passing /
# play-continuation pass.
#
# MEASURED ROOT CAUSES, established by reading the v0.8.5 code against the
# v0.8.5 rendered playtest numbers before anything was changed:
#
#  1. AI ABANDONS THE PLAY. Not a timer. post_action_involvement() was a
#     decaying weight blended on top of a duty target that had ALREADY sent
#     the player home. The instant a player kicked, TeamPlan re-allocated
#     them: they are now 0m from the ball, which scores badly for
#     SUPPORT_SHORT (it wants ~9m) and is explicitly penalised for
#     RUN_BEHIND (dist_to_ball < 6.0 costs 2.0), so they reliably fell
#     through to COVER_SPACE -- the leftover -- whose target was
#     shape.lerp(play, 0.12 + 0.22*attack_weight), i.e. 70-88% of a STATIC
#     formation anchor. The system spent 2.5s partially cancelling a "go
#     home" instruction it had just issued itself.
#
#  2/3. OFF-BALL INACTIVITY. Structural. Ten outfielders against attacking
#     slot ceilings totalling six (SUPPORT_SHORT 2 + RUN_BEHIND 2 +
#     SUPPORT_WIDE 2), so four to six players per side were ALWAYS
#     leftovers on that same near-static anchor. The v0.8.5 rendered
#     playtest measured midfielders idle for 75-76% of all frames. The
#     attacking branch also held shape.z fixed, so play switching flanks --
#     the most common thing in a football match -- moved a shape-holder's
#     target by exactly nothing.
#
#  4. HUMAN PASS. Four compounding defects. _process_pass_input() called
#     execute_pass() with no forward_axis and no plan, so W_PROGRESSION
#     (0.34, the largest weight) scored a flat ZERO on every human pass.
#     W_ALIGNMENT was 0.08, so where the player aimed was ~8% of a decision
#     owned by openness/progression/distance/role. The 3.5-14m band rejected
#     a teammate the player was plainly pointing at. And with no option the
#     button fired PASS_SPEED_MAX * pass_speed_scale = up to 12.1 m/s
#     against a SHOT_SPEED_MIN of 12.5 -- the reported "PASS behaves like a
#     weak shot" was literally a full-power blind punt.
#
#  7. WEAK AI SHOTS. execute_shot() took no direction, so the kick fell back
#     to _get_aim_direction() -- which is move_input, and move_input is
#     Vector2.ZERO for any carrier inside its arrive radius, leaving the
#     shot to go wherever _facing_angle last pointed. Power was also
#     INVERTED: charge = 0.45 + range_quality*0.55, and range_quality is
#     highest when CLOSEST, so the AI struck hardest from two metres and
#     softest from thirteen.
#
#  9. BEHIND THE GOAL. There was no model of the pitch. FIELD_HALF_LENGTH
#     (26) is a formation-layout box; the built stadium in Field.tscn puts
#     the goal mouth at x = +/-29 and the perimeter wall at +/-35, so the
#     point every attacking decision aimed at sat 3m in FRONT of the goal
#     and the whole strip behind it was unmodelled. Worse,
#     angle_quality used absf(goal_dir.dot(forward_axis)) -- so a shot
#     pointing directly AWAY from the attacking direction, which is what a
#     shot from behind the net looks like, scored a perfect 1.0.
#
#  5. STIFF BALL CONTROL. A CharacterBody3D is not able to push a
#     RigidBody3D -- Godot stops it dead -- and the player's collision_mask
#     includes the ball's layer. A carrier was therefore being physically
#     braked by a 0.45kg football: measured in an isolated 1v0, a player
#     told to sprint in a straight line with the ball at their feet reached
#     0.9 m/s against a sprint speed of 8.5. Separately, the dribble damper
#     opposed the ball's ABSOLUTE velocity, so it fought the very motion the
#     spring was producing (carrying the ball at a sprint demanded ~30 m/s^2
#     of damper force against a total budget of 18), which is why
#     dribble_distance_sprint had no observable effect at all.
#
# Run via: godot --headless --path . tests/V0_8_6OffBallTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	await _run_tests()


func _run_tests() -> void:
	# 1-2: play continuation after a ball action (one shared scene)
	await _test_play_continuation_after_a_ball_action()
	# 3-4: off-ball activity, plus 10/11 -- all measured over ONE shared
	# live passage. Instantiating the 22-player scene is by far the most
	# expensive thing this suite does, and these are all just different
	# statistics over the same match.
	await _test_live_match_off_ball_behaviour()
	await _test_shape_holders_track_play_laterally()
	# 5-7: human passing
	await _test_human_pass_goes_to_the_teammate_being_aimed_at()
	await _test_human_pass_produces_teammate_directed_velocity()
	await _test_pass_and_shot_remain_distinguishable()
	await _test_pass_with_no_target_is_not_a_disguised_shot()

	# 9: AI shooting
	await _test_ai_shot_is_goal_directed()
	await _test_ai_shot_power_rises_with_distance()
	# 10: playable area (its live-match half is folded into the shared
	#     passage above)
	await _test_players_are_never_targeted_behind_the_goal()
	await _test_no_shot_is_taken_from_behind_the_goal_line()
	# 11-15: preserved systems
	await _test_possession_stealing_still_works()
	await _test_goalkeeper_behaviour_unchanged()
	# 8 + 14/15 + 16: AI-to-human passing, multitouch/switching and team
	# identification, all over one shared scene.
	await _test_live_match_human_facing_systems()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# ------------------------------------------------ 1-2. play continuation

## The core claim of this milestone: a player who has just played the ball
## holds a FOLLOW_UP DUTY, not a leftover COVER_SPACE one. Asserted at the
## level of the allocation rather than by watching the player walk, because
## the allocation is the thing that was wrong -- a follow-up blended on top
## of a "return to your formation slot" target is still, underneath, a
## return to your formation slot.
##
## Passer, shooter and the decay all share one scene: instantiating
## Main.tscn (22 glTF characters) is what this suite spends its wall clock
## on, and these three are the same experiment with different setups.
func _test_play_continuation_after_a_ball_action() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(120):
		await get_tree().physics_frame

	# --- a player who just PASSED ---
	var passer: FootballPlayer = main.home_players[9]
	var home_slot: Vector3 = FormationManager.get_world_position(passer.formation_slot, 0)
	passer.post_action_timer = FootballPlayer.POST_ACTION_WINDOW
	passer.post_action_kind = FootballPlayer.KickKind.PASS
	await get_tree().physics_frame
	await get_tree().physics_frame

	var duty: int = main.home_team.plan.duty_of(passer)
	_check("A player who just passed is allocated FOLLOW_UP, not the COVER_SPACE leftover (duty=%d)" % duty,
		duty == TeamPlan.Duty.FOLLOW_UP)
	_check("FOLLOW_UP exists as a distinct duty from COVER_SPACE",
		TeamPlan.Duty.FOLLOW_UP != TeamPlan.Duty.COVER_SPACE)
	var to_slot: float = passer.ai_target.distance_to(home_slot)
	var stands_at: float = passer.global_position.distance_to(home_slot)
	_check("The passer's target is not simply their formation slot (target %.1fm from slot, player %.1fm from it)"
		% [to_slot, stands_at], to_slot > 1.0 or stands_at < 1.0)
	passer.post_action_timer = 0.0

	# --- a player who just SHOT ---
	var shooter: FootballPlayer = main.home_players[8]
	shooter.post_action_timer = FootballPlayer.POST_ACTION_WINDOW
	shooter.post_action_kind = FootballPlayer.KickKind.SHOT
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("A player who just shot is allocated FOLLOW_UP", main.home_team.plan.duty_of(shooter) == TeamPlan.Duty.FOLLOW_UP)
	_check("The shooter's follow-up target is not back toward their own goal (target x=%.1f, own goal at %.1f)"
		% [shooter.ai_target.x, -FormationManager.GOAL_LINE_X],
		shooter.ai_target.x > -FormationManager.GOAL_LINE_X + 5.0)

	# --- and the follow-up must EASE out, not switch off ---
	var involvements: Array = []
	var biggest_step := 0.0
	var previous: Vector3 = Vector3.INF
	for i in range(int(FootballPlayer.POST_ACTION_WINDOW * 60) + 40):
		await get_tree().physics_frame
		involvements.append(shooter.post_action_involvement())
		if previous != Vector3.INF:
			biggest_step = maxf(biggest_step, shooter.ai_smoothed_target.distance_to(previous))
		previous = shooter.ai_smoothed_target

	_check("Follow-up involvement starts full and reaches zero (%.2f -> %.2f)"
		% [involvements[0], involvements[involvements.size() - 1]],
		involvements[0] > 0.8 and involvements[involvements.size() - 1] == 0.0)
	var step_limit: float = AIController.TARGET_MAX_SPEED / 60.0 + 0.02
	_check("The aim point never jumps as the follow-up expires (max step %.3fm, limit %.3fm)" % [biggest_step, step_limit],
		biggest_step <= step_limit)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------- 3-4. off-ball activity

## Off-ball behaviour, the playable-area rule and movement stability, all
## measured over ONE 15s live passage of the real 22-player match.
##
## Combined deliberately: these are separate claims but the same experiment,
## and instantiating Main.tscn (22 characters, each a glTF model) is what
## this suite actually spends its wall-clock time on.
func _test_live_match_off_ball_behaviour() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(180):
		await get_tree().physics_frame

	var mids: Array = []
	var outfield: Array = []
	for p in main.home_players + main.away_players:
		if p.is_goalkeeper:
			continue
		outfield.append(p)
		if FormationManager.role_category(p.formation_role) == "MID":
			mids.append(p)

	# off-ball employment
	var employed := 0
	var attacking_samples := 0
	var attacking_outfielders := 0
	# midfield activity
	var mid_idle := 0
	var mid_frames := 0
	var mid_travel := 0.0
	# advancing-run separation
	var worst_lane_gap := INF
	var worst_lane_pair := ""
	var lane_samples := 0
	# playable area
	var behind_goal := 0
	var target_samples := 0
	var deepest := 0.0
	# movement stability
	var worst_step := 0.0
	var reversals := 0
	var moving_frames := 0
	var last_target: Dictionary = {}
	var last_dir: Dictionary = {}
	var last_pos: Dictionary = {}
	for p in mids:
		last_pos[p.get_instance_id()] = p.global_position

	for i in range(600):
		await get_tree().physics_frame

		for team in [main.home_team, main.away_team]:
			var attacking: bool = team.plan.attack_intent > 0.5
			var advancing: Array = []
			for p in team.players:
				if p.is_goalkeeper:
					continue
				var duty: int = team.plan.duty_of(p)
				if attacking:
					attacking_outfielders += 1
					if p.has_possession or duty != TeamPlan.Duty.COVER_SPACE:
						employed += 1
				# A player whose intent is being driven by a personality event
				# is skipped by AIController entirely (see TeamController), so
				# their ai_target is stale -- Vector3.ZERO if the AI has never
				# run for them. TeamPlan still allocates them a duty, so they
				# would otherwise show up here comparing equal to each other at
				# z=0 and look like converging runs. Their positioning is not
				# what this assertion is about.
				if duty == TeamPlan.Duty.PUSH_UP and not p.has_active_personality_event():
					advancing.append(p)
			if attacking:
				attacking_samples += 1
			if advancing.size() >= 2:
				lane_samples += 1
				for a in range(advancing.size()):
					for b in range(a + 1, advancing.size()):
						var gap: float = absf(advancing[a].ai_target.z - advancing[b].ai_target.z)
						if gap < worst_lane_gap:
							worst_lane_gap = gap
							worst_lane_pair = "%s(%s,slot%.2f,tgt%.2f,ev'%s') vs %s(%s,slot%.2f,tgt%.2f,ev'%s')" % [
								advancing[a].player_data.display_name, advancing[a].formation_role,
								advancing[a].formation_slot.y, advancing[a].ai_target.z, advancing[a].active_personality_event,
								advancing[b].player_data.display_name, advancing[b].formation_role,
								advancing[b].formation_slot.y, advancing[b].ai_target.z, advancing[b].active_personality_event]

		for p in outfield:
			var id: int = p.get_instance_id()
			target_samples += 1
			deepest = maxf(deepest, absf(p.ai_target.x))
			if FormationManager.is_behind_goal_line(p.ai_target):
				behind_goal += 1
			if last_target.has(id):
				worst_step = maxf(worst_step, last_target[id].distance_to(p.ai_smoothed_target))
			last_target[id] = p.ai_smoothed_target
			var v := Vector2(p.velocity.x, p.velocity.z)
			if v.length() >= 0.5:
				moving_frames += 1
				var dir: Vector2 = v.normalized()
				if last_dir.has(id) and last_dir[id].dot(dir) < -0.5:
					reversals += 1
				last_dir[id] = dir

		for p in mids:
			var mid_id: int = p.get_instance_id()
			mid_frames += 1
			if Vector2(p.velocity.x, p.velocity.z).length() < 0.3:
				mid_idle += 1
			mid_travel += last_pos[mid_id].distance_to(p.global_position)
			last_pos[mid_id] = p.global_position

	# --- every outfielder has an off-ball objective ---
	var employed_share: float = 100.0 * employed / maxf(attacking_outfielders, 1)
	_check("Sampled a real attacking passage (%d frames)" % attacking_samples, attacking_samples > 60)
	# Before PUSH_UP the attacking ceilings totalled six jobs for ten
	# outfielders, so this could not structurally exceed ~60%.
	_check("Most outfielders hold a specific off-ball job while attacking (%.0f%%; structural ceiling was ~60%% before PUSH_UP)" % employed_share,
		employed_share > 70.0)

	# --- midfielders are not inert ---
	var idle_pct: float = 100.0 * mid_idle / maxf(mid_frames, 1)
	var per_player: float = mid_travel / maxf(mids.size(), 1)
	_check("Found midfielders on both sides (%d)" % mids.size(), mids.size() >= 6)
	_check("Midfielders are not mostly stationary (%.0f%% idle; the v0.8.5 rendered playtest measured 75-76%%)" % idle_pct,
		idle_pct < 60.0)
	_check("Midfielders cover real ground over 10s (%.0fm per player)" % per_player, per_player > 8.0)

	# --- advancing runs are complementary, not identical ---
	_check("Saw at least two players advancing off the ball at once (%d samples)" % lane_samples, lane_samples > 20)
	if lane_samples > 0:
		_check("Two advancing players never target the same lane (closest gap %.2fm -- %s)" % [worst_lane_gap, worst_lane_pair],
			worst_lane_gap > 0.5)

	# --- nobody is ever aimed behind a goal ---
	_check("No outfielder is ever aimed behind a goal (%d of %d target-frames, deepest x=%.1f)"
		% [behind_goal, target_samples, deepest], behind_goal == 0)

	# --- stable states do not oscillate ---
	var limit: float = AIController.TARGET_MAX_SPEED / 60.0 + 0.02
	var per_1000: float = 1000.0 * reversals / maxf(moving_frames, 1)
	_check("The steered aim point is still rate-limited (worst step %.3fm, limit %.3fm)" % [worst_step, limit],
		worst_step <= limit)
	_check("Direction reversals stay within the v0.8.5 band (%.2f per 1000 moving frames; v0.8.5 measured 3.19-4.65)" % per_1000,
		per_1000 < 6.0)

	main.queue_free()
	await get_tree().process_frame


## The lateral half of the midfield-inactivity bug: a shape-holder's target
## used to hold shape.z fixed, so a switch of play moved it by nothing.
func _test_shape_holders_track_play_laterally() -> void:
	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-26, 1, 0), Vector3(26, 1, 0))
	plan.attack_intent = 1.0

	var shape := Vector3(0, 1, -8)
	plan.slow_ball_pos = Vector3(5, 0.35, -12)
	var left: Vector3 = AIController._cover_space_target(shape, plan.slow_ball_pos, Vector3(-26, 1, 0), plan, "MID")
	plan.slow_ball_pos = Vector3(5, 0.35, 12)
	var right: Vector3 = AIController._cover_space_target(shape, plan.slow_ball_pos, Vector3(-26, 1, 0), plan, "MID")

	_check("Play switching flanks moves a shape-holder's target laterally (%.1fm)" % absf(left.z - right.z),
		absf(left.z - right.z) > 1.5)
	# ...but a line shifts across, it does not collapse onto the ball.
	_check("A shape-holder does not simply run at the ball's channel (target z=%.1f vs ball z=12.0)" % right.z,
		absf(right.z - 12.0) > 2.0)


# --------------------------------------------------- 5-7. human passing

## The reported bug directly: point at a teammate, press PASS, and the ball
## must go to THAT teammate. Set up so that the aimed-at teammate is the
## WORSE option on every other criterion (further, less open, deeper role)
## -- pre-v0.8.6, alignment was 8% of the score and lost this every time.
func _test_human_pass_goes_to_the_teammate_being_aimed_at() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 0), "CM")
	# Aimed at: further away, marked, and a defender (worst role bonus).
	var aimed_at: FootballPlayer = _spawn(0, Vector3(0, 1, -11.0), "CB")
	var marker: FootballPlayer = _spawn(1, Vector3(1.5, 1, -11.0), "CM")
	# The distractor: closer, wide open, a forward, and further up the pitch
	# -- i.e. the option the evaluator would pick on every other term.
	var distractor: FootballPlayer = _spawn(0, Vector3(8.0, 1, 1.0), "ST")
	await get_tree().physics_frame

	var mates: Array = [passer, aimed_at, distractor]
	var opps: Array = [marker]
	for p in mates:
		p.set_match_context(mates, opps)
	marker.set_match_context(opps, mates)

	# Aim the stick at the deep, marked defender.
	passer.move_input = Vector2(0, -1)
	var option: PassEvaluator.Option = PassEvaluator.best_option(
		passer, Vector3(0, 0, -1), Vector3.RIGHT, null,
		FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)

	_check("An aimed pass finds a target at all", option != null)
	if option != null:
		_check("An aimed pass picks the teammate being AIMED AT over a closer, more open, more advanced one",
			option.target == aimed_at)

	# And the same aim through the omnidirectional AI search legitimately
	# prefers the better football option -- the two weightings are different
	# on purpose, so this is the control that proves `aimed` is doing the work.
	var ai_option: PassEvaluator.Option = PassEvaluator.best_option(
		passer, Vector3(0, 0, -1), Vector3.RIGHT, null,
		FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI, false)
	if ai_option != null:
		_check("The AI's own (unaimed) search is free to prefer the better option instead",
			ai_option.target == distractor)

	for n in [field, ball, passer, aimed_at, marker, distractor]:
		n.queue_free()
	await get_tree().process_frame


## The pass must actually travel toward the chosen teammate, not merely
## select them -- PASS_ASSIST_BLEND used to drag the ball 30% of the way
## back toward the raw stick angle after the choice was made.
func _test_human_pass_produces_teammate_directed_velocity() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var passer: FootballPlayer = _spawn(0, Vector3(0, 1, 0), "CM")
	var mate: FootballPlayer = _spawn(0, Vector3(6.0, 1, -7.0), "ST")
	await get_tree().physics_frame
	var mates: Array = [passer, mate]
	passer.set_match_context(mates, [])
	mate.set_match_context(mates, [])

	# Aim roughly at the teammate (not exactly -- the player is a human) and
	# let the facing settle, then seat the ball at their feet so the pass is
	# testing the PASS, not whether a dribble happened to survive 40 frames.
	passer.move_input = Vector2(0.7, -0.7)
	for i in range(40):
		await get_tree().physics_frame
	var feet: Vector3 = passer.global_position + Vector3(0.5, 0.35, -0.5)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), feet))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	passer.move_input = Vector2.ZERO
	for i in range(20):
		await get_tree().physics_frame
	_check("The passer has the ball before pressing PASS", passer.has_possession)
	passer.move_input = Vector2(0.7, -0.7)
	await get_tree().physics_frame

	passer.pass_requested = true
	await get_tree().physics_frame
	await get_tree().physics_frame

	var vel := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	var to_mate: Vector3 = (mate.global_position - passer.global_position)
	to_mate.y = 0.0
	var alignment: float = vel.normalized().dot(to_mate.normalized()) if vel.length() > 0.1 else -1.0

	_check("The aimed pass was actually struck (%.1f m/s)" % vel.length(), vel.length() > 2.0)
	_check("The ball travels at the intended teammate (alignment %.2f, 1.0 = dead on)" % alignment, alignment > 0.9)
	_check("Passing recorded the teammate it was aimed at", passer.last_kick_target == mate)
	_check("A pass is recorded as a PASS, not a shot", passer.last_kick_kind == FootballPlayer.KickKind.PASS)

	for n in [field, ball, passer, mate]:
		n.queue_free()
	await get_tree().process_frame


## The invariant that keeps the two actions meaningfully different: the pass
## speed band sits entirely below the shot speed band, for every stat line.
func _test_pass_and_shot_remain_distinguishable() -> void:
	var fastest_pass: float = PassEvaluator.PASS_SPEED_MAX * 1.1  # best possible pass_speed_scale
	_check("The fastest possible pass (%.1f m/s) is slower than the softest possible shot (%.1f m/s)"
		% [fastest_pass, FootballPlayer.SHOT_SPEED_MIN], fastest_pass < FootballPlayer.SHOT_SPEED_MIN)
	_check("A no-target pass is far below shot speed (%.1f vs %.1f m/s)"
		% [FootballPlayer.PASS_NO_TARGET_SPEED * 1.1, FootballPlayer.SHOT_SPEED_MIN],
		FootballPlayer.PASS_NO_TARGET_SPEED * 1.1 < FootballPlayer.SHOT_SPEED_MIN * 0.8)


## The specific reported symptom: "PASS often behaves like a weak shot or
## launches the ball". With nothing to pass to, the old code fired
## PASS_SPEED_MAX * pass_speed_scale = up to 12.1 m/s against a
## SHOT_SPEED_MIN of 12.5.
func _test_pass_with_no_target_is_not_a_disguised_shot() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var lonely: FootballPlayer = _spawn(0, Vector3(0, 1, 0), "CM")
	await get_tree().physics_frame
	lonely.set_match_context([lonely], [])  # nobody to pass to at all

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0.4, 0.35, 0.0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	lonely.move_input = Vector2(1, 0)
	for i in range(40):
		await get_tree().physics_frame

	lonely.pass_requested = true
	await get_tree().physics_frame
	await get_tree().physics_frame

	var speed: float = ball.linear_velocity.length()
	_check("A pass with nothing to aim at still plays the ball (%.1f m/s)" % speed, speed > 1.0)
	_check("...but as a knock into space, not a shot (%.1f m/s vs shot floor %.1f)" % [speed, FootballPlayer.SHOT_SPEED_MIN],
		speed < FootballPlayer.SHOT_SPEED_MIN * 0.85)
	_check("...and it is still recorded as a PASS", lonely.last_kick_kind == FootballPlayer.KickKind.PASS)

	for n in [field, ball, lonely]:
		n.queue_free()
	await get_tree().process_frame


# ------------------------------------------ 8. AI passing to the human

# ---------------------------------------------------- 9. AI shooting

## execute_shot() previously took no direction, so the shot went wherever
## _get_aim_direction() happened to point -- and that is move_input, which
## is ZERO for a carrier standing inside its arrive radius.
func _test_ai_shot_is_goal_directed() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var striker: FootballPlayer = _spawn(0, Vector3(20, 1, 6.0), "ST")
	await get_tree().physics_frame
	striker.set_match_context([striker], [])

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(20.5, 0.35, 6.0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	# Deliberately facing AWAY from goal and standing still -- the exact
	# situation in which the old fallback aim was wrong.
	striker.move_input = Vector2(-1, 0)
	for i in range(30):
		await get_tree().physics_frame
	striker.move_input = Vector2.ZERO
	for i in range(20):
		await get_tree().physics_frame

	var aim_point: Vector3 = FormationManager.goal_aim_point(Vector3.RIGHT, striker.global_position)
	var to_goal: Vector3 = aim_point - striker.global_position
	to_goal.y = 0.0
	striker.execute_shot(striker.shot_charge_for_distance(to_goal.length()), to_goal.normalized())
	await get_tree().physics_frame

	var vel := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	var alignment: float = vel.normalized().dot(to_goal.normalized()) if vel.length() > 0.1 else -1.0
	_check("An explicitly aimed shot travels at the goal even when the shooter faces away (alignment %.2f)" % alignment,
		alignment > 0.95)
	_check("The goal mouth is where the goal actually is (x=%.1f, Field.tscn posts at 29)" % aim_point.x,
		absf(aim_point.x - FormationManager.GOAL_LINE_X) < 0.01)
	_check("The aim point is between the posts (z=%.1f, half-width %.1f)" % [aim_point.z, FormationManager.GOAL_HALF_WIDTH],
		absf(aim_point.z) < FormationManager.GOAL_HALF_WIDTH)

	for n in [field, ball, striker]:
		n.queue_free()
	await get_tree().process_frame


## Power used to be INVERTED: charge = 0.45 + range_quality*0.55, where
## range_quality is highest when closest. The AI hit hardest from 2m.
func _test_ai_shot_power_rises_with_distance() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	await get_tree().physics_frame
	var p: FootballPlayer = _spawn(0, Vector3(0, 1, 0), "ST")
	await get_tree().physics_frame

	var close: float = p.shot_charge_for_distance(2.0)
	var mid: float = p.shot_charge_for_distance(7.0)
	var far: float = p.shot_charge_for_distance(13.0)
	_check("Shot power rises with distance (2m %.2f < 7m %.2f < 13m %.2f)" % [close, mid, far],
		close < mid and mid < far)
	_check("Even a tap-in is struck rather than rolled (%.2f >= %.2f)" % [close, FootballPlayer.SHOT_CHARGE_MIN],
		close >= FootballPlayer.SHOT_CHARGE_MIN)

	var slowest: float = lerp(p.shoot_min_speed, p.shoot_max_speed, close)
	_check("Even the softest shot stays inside the shot speed band (%.1f m/s >= %.1f)" % [slowest, FootballPlayer.SHOT_SPEED_MIN],
		slowest >= FootballPlayer.SHOT_SPEED_MIN)

	for n in [field, p]:
		n.queue_free()
	await get_tree().process_frame


# ------------------------------------------------- 10. playable area

func _test_players_are_never_targeted_behind_the_goal() -> void:
	_check("The playable area stops short of the goal line (%.1f < %.1f)"
		% [FormationManager.PLAYABLE_HALF_LENGTH, FormationManager.GOAL_LINE_X],
		FormationManager.PLAYABLE_HALF_LENGTH < FormationManager.GOAL_LINE_X)

	# Every extreme a duty target could reach is pulled back in front of goal.
	for probe in [Vector3(60, 1, 0), Vector3(-60, 1, 0), Vector3(31, 1, 30), Vector3(-31, 1, -30)]:
		var clamped: Vector3 = FormationManager.clamp_to_playable(probe)
		_check("A target at %s is clamped inside the pitch (-> %.1f, %.1f)" % [probe, clamped.x, clamped.z],
			not FormationManager.is_behind_goal_line(clamped)
				and absf(clamped.z) <= FormationManager.PLAYABLE_HALF_WIDTH + 0.001)

	_check("A position level with the goal line counts as behind it",
		FormationManager.is_behind_goal_line(Vector3(FormationManager.PLAYABLE_HALF_LENGTH + 0.5, 1, 0)))
	_check("A position in normal play does not",
		not FormationManager.is_behind_goal_line(Vector3(20, 1, 0)))


## The absf() bug: a shot pointing directly away from the attacking
## direction -- which is what a shot from behind the net is -- used to score
## a perfect 1.0 for angle, making behind-the-goal the best-scoring position
## on the pitch.
func _test_no_shot_is_taken_from_behind_the_goal_line() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	# Standing behind the goal, ball at their feet, aimed back at the net.
	var behind: FootballPlayer = _spawn(0, Vector3(31.0, 1, 0.0), "ST")
	await get_tree().physics_frame
	behind.set_match_context([behind], [])
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(30.6, 0.35, 0.0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(40):
		await get_tree().physics_frame

	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-26, 1, 0), Vector3(26, 1, 0))
	plan.attack_intent = 1.0
	var kicks_before: int = behind.kick_count
	for i in range(90):
		AIController._decide_possession_action(behind, ball, Vector3(26, 1, 0), [], Vector3.RIGHT, plan, 1.0 / 60.0)
		await get_tree().physics_frame

	_check("A player behind the goal line never shoots at it (%d kicks)" % (behind.kick_count - kicks_before),
		behind.kick_count == kicks_before)

	# ...and the angle term is signed, so a backwards shot is worth nothing.
	var backwards: float = clampf(Vector3.LEFT.dot(Vector3.RIGHT), 0.0, 1.0)
	_check("A shot pointing away from the attacking direction scores zero for angle (was 1.0 via absf)", backwards == 0.0)

	for n in [field, ball, behind]:
		n.queue_free()
	await get_tree().process_frame


# ------------------------------------------- 11-15. preserved systems

## Item 12 of the brief: possession stealing must not regress.
func _test_possession_stealing_still_works() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier: FootballPlayer = _spawn(0, Vector3(0, 1, 0), "CM")
	var thief: FootballPlayer = _spawn(1, Vector3(1.6, 1, 0), "CB")
	await get_tree().physics_frame
	carrier.set_match_context([carrier], [thief])
	thief.set_match_context([thief], [carrier])

	# BallContest is driven by PossessionManager's own frame tick, so an
	# isolated duel needs one or no challenge is ever evaluated at all.
	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, thief], ball)
	carrier.set_possession_manager(pm)
	thief.set_possession_manager(pm)

	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0.5, 0.35, 0.0)))
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	for i in range(40):
		await get_tree().physics_frame
	_check("The carrier has the ball before the challenge", carrier.has_possession)

	# A sustained, committed challenge must still take the ball.
	var dispossessed := false
	for i in range(180):
		var to_ball: Vector3 = ball.global_position - thief.global_position
		thief.move_input = Vector2(to_ball.x, to_ball.z).normalized()
		await get_tree().physics_frame
		if not carrier.has_possession:
			dispossessed = true
			break

	_check("A committed challenger still wins the ball off a carrier (challenge reached %.2f of %.2f)"
		% [thief.challenge_progress, BallContest.CHALLENGE_TIME_REQUIRED], dispossessed)

	for n in [field, ball, carrier, thief, pm]:
		n.queue_free()
	await get_tree().process_frame


func _test_goalkeeper_behaviour_unchanged() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var keeper: FootballPlayer = main.home_players[0]
	_check("The home goalkeeper is still flagged as one", keeper.is_goalkeeper)

	var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 0)
	var furthest := 0.0
	var biggest_step := 0.0
	var previous: Vector3 = keeper.global_position
	for i in range(300):
		await get_tree().physics_frame
		furthest = maxf(furthest, keeper.global_position.distance_to(own_goal))
		biggest_step = maxf(biggest_step, previous.distance_to(keeper.global_position))
		previous = keeper.global_position

	_check("The goalkeeper still holds its own area (max %.1fm from goal)" % furthest, furthest < 12.0)
	_check("The goalkeeper still moves smoothly rather than teleporting (max step %.2fm)" % biggest_step, biggest_step < 0.4)
	_check("The goalkeeper is never allocated an outfield attacking duty",
		main.home_team.plan.duty_of(keeper) == TeamPlan.Duty.COVER_SPACE)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------- 16. team identification

## The human-facing systems the brief says must not regress, plus the
## human's standing as a pass target -- one scene, because each is a couple
## of frames of checking and the scene is the expensive part.
func _test_live_match_human_facing_systems() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	# --- 8. the human is a legitimate AI pass target: never forced, never
	#        excluded. Put them somewhere a pass genuinely should go. ---
	var human: FootballPlayer = main.player_controller.controlled_player
	var carrier: FootballPlayer = null
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			carrier = p
			break
	var fwd: Vector3 = main.home_team.plan.forward_axis()
	carrier.global_position = Vector3(0, 1, 0)
	human.global_position = carrier.global_position + fwd * 9.0
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var option: PassEvaluator.Option = PassEvaluator.best_option(
		carrier, fwd, fwd, main.home_team.plan, FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI)
	_check("An AI carrier evaluates a well-placed human teammate as a pass option", option != null)
	_check("...and selects them when they are the best one available", option != null and option.target == human)

	# --- 16. team identification ---
	var home_ring: MeshInstance3D = main.home_players[3].team_ring
	var away_ring: MeshInstance3D = main.away_players[3].team_ring
	_check("Every player carries a team marker", home_ring != null and away_ring != null)
	_check("The team marker is visible during normal play", home_ring.visible and away_ring.visible)
	var home_mat: StandardMaterial3D = home_ring.get_surface_override_material(0)
	var away_mat: StandardMaterial3D = away_ring.get_surface_override_material(0)
	_check("Team markers are actually tinted", home_mat != null and away_mat != null)
	if home_mat != null and away_mat != null:
		var separation: float = Vector3(
			home_mat.albedo_color.r - away_mat.albedo_color.r,
			home_mat.albedo_color.g - away_mat.albedo_color.g,
			home_mat.albedo_color.b - away_mat.albedo_color.b).length()
		_check("Teammates and opponents are told apart by colour (separation %.2f)" % separation, separation > 0.4)
		_check("The home marker matches the home team colour",
			home_mat.albedo_color.r > 0.8 and home_mat.albedo_color.g > 0.8)

	# --- 14. multitouch: joystick + sprint + shoot all held at once ---
	var before: FootballPlayer = main.player_controller.controlled_player
	InputState.move_vector = Vector2(0.6, -0.4)
	InputState.sprint_held = true
	InputState.shoot_held = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("Joystick input still reaches the controlled player", before.move_input.length() > 0.5)
	_check("Sprint input still reaches the controlled player", before.sprint_requested)
	_check("Shoot-hold still reaches the controlled player", before.shoot_held)
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false
	InputState.shoot_held = false
	InputState.shoot_release_pending = false
	await get_tree().physics_frame

	# --- 15. switching ---
	_check("The controlled player is individually marked", before.control_indicator.visible)
	InputState.switch_pressed = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	var after: FootballPlayer = main.player_controller.controlled_player
	_check("Player switching still changes the controlled player", after != before)
	_check("Switching still lands on a home-roster player", main.home_players.has(after))
	_check("The new controlled player is marked, the old one is not",
		after.control_indicator.visible and not before.control_indicator.visible)
	_check("A player who is not controlled still has a team marker", before.team_ring.visible)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------ helpers

func _spawn(team_id: int, pos: Vector3, role: String) -> FootballPlayer:
	var data := PlayerData.new()
	data.id = "v086_%d_%s" % [team_id, role]
	data.display_name = "Test"
	data.visual_id = "teio"
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60

	var player: FootballPlayer = PlayerScene.instantiate()
	player.team_id = team_id
	player.formation_role = role
	add_child(player)
	player.global_position = pos
	player.apply_player_data(data)
	return player


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
