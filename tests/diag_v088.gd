extends Node3D

# V0.8.8 DIAGNOSTIC -- measurement only, changes nothing.
#
# The report is that AI can steal, pass and shoot from unrealistic
# distances. Two candidate root causes were found by reading the code; this
# measures what actually happens in a live match so the fix is aimed at the
# real numbers rather than at the constants:
#
#  A. execute_pass/execute_shot take the ball from `ball_in_action_range`
#     (ActionArea, radius 2.5m) with NO possession check whatsoever. If that
#     is the cause, kicks will be observed several metres from the ball.
#
#  B. PossessionManager elects a carrier from `has_possession`, which is
#     just "ball inside my ControlArea" (~1.55-1.90m after v0.8.7 widened it
#     to contain the dribble leash). If that is the cause, possession will
#     be seen changing hands at well over a contact distance, and without
#     any BallContest challenge having been built.
#
# Also records how far the ball is from a carrier's feet over time, which
# is the "possession is sticky / ball feels heavy" question.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 40.0


func _ready() -> void:
	await _measure_live_match()
	await _measure_pass_direction()
	get_tree().quit(0)


func _measure_live_match() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var ball: RigidBody3D = main.ball
	var players: Array = main.home_players + main.away_players

	var kick_dists: Array = []
	var kick_no_possession := 0
	var kicks := 0
	var kick_counts := {}

	var steal_dists: Array = []
	var steals := 0
	var interceptions := 0
	var _prev_carrier_had_control := false
	var steals_without_challenge := 0

	var prev_carrier: FootballPlayer = null
	var carrier_gap_sum := 0.0
	var carrier_frames := 0

	# has_possession is a proximity flag; record how far the ball actually is
	# from everyone who currently claims possession.
	var claim_dists: Array = []

	for i in range(int(SECONDS * 60.0)):
		await get_tree().physics_frame

		for p in players:
			var seen: int = kick_counts.get(p, -1)
			if seen >= 0 and p.kick_count > seen:
				kicks += 1
				var d: float = p.global_position.distance_to(ball.global_position)
				kick_dists.append(d)
				# Was this player actually the elected carrier when they
				# struck it? That is the only defensible licence to kick.
				if pm.current_carrier != p:
					kick_no_possession += 1
			kick_counts[p] = p.kick_count
			if p.has_possession:
				claim_dists.append(p.global_position.distance_to(ball.global_position))

		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and is_instance_valid(carrier):
			carrier_frames += 1
			carrier_gap_sum += Vector2(
				ball.global_position.x - carrier.global_position.x,
				ball.global_position.z - carrier.global_position.z).length()

		# Distinguish a STEAL from an INTERCEPTION. Both show up as
		# possession moving between opposing players, but only one is a
		# problem: taking the ball off someone who still had it under
		# control. Collecting a ball that had already run loose (a stray
		# pass, a heavy touch) is ordinary football and the previous carrier
		# being metres away is expected -- lumping the two together made the
		# first version of this diagnostic report 4m "steals" that were
		# nothing of the kind.
		if carrier != null and prev_carrier != null and carrier != prev_carrier \
			and carrier.team_id != prev_carrier.team_id:
			var victim_gap: float = prev_carrier.global_position.distance_to(ball.global_position)
			if _prev_carrier_had_control:
				steals += 1
				steal_dists.append(victim_gap)
				if carrier.challenge_progress <= 0.01:
					steals_without_challenge += 1
			else:
				interceptions += 1
		if carrier != null:
			prev_carrier = carrier
			_prev_carrier_had_control = carrier.has_possession \
				and carrier.global_position.distance_to(ball.global_position) < 2.0

	print("DIAG-A: %d kicks observed" % kicks)
	if kicks > 0:
		print("DIAG-A:   distance from kicker to ball: mean %.2fm, max %.2fm" % [
			_mean(kick_dists), _max(kick_dists)])
		print("DIAG-A:   kicks struck by a player who was NOT the elected carrier: %d (%.0f%%)" % [
			kick_no_possession, 100.0 * kick_no_possession / kicks])
		print("DIAG-A:   ActionArea radius is %.2fm and execute_pass/shot check no possession" % 2.5)
	print("DIAG-B: %d genuine steals (victim still had control) + %d interceptions of loose balls" % [steals, interceptions])
	if steals > 0:
		print("DIAG-B:   STEAL: distance from the dispossessed player to the ball: mean %.2fm, max %.2fm" % [
			_mean(steal_dists), _max(steal_dists)])
		print("DIAG-B:   steals with no challenge built at all: %d (%.0f%%)" % [
			steals_without_challenge, 100.0 * steals_without_challenge / steals])
	if claim_dists.size() > 0:
		print("DIAG-B:   ball distance whenever a player claims has_possession: mean %.2fm, max %.2fm" % [
			_mean(claim_dists), _max(claim_dists)])
	if carrier_frames > 0:
		print("DIAG-C: mean ball gap from the elected carrier's feet: %.2fm over %d frames" % [
			carrier_gap_sum / carrier_frames, carrier_frames])

	# What does the carrier's option set actually look like, and what jobs
	# are their teammates on? "Teammates move but I have nobody to pass to"
	# is either too few players in range, too few clear lanes, or too few
	# players on a duty that offers an option at all.
	var plan: TeamPlan = main.home_team.plan
	var opt_frames := 0
	var in_range_sum := 0.0
	var passable_sum := 0.0
	var duty_counts := {}
	var duty_samples := 0
	for i in range(int(20.0 * 60.0)):
		await get_tree().physics_frame
		var c: FootballPlayer = pm.current_carrier
		if c == null or not is_instance_valid(c) or not (c in main.home_players):
			continue
		opt_frames += 1
		duty_samples += 1
		for mate in main.home_players:
			if mate == c or mate.is_goalkeeper:
				continue
			var d: int = plan.duty_of(mate)
			duty_counts[d] = duty_counts.get(d, 0) + 1
			var to_mate: Vector3 = mate.global_position - c.global_position
			to_mate.y = 0.0
			var dist: float = to_mate.length()
			if dist < PassEvaluator.MIN_PASS_DISTANCE or dist > PassEvaluator.MAX_PASS_DISTANCE:
				continue
			in_range_sum += 1.0
			if not PassEvaluator._lane_blocked(c.global_position, to_mate / dist, dist, c.opponents):
				passable_sum += 1.0
	if opt_frames > 0:
		print("DIAG-E: carrier had %.1f teammates in passing range, %.1f of them with a clear lane" % [
			in_range_sum / opt_frames, passable_sum / opt_frames])
		var names := ["CONTEST", "PRESS_SUPPORT", "SUPPORT_SHORT", "SUPPORT_WIDE",
			"RUN_BEHIND", "MARK", "COVER_SPACE", "FOLLOW_UP", "PUSH_UP"]
		var line := ""
		for d in duty_counts.keys():
			line += "%s=%.1f " % [names[d] if d < names.size() else str(d),
				float(duty_counts[d]) / duty_samples]
		print("DIAG-E: duties per frame while this side has the ball: %s" % line)

	main.queue_free()
	await get_tree().process_frame


## Does the human PASS follow the stick? Two teammates, one near but off to
## the side, one further away but exactly where the player is pointing.
func _measure_pass_direction() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var plan: TeamPlan = main.home_team.plan
	var fwd: Vector3 = plan.forward_axis()
	var mates: Array = []
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			mates.append(p)
		if p != human:
			p.global_position = Vector3(200, 1, -200)
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	human.global_position = Vector3(0, 1, 0)

	var near_mate: FootballPlayer = mates[0]
	var far_mate: FootballPlayer = mates[1]
	print("DIAG-D: aiming at a teammate 8m away with another 3m away off to the side")
	for angle in [0.0, 45.0, 90.0, 180.0, 270.0]:
		var aim: Vector3 = fwd.rotated(Vector3.UP, deg_to_rad(angle))
		var side: Vector3 = aim.rotated(Vector3.UP, deg_to_rad(115.0))
		far_mate.global_position = human.global_position + aim * 8.0
		near_mate.global_position = human.global_position + side * 3.0
		far_mate.velocity = Vector3.ZERO
		near_mate.velocity = Vector3.ZERO
		await get_tree().physics_frame
		await get_tree().physics_frame
		var opt: PassEvaluator.Option = PassEvaluator.best_option(
			human, aim, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
		var picked := "NOTHING"
		if opt != null:
			picked = "the AIMED teammate" if opt.target == far_mate else "the NEAR one off-aim"
		print("DIAG-D:   aim %3.0f deg -> %s" % [angle, picked])

	main.queue_free()
	await get_tree().process_frame


func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _max(a: Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m
