extends Node3D

## v0.9.1 diagnostic: what causes a >0.253m jump in the steered aim point?
##
## v0_8_6 asserts that ai_smoothed_target moves no further per frame than
## TARGET_MAX_SPEED allows. Measured across six runs per side, that assertion
## fails 0/6 at the v0.9.0 baseline and 2/6 on v0.9.1, with steps of 16-27m --
## far too large to be a rate-limiter slipping, and about the distance from
## open play back to a formation slot.
##
## AIController marks a target `discontinuous` when player.ai_state < 0, which
## FootballPlayer.reset_intent() sets, which MatchManager._reset_all_players()
## calls after a GOAL. That path deliberately skips the rate limit so a stale
## pre-kickoff target is not dragged into the new situation.
##
## So the question is not "is the limiter broken" but "does every oversized
## step coincide with a reset". This records both and prints the answer
## instead of assuming it.

const MainScene := preload("res://scenes/Main.tscn")


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var outfield: Array = []
	for p in main.home_players + main.away_players:
		if not p.is_goalkeeper:
			outfield.append(p)

	var limit: float = AIController.TARGET_MAX_SPEED / 60.0 + 0.02
	var last_target := {}
	var was_reset := {}
	var big_steps := 0
	var big_near_reset := 0
	var big_no_reset := 0
	var worst := 0.0
	var worst_ctx := ""
	var goals := 0
	var prev_score := -1
	# The OTHER intermittent v0_8_6 assertion: two PUSH_UP players aiming at
	# the same lane. Right after a kickoff everybody is standing on their
	# formation slot, so this asks the same question -- is a converging pair
	# just the reset, or a real positioning failure in open play?
	var lane_bad := 0
	var lane_bad_near_reset := 0
	var lane_worst := INF
	var lane_worst_ctx := ""
	var lane_full_sum := 0.0
	var lane_truly_together := 0
	# Frames since this player last had ai_state < 0.
	var since_reset := {}

	for i in range(60 * 60):
		await get_tree().physics_frame

		var score: int = main.home_score + main.away_score
		if prev_score >= 0 and score != prev_score:
			goals += 1
		prev_score = score

		for team in [main.home_team, main.away_team]:
			var advancing: Array = []
			for p in team.players:
				if p.is_goalkeeper:
					continue
				if team.plan.duty_of(p) == TeamPlan.Duty.PUSH_UP and not p.has_active_personality_event():
					advancing.append(p)
			for a in range(advancing.size()):
				for b in range(a + 1, advancing.size()):
					var gap: float = absf(advancing[a].ai_target.z - advancing[b].ai_target.z)
					if gap <= 0.5:
						lane_bad += 1
						# The assertion compares ONLY the z axis. Two players
						# sharing a channel at different DEPTHS are not making
						# the same run -- a full-back overlapping behind a
						# midfielder is ordinary football -- so record the
						# full separation as well before calling this a
						# convergence.
						var full: float = advancing[a].ai_target.distance_to(advancing[b].ai_target)
						lane_full_sum += full
						if full < 3.0:
							lane_truly_together += 1
						var sa: int = since_reset.get(advancing[a].get_instance_id(), 9999)
						var sb: int = since_reset.get(advancing[b].get_instance_id(), 9999)
						var near: int = mini(sa, sb)
						if near <= 90:
							lane_bad_near_reset += 1
						if gap < lane_worst:
							lane_worst = gap
							lane_worst_ctx = "%s vs %s  gap %.2fm  frames since reset %d" % [
								advancing[a].formation_role, advancing[b].formation_role, gap, near]

		for p in outfield:
			var id: int = p.get_instance_id()
			if p.ai_state < 0:
				since_reset[id] = 0
			else:
				since_reset[id] = since_reset.get(id, 9999) + 1

			if last_target.has(id):
				var step: float = last_target[id].distance_to(p.ai_smoothed_target)
				if step > limit:
					big_steps += 1
					# "Near a reset" = this player was reset within the last
					# handful of frames, so the jump is the documented
					# discontinuity rather than a limiter failure.
					if since_reset.get(id, 9999) <= 3:
						big_near_reset += 1
					else:
						big_no_reset += 1
					if step > worst:
						worst = step
						worst_ctx = "%s  step %.2fm  frames since reset %d  duty %d  state %d" % [
							p.player_data.display_name if p.player_data else p.name,
							step, since_reset.get(id, 9999), p.ai_duty, p.ai_state]
			last_target[id] = p.ai_smoothed_target

	print("DIAG-STEP: limit %.3fm, %d goals in the sample" % [limit, goals])
	print("DIAG-STEP: %d oversized steps -- %d within 3 frames of a reset, %d NOT" % [
		big_steps, big_near_reset, big_no_reset])
	if worst_ctx != "":
		print("DIAG-STEP: worst -- %s" % worst_ctx)
	if big_no_reset > 0:
		print("DIAG-STEP: >>> %d oversized steps are NOT explained by a reset; the limiter is genuinely being bypassed" % big_no_reset)
	else:
		print("DIAG-STEP: every oversized step coincided with a reset (goal/kickoff), i.e. the documented discontinuity")
	if lane_bad == 0:
		print("DIAG-STEP: no converging PUSH_UP pairs at all")
	else:
		print("DIAG-STEP: %d converging PUSH_UP samples (gap <= 0.5m) -- %d within 1.5s of a reset (%.0f%%)" % [
			lane_bad, lane_bad_near_reset, 100.0 * lane_bad_near_reset / lane_bad])
		print("DIAG-STEP:   worst -- %s" % lane_worst_ctx)
		print("DIAG-STEP:   mean FULL 3D separation of those pairs: %.2fm" % (lane_full_sum / lane_bad))
		print("DIAG-STEP:   pairs genuinely together (full separation < 3m): %d of %d (%.0f%%)" % [
			lane_truly_together, lane_bad, 100.0 * lane_truly_together / lane_bad])
	get_tree().quit()
