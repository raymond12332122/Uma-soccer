extends Node3D

# V0.8.7 DIAGNOSTIC -- measurement only, changes nothing.
#
# Four reported problems, four hypotheses to confirm or kill before any
# code changes:
#
#  A. Human PASS "behaves like a small/weak kick".
#     Hypothesis: PASS_ASSIST_MIN_ALIGNMENT = 0.25 is a HARD 75-degree cone.
#     A teammate outside it is not merely deprioritised, they are skipped
#     entirely -- best_option returns null -- and the fallback fires a blind
#     PASS_NO_TARGET_SPEED (7.0 m/s) knock. Measure how often a real aim at
#     a real teammate produces null, and what speed actually leaves the boot.
#
#  B. Ball feels "too large / heavy / stuck to the ground".
#     Hypothesis: this is GEOMETRY, not physics tuning. Player capsule
#     radius 0.40 + ball radius 0.35 = 0.75m minimum centre-to-centre
#     contact distance, but dribble_distance targets 0.62m. The spring
#     permanently pulls the ball to a point inside the player's own capsule,
#     so the ball can never be anywhere except jammed against them.
#     Measure the actual separation at walk and at sprint.
#
#  C. Teammates move but "don't create useful passing lanes".
#     Hypothesis: no support duty evaluates the lane. SUPPORT_SHORT/WIDE,
#     PUSH_UP and RUN_BEHIND all derive a target from pure geometry
#     (formation slot, ball position, forward axis) and never ask whether an
#     opponent is standing in the line from the carrier. Measure what
#     fraction of support teammates are actually passable at any moment.
#
#  D. Midfielders passive when the ball is far away.
#     Measure idle fraction as a function of distance to the ball.

const MainScene := preload("res://scenes/Main.tscn")


func _ready() -> void:
	await _diag_a_human_pass()
	await _diag_b_ball_separation()
	await _diag_c_passing_lanes()
	await _diag_d_human_pressure()
	get_tree().quit(0)


## Why can a human who simply runs at the ball keep it? Reproduces the
## v0_8_4 scenario and reports, for the frames the human is carrying, where
## the opponents actually ARE and what is limiting their challenge.
func _diag_d_human_pressure() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var pm: PossessionManager = main.possession_manager
	var ball: RigidBody3D = main.ball

	var carry_frames := 0
	var nearest_sum := 0.0
	var in_range_frames := 0
	var rate_sum := 0.0
	var rate_frames := 0
	var human_speed_sum := 0.0
	var opp_speed_sum := 0.0
	var gap_sum := 0.0

	for i in range(int(30.0 * 60.0)):
		await get_tree().physics_frame
		var to_ball: Vector3 = ball.global_position - human.global_position
		InputState.move_vector = Vector2(to_ball.x, to_ball.z).limit_length(1.0)
		InputState.sprint_held = to_ball.length() > 6.0
		if pm.current_carrier != human:
			continue
		carry_frames += 1
		human_speed_sum += human.velocity.length()
		gap_sum += Vector2(ball.global_position.x - human.global_position.x,
			ball.global_position.z - human.global_position.z).length()
		var nearest := 999.0
		var nearest_opp: FootballPlayer = null
		for opp in human.opponents:
			if opp == null or not is_instance_valid(opp) or opp.is_goalkeeper:
				continue
			var d: float = opp.global_position.distance_to(ball.global_position)
			if d < nearest:
				nearest = d
				nearest_opp = opp
		nearest_sum += nearest
		if nearest <= BallContest.CHALLENGE_RANGE:
			in_range_frames += 1
			var r: float = BallContest.challenge_rate(nearest_opp, human, ball)
			rate_sum += r
			rate_frames += 1
			opp_speed_sum += nearest_opp.velocity.length()
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false

	if carry_frames > 0:
		print("DIAG-D: human carried for %d frames | human %.1f m/s, ball gap %.2fm"
			% [carry_frames, human_speed_sum / carry_frames, gap_sum / carry_frames])
		print("DIAG-D:   nearest opponent to ball: %.2fm on average" % (nearest_sum / carry_frames))
		print("DIAG-D:   frames with an opponent inside CHALLENGE_RANGE (%.1fm): %d (%.0f%%)"
			% [BallContest.CHALLENGE_RANGE, in_range_frames, 100.0 * in_range_frames / carry_frames])
		if rate_frames > 0:
			print("DIAG-D:   mean challenge rate when in range: %.2f/s (need %.2f sustained)"
				% [rate_sum / rate_frames, BallContest.CHALLENGE_TIME_REQUIRED])
			print("DIAG-D:   chasing opponent speed %.1f m/s vs human %.1f m/s"
				% [opp_speed_sum / rate_frames, human_speed_sum / carry_frames])

	main.queue_free()
	await get_tree().process_frame


# --------------------------------------------------------------- A: pass

## Fan teammates out at known angles around a carrier and, for each, aim
## the stick directly at them and ask the evaluator what it would do.
func _diag_a_human_pass() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var fwd: Vector3 = main.home_team.plan.forward_axis()
	var plan: TeamPlan = main.home_team.plan

	# Park everyone irrelevant far away so only our arrangement matters.
	var mates: Array = []
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			mates.append(p)
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)

	human.global_position = Vector3(0, 1, 0)

	# Six teammates evenly around the carrier at a very ordinary 9m.
	var angles := [0.0, 45.0, 90.0, 135.0, 180.0, 270.0]
	var placed: Array = []
	for i in range(mates.size()):
		if i < angles.size():
			var a: float = deg_to_rad(angles[i])
			var dir: Vector3 = fwd.rotated(Vector3.UP, a)
			mates[i].global_position = human.global_position + dir * 9.0
			placed.append({"mate": mates[i], "angle": angles[i], "dir": dir})
		else:
			mates[i].global_position = Vector3(-200, 1, -200)
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("DIAG-A: aiming directly at a teammate 9m away, one angle at a time")
	print("DIAG-A: cone constant PASS_ASSIST_MIN_ALIGNMENT = %.2f (= %.0f degrees)"
		% [FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, rad_to_deg(acos(FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT))])
	var nulls := 0
	for entry in placed:
		var aim: Vector3 = entry["dir"]
		var option: PassEvaluator.Option = PassEvaluator.best_option(
			human, aim, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
		if option == null:
			nulls += 1
			print("DIAG-A:   aim %3.0f deg -> NO OPTION (falls back to a blind %.1f m/s knock)"
				% [entry["angle"], FootballPlayer.PASS_NO_TARGET_SPEED])
		else:
			var correct: bool = option.target == entry["mate"]
			# The gap between the real 9m and the distance the SPEED was
			# solved from is the lead, and any large gap means the pass is
			# being weighted for where the receiver will be in over a second.
			var aim_dist: float = human.global_position.distance_to(option.aim_point)
			var true_dist: float = human.global_position.distance_to(option.target.global_position)
			var roll: float = PassEvaluator.ROLL_PER_SPEED * option.speed - PassEvaluator.ROLL_OFFSET
			print("DIAG-A:   aim %3.0f deg -> %s (%s) speed %.1f m/s | true dist %.1fm, lead-adjusted %.1fm, ball rolls %.1fm%s"
				% [entry["angle"], option.target.player_data.display_name,
				"the teammate aimed at" if correct else "A DIFFERENT TEAMMATE", option.speed,
				true_dist, aim_dist, roll,
				"  <<< FALLS SHORT" if roll < true_dist else ""])
	print("DIAG-A: %d of %d deliberate aims produced no pass target at all" % [nulls, placed.size()])

	main.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------- B: separation

## How far from the player does the ball actually sit while being dribbled?
func _diag_b_ball_separation() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var ball: RigidBody3D = main.ball
	# Park EVERY other player far away -- otherwise a teammate or opponent
	# takes the ball and the separation figure measures nothing.
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	for p in main.home_players:
		if p != human:
			p.global_position = Vector3(200, 1, -200)

	# Read the real geometry out of the live scene rather than restating
	# constants -- a stale hardcoded number here would quietly invalidate
	# every conclusion drawn from this diagnostic.
	var capsule_r: float = (human.get_node("CollisionShape3D").shape as CapsuleShape3D).radius
	var ball_r: float = (ball.get_node("CollisionShape3D").shape as SphereShape3D).radius
	var control_r: float = (human.control_area.get_node("CollisionShape3D").shape as SphereShape3D).radius
	var action_r: float = (human.action_area.get_node("CollisionShape3D").shape as SphereShape3D).radius
	print("DIAG-B: capsule %.2f + ball %.2f = %.2fm contact floor | control radius %.2f, action radius %.2f"
		% [capsule_r, ball_r, capsule_r + ball_r, control_r, action_r])
	print("DIAG-B: dribble_distance (walk) = %.2f, dribble_distance_sprint = %.2f"
		% [human.dribble_distance, human.dribble_distance_sprint])
	if human.dribble_distance < capsule_r + ball_r:
		print("DIAG-B: >>> the WALK target (%.2f) is INSIDE the contact floor (%.2f) <<<"
			% [human.dribble_distance, capsule_r + ball_r])

	for phase in [{"name": "walk", "sprint": false}, {"name": "sprint", "sprint": true}]:
		# Start at one end and run along +x so 150 frames never reaches the
		# far touchline (a player pinned against the boundary stops moving,
		# which silently turned the sprint sample into a standstill sample).
		# Settle STATIONARY on the ground first, with no input at all. Placing
		# the player mid-air and moving in the same frame let gravity and the
		# initial ball collision dominate the sample.
		InputState.move_vector = Vector2.ZERO
		InputState.sprint_held = false
		InputState.shoot_held = false
		human.global_position = Vector3(-22, 0.1, 0)
		human.velocity = Vector3.ZERO
		human.reset_intent()
		ball.global_position = human.global_position + Vector3(0.8, 0.25, 0)
		ball.linear_velocity = Vector3.ZERO
		ball.angular_velocity = Vector3.ZERO
		for i in range(40):
			await get_tree().physics_frame
		if not human.has_possession:
			print("DIAG-B: %s -- WARNING: no possession even standing still next to the ball" % phase["name"])
		# Now start the run and let it reach steady state.
		InputState.move_vector = Vector2(1, 0)
		InputState.sprint_held = phase["sprint"]
		for i in range(45):
			await get_tree().physics_frame
		# Record separation UNCONDITIONALLY -- gating on has_possession hides
		# the interesting case (the ball being shoved away and chased), which
		# is precisely the behaviour under investigation.
		var sum := 0.0
		var n := 0
		var min_sep := 99.0
		var max_sep := 0.0
		var speed_sum := 0.0
		var ball_speed_sum := 0.0
		var possessed := 0
		var in_control_sensor := 0
		var cooldown_frames := 0
		var touches := 0
		for i in range(120):
			await get_tree().physics_frame
			if human.ball_in_control_range != null:
				in_control_sensor += 1
			if human.touched_ball_this_frame:
				touches += 1
			var d := Vector2(ball.global_position.x - human.global_position.x,
				ball.global_position.z - human.global_position.z).length()
			sum += d
			n += 1
			speed_sum += human.velocity.length()
			ball_speed_sum += Vector2(ball.linear_velocity.x, ball.linear_velocity.z).length()
			min_sep = minf(min_sep, d)
			max_sep = maxf(max_sep, d)
			if human.has_possession:
				possessed += 1
		print("DIAG-B: %s -- separation mean %.2fm (min %.2f max %.2f) | player %.1f m/s, ball %.1f m/s | possession %d/%d, in control sensor %d/%d, touches %d"
			% [phase["name"], sum / n, min_sep, max_sep, speed_sum / n, ball_speed_sum / n,
			possessed, n, in_control_sensor, n, touches])

	# A direction change is the thing the brief calls a "fake": run one way,
	# reverse the stick, and see whether the ball actually follows the new
	# direction or is simply left behind / run over.
	human.global_position = Vector3(-22, 1, 0)
	human.velocity = Vector3.ZERO
	ball.global_position = human.global_position + Vector3(0.8, -0.65, 0)
	ball.linear_velocity = Vector3.ZERO
	InputState.move_vector = Vector2(1, 0)
	InputState.sprint_held = false
	for i in range(60):
		await get_tree().physics_frame
	InputState.move_vector = Vector2(0, 1)
	var kept := 0
	var total := 0
	for i in range(60):
		await get_tree().physics_frame
		total += 1
		if human.has_possession:
			kept += 1
	print("DIAG-B: after a 90-degree direction change, possession kept on %d of %d frames" % [kept, total])
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false

	main.queue_free()
	await get_tree().process_frame


# --------------------------------------------------------------- C: lanes

## In a live match, for every moment a home player carries the ball, how
## many of their teammates are actually passable?
func _diag_c_passing_lanes() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var plan: TeamPlan = main.home_team.plan

	var carrier_frames := 0
	var option_sum := 0.0
	var blocked_sum := 0.0
	var in_range_sum := 0.0
	var best_score_sum := 0.0
	var no_option_frames := 0

	# midfield activity by ball distance
	var mid_far_frames := 0
	var mid_far_idle := 0

	for i in range(int(45.0 * 60.0)):
		await get_tree().physics_frame
		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and is_instance_valid(carrier) and carrier in main.home_players:
			carrier_frames += 1
			var in_range := 0
			var blocked := 0
			for mate in carrier.teammates:
				if mate == carrier or mate == null or not is_instance_valid(mate) or mate.is_goalkeeper:
					continue
				var to_mate: Vector3 = mate.global_position - carrier.global_position
				to_mate.y = 0.0
				var dist: float = to_mate.length()
				if dist < PassEvaluator.MIN_PASS_DISTANCE or dist > PassEvaluator.MAX_PASS_DISTANCE:
					continue
				in_range += 1
				if PassEvaluator._lane_blocked(carrier.global_position, to_mate / dist, dist, carrier.opponents):
					blocked += 1
			in_range_sum += in_range
			blocked_sum += blocked
			var opt: PassEvaluator.Option = PassEvaluator.best_option(
				carrier, carrier._get_aim_direction(), plan.forward_axis(), plan,
				FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI)
			if opt == null:
				no_option_frames += 1
			else:
				best_score_sum += opt.score
				option_sum += 1

		for p in main.home_players:
			if p.is_goalkeeper:
				continue
			if FormationManager.role_category(p.formation_role) != "MID":
				continue
			var ball_d: float = p.global_position.distance_to(main.ball.global_position)
			if ball_d > 20.0:
				mid_far_frames += 1
				if p.velocity.length() < 0.5:
					mid_far_idle += 1

	if carrier_frames > 0:
		print("DIAG-C: home carrier for %d frames" % carrier_frames)
		print("DIAG-C:   teammates in passing range: %.2f per frame" % (in_range_sum / carrier_frames))
		print("DIAG-C:   of those, lane BLOCKED: %.2f per frame (%.0f%%)"
			% [blocked_sum / carrier_frames, 100.0 * blocked_sum / maxf(in_range_sum, 1.0)])
		print("DIAG-C:   frames with no pass option at all: %d (%.0f%%)"
			% [no_option_frames, 100.0 * no_option_frames / carrier_frames])
		if option_sum > 0:
			print("DIAG-C:   mean best-option score when one exists: %.2f" % (best_score_sum / option_sum))
	if mid_far_frames > 0:
		print("DIAG-C: midfielders >20m from ball: idle %.0f%% of the time (%d/%d player-frames)"
			% [100.0 * mid_far_idle / mid_far_frames, mid_far_idle, mid_far_frames])

	# Is the lane refinement actually reached? Count how the home side's
	# duties are distributed while they hold the ball -- the refinement only
	# applies to the four support duties.
	var duty_counts := {}
	var samples := 0
	for i in range(240):
		await get_tree().physics_frame
		var carrier: FootballPlayer = pm.current_carrier
		if carrier == null or not is_instance_valid(carrier) or not (carrier in main.home_players):
			continue
		samples += 1
		for p in main.home_players:
			if p.is_goalkeeper:
				continue
			var d: int = plan.duty_of(p)
			duty_counts[d] = duty_counts.get(d, 0) + 1
	if samples > 0:
		var names := ["CONTEST", "PRESS_SUPPORT", "SUPPORT_SHORT", "SUPPORT_WIDE",
			"RUN_BEHIND", "MARK", "COVER_SPACE", "FOLLOW_UP", "PUSH_UP"]
		var line := ""
		for d in duty_counts.keys():
			line += "%s=%.1f " % [names[d] if d < names.size() else str(d), float(duty_counts[d]) / samples]
		print("DIAG-C: duties per frame while home holds the ball (%d frames): %s" % [samples, line])

	main.queue_free()
	await get_tree().process_frame
