extends Node3D

# V0.8.5 DIAGNOSTIC -- measurement only, changes nothing.
#
# The report says the team's tactical phase flips on individual ball
# CONTACTS rather than on real possession changes. This instruments the
# whole chain so the actual mechanism is measured rather than assumed:
#
#   ball contact (FootballPlayer.has_possession)
#     -> PossessionManager.possessing_team      (instantaneous)
#     -> PossessionManager.last_team_with_possession (0.3s confirm)
#     -> TeamPlan.attack_intent                 (slewed +-1)
#     -> TeamPlan duty allocation               (attacking set vs defending set)
#     -> AIController target                    (metres)
#     -> observed movement reversal
#
# For every link it reports rate, dwell time, and -- for reversals -- how
# many frames after which upstream event they occurred.

const MainScene := preload("res://scenes/Main.tscn")

const SAMPLE_SECONDS := 60.0


func _ready() -> void:
	await _run()


func _run() -> void:
	for run in range(RUNS):
		await _sample(run)
	get_tree().quit(0)


const RUNS := 3


func _sample(run: int) -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	# All 22 players AI-driven. An idle human standing on the ball freezes
	# the match and makes every team-level statistic meaningless -- the two
	# runs that produced 15 and 1 phase changes differed by exactly that.
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var home: TeamController = main.home_team
	var players: Array = main.home_players + main.away_players

	var frames := int(SAMPLE_SECONDS * 60.0)

	# --- link 1-2: contact and instantaneous possession
	var contact_events := 0          # a player gaining has_possession
	var contact_durations: Array = []
	var contact_started: Dictionary = {}
	var had_possession: Dictionary = {}

	# --- link 3: instantaneous team possession
	var inst_team_changes := 0
	var prev_inst := -99

	# --- link 4: sticky team possession (what shape reads)
	var sticky_changes := 0
	var prev_sticky := -99
	var sticky_dwells: Array = []
	var last_sticky_change_frame := 0
	var sticky_change_frames: Array = []

	# --- link 5: attack_intent
	var intent_zero_crossings := 0
	var prev_intent_sign := 0
	var intent_min := 99.0
	var intent_max := -99.0
	var intent_abs_sum := 0.0
	var intent_settled_frames := 0   # |intent| > 0.9, i.e. a committed phase

	# --- link 6: duty churn
	var duty_changes := 0
	var duty_set_flips := 0          # attacking-set <-> defending-set
	var prev_duty: Dictionary = {}
	var prev_attacking_shape := -99

	# --- link 7: target displacement caused by a phase change
	var prev_target: Dictionary = {}
	var jump_on_phase_frame: Array = []   # target jump (m) on frames sticky changed
	var jump_baseline: Array = []         # target jump (m) on other frames
	var jump_duty_changed: Array = []     # of the above, players who also got a new duty
	var jump_duty_same: Array = []        # ...and players who kept their duty

	# --- link 8: reversals, attributed
	var prev_vel: Dictionary = {}
	var reversals := 0
	var reversal_frames: Array = []
	# A frozen player can never register a reversal, so the raw count is not
	# comparable across builds that differ in how much anyone moves. Rate
	# per MOVING frame is.
	var moving_frames := 0
	var rev_recent_duty_change := 0   # duty changed within the last 10 frames
	var rev_near_target := 0          # already within 2.5m of own target
	var last_duty_change_frame: Dictionary = {}

	# --- midfielder activity vs ball distance
	var mid_far_frames := 0
	var mid_far_idle := 0

	for f in range(frames):
		await get_tree().physics_frame

		var ball_pos: Vector3 = main.ball.global_position

		for p in players:
			var id: int = p.get_instance_id()

			# contact
			var hp: bool = p.has_possession
			if hp and not had_possession.get(id, false):
				contact_events += 1
				contact_started[id] = f
			elif not hp and had_possession.get(id, false):
				contact_durations.append((f - contact_started.get(id, f)) / 60.0)
			had_possession[id] = hp

			# duty churn
			var d: int = p.ai_duty
			var duty_changed_now: bool = prev_duty.has(id) and prev_duty[id] != d
			if duty_changed_now:
				duty_changes += 1
			prev_duty[id] = d

			# target jump
			var t: Vector3 = p.ai_target
			if prev_target.has(id):
				var jump: float = t.distance_to(prev_target[id])
				if pm.last_team_with_possession != prev_sticky:
					jump_on_phase_frame.append(jump)
					if duty_changed_now:
						jump_duty_changed.append(jump)
					else:
						jump_duty_same.append(jump)
				else:
					jump_baseline.append(jump)
			prev_target[id] = t

			# reversal: horizontal velocity direction flipped by >120 deg
			# while actually moving
			if duty_changed_now:
				last_duty_change_frame[id] = f
			var v := Vector3(p.velocity.x, 0.0, p.velocity.z)
			if v.length() > 0.8:
				moving_frames += 1
				if prev_vel.has(id):
					var pv: Vector3 = prev_vel[id]
					if pv.length() > 0.8 and v.normalized().dot(pv.normalized()) < -0.5:
						reversals += 1
						reversal_frames.append(f)
						if f - last_duty_change_frame.get(id, -999) <= 10:
							rev_recent_duty_change += 1
						if p.global_position.distance_to(p.ai_smoothed_target) < 2.5:
							rev_near_target += 1
				prev_vel[id] = v

			# midfielder activity when ball is far
			if FormationManager.role_category(p.formation_role) == "MID":
				if p.global_position.distance_to(ball_pos) > 20.0:
					mid_far_frames += 1
					if Vector3(p.velocity.x, 0, p.velocity.z).length() < 0.5:
						mid_far_idle += 1

		# instantaneous team
		if pm.possessing_team != prev_inst:
			inst_team_changes += 1
			prev_inst = pm.possessing_team

		# sticky team
		if pm.last_team_with_possession != prev_sticky:
			if prev_sticky != -99:
				sticky_changes += 1
				sticky_dwells.append((f - last_sticky_change_frame) / 60.0)
				sticky_change_frames.append(f)
			last_sticky_change_frame = f
			prev_sticky = pm.last_team_with_possession

		# attack_intent
		var ai: float = home.plan.attack_intent
		intent_min = minf(intent_min, ai)
		intent_max = maxf(intent_max, ai)
		intent_abs_sum += absf(ai)
		if absf(ai) > 0.9:
			intent_settled_frames += 1
		var s: int = signi(int(signf(ai))) if absf(ai) > 0.05 else 0
		if s != 0 and prev_intent_sign != 0 and s != prev_intent_sign:
			intent_zero_crossings += 1
		if s != 0:
			prev_intent_sign = s

		# duty SET flip (home team)
		var attacking_shape: int = 1 if pm.last_team_with_possession == home.team_id else 0
		if prev_attacking_shape != -99 and attacking_shape != prev_attacking_shape:
			duty_set_flips += 1
		prev_attacking_shape = attacking_shape

	# ---------------------------------------------------------------- report
	var secs: float = frames / 60.0
	var n: int = players.size()

	print("DIAG: === run %d: sample %.0fs, %d players ===" % [run, secs, n])
	print("DIAG: contacts (a player gaining has_possession): %d (%.1f/s)" % [
		contact_events, contact_events / secs])
	print("DIAG:   median contact duration %.3fs, %d%% shorter than 0.30s" % [
		_median(contact_durations), _pct_below(contact_durations, 0.30)])
	print("DIAG: instantaneous possessing_team changes: %d (%.1f/s)" % [
		inst_team_changes, inst_team_changes / secs])
	print("DIAG: STICKY last_team_with_possession changes: %d (%.2f/s), median dwell %.2fs, %d%% of dwells under 1.0s" % [
		sticky_changes, sticky_changes / secs, _median(sticky_dwells), _pct_below(sticky_dwells, 1.0)])
	print("DIAG: attack_intent: range %.2f..%.2f, mean |intent| %.2f, sign flips %d (%.2f/s), settled(|i|>0.9) %d%% of frames" % [
		intent_min, intent_max, intent_abs_sum / frames, intent_zero_crossings,
		intent_zero_crossings / secs, int(100.0 * intent_settled_frames / frames)])
	print("DIAG: duty changes %.3f/player/s | duty-SET flips (attacking<->defending) %d (%.2f/s)" % [
		duty_changes / float(n) / secs, duty_set_flips, duty_set_flips / secs])
	print("DIAG: target jump on a phase-change frame: mean %.2fm (n=%d) | on other frames: mean %.2fm (n=%d)" % [
		_mean(jump_on_phase_frame), jump_on_phase_frame.size(),
		_mean(jump_baseline), jump_baseline.size()])
	print("DIAG: reversals %d (%.3f/player/s) | per 1000 MOVING frames: %.2f (moving frames %d)" % [
		reversals, reversals / float(n) / secs,
		1000.0 * reversals / maxf(moving_frames, 1), moving_frames])
	print("DIAG:   of those reversals: %d%% within 10 frames of a duty change, %d%% already within 2.5m of own target" % [
		int(100.0 * rev_recent_duty_change / maxf(reversals, 1)),
		int(100.0 * rev_near_target / maxf(reversals, 1))])
	print("DIAG:   %d%% of reversals fell within 30 frames (0.5s) AFTER a sticky phase change" % [
		_pct_within(reversal_frames, sticky_change_frames, 30)])
	print("DIAG:   %d%% within 60 frames (1.0s)" % [
		_pct_within(reversal_frames, sticky_change_frames, 60)])
	print("DIAG: midfielders with ball >20m away: idle %d%% of %d frames" % [
		int(100.0 * mid_far_idle / maxf(mid_far_frames, 1)), mid_far_frames])

	# Is a phase change a genuine TURNOVER or a FLAP (reverted quickly)?
	var flaps := 0
	for i in range(sticky_change_frames.size() - 1):
		if sticky_change_frames[i + 1] - sticky_change_frames[i] < 90:  # 1.5s
			flaps += 1
	print("DIAG: phase changes reverted within 1.5s (flaps): %d of %d" % [flaps, sticky_changes])

	# Decompose the jump: players whose DUTY also changed on that frame vs not.
	print("DIAG: jump on phase frame -- duty ALSO changed: mean %.2fm (n=%d) | duty unchanged: mean %.2fm (n=%d)" % [
		_mean(jump_duty_changed), jump_duty_changed.size(),
		_mean(jump_duty_same), jump_duty_same.size()])
	print("DIAG: DONE")

	main.queue_free()
	await get_tree().process_frame


func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var c: Array = a.duplicate()
	c.sort()
	return c[c.size() / 2]


func _pct_below(a: Array, threshold: float) -> int:
	if a.is_empty():
		return 0
	var c := 0
	for v in a:
		if v < threshold:
			c += 1
	return int(100.0 * c / a.size())


## What share of `events` happened within `window` frames after any `marks` frame.
func _pct_within(events: Array, marks: Array, window: int) -> int:
	if events.is_empty():
		return 0
	var hit := 0
	for e in events:
		for m in marks:
			if e >= m and e - m <= window:
				hit += 1
				break
	return int(100.0 * hit / events.size())
