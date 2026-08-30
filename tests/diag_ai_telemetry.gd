extends Node3D

## LEVEL 2 validation: what does a whole match actually look like, in numbers?
##
## Runs the same match twice on the same build -- once with the AI 2.0
## defensive unit switched off, once with it on -- and reports the difference.
## A single run of any live-match statistic in this project is noisy enough to
## support whatever conclusion you went looking for (the seed does not make
## runs deterministic here; that was established in v0.9.2.1), so nothing is
## claimed from one number.
##
## The headline measures are the ones QA's complaints translate into:
##
##   defensive clustering   how many of the defending side are inside a few
##                          metres of the ball. "Ten ball chasers" is a number.
##   midfield participation how much of the match a midfielder spends doing
##                          something other than holding a formation slot.
##   duty distribution      which jobs actually get allocated, and how often.
##   possession churn       turnovers per minute -- a proxy for whether the
##                          new shape simply gives the ball away.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 75
const SAMPLE_EVERY := 6

## Radius around the ball inside which a defending player counts as "at the
## ball". Wide enough to include the presser and the second man, so a healthy
## side sits near 2, not near 6.
const CLUSTER_RADIUS := 8.0


func _ready() -> void:
	print("TELEMETRY: ==== AI behaviour, paired A/B on one build ====")
	var off: Dictionary = await _run(false)
	var on: Dictionary = await _run(true)
	_compare(off, on)
	get_tree().quit()


func _run(unit_defending: bool) -> Dictionary:
	TeamPlan.unit_defending_enabled = unit_defending
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var pm: PossessionManager = main.possession_manager
	var ball: RigidBody3D = main.ball

	var duty_frames := {}
	var cluster_sum := 0.0
	var cluster_max := 0
	var samples := 0
	var mid_active := 0
	var mid_frames := 0
	var turnovers := 0
	var last_team: int = -1

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		if pm.possessing_team != -1 and pm.possessing_team != last_team:
			if last_team != -1:
				turnovers += 1
			last_team = pm.possessing_team
		if i % SAMPLE_EVERY != 0:
			continue
		samples += 1

		# Which side is defending right now?
		var defending_team: int = -1
		if pm.current_carrier != null:
			defending_team = 1 - pm.current_carrier.team_id

		var at_ball := 0
		for p in players:
			if p == null or not is_instance_valid(p) or p.is_goalkeeper:
				continue
			var team: TeamController = main.home_team if p.team_id == 0 else main.away_team
			var duty: int = team.plan.duty_of(p)
			var name: String = TeamPlan.Duty.keys()[duty]
			duty_frames[name] = duty_frames.get(name, 0) + 1

			if defending_team != -1 and p.team_id == defending_team:
				if p.global_position.distance_to(ball.global_position) < CLUSTER_RADIUS:
					at_ball += 1

			if FormationManager.role_category(p.formation_role) == "MID":
				mid_frames += 1
				# A midfielder is "participating" when they have a job that is
				# about the game rather than about standing in their slot.
				if duty != TeamPlan.Duty.COVER_SPACE:
					mid_active += 1

		if defending_team != -1:
			cluster_sum += float(at_ball)
			cluster_max = maxi(cluster_max, at_ball)

	main.get_parent().remove_child(main)
	main.queue_free()
	for i in range(3):
		await get_tree().physics_frame
	TeamPlan.unit_defending_enabled = true

	var total_duty := 0
	for k in duty_frames:
		total_duty += duty_frames[k]
	return {
		"label": "unit defending ON" if unit_defending else "unit defending OFF",
		"duties": duty_frames,
		"total_duty": total_duty,
		"cluster_mean": cluster_sum / maxf(samples, 1),
		"cluster_max": cluster_max,
		"mid_participation": float(mid_active) / maxf(mid_frames, 1),
		"turnovers_per_min": 60.0 * turnovers / float(SECONDS),
	}


func _compare(off: Dictionary, on: Dictionary) -> void:
	for r in [off, on]:
		print("TELEMETRY: ---- %s ----" % r["label"])
		print("TELEMETRY:   defenders within %.0f m of the ball: mean %.2f, worst %d" % [
			CLUSTER_RADIUS, r["cluster_mean"], r["cluster_max"]])
		print("TELEMETRY:   midfielders on a job other than holding shape: %.1f%%" % [
			r["mid_participation"] * 100.0])
		print("TELEMETRY:   turnovers per minute: %.1f" % r["turnovers_per_min"])
		var keys: Array = r["duties"].keys()
		keys.sort_custom(func(a, b): return r["duties"][a] > r["duties"][b])
		for k in keys:
			print("TELEMETRY:     %-14s %5.1f%%" % [
				k, 100.0 * r["duties"][k] / maxf(r["total_duty"], 1)])
	print("TELEMETRY: ---- difference ----")
	print("TELEMETRY:   clustering  %.2f -> %.2f  (%+.2f defenders at the ball)" % [
		off["cluster_mean"], on["cluster_mean"],
		on["cluster_mean"] - off["cluster_mean"]])
	print("TELEMETRY:   midfield    %.1f%% -> %.1f%%  (%+.1f points)" % [
		off["mid_participation"] * 100.0, on["mid_participation"] * 100.0,
		(on["mid_participation"] - off["mid_participation"]) * 100.0])
	print("TELEMETRY:   turnovers   %.1f -> %.1f per minute" % [
		off["turnovers_per_min"], on["turnovers_per_min"]])
