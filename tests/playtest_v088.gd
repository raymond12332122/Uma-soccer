extends Node3D

## Rendered playtest driver for the v0.8.8 report. Runs the REAL entry
## point (scenes/Main.tscn) windowed under Xvfb, plays two passages, and
## reports measured gameplay observations rather than assertions.
##
## v0.8.8 measures what this milestone changed: how the ball actually sits
## relative to a dribbler and how often it is touched, whether off-ball
## players are offering passing lanes rather than merely moving, and
## whether a human PASS reaches the teammate it was aimed at.
##
##   Phase A: 22-player AI vs AI, human idle.
##   Phase B: human vs AI -- the controlled player is driven toward the
##            ball, sprints, and presses PASS whenever an option exists,
##            so the whole human path is genuinely exercised.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/PlaytestV087.tscn

const MainScene := preload("res://scenes/Main.tscn")

## Matched to v0.8.6: under llvmpipe (no GPU here) longer passages do not
## finish in reasonable wall clock, and every figure below is a rate or a
## percentage so the conclusions do not depend on the duration.
const PHASE_SECONDS := 45

var main: Node3D
var _kick_counts := {}
## Each player's distance to the ball as of the previous physics frame --
## see the kick block for why a kick cannot be measured on its own frame.
var _prev_gap := {}


func _ready() -> void:
	main = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame
	await _phase_ai_vs_ai()
	await _phase_human_vs_ai()
	print("PLAYTEST: complete")
	get_tree().quit(0)


func _all_players() -> Array:
	return main.home_players + main.away_players


# --------------------------------------------------- Phase A: AI vs AI

func _phase_ai_vs_ai() -> void:
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(60):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var plan: TeamPlan = main.home_team.plan
	var frames := int(PHASE_SECONDS * 60.0)

	# dribbling
	var carry_frames := 0
	var sep_sum := 0.0
	var touches := 0
	# passing
	var passes := 0
	var shots := 0
	# off-ball
	var lane_open := 0.0
	var lane_total := 0.0
	var converge_frames := 0
	var mid_far_frames := 0
	var mid_far_moving := 0
	var fwd_ahead := 0
	var fwd_total := 0
	# movement
	var reversals := 0
	var prev_dir := {}
	var behind_goal_frames := 0
	var turnovers := 0
	var prev_team := -99
	# v0.8.8: the milestone's own question -- can a player interact with the
	# ball from a distance they could not physically reach?
	var kick_dists: Array = []
	var kick_no_carrier := 0
	var claim_max := 0.0

	for i in range(frames):
		await get_tree().physics_frame

		for p in _all_players():
			var gap: float = p.global_position.distance_to(main.ball.global_position)
			var seen: int = _kick_counts.get(p, -1)
			if seen >= 0 and p.kick_count > seen:
				if p.last_kick_kind == FootballPlayer.KickKind.PASS:
					passes += 1
				elif p.last_kick_kind == FootballPlayer.KickKind.SHOT:
					shots += 1
				# v0.8.8: how far from the ball was this struck, and did the
				# striker actually have it? The milestone's core question.
				#
				# Taken from the PREVIOUS frame, for the same reason the
				# regression suite does (see v0_8_8_possession_validity_test):
				# kick_count is incremented inside the player's own
				# _physics_process and the ball is integrated with its new
				# launch velocity later in the same frame, so by the time
				# this loop can see the kick the ball has already left. A
				# shot at ~22 m/s is 0.37m away one frame on, and the error
				# is worst for the hardest kicks -- it is what put a rendered
				# run's "furthest" at 2.48m, a shade outside the 2.4m
				# challenge range, for a kick that was in fact legal.
				kick_dists.append(_prev_gap.get(p, gap))
				if pm.current_carrier != p:
					kick_no_carrier += 1
			_kick_counts[p] = p.kick_count
			_prev_gap[p] = gap
			if p.has_possession:
				claim_max = maxf(claim_max, p.global_position.distance_to(main.ball.global_position))

			if FormationManager.is_behind_goal_line(p.global_position):
				behind_goal_frames += 1

			var v := Vector2(p.velocity.x, p.velocity.z)
			if v.length() > 1.0:
				var d: Vector2 = v.normalized()
				if prev_dir.has(p) and d.dot(prev_dir[p]) < -0.7:
					reversals += 1
				prev_dir[p] = d

		if pm.last_team_with_possession != prev_team and pm.last_team_with_possession >= 0:
			if prev_team >= 0:
				turnovers += 1
			prev_team = pm.last_team_with_possession

		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and is_instance_valid(carrier):
			carry_frames += 1
			sep_sum += Vector2(
				main.ball.global_position.x - carrier.global_position.x,
				main.ball.global_position.z - carrier.global_position.z).length()
			if carrier.touched_ball_this_frame:
				touches += 1

			var near := 0
			for mate in carrier.teammates:
				if mate == carrier or mate.is_goalkeeper:
					continue
				if mate.global_position.distance_to(main.ball.global_position) < 6.0:
					near += 1
				var to_mate: Vector3 = mate.global_position - carrier.global_position
				to_mate.y = 0.0
				var d2: float = to_mate.length()
				if d2 >= PassEvaluator.MIN_PASS_DISTANCE and d2 <= PassEvaluator.MAX_PASS_DISTANCE:
					lane_total += 1.0
					if not PassEvaluator._lane_blocked(carrier.global_position, to_mate / d2, d2, carrier.opponents):
						lane_open += 1.0
			if near >= 4:
				converge_frames += 1

		for p in main.home_players:
			if p.is_goalkeeper:
				continue
			var cat: String = FormationManager.role_category(p.formation_role)
			if cat == "MID" and p.global_position.distance_to(main.ball.global_position) > 20.0:
				mid_far_frames += 1
				if p.velocity.length() > 0.5:
					mid_far_moving += 1
			if cat == "FWD":
				fwd_total += 1
				if (p.global_position - main.ball.global_position).dot(plan.forward_axis()) > 0.0:
					fwd_ahead += 1

	print("PLAYTEST A (AI vs AI, %ds) -----------------------------" % PHASE_SECONDS)
	print("  DRIBBLING: mean ball/carrier separation %.2fm over %d carrier frames" % [
		sep_sum / maxf(carry_frames, 1), carry_frames])
	print("  DRIBBLING: %d discrete touches (%.1f per second of carrying)" % [
		touches, touches / maxf(carry_frames / 60.0, 0.01)])
	print("  PASSING:   %d passes, %d shots (%.1f passes/min)" % [
		passes, shots, passes * 60.0 / PHASE_SECONDS])
	print("  OFF-BALL:  %.0f%% of in-range teammates had a CLEAR passing lane" % [
		100.0 * lane_open / maxf(lane_total, 1.0)])
	print("  OFF-BALL:  teammates bunched on the ball on %.0f%% of carrier frames" % [
		100.0 * converge_frames / maxf(carry_frames, 1)])
	print("  OFF-BALL:  midfielders >20m from the ball moving %.0f%% of the time" % [
		100.0 * mid_far_moving / maxf(mid_far_frames, 1)])
	print("  OFF-BALL:  forwards ahead of the ball %.0f%% of the time" % [
		100.0 * fwd_ahead / maxf(fwd_total, 1)])
	print("  MOVEMENT:  %d direction reversals (%.1f/min), %d frames behind a goal line" % [
		reversals, reversals * 60.0 / PHASE_SECONDS, behind_goal_frames])
	print("  MOVEMENT:  %d turnovers (%.1f/min)" % [turnovers, turnovers * 60.0 / PHASE_SECONDS])
	if kick_dists.size() > 0:
		var kd_sum := 0.0
		var kd_max := 0.0
		for v in kick_dists:
			kd_sum += v
			kd_max = maxf(kd_max, v)
		print("  POSSESSION: kicks struck from %.2fm on average, furthest %.2fm (challenge range %.1fm)" % [
			kd_sum / kick_dists.size(), kd_max, BallContest.CHALLENGE_RANGE])
	print("  POSSESSION: %d kicks by a player who was NOT the elected carrier" % kick_no_carrier)
	print("  POSSESSION: furthest the ball ever was from a player claiming possession: %.2fm" % claim_max)


# ------------------------------------------------ Phase B: human vs AI

func _phase_human_vs_ai() -> void:
	main.queue_free()
	await get_tree().process_frame
	main = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var plan: TeamPlan = main.home_team.plan
	var human: FootballPlayer = main.player_controller.controlled_player
	var frames := int(PHASE_SECONDS * 60.0)

	var human_carry := 0
	var any_carry := 0
	var sep_sum := 0.0
	var touches := 0
	var pass_attempts := 0
	var pass_reached := 0
	var pass_speed_sum := 0.0
	var challenged_frames := 0
	var lost_count := 0
	var was_carrying := false
	var pending_target: FootballPlayer = null
	var pending_frames := 0

	for i in range(frames):
		await get_tree().physics_frame
		var to_ball: Vector3 = main.ball.global_position - human.global_position
		InputState.move_vector = Vector2(to_ball.x, to_ball.z).limit_length(1.0)
		InputState.sprint_held = to_ball.length() > 6.0

		# Did a pass in flight arrive at the teammate it was aimed at?
		if pending_target != null:
			pending_frames += 1
			if is_instance_valid(pending_target) and \
				main.ball.global_position.distance_to(pending_target.global_position) < 2.5:
				pass_reached += 1
				pending_target = null
			elif pending_frames > 150:
				pending_target = null

		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and is_instance_valid(carrier):
			any_carry += 1
		if carrier == human:
			human_carry += 1
			sep_sum += Vector2(
				main.ball.global_position.x - human.global_position.x,
				main.ball.global_position.z - human.global_position.z).length()
			if human.touched_ball_this_frame:
				touches += 1
			for opp in human.opponents:
				if opp != null and is_instance_valid(opp) and opp.challenge_progress > 0.05:
					challenged_frames += 1
					break
			# Press PASS about twice a second while carrying.
			if i % 30 == 0:
				var opt: PassEvaluator.Option = PassEvaluator.best_option(
					human, human._get_aim_direction(), plan.forward_axis(), plan,
					FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
				if opt != null:
					pass_attempts += 1
					pending_target = opt.target
					pending_frames = 0
					human.execute_pass(FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, plan.forward_axis(), plan)
					await get_tree().physics_frame
					pass_speed_sum += main.ball.linear_velocity.length()
			was_carrying = true
		elif was_carrying:
			lost_count += 1
			was_carrying = false

	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false

	print("PLAYTEST B (human vs AI, %ds) --------------------------" % PHASE_SECONDS)
	print("  DRIBBLING: human carried %d frames (%.0f%% of all carrying)" % [
		human_carry, 100.0 * human_carry / maxf(any_carry, 1)])
	print("  DRIBBLING: mean ball separation while carrying %.2fm, %d touches" % [
		sep_sum / maxf(human_carry, 1), touches])
	print("  DRIBBLING: dispossessed %d times; under active challenge %.0f%% of carrying frames" % [
		lost_count, 100.0 * challenged_frames / maxf(human_carry, 1)])
	print("  PASSING:   %d human passes attempted, %d reached the intended teammate (%.0f%%)" % [
		pass_attempts, pass_reached, 100.0 * pass_reached / maxf(pass_attempts, 1)])
	print("  PASSING:   mean launch speed %.1f m/s (shot floor is %.1f)" % [
		pass_speed_sum / maxf(pass_attempts, 1), FootballPlayer.SHOT_SPEED_MIN])
