extends Node3D

## Rendered playtest driver for the v0.8.6 report. Runs the REAL entry
## point (scenes/Main.tscn) windowed under Xvfb, plays two full passages,
## and reports measured gameplay observations rather than assertions.
##
## v0.8.6 adds the measurements this milestone is actually about: how many
## outfielders hold a real off-ball job rather than the leftover one, how
## active each line is off the ball, whether anybody ends up behind a goal,
## what the AI's shots are struck at, and where a HUMAN pass ends up.
##
##   Phase A: 22-player AI vs AI, human idle.
##   Phase B: human vs AI -- the controlled player is driven toward the
##            ball and told to sprint, so the human path (PlayerController
##            -> InputState -> FootballPlayer) is genuinely exercised.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/PlaytestV086.tscn

const MainScene := preload("res://scenes/Main.tscn")

## v0.8.6: halved from 90. Under llvmpipe (no GPU in this container) two
## 90-second passages of a 22-player match did not finish inside 25 minutes
## of wall clock. 45s each is still several hundred possessions and every
## statistic below is a rate or a percentage, so the conclusions are
## unaffected -- it just fits in a run that actually completes.
const PHASE_SECONDS := 45

var main: Node3D
var _shot_index := 0


func _ready() -> void:
	main = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame
	print("PLAYTEST: spawned -- home=%d away=%d controlled=%s" % [
		main.home_players.size(), main.away_players.size(),
		main.player_controller.controlled_player.player_data.display_name])

	await _shot("01_kickoff")
	# v0.8.5: genuinely all-AI. Leaving a human-controlled player standing
	# idle lets them collect the ball and hold it forever (no AI drives them,
	# and nothing makes them pass), which freezes the match -- two otherwise
	# identical diagnostic runs differed by exactly that, one showing 15
	# tactical phase changes and the other 1.
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	await _run_phase("A: 22-player AI vs AI (all 22 AI-driven)", false)
	await _shot("02_ai_vs_ai")
	main.restart_match()
	main._set_human_player(main.home_players[9])  # the ST slot -- MatchManager.DEFAULT_HUMAN_INDEX
	for i in range(120):
		await get_tree().physics_frame
	await _run_phase("B: human vs AI (human chases the ball and sprints)", true)
	await _shot("03_human_vs_ai")

	print("PLAYTEST: COMPLETE")
	get_tree().quit()


func _run_phase(label: String, human_active: bool) -> void:
	var frames: int = PHASE_SECONDS * 60
	var pm: PossessionManager = main.possession_manager
	var ball: RigidBody3D = main.ball

	var turnovers := 0
	var prev_carrier: FootballPlayer = null
	var carrier_frames := 0

	# v0.8.5: the milestone's own subject -- how often the TACTICAL PHASE
	# changes, how long each lasts, and how much of the team is reassigned
	# when it does.
	var phase_changes := 0
	var prev_sticky: int = pm.last_team_with_possession
	var last_phase_frame := 0
	var phase_dwells: Array = []
	var duty_changes_at_phase := 0
	var prev_duty: Dictionary = {}
	var loose_frames := 0
	var contested_frames := 0
	var settled_frames := 0

	var seen := {}
	var passes := 0
	var shots := 0
	var passes_to_human := 0
	var pass_speeds: Array = []
	var shot_speeds: Array = []

	var reversals := 0
	var loops := 0
	var prev_move := {}
	var last_rev := {}

	var mid_travel := 0.0
	var mid_idle := 0
	var mid_frames := 0
	var fwd_travel := 0.0
	var def_travel := 0.0
	var prev_pos := {}

	var peak_challenge := 0.0
	var challenge_frames := 0

	# v0.8.6: is anybody unemployed off the ball, and is anybody behind a goal?
	var duty_counts: Dictionary = {}
	var employed := 0
	var outfield_samples := 0
	var behind_goal_frames := 0
	var fwd_idle := 0
	var fwd_frames := 0
	var def_idle := 0
	var def_frames := 0
	var human_passes := 0
	var human_passes_on_target := 0
	var human_pass_cooldown := 0

	# post-kick behaviour: distance closed toward own formation slot in the
	# second after a kick. Positive = heading home.
	var pending: Array = []
	var shot_home := 0.0
	var shot_n := 0
	var pass_home := 0.0
	var pass_n := 0

	var human: FootballPlayer = main.player_controller.controlled_player
	var human_touches := 0
	var human_seen_kicks: int = human.kick_count if human != null else 0

	for i in range(frames):
		if human_active:
			human_pass_cooldown = maxf(0, human_pass_cooldown - 1)
			human_pass_cooldown = _drive_human(int(human_pass_cooldown))
		await get_tree().physics_frame

		# Did the human's PASS actually find a teammate? last_kick_target is
		# null for a blind knock into space, so this separates "the button
		# played the ball to somebody" from "the button hoofed it".
		var h: FootballPlayer = main.player_controller.controlled_player
		if human_active and h != null and h.kick_count != human_seen_kicks:
			human_seen_kicks = h.kick_count
			if h.last_kick_kind == FootballPlayer.KickKind.PASS:
				human_passes += 1
				if h.last_kick_target != null:
					human_passes_on_target += 1

		# tactical phase accounting
		match pm.phase:
			PossessionManager.Phase.LOOSE: loose_frames += 1
			PossessionManager.Phase.CONTESTED: contested_frames += 1
			PossessionManager.Phase.SETTLED: settled_frames += 1
		var phase_changed_now := false
		if pm.last_team_with_possession != prev_sticky:
			if prev_sticky != -1:
				phase_changes += 1
				phase_dwells.append((i - last_phase_frame) / 60.0)
			prev_sticky = pm.last_team_with_possession
			last_phase_frame = i
			phase_changed_now = true
		for p in main.home_players + main.away_players:
			var pid: int = p.get_instance_id()
			if phase_changed_now and prev_duty.has(pid) and prev_duty[pid] != p.ai_duty:
				duty_changes_at_phase += 1
			prev_duty[pid] = p.ai_duty

		var c: FootballPlayer = pm.current_carrier
		if c != null:
			carrier_frames += 1
			if prev_carrier != null and c.team_id != prev_carrier.team_id:
				turnovers += 1
			if c == main.player_controller.controlled_player:
				human_touches += 1
			prev_carrier = c

		for p in main.home_players + main.away_players:
			if not p.is_goalkeeper:
				outfield_samples += 1
				var d: int = p.ai_duty
				duty_counts[d] = duty_counts.get(d, 0) + 1
				if p.has_possession or d != TeamPlan.Duty.COVER_SPACE:
					employed += 1
				if FormationManager.is_behind_goal_line(p.global_position):
					behind_goal_frames += 1

			# --- kicks ---
			if p.kick_count != seen.get(p, 0):
				seen[p] = p.kick_count
				var slot: Vector3 = FormationManager.get_world_position(p.formation_slot, p.team_id)
				pending.append({"p": p, "kind": p.last_kick_kind, "at": i,
					"d0": p.global_position.distance_to(slot), "slot": slot})
				if p.last_kick_kind == FootballPlayer.KickKind.PASS:
					passes += 1
					pass_speeds.append(p.last_kick_power)
					if p.last_kick_target == main.player_controller.controlled_player:
						passes_to_human += 1
				elif p.last_kick_kind == FootballPlayer.KickKind.SHOT:
					shots += 1
					shot_speeds.append(p.last_kick_power)

			# --- challenges ---
			if p.challenge_progress > 0.0:
				challenge_frames += 1
			peak_challenge = maxf(peak_challenge, p.challenge_progress)

			if p.is_goalkeeper or p == human:
				continue

			# --- movement ---
			var cat: String = FormationManager.role_category(p.formation_role)
			if prev_pos.has(p):
				var step: float = Vector2(p.global_position.x - prev_pos[p].x, p.global_position.z - prev_pos[p].z).length()
				if cat == "MID":
					mid_travel += step
				elif cat == "FWD":
					fwd_travel += step
				elif cat == "DEF":
					def_travel += step
			prev_pos[p] = p.global_position
			var moving: bool = Vector2(p.velocity.x, p.velocity.z).length() >= 0.4
			if cat == "MID":
				mid_frames += 1
				if not moving:
					mid_idle += 1
			elif cat == "FWD":
				fwd_frames += 1
				if not moving:
					fwd_idle += 1
			elif cat == "DEF":
				def_frames += 1
				if not moving:
					def_idle += 1

			var mv: Vector2 = p.move_input
			if mv.length() > 0.25 and prev_move.has(p) and prev_move[p].length() > 0.25:
				if mv.normalized().dot(prev_move[p].normalized()) < -0.3:
					reversals += 1
					if i - last_rev.get(p, -999) < 60:
						loops += 1
					last_rev[p] = i
			if mv.length() > 0.25:
				prev_move[p] = mv

		# --- score post-kick behaviour one second later ---
		for e in pending:
			if e.has("done") or i - e["at"] != 60:
				continue
			e["done"] = true
			var pl: FootballPlayer = e["p"]
			var closed: float = e["d0"] - pl.global_position.distance_to(e["slot"])
			if e["kind"] == FootballPlayer.KickKind.SHOT:
				shot_home += closed
				shot_n += 1
			else:
				pass_home += closed
				pass_n += 1

	var secs: float = frames / 60.0
	var outfield := 20.0
	print("PLAYTEST: === %s (%.0fs) ===" % [label, secs])
	print("PLAYTEST:   score %d-%d | possession changes between teams: %d (%.1f/min) | a carrier existed %.0f%% of the time" % [
		main.home_score, main.away_score, turnovers, turnovers * 60.0 / secs, 100.0 * carrier_frames / frames])
	print("PLAYTEST:   AI kicks -- passes %d, shots %d | pass speed avg %.1f max %.1f m/s | shot speed avg %.1f min %.1f m/s" % [
		passes, shots, _avg(pass_speeds), pass_speeds.max() if not pass_speeds.is_empty() else 0.0,
		_avg(shot_speeds), shot_speeds.min() if not shot_speeds.is_empty() else 0.0])
	print("PLAYTEST:   passes aimed at the HUMAN-controlled teammate: %d of %d | frames the human held the ball: %d" % [
		passes_to_human, passes, human_touches])
	print("PLAYTEST:   movement -- %.3f reversals/player/sec, %.3f forward-back loops/player/sec" % [
		reversals / (outfield * secs), loops / (outfield * secs)])
	print("PLAYTEST:   activity -- MID %.0fm/player, FWD %.0fm/player, DEF %.0fm/player | midfielders idle %.0f%% of frames" % [
		mid_travel / 6.0, fwd_travel / 6.0, def_travel / 8.0, 100.0 * mid_idle / maxf(mid_frames, 1)])
	print("PLAYTEST:   off-ball employment -- %.0f%% of outfielder-frames hold a real job (rest are the COVER_SPACE leftover) | %s" % [
		100.0 * employed / maxf(outfield_samples, 1), _duty_census(duty_counts, outfield_samples)])
	print("PLAYTEST:   line activity (idle %% of frames) -- MID %.0f%%, FWD %.0f%%, DEF %.0f%%" % [
		100.0 * mid_idle / maxf(mid_frames, 1), 100.0 * fwd_idle / maxf(fwd_frames, 1), 100.0 * def_idle / maxf(def_frames, 1)])
	print("PLAYTEST:   behind the goal line -- %d outfielder-frames of %d (%.2f%%)" % [
		behind_goal_frames, outfield_samples, 100.0 * behind_goal_frames / maxf(outfield_samples, 1)])
	if human_active:
		print("PLAYTEST:   HUMAN pass button -- %d passes, %d found a named teammate (%.0f%%)" % [
			human_passes, human_passes_on_target, 100.0 * human_passes_on_target / maxf(human_passes, 1)])
	print("PLAYTEST:   ball contest -- peak challenge %.2f of %.2f, %d player-frames challenging" % [
		peak_challenge, BallContest.CHALLENGE_TIME_REQUIRED, challenge_frames])
	var mean_dwell := 0.0
	for d in phase_dwells:
		mean_dwell += d
	mean_dwell = mean_dwell / maxf(phase_dwells.size(), 1)
	print("PLAYTEST:   TACTICAL PHASE -- %d changes (%.2f/min), mean dwell %.2fs | player duty changes AT a phase change: %d (%.1f per change, of 20 outfielders)" % [
		phase_changes, phase_changes * 60.0 / (frames / 60.0), mean_dwell,
		duty_changes_at_phase, duty_changes_at_phase / maxf(phase_changes, 1)])
	print("PLAYTEST:   possession phase split -- LOOSE %d%%, CONTESTED %d%%, SETTLED %d%%" % [
		100 * loose_frames / frames, 100 * contested_frames / frames, 100 * settled_frames / frames])
	print("PLAYTEST:   1s after a kick, kicker closed toward own slot -- after a SHOT %.2fm (n=%d), after a PASS %.2fm (n=%d); positive = heading home" % [
		shot_home / maxf(shot_n, 1), shot_n, pass_home / maxf(pass_n, 1), pass_n])


## Drives the controlled player through the same InputState the touch HUD
## writes, so this exercises the real human path.
## Returns the new PASS cooldown in frames.
func _drive_human(cooldown: int) -> int:
	var human: FootballPlayer = main.player_controller.controlled_player
	if human == null:
		return cooldown
	var to_ball: Vector3 = main.ball.global_position - human.global_position
	to_ball.y = 0.0

	# v0.8.6: once the human has the ball, aim at the most useful-looking
	# teammate and press PASS -- otherwise the human path never exercises the
	# aimed-pass code at all, which is the part this milestone reworked.
	if human.has_possession and human.possession_time > 0.8 and cooldown <= 0:
		var target: FootballPlayer = _pick_human_pass_target(human)
		if target != null:
			var aim: Vector3 = target.global_position - human.global_position
			aim.y = 0.0
			InputState.move_vector = Vector2(aim.x, aim.z).normalized()
			InputState.sprint_held = false
			InputState.pass_pressed = true
			return 90
		return cooldown

	InputState.move_vector = Vector2(to_ball.x, to_ball.z).limit_length(1.0)
	InputState.sprint_held = to_ball.length() > 6.0
	return cooldown


## Whoever a person would plausibly aim at: a teammate up the pitch and in
## realistic passing range.
func _pick_human_pass_target(human: FootballPlayer) -> FootballPlayer:
	var fwd: Vector3 = main.home_team.plan.forward_axis()
	var best: FootballPlayer = null
	var best_score := -INF
	for mate in main.home_players:
		if mate == human or mate.is_goalkeeper:
			continue
		var to_mate: Vector3 = mate.global_position - human.global_position
		to_mate.y = 0.0
		var d: float = to_mate.length()
		if d < 5.0 or d > 16.0:
			continue
		var score: float = to_mate.normalized().dot(fwd) * 10.0 - absf(d - 10.0)
		if score > best_score:
			best_score = score
			best = mate
	return best


## Which duties the outfield actually held, most common first.
func _duty_census(counts: Dictionary, total: int) -> String:
	var names := {
		TeamPlan.Duty.CONTEST: "CONTEST", TeamPlan.Duty.PRESS_SUPPORT: "PRESS_SUP",
		TeamPlan.Duty.SUPPORT_SHORT: "SUP_SHORT", TeamPlan.Duty.SUPPORT_WIDE: "SUP_WIDE",
		TeamPlan.Duty.RUN_BEHIND: "RUN_BEHIND", TeamPlan.Duty.MARK: "MARK",
		TeamPlan.Duty.COVER_SPACE: "COVER", TeamPlan.Duty.FOLLOW_UP: "FOLLOW_UP",
		TeamPlan.Duty.PUSH_UP: "PUSH_UP",
	}
	var keys: Array = counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	var parts: Array = []
	for k in keys:
		parts.append("%s %.0f%%" % [names.get(k, str(k)), 100.0 * counts[k] / maxf(total, 1)])
	return ", ".join(parts)


func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _shot(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		print("PLAYTEST: screenshot skipped (headless)")
		return
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	_shot_index += 1
	var path: String = "user://playtest_%02d_%s.png" % [_shot_index, label]
	img.save_png(path)
	print("PLAYTEST: screenshot -> %s" % ProjectSettings.globalize_path(path))
