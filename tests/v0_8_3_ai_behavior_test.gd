extends Node3D

# Regression tests for the V0.8.3 team-AI pass.
#
# The v0.8.3 playtest reported six distinct AI problems. Each one was traced
# to a specific mechanism (instrumented in a live 22-player match, not
# guessed), and each test below pins the mechanism rather than the symptom:
#
#   1. residual movement oscillation  -> arrival overshoot in _move_toward
#      (31% of measured reversals) and opposed shape targets (59%)
#   2. everyone contests / forwards crowd -> nothing allocated duties, so
#      every similar player independently chose the same job
#   3. midfielders inactive when the ball is far -> the fallback target was
#      a near-static formation point (DEF measured 40% of frames stationary)
#   4. AI passes not useful / not directional -> pass power was a constant
#      impulse carrying the ball ~8m while targets were picked out to 26m,
#      and the chosen target only got 70% of the aim
#   5. AI shots indistinguishable from passes -> the two power bands were
#      close enough that ball speed alone could not separate them, and
#      nothing recorded the intent
#   6. human close control stiff -> _facing_angle snapped to the input
#      direction, teleporting the dribble point across the player
#
# Run via: godot --headless --path . tests/V0_8_3AIBehaviorTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	await _test_duty_slots_are_capped_and_exclusive()
	await _test_no_teammate_contests_our_own_carrier()
	await _test_attack_intent_is_continuous_not_a_snap()
	await _test_arrival_does_not_overshoot_and_reverse()
	await _test_pass_and_shot_bands_cannot_overlap()
	await _test_kick_instrumentation_records_intent()
	await _test_pass_power_actually_reaches_its_target()
	await _test_pass_is_aimed_at_the_chosen_teammate()
	await _test_human_controlled_teammate_is_a_normal_pass_option()
	await _test_carrier_releases_the_ball_rather_than_holding_forever()
	await _test_facing_angle_turns_at_a_finite_rate()
	await _test_live_match_midfielders_stay_active()
	await _test_live_match_forwards_sustain_advanced_positions()
	await _test_live_match_contest_is_not_a_swarm()
	await _test_live_match_defenders_hold_shape()
	await _test_live_match_movement_is_not_oscillating()
	await _test_live_match_ai_passes_and_shoots_distinguishably()
	await _test_ai_shoots_from_a_real_chance_and_not_from_nowhere()
	await _test_live_match_goalkeepers_unchanged()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# ------------------------------------------------- 1. duty allocation caps
#
# "Almost everyone seems to contest the attacking player/ball at once" and
# "not every player should contest / make the same run". The ceiling is
# structural: a fixed number of slots, filled by the best-suited candidate.

func _test_duty_slots_are_capped_and_exclusive() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var worst_run_behind := 0
	var worst_contest := 0
	var worst_wide := 0
	for i in range(180):
		await get_tree().physics_frame
		for team in [main.home_team, main.away_team]:
			var counts := {}
			for p in team.players:
				if p.is_goalkeeper or p == team.human_player:
					continue
				var d: int = team.plan.duty_of(p)
				counts[d] = counts.get(d, 0) + 1
			worst_run_behind = maxi(worst_run_behind, counts.get(TeamPlan.Duty.RUN_BEHIND, 0))
			worst_contest = maxi(worst_contest, counts.get(TeamPlan.Duty.CONTEST, 0))
			worst_wide = maxi(worst_wide, counts.get(TeamPlan.Duty.SUPPORT_WIDE, 0))

	_check("At most one player per team is ever nominated to contest the ball (peak %d)" % worst_contest, worst_contest <= 1)
	_check("At most TeamPlan.MAX_RUN_BEHIND players make a run in behind at once (peak %d)" % worst_run_behind, worst_run_behind <= TeamPlan.MAX_RUN_BEHIND)
	_check("At most TeamPlan.MAX_SUPPORT_WIDE players hold the wide slot at once (peak %d)" % worst_wide, worst_wide <= TeamPlan.MAX_SUPPORT_WIDE)

	main.queue_free()
	await get_tree().process_frame


# --------------------------------------------- 2. nobody presses our own man

func _test_no_teammate_contests_our_own_carrier() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var carrier_frames := 0
	var violations := 0
	for i in range(300):
		await get_tree().physics_frame
		var carrier: FootballPlayer = main.possession_manager.current_carrier
		if carrier == null:
			continue
		carrier_frames += 1
		var team: TeamController = main.home_team if carrier.team_id == 0 else main.away_team
		for p in team.players:
			if p == carrier or p.is_goalkeeper:
				continue
			if team.plan.duty_of(p) == TeamPlan.Duty.CONTEST:
				violations += 1

	_check("Sampled enough carrier frames for the check to mean something (%d)" % carrier_frames, carrier_frames > 30)
	_check("No teammate is ever told to contest our own ball carrier (%d violations)" % violations, violations == 0)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------ 3. phase is a ramp, not a step change
#
# The core anti-oscillation property: because attack_intent is continuous,
# a change of possession moves every downstream target smoothly instead of
# swinging it to the opposite side of the player on a single frame.

func _test_attack_intent_is_continuous_not_a_snap() -> void:
	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-26, 1, 0), Vector3(26, 1, 0))

	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pm := PossessionManager.new()
	add_child(pm)

	pm.last_team_with_possession = 0
	for i in range(240):
		plan.update([], [], ball, pm, 1.0 / 60.0)
	_check("Attack intent reaches full attacking commitment while we hold the ball (%.2f)" % plan.attack_intent, plan.attack_intent > 0.95)

	# Now lose it, and watch the intent travel rather than teleport.
	pm.last_team_with_possession = 1
	var biggest_single_frame_step := 0.0
	var previous: float = plan.attack_intent
	var frames_to_flip := 0
	for i in range(600):
		plan.update([], [], ball, pm, 1.0 / 60.0)
		biggest_single_frame_step = maxf(biggest_single_frame_step, absf(plan.attack_intent - previous))
		previous = plan.attack_intent
		if plan.attack_intent < -0.95:
			frames_to_flip = i
			break

	_check("Losing the ball eventually swings the team fully into defending (%.2f)" % plan.attack_intent, plan.attack_intent < -0.95)
	_check("...but it takes a real transition, not one frame (%d frames)" % frames_to_flip, frames_to_flip > 30)
	_check("Attack intent never steps by more than the slew rate allows (max step %.4f)" % biggest_single_frame_step,
		biggest_single_frame_step <= TeamPlan.INTENT_SLEW_RATE / 60.0 + 0.0001)

	pm.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------------ 4. arrival without recoil
#
# 31% of every reversal measured in a live v0.8.2 match happened with the
# state AND the target both unchanged -- the player had simply arrived,
# coasted past (full input until a 0.6m radius, ~1.8m of stopping distance
# from a sprint), and driven back. No external trigger at all.

func _test_arrival_does_not_overshoot_and_reverse() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	await get_tree().physics_frame

	var pair := _make_player("arrive", 0, Vector3(-12, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])
	await get_tree().physics_frame

	var target := Vector3(0, 1, 0)
	var reversals := 0
	var prev_input := Vector2.ZERO
	var closest := INF
	var overshoot := 0.0

	for i in range(400):
		AIController._move_toward(player, target, AIController.ARRIVE_RADIUS)
		player.sprint_requested = true
		await get_tree().physics_frame
		var flat := Vector2(player.global_position.x - target.x, player.global_position.z - target.z)
		closest = minf(closest, flat.length())
		# Past the target along the approach axis = overshoot.
		if player.global_position.x > target.x:
			overshoot = maxf(overshoot, player.global_position.x - target.x)
		if player.move_input.length() > 0.15 and prev_input.length() > 0.15:
			if player.move_input.normalized().dot(prev_input.normalized()) < -0.3:
				reversals += 1
		if player.move_input.length() > 0.15:
			prev_input = player.move_input

	_check("A player driven at a fixed target actually reaches it (closest %.2fm)" % closest, closest < AIController.ARRIVE_RADIUS * AIController.ARRIVE_RELEASE_MULT + 0.2)
	_check("...without coasting past it (overshoot %.2fm)" % overshoot, overshoot < 0.5)
	_check("...and without ever reversing direction on arrival (%d reversals)" % reversals, reversals == 0)
	_check("...and comes to rest rather than twitching in the deadzone", player.move_input == Vector2.ZERO)

	player.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ----------------------------------------- 5/6. shot vs pass, by construction

func _test_pass_and_shot_bands_cannot_overlap() -> void:
	_check("Every pass launch speed is below every shot launch speed (%.1f < %.1f)" % [PassEvaluator.PASS_SPEED_MAX, FootballPlayer.SHOT_SPEED_MIN],
		PassEvaluator.PASS_SPEED_MAX < FootballPlayer.SHOT_SPEED_MIN)

	# And no combination of player stats can drag a player out of the band.
	var worst_shot_min := INF
	for shooting in [0, 25, 50, 75, 100]:
		for passing in [0, 25, 50, 75, 100]:
			var pair := _make_player("band", 0, Vector3.ZERO)
			var player: FootballPlayer = pair[0]
			var data: PlayerData = pair[1]
			data.shooting = shooting
			data.passing = passing
			add_child(player)
			player.apply_player_data(data)
			worst_shot_min = minf(worst_shot_min, player.shoot_min_speed)
			var max_pass: float = PassEvaluator.PASS_SPEED_MAX * player.pass_speed_scale
			if max_pass >= player.shoot_min_speed:
				worst_shot_min = -1.0
			player.queue_free()
	await get_tree().process_frame
	_check("No stat combination lets a pass reach shot speed (worst shot floor %.2f)" % worst_shot_min, worst_shot_min > 0.0)

	# The measured ball-roll model the pass power solve is built on.
	_check("A short pass is solved slower than a long one",
		PassEvaluator.speed_for_distance(5.0) < PassEvaluator.speed_for_distance(12.0))
	_check("Pass speed is clamped into the pass band at both extremes",
		PassEvaluator.speed_for_distance(0.5) >= PassEvaluator.PASS_SPEED_MIN
		and PassEvaluator.speed_for_distance(100.0) <= PassEvaluator.PASS_SPEED_MAX)


func _test_kick_instrumentation_records_intent() -> void:
	var ctx := await _make_kick_scenario()
	var kicker: FootballPlayer = ctx["kicker"]
	var mate: FootballPlayer = ctx["mate"]
	var ball: BallController = ctx["ball"]

	_check("A player has not kicked anything yet", kicker.last_kick_kind == FootballPlayer.KickKind.NONE)

	# Face the teammate first -- execute_pass()'s default is the HUMAN aim
	# cone (PASS_ASSIST_MIN_ALIGNMENT), which deliberately refuses to find a
	# receiver the passer is not actually aiming at.
	kicker.move_input = Vector2(1, 0)
	for i in range(20):
		await get_tree().physics_frame
	kicker.execute_pass()
	_check("A pass is recorded as a pass", kicker.last_kick_kind == FootballPlayer.KickKind.PASS)
	_check("A pass records which teammate it was aimed at", kicker.last_kick_target == mate)
	_check("A pass's recorded speed is inside the pass band (%.2f)" % kicker.last_kick_power,
		kicker.last_kick_power < FootballPlayer.SHOT_SPEED_MIN)
	var kicks_after_pass: int = kicker.kick_count

	kicker._possession_cooldown_timer = 0.0
	kicker.execute_shot(1.0)
	_check("A shot is recorded as a shot", kicker.last_kick_kind == FootballPlayer.KickKind.SHOT)
	_check("A shot records no pass target", kicker.last_kick_target == null)
	_check("A shot's recorded speed is inside the shot band (%.2f)" % kicker.last_kick_power,
		kicker.last_kick_power >= FootballPlayer.SHOT_SPEED_MIN)
	_check("The kick counter advances once per kick", kicker.kick_count == kicks_after_pass + 1)

	await _teardown_kick(ctx)


# --------------------------------------------- 7. a pass that actually gets there
#
# The single largest cause of "passes are often not useful": pass power was
# a fixed impulse (measured launch speed 3.1-5.8 m/s, carrying the ball
# 3.7-8.2m) while _find_pass_target happily selected teammates out to 26m.

func _test_pass_power_actually_reaches_its_target() -> void:
	for distance in [5.0, 9.0, 13.0]:
		var ctx := await _make_kick_scenario(distance)
		var kicker: FootballPlayer = ctx["kicker"]
		var mate: FootballPlayer = ctx["mate"]
		var ball: BallController = ctx["ball"]

		kicker.execute_pass(FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI, Vector3(1, 0, 0))
		var start: Vector3 = ball.global_position
		var closest_to_mate := INF
		for i in range(400):
			await get_tree().physics_frame
			closest_to_mate = minf(closest_to_mate, Vector2(ball.global_position.x - mate.global_position.x, ball.global_position.z - mate.global_position.z).length())
			if Vector3(ball.linear_velocity.x, 0, ball.linear_velocity.z).length() < 0.4:
				break
		var travelled: float = Vector2(ball.global_position.x - start.x, ball.global_position.z - start.z).length()
		_check("A %.0fm pass carries the ball far enough to arrive (travelled %.1fm, closest approach %.2fm)" % [distance, travelled, closest_to_mate],
			closest_to_mate < 2.0)
		await _teardown_kick(ctx)


func _test_pass_is_aimed_at_the_chosen_teammate() -> void:
	# A teammate square to the passer -- exactly the case the old 0.7 aim
	# blend broke, because an AI carrier's own aim is "toward the goal".
	var ctx := await _make_kick_scenario(9.0, Vector3(0, 0, 9.0))
	var kicker: FootballPlayer = ctx["kicker"]
	var mate: FootballPlayer = ctx["mate"]
	var ball: BallController = ctx["ball"]

	# Face straight up the pitch, i.e. 90 degrees away from the teammate.
	kicker.move_input = Vector2(1, 0)
	await get_tree().physics_frame
	kicker.execute_pass(FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI, Vector3(1, 0, 0))

	var to_mate: Vector3 = mate.global_position - kicker.global_position
	to_mate.y = 0.0
	var error_deg: float = rad_to_deg(acos(clampf(kicker.last_kick_dir.normalized().dot(to_mate.normalized()), -1.0, 1.0)))
	_check("An AI pass is aimed at the teammate it chose, not blended toward the passer's own heading (%.1f deg off)" % error_deg, error_deg < 20.0)

	await _teardown_kick(ctx)


func _test_human_controlled_teammate_is_a_normal_pass_option() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(60):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	# Put an AI teammate on the ball with the human as the only sensible
	# option: everyone else is moved far away, the human is left open at a
	# realistic passing distance.
	var carrier: FootballPlayer = null
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			carrier = p
			break
	_check("Found an AI teammate to carry the ball for the human-target check", carrier != null)
	if carrier == null:
		main.queue_free()
		return

	for p in main.home_players:
		if p != human and p != carrier:
			p.global_position = Vector3(-200, 1, -200)
	for p in main.away_players:
		p.global_position = Vector3(200, 1, 200)
	carrier.global_position = Vector3(0, 1, 0)
	human.global_position = Vector3(9, 1, 3)
	await get_tree().physics_frame

	var option: PassEvaluator.Option = PassEvaluator.best_option(carrier, Vector3(1, 0, 0), Vector3(1, 0, 0))
	_check("An AI carrier will pass to the human-controlled teammate like any other player",
		option != null and option.target == human)

	main.queue_free()
	await get_tree().process_frame


func _test_carrier_releases_the_ball_rather_than_holding_forever() -> void:
	var ctx := await _make_kick_scenario(9.0)
	var kicker: FootballPlayer = ctx["kicker"]
	var ball: BallController = ctx["ball"]
	var pm: PossessionManager = ctx["pm"]

	# Sit the carrier well outside shooting range with one good option and
	# let the real decision hierarchy run. It must let the ball go.
	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-26, 1, 0), Vector3(26, 1, 0))
	var released_after := -1
	for i in range(600):
		kicker.possession_time = float(i) / 60.0
		AIController._decide_possession_action(kicker, ball, Vector3(26, 1, 0), [], Vector3(1, 0, 0), plan, 1.0 / 60.0)
		if kicker.kick_count > 0:
			released_after = i
			break
		await get_tree().physics_frame

	_check("An AI carrier with a good option releases the ball instead of dribbling forever (released after %.2fs)" % (released_after / 60.0),
		released_after >= 0)
	_check("...but not on the very first frame it touches the ball", released_after > 0)

	await _teardown_kick(ctx)


# ---------------------------------------------- 8. human close control feel

func _test_facing_angle_turns_at_a_finite_rate() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	await get_tree().physics_frame
	var pair := _make_player("turn", 0, Vector3(0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])

	player.move_input = Vector2(1, 0)
	for i in range(60):
		await get_tree().physics_frame
	var before: float = player._facing_angle

	# Slam the stick to the exact opposite direction, as a human can.
	player.move_input = Vector2(-1, 0)
	await get_tree().physics_frame
	var step: float = absf(wrapf(player._facing_angle - before, -PI, PI))
	_check("A 180-degree input flick does not snap the player's facing in one frame (%.2f rad)" % step, step < PI * 0.5)

	var frames := 0
	while frames < 120 and absf(wrapf(player._facing_angle - atan2(-1.0, 0.0), -PI, PI)) > 0.15:
		await get_tree().physics_frame
		frames += 1
	_check("...but the facing does complete the turn promptly (%d frames)" % frames, frames < 60)

	player.queue_free()
	field.queue_free()
	await get_tree().process_frame


# =================================================== live 22-player checks

func _test_live_match_midfielders_stay_active() -> void:
	# The ball is parked in a far corner, which is precisely the state the
	# playtest described as making midfielders "barely move or become
	# inactive". Their target must stay ball-relative, so they keep working.
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var travel := {}
	var idle_frames := {}
	var frames := 300
	var prev := {}
	for p in main.home_players + main.away_players:
		prev[p] = p.global_position
		travel[p] = 0.0
		idle_frames[p] = 0

	for i in range(frames):
		_teleport(main.ball, Vector3(22, 0.35, 15))
		await get_tree().physics_frame
		for p in main.home_players + main.away_players:
			travel[p] += Vector2(p.global_position.x - prev[p].x, p.global_position.z - prev[p].z).length()
			prev[p] = p.global_position
			if Vector2(p.velocity.x, p.velocity.z).length() < 0.4:
				idle_frames[p] += 1

	var mid_travel := 0.0
	var mid_idle := 0.0
	var mid_count := 0
	var def_idle := 0.0
	var def_count := 0
	for p in main.home_players + main.away_players:
		if p.is_goalkeeper or p == main.player_controller.controlled_player:
			continue
		var cat: String = FormationManager.role_category(p.formation_role)
		if cat == "MID":
			mid_travel += travel[p]
			mid_idle += float(idle_frames[p]) / frames
			mid_count += 1
		elif cat == "DEF":
			def_idle += float(idle_frames[p]) / frames
			def_count += 1

	var avg_mid_travel: float = mid_travel / maxf(mid_count, 1)
	var avg_mid_idle: float = 100.0 * mid_idle / maxf(mid_count, 1)
	var avg_def_idle: float = 100.0 * def_idle / maxf(def_count, 1)
	_check("Midfielders keep repositioning even with the ball parked in a far corner (avg %.1fm over %.1fs)" % [avg_mid_travel, frames / 60.0], avg_mid_travel > 6.0)
	_check("Midfielders are not standing still most of the time (idle %.1f%% of frames)" % avg_mid_idle, avg_mid_idle < 55.0)
	_check("Defenders are not frozen either (idle %.1f%% of frames)" % avg_def_idle, avg_def_idle < 65.0)

	main.queue_free()
	await get_tree().process_frame


func _test_live_match_forwards_sustain_advanced_positions() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(180):
		await get_tree().physics_frame

	# Sample how far forwards sit relative to their own defenders while
	# their team is on the ball -- a run in behind should be sustained,
	# not a twitch.
	var samples := 0
	var advanced_samples := 0
	for i in range(420):
		await get_tree().physics_frame
		for team_id in [0, 1]:
			var team: TeamController = main.home_team if team_id == 0 else main.away_team
			if team.plan == null or team.plan.attack_intent < 0.5:
				continue
			var side: float = 1.0 if team_id == 0 else -1.0
			var fwd_best := -INF
			var def_best := -INF
			for p in team.players:
				if p.is_goalkeeper:
					continue
				var along: float = p.global_position.x * side
				var cat: String = FormationManager.role_category(p.formation_role)
				if cat == "FWD":
					fwd_best = maxf(fwd_best, along)
				elif cat == "DEF":
					def_best = maxf(def_best, along)
			if fwd_best == -INF or def_best == -INF:
				continue
			samples += 1
			if fwd_best > def_best + 8.0:
				advanced_samples += 1

	var ratio: float = float(advanced_samples) / maxf(samples, 1)
	_check("Sampled attacking phases for the forward-run check (%d)" % samples, samples > 50)
	_check("While attacking, forwards hold a clearly advanced line ahead of their own defenders (%.0f%% of sampled frames)" % (ratio * 100.0), ratio > 0.8)

	main.queue_free()
	await get_tree().process_frame


func _test_live_match_contest_is_not_a_swarm() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var samples := 0
	var total_near := 0.0
	var worst := 0
	for i in range(420):
		await get_tree().physics_frame
		var carrier: FootballPlayer = main.possession_manager.current_carrier
		if carrier == null:
			continue
		var team: TeamController = main.home_team if carrier.team_id == 0 else main.away_team
		var near := 0
		for p in team.players:
			if p == carrier or p.is_goalkeeper:
				continue
			if p.global_position.distance_to(main.ball.global_position) < 5.0:
				near += 1
		samples += 1
		total_near += near
		worst = maxi(worst, near)

	var avg: float = total_near / maxf(samples, 1)
	_check("Sampled enough possession frames for the crowding check (%d)" % samples, samples > 40)
	_check("A carrier's own teammates give them space rather than converging on the ball (avg %.2f teammates within 5m)" % avg, avg < 1.4)

	main.queue_free()
	await get_tree().process_frame


func _test_live_match_defenders_hold_shape() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(180):
		await get_tree().physics_frame

	var samples := 0
	var goalside := 0
	for i in range(360):
		await get_tree().physics_frame
		for team_id in [0, 1]:
			var team: TeamController = main.home_team if team_id == 0 else main.away_team
			if team.plan == null or team.plan.attack_intent > -0.5:
				continue
			var side: float = 1.0 if team_id == 0 else -1.0
			for p in team.players:
				if p.is_goalkeeper or p == team.human_player:
					continue
				if FormationManager.role_category(p.formation_role) != "DEF":
					continue
				samples += 1
				# Goal-side of the ball, i.e. between it and our own goal.
				if p.global_position.x * side < main.ball.global_position.x * side + 3.0:
					goalside += 1

	var ratio: float = float(goalside) / maxf(samples, 1)
	_check("Sampled defending phases for the shape check (%d)" % samples, samples > 100)
	_check("While defending, defenders stay goal-side of the ball (%.0f%% of samples)" % (ratio * 100.0), ratio > 0.85)

	main.queue_free()
	await get_tree().process_frame


func _test_live_match_movement_is_not_oscillating() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var prev_move := {}
	var last_reversal_frame := {}
	var reversals := 0
	var loops := 0
	var players := 0
	var frames := 900
	for i in range(frames):
		await get_tree().physics_frame
		for p in main.home_players + main.away_players:
			if p.is_goalkeeper or p == main.player_controller.controlled_player:
				continue
			var mv: Vector2 = p.move_input
			if mv.length() > 0.25 and prev_move.has(p) and prev_move[p].length() > 0.25:
				if mv.normalized().dot(prev_move[p].normalized()) < -0.3:
					reversals += 1
					if i - last_reversal_frame.get(p, -999) < 60:
						loops += 1
					last_reversal_frame[p] = i
			if mv.length() > 0.25:
				prev_move[p] = mv
	for p in main.home_players + main.away_players:
		if not p.is_goalkeeper and p != main.player_controller.controlled_player:
			players += 1

	var per_player_per_sec: float = reversals / (maxf(players, 1) * (frames / 60.0))
	var loops_per_player_per_sec: float = loops / (maxf(players, 1) * (frames / 60.0))
	# Two different things, and only the second is the reported bug.
	#
	# A player turning round because the ball went the other way is just
	# football, and a raw reversal count cannot tell that apart from a
	# fault. The "loops" figure below counts the actual reported signature
	# -- the SAME player reversing twice inside one second, i.e. forward ->
	# backward -> forward. Measured directly against the v0.8.2 build in
	# the same harness: 0.024-0.034 loops per player per second there,
	# 0.011-0.017 here. Bars are set with room for the run-to-run variance
	# of a 22-player physics match (both figures move ~30% between runs).
	_check("AI players do not loop forward-and-back (%.3f loops per player per second, %d total)" % [loops_per_player_per_sec, loops],
		loops_per_player_per_sec < 0.028)
	_check("Overall direction changes stay at or below the v0.8.2 baseline of ~0.15 (%.3f per player per second)" % per_player_per_sec,
		per_player_per_sec < 0.17)

	main.queue_free()
	await get_tree().process_frame


func _test_live_match_ai_passes_and_shoots_distinguishably() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	# v0.8.5: drive all 22. This test counts what the AI does, but it was
	# leaving a human-controlled player on the pitch with nobody driving
	# them -- no AI, and no input. That player still collects the ball, and
	# then simply stands there holding it, because nothing in the game makes
	# a human pass. Whole passages of the sampled minute were therefore a
	# frozen match, which is why this measured 5-10 AI passes while a
	# rendered 60s match of the same build measured 29-61, and why extending
	# the window from 30s to 60s in v0.8.4 did not make the counts agree.
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var seen := {}
	var passes := 0
	var shots := 0
	var pass_speeds: Array = []
	var shot_speeds: Array = []
	var passes_with_target := 0
	# 60 seconds, matching the rendered playtest's sampling window. A 30s
	# window produced counts wildly inconsistent with the same build
	# measured over 60s (5 versus 41 passes), so it was too short to
	# characterise a stochastic 22-player match at all.
	for i in range(3600):
		await get_tree().physics_frame
		for p in main.home_players + main.away_players:
			if p.kick_count == seen.get(p, 0):
				continue
			seen[p] = p.kick_count
			if p.last_kick_kind == FootballPlayer.KickKind.PASS:
				passes += 1
				pass_speeds.append(p.last_kick_power)
				if p.last_kick_target != null:
					passes_with_target += 1
			elif p.last_kick_kind == FootballPlayer.KickKind.SHOT:
				shots += 1
				shot_speeds.append(p.last_kick_power)

	_check("AI players genuinely pass to each other during a live match (%d passes in 60s)" % passes, passes >= 12)
	_check("Almost every AI pass has a real intended receiver (%d of %d)" % [passes_with_target, passes], passes_with_target >= int(passes * 0.8))
	_check("AI players do not shoot constantly (%d shots vs %d passes in 60s)" % [shots, passes], shots <= passes * 2)
	if not pass_speeds.is_empty() and not shot_speeds.is_empty():
		_check("The slowest shot is still faster than the fastest pass (%.1f vs %.1f m/s)" % [shot_speeds.min(), pass_speeds.max()],
			shot_speeds.min() > pass_speeds.max())

	main.queue_free()
	await get_tree().process_frame


## Whether a shot happens at all in any given 30 seconds of a 22-player
## match depends on whether an attack survives long enough to reach the
## box, which varies a great deal run to run (measured between 0 and 9
## outfield shots across otherwise identical 45-second runs). So the
## SHOOTING DECISION is verified deterministically instead: put an AI
## player in an unambiguous shooting position and in an unambiguous
## non-shooting one, and check the hierarchy resolves each correctly.
func _test_ai_shoots_from_a_real_chance_and_not_from_nowhere() -> void:
	# A. A clear chance close to goal must be taken, and must be a SHOT.
	var near := await _make_carrier_at(Vector3(19, 1, 0))
	var shooter: FootballPlayer = near["kicker"]
	var plan := TeamPlan.new()
	plan.setup(0, Vector3(-26, 1, 0), Vector3(26, 1, 0))
	var shot_taken := false
	for i in range(120):
		shooter.possession_time = 0.5
		AIController._decide_possession_action(shooter, near["ball"], Vector3(26, 1, 0), [], Vector3(1, 0, 0), plan, 1.0 / 60.0)
		if shooter.kick_count > 0:
			shot_taken = true
			break
		await get_tree().physics_frame
	_check("An AI player with a clear chance 7m from goal shoots (score %.2f vs threshold %.2f)" % [shooter.last_shoot_score, shooter.last_shoot_threshold], shot_taken)
	_check("...and it is recorded as a shot, not a pass", shooter.last_kick_kind == FootballPlayer.KickKind.SHOT)
	_check("...struck at a real shot speed (%.1f m/s, band starts at %.1f)" % [shooter.last_kick_power, FootballPlayer.SHOT_SPEED_MIN],
		shooter.last_kick_power >= FootballPlayer.SHOT_SPEED_MIN)
	await _teardown_kick(near)

	# B. From the halfway line, the same logic must never produce a shot.
	var far := await _make_carrier_at(Vector3(-2, 1, 0))
	var midfielder: FootballPlayer = far["kicker"]
	var wild_shot := false
	for i in range(240):
		midfielder.possession_time = 0.5
		AIController._decide_possession_action(midfielder, far["ball"], Vector3(26, 1, 0), [], Vector3(1, 0, 0), plan, 1.0 / 60.0)
		if midfielder.last_kick_kind == FootballPlayer.KickKind.SHOT:
			wild_shot = true
			break
		await get_tree().physics_frame
	_check("An AI player 28m from goal never shoots from there", not wild_shot)
	await _teardown_kick(far)


## A lone AI carrier at a given spot, with no teammates or opponents, so a
## decision can be isolated from the rest of a match.
func _make_carrier_at(pos: Vector3) -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var pair := _make_player("decider", 0, pos)
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])
	player.formation_role = "ST"
	player.set_match_context([player], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([player], ball)
	player.set_possession_manager(pm)

	_teleport(ball, pos + Vector3(0.5, -0.65, 0))
	for i in range(4):
		await get_tree().physics_frame
	return {"field": field, "ball": ball, "kicker": player, "mate": player, "pm": pm}


func _test_live_match_goalkeepers_unchanged() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var max_dist := {}
	for i in range(420):
		await get_tree().physics_frame
		for p in main.home_players + main.away_players:
			if not p.is_goalkeeper:
				continue
			var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), p.team_id)
			max_dist[p] = maxf(max_dist.get(p, 0.0), p.global_position.distance_to(own_goal))

	var worst := 0.0
	for p in max_dist:
		worst = maxf(worst, max_dist[p])
	_check("Goalkeepers still hold their line and never wander upfield (max %.1fm from own goal)" % worst, worst < 8.0)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------- utils

func _make_kick_scenario(mate_distance: float = 9.0, offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var kicker_pair := _make_player("kicker", 0, Vector3(0, 1, 0))
	var kicker: FootballPlayer = kicker_pair[0]
	add_child(kicker)
	kicker.apply_player_data(kicker_pair[1])

	var mate_pos: Vector3 = Vector3(mate_distance, 1, 0) if offset == Vector3.ZERO else Vector3(0, 1, 0) + offset
	var mate_pair := _make_player("mate", 0, mate_pos)
	var mate: FootballPlayer = mate_pair[0]
	add_child(mate)
	mate.apply_player_data(mate_pair[1])

	kicker.set_match_context([kicker, mate], [])
	mate.set_match_context([kicker, mate], [])

	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([kicker, mate], ball)
	kicker.set_possession_manager(pm)
	mate.set_possession_manager(pm)

	_teleport(ball, Vector3(0.5, 0.35, 0))
	for i in range(4):
		await get_tree().physics_frame

	return {"field": field, "ball": ball, "kicker": kicker, "mate": mate, "pm": pm}


func _teardown_kick(ctx: Dictionary) -> void:
	ctx["kicker"].queue_free()
	if ctx["mate"] != ctx["kicker"]:
		ctx["mate"].queue_free()
	ctx["pm"].queue_free()
	ctx["ball"].queue_free()
	ctx["field"].queue_free()
	await get_tree().process_frame


## RigidBody3D teleports go through PhysicsServer3D -- a plain
## global_position write can be silently lost under real-time execution
## (see the run-uma-soccer skill's Gotchas).
func _teleport(ball: RigidBody3D, pos: Vector3) -> void:
	var xform: Transform3D = ball.global_transform
	xform.origin = pos
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	PhysicsServer3D.body_set_state(ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)


func _make_player(id: String, team_id: int, pos: Vector3) -> Array:
	var data := PlayerData.new()
	data.id = id
	data.display_name = "Test"
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
	player.position = pos
	return [player, data]


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
