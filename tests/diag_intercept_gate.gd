extends Node3D

## Why does the INTERCEPT duty almost never get allocated?
##
## Two guesses have already been wrong (the danger multiplier, then the intent
## threshold), so this stops guessing and counts every gate the allocation has
## to pass, on the same live match, from the plan's own public state.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 45


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var teams: Array = [main.home_team, main.away_team]
	var frames := 0
	var g_no_ball := 0
	var g_intent := 0
	var g_carrier := 0
	var g_perception := 0
	var g_lanes := 0
	var lane_threat_seen: Array = []

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		for team in teams:
			var plan: TeamPlan = team.plan
			frames += 1
			if plan.we_have_ball:
				continue
			g_no_ball += 1
			if plan.attack_intent >= TeamPlan.INTERCEPT_MIN_INTENT:
				continue
			g_intent += 1
			if plan.carrier == null or not is_instance_valid(plan.carrier):
				continue
			g_carrier += 1
			if plan.perception == null:
				continue
			g_perception += 1

			# Recompute the lane search exactly as the allocation does, so the
			# number of candidate lanes is measured rather than assumed.
			var per: FootballPerception = plan.perception
			var from: Vector3 = plan.carrier.global_position
			var best_threat := 0.0
			var lanes := 0
			for o in team.opponent_team.players:
				if o == null or not is_instance_valid(o) or o == plan.carrier or o.is_goalkeeper:
					continue
				var to: Vector3 = o.global_position
				var gain: float = per.progression(to, from)
				if gain <= 0.0:
					continue
				var advance: float = clampf(gain / 15.0, 0.0, 1.0)
				var danger: float = lerpf(TeamPlan.DANGER_FLOOR, 1.0, per.danger_at(to))
				var threat: float = advance * danger * per.lane_quality(from, to)
				best_threat = maxf(best_threat, threat)
				if threat >= TeamPlan.INTERCEPT_MIN_THREAT:
					lanes += 1
			if lanes > 0:
				g_lanes += 1
			if lane_threat_seen.size() < 4000:
				lane_threat_seen.append(best_threat)

	print("GATE: team-frames sampled                 %d" % frames)
	print("GATE: ...where we do NOT have the ball    %d (%.1f%%)" % [
		g_no_ball, 100.0 * g_no_ball / maxf(frames, 1)])
	print("GATE: ...and attack_intent < %.2f         %d (%.1f%% of frames)" % [
		TeamPlan.INTERCEPT_MIN_INTENT, g_intent, 100.0 * g_intent / maxf(frames, 1)])
	print("GATE: ...and an opponent is carrying      %d (%.1f%% of frames)" % [
		g_carrier, 100.0 * g_carrier / maxf(frames, 1)])
	print("GATE: ...and perception exists            %d (%.1f%% of frames)" % [
		g_perception, 100.0 * g_perception / maxf(frames, 1)])
	print("GATE: ...and at least one lane clears %.2f  %d (%.1f%% of frames)" % [
		TeamPlan.INTERCEPT_MIN_THREAT, g_lanes, 100.0 * g_lanes / maxf(frames, 1)])

	lane_threat_seen.sort()
	if not lane_threat_seen.is_empty():
		var n: int = lane_threat_seen.size()
		print("GATE: best-lane threat distribution over %d eligible frames:" % n)
		print("GATE:   p10 %.3f  median %.3f  p90 %.3f  max %.3f" % [
			lane_threat_seen[n / 10], lane_threat_seen[n / 2],
			lane_threat_seen[n * 9 / 10], lane_threat_seen[n - 1]])
	get_tree().quit()
