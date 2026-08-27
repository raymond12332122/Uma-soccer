extends Node3D

## Rendered playtest driver for the v0.8.4 report. Runs the REAL entry
## point (scenes/Main.tscn) windowed under Xvfb, plays two full passages,
## and reports measured gameplay observations rather than assertions.
##
##   Phase A: 22-player AI vs AI, human idle.
##   Phase B: human vs AI -- the controlled player is driven toward the
##            ball and told to sprint, so the human path (PlayerController
##            -> InputState -> FootballPlayer) is genuinely exercised.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/PlaytestV084.tscn

const MainScene := preload("res://scenes/Main.tscn")

const PHASE_SECONDS := 60

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
	await _run_phase("A: 22-player AI vs AI (human idle)", false)
	await _shot("02_ai_vs_ai")
	main.restart_match()
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

	# post-kick behaviour: distance closed toward own formation slot in the
	# second after a kick. Positive = heading home.
	var pending: Array = []
	var shot_home := 0.0
	var shot_n := 0
	var pass_home := 0.0
	var pass_n := 0

	var human: FootballPlayer = main.player_controller.controlled_player
	var human_touches := 0

	for i in range(frames):
		if human_active:
			_drive_human()
		await get_tree().physics_frame

		var c: FootballPlayer = pm.current_carrier
		if c != null:
			carrier_frames += 1
			if prev_carrier != null and c.team_id != prev_carrier.team_id:
				turnovers += 1
			if c == main.player_controller.controlled_player:
				human_touches += 1
			prev_carrier = c

		for p in main.home_players + main.away_players:
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
			if cat == "MID":
				mid_frames += 1
				if Vector2(p.velocity.x, p.velocity.z).length() < 0.4:
					mid_idle += 1

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
	print("PLAYTEST:   ball contest -- peak challenge %.2f of %.2f, %d player-frames challenging" % [
		peak_challenge, BallContest.CHALLENGE_TIME_REQUIRED, challenge_frames])
	print("PLAYTEST:   1s after a kick, kicker closed toward own slot -- after a SHOT %.2fm (n=%d), after a PASS %.2fm (n=%d); positive = heading home" % [
		shot_home / maxf(shot_n, 1), shot_n, pass_home / maxf(pass_n, 1), pass_n])


## Drives the controlled player through the same InputState the touch HUD
## writes, so this exercises the real human path.
func _drive_human() -> void:
	var human: FootballPlayer = main.player_controller.controlled_player
	if human == null:
		return
	var to_ball: Vector3 = main.ball.global_position - human.global_position
	to_ball.y = 0.0
	InputState.move_vector = Vector2(to_ball.x, to_ball.z).limit_length(1.0)
	InputState.sprint_held = to_ball.length() > 6.0


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
