extends Node3D

# Headless regression test for the v0.7 11v11 match upgrade: 22-player
# spawn/formation/roles, smart switching, possession stability, role-based
# attacking/defensive team shape, goalkeeper behavior, pass assist,
# stamina fatigue, personality events with duplicated characters across
# both teams, and goal/restart reset at full 22-player scale. Run via:
#   godot --headless --path . tests/V0_7MatchTest.tscn
#
# Complements (does not duplicate) team_system_test.gd, main_scene_test.gd,
# and personality_test.gd, which already cover the underlying mechanics at
# smaller scale / from earlier milestones -- this suite is specifically
# about what changed or scaled up in v0.7.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	_test_role_category_constants()
	_test_possession_hysteresis_unit()
	_test_pass_assist_unit()

	var main = MainScene.instantiate()
	add_child(main)
	for i in range(5):
		await get_tree().physics_frame
	var default_player: FootballPlayer = main.player_controller.controlled_player

	_test_roster_and_formation(main)
	_test_multiple_instances_independent(main)
	_test_smart_switching(main)
	await _test_role_based_shape(main)
	await _test_goalkeeper_no_teleport(main)
	await _test_stamina_fatigue(main)
	await _test_ai_shot_scores(main)
	await _test_goal_reset_22(main)
	await _test_full_restart_22(main, default_player)
	await _test_performance_smoke(main)

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# --------------------------------------------------------------- helpers

func _make_player(visual_id: String, pos: Vector3, role: String = "") -> FootballPlayer:
	var data := PlayerData.new()
	data.id = "test_%s_%s" % [visual_id, role]
	data.display_name = visual_id
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60
	data.visual_id = visual_id

	var player: FootballPlayer = PlayerScene.instantiate()
	player.position = pos
	add_child(player)
	player.apply_player_data(data)
	player.formation_role = role
	return player


# ------------------------------------------------------- A. formation/roles

func _test_role_category_constants() -> void:
	_check(
		"Forwards get the biggest attacking advance multiplier, defenders the smallest",
		AIController.ROLE_ATTACK_MULT["FWD"] > AIController.ROLE_ATTACK_MULT["MID"]
		and AIController.ROLE_ATTACK_MULT["MID"] > AIController.ROLE_ATTACK_MULT["DEF"]
	)
	_check(
		"Defenders get the strongest defensive recovery pull, forwards the weakest ('limited defensive support')",
		AIController.ROLE_DEFENSE_MULT["DEF"] > AIController.ROLE_DEFENSE_MULT["MID"]
		and AIController.ROLE_DEFENSE_MULT["MID"] > AIController.ROLE_DEFENSE_MULT["FWD"]
	)
	_check("role_category maps specific slots to the right broad bucket", (
		FormationManager.role_category("GK") == "GK"
		and FormationManager.role_category("CB") == "DEF"
		and FormationManager.role_category("CM") == "MID"
		and FormationManager.role_category("ST") == "FWD"
	))
	_check("role_category falls back to a neutral 'MID' for an unrecognized/empty role", FormationManager.role_category("") == "MID")

	var slots: Array = FormationManager.get_slots("4_3_3")
	_check("4-3-3 formation has exactly 11 slots", slots.size() == 11)
	_check("4-3-3 slot 0 is the goalkeeper (spawn-order convention)", slots[0]["role"] == "GK")
	var role_counts := {"GK": 0, "DEF": 0, "MID": 0, "FWD": 0}
	for slot in slots:
		var cat: String = FormationManager.role_category(slot["role"])
		role_counts[cat] += 1
	_check(
		"4-3-3 has 1 GK, 4 DEF, 3 MID, 3 FWD",
		role_counts["GK"] == 1 and role_counts["DEF"] == 4 and role_counts["MID"] == 3 and role_counts["FWD"] == 3
	)


func _test_roster_and_formation(main: Node3D) -> void:
	_check("22 total players spawned", main.home_players.size() + main.away_players.size() == 22)
	_check("11 home players spawned", main.home_players.size() == 11)
	_check("11 away players spawned", main.away_players.size() == 11)

	var gk_count := 0
	var role_assigned := true
	for p in main.home_players + main.away_players:
		if p.is_goalkeeper:
			gk_count += 1
		if p.formation_role == "":
			role_assigned = false
	_check("Exactly 2 goalkeepers across both full 22-player squads", gk_count == 2)
	_check("Every spawned player has a non-empty formation_role", role_assigned)

	# Every character used exactly once per team (see TestRoster.HOME_ORDER/
	# AWAY_ORDER) -- confirm no accidental duplicate visual_id within a team.
	var home_ids := {}
	var dup_within_team := false
	for p in main.home_players:
		if home_ids.has(p.player_data.visual_id):
			dup_within_team = true
		home_ids[p.player_data.visual_id] = true
	_check("No character appears twice on the same team", not dup_within_team and home_ids.size() == 11)


# --------------------------------------------------- B. multiple instances

func _test_multiple_instances_independent(main: Node3D) -> void:
	var home_gold: FootballPlayer = null
	var away_gold: FootballPlayer = null
	for p in main.home_players:
		if p.player_data.visual_id == "gold_ship":
			home_gold = p
	for p in main.away_players:
		if p.player_data.visual_id == "gold_ship":
			away_gold = p

	_check("Gold Ship appears on both teams (reused character, per the brief)", home_gold != null and away_gold != null)
	if home_gold == null or away_gold == null:
		return

	_check("The two Gold Ship instances are genuinely distinct player/PlayerData objects", home_gold != away_gold and home_gold.player_data != away_gold.player_data)
	_check("The two Gold Ship instances have distinct (but equal-valued) PersonalityData objects", home_gold.personality != away_gold.personality and is_equal_approx(home_gold.personality.playfulness, away_gold.personality.playfulness))

	# Draining one instance's stamina must never affect the other.
	away_gold.current_stamina = away_gold.max_stamina
	home_gold.current_stamina = 12.0
	_check("Stamina is tracked per-instance, not shared between duplicated characters", not is_equal_approx(home_gold.current_stamina, away_gold.current_stamina))

	# Forcing a personality event on one instance must never touch the other.
	var events := PersonalityEventSystem.new()
	var ctx := _make_context(main.ball, main.match_mood)
	home_gold.reset_intent()
	away_gold.reset_intent()
	events.force_trigger(home_gold, "gold_ship_bored_sit", ctx)
	_check("Forcing an event on one Gold Ship instance leaves the other one's event state untouched", home_gold.active_personality_event == "gold_ship_bored_sit" and away_gold.active_personality_event == "")


func _make_context(ball: RigidBody3D, mood: MatchMood) -> PersonalityContext:
	var ctx := PersonalityContext.new()
	ctx.ball = ball
	ctx.mood = mood
	ctx.teammates = []
	ctx.opponents = []
	ctx.own_goal_pos = Vector3(-26, 1, 0)
	ctx.opponent_goal_pos = Vector3(26, 1, 0)
	ctx.possessing_team = -1
	ctx.is_loose = true
	return ctx


# ------------------------------------------------------- C. smart switching

func _test_smart_switching(main: Node3D) -> void:
	var candidates: Array = []
	for p in main.home_players:
		if not p.is_goalkeeper:
			candidates.append(p)
	if candidates.size() < 2:
		return
	var near_but_wrong_side: FootballPlayer = candidates[0]
	var far_but_defensively_relevant: FootballPlayer = candidates[1]

	# Opponent has the ball, deep in home's own half -- defensive danger.
	main.possession_manager.possessing_team = 1
	main.possession_manager.is_loose = false
	main.ball.global_position = Vector3(-10, 1, 0)

	near_but_wrong_side.global_position = Vector3(-5, 1, 0)   # closer to the ball (dist 5), but upfield of it -- not a defensive candidate
	far_but_defensively_relevant.global_position = Vector3(-16, 1, 0)  # farther (dist 6), but goal-side of the ball -- defensively relevant

	var picked: FootballPlayer = main._select_switch_target([near_but_wrong_side, far_but_defensively_relevant])
	_check(
		"Switching prefers a defensively-relevant teammate over a merely-closer one when the opponent has the ball (not always closest)",
		picked == far_but_defensively_relevant
	)

	# Symmetric check for attacking relevance: our team has the ball, and
	# an upfield teammate (potential attacking outlet) beats a closer but
	# behind-the-ball one.
	main.possession_manager.possessing_team = 0
	main.possession_manager.is_loose = false
	main.ball.global_position = Vector3(0, 1, 0)
	near_but_wrong_side.global_position = Vector3(-2, 1, 0)   # closer (dist 2), but behind the ball -- not an attacking outlet
	far_but_defensively_relevant.global_position = Vector3(3, 1, 0)  # slightly farther (dist 3), ahead of the ball -- attacking outlet

	var picked_attack: FootballPlayer = main._select_switch_target([near_but_wrong_side, far_but_defensively_relevant])
	_check(
		"Switching prefers an attacking-relevant teammate ahead of the ball over a merely-closer one when our team has the ball",
		picked_attack == far_but_defensively_relevant
	)


# --------------------------------------------------- D. role-based shape

func _test_role_based_shape(main: Node3D) -> void:
	var ball: BallController = main.ball
	var possession: PossessionManager = main.possession_manager

	# Defensive shape: with the opponent in possession, the nominated
	# ball_challenger goes straight at the ball; a non-challenger falls
	# back toward its own goal instead of following. Positioned within the
	# real field's ground bounds (z in [-17,17]) since this runs inside the
	# live Main scene.
	var defender := _make_player("air_groove", Vector3(0, 1, -10), "CB")
	var teammate := _make_player("oguri_cap", Vector3(0, 1, -12), "CB")
	var own_goal := Vector3(-26, 1, -10)
	var opp_goal := Vector3(26, 1, -10)
	var loose_ball_pos := Vector3(5, 1, -10)

	# A plain RigidBody3D, not BallScene -- this test runs inside the live
	# Main scene, and BallScene's "ball" group + collision layer would let
	# real match players' Action/Control Areas pick it up as if it were the
	# real ball, corrupting their ball_in_control_range the moment this gets
	# freed below. A bare RigidBody3D (default collision_layer, no group)
	# is invisible to those Areas -- AIController only ever reads its
	# position anyway.
	var fake_ball := RigidBody3D.new()
	add_child(fake_ball)
	fake_ball.global_position = loose_ball_pos
	await get_tree().physics_frame

	var challenger: FootballPlayer = AIController.find_ball_challenger([defender, teammate], fake_ball)
	_check("find_ball_challenger picks the teammate nearest the ball", challenger == defender)

	AIController.update_player(defender, fake_ball, possession, [defender, teammate], [], own_goal, opp_goal, Vector3(-14, 1, -30), challenger, null)
	var defender_target_dir: Vector3 = (fake_ball.global_position - defender.global_position)
	_check("The ball challenger moves toward the ball, not its formation slot", defender.move_input.length() > 0.0 and Vector2(defender_target_dir.x, defender_target_dir.z).normalized().dot(defender.move_input.normalized()) > 0.9)

	AIController.update_player(teammate, fake_ball, possession, [defender, teammate], [], own_goal, opp_goal, Vector3(-14, 1, -32), challenger, null)
	var to_own_goal: Vector2 = Vector2(own_goal.x - teammate.global_position.x, own_goal.z - teammate.global_position.z)
	_check("A non-challenger defender's move points back toward its own defensive shape, not the ball", teammate.move_input.length() == 0.0 or to_own_goal.normalized().dot(teammate.move_input.normalized()) > 0.0)

	fake_ball.queue_free()

	# Attacking shape: a winger's target gets pulled wider (bigger |z|
	# offset from its formation slot) than a central midfielder's does,
	# under otherwise-identical conditions.
	var winger := _make_player("silence_suzuka", Vector3(0, 1, -10), "LW")
	var mid := _make_player("grass_wonder", Vector3(0, 1, -10), "CM")
	possession.possessing_team = 0
	possession.is_loose = false
	var slot := Vector3(5, 1, -10)
	AIController.update_player(winger, ball, possession, [winger], [], Vector3(-26, 1, 0), Vector3(26, 1, 0), slot)
	AIController.update_player(mid, ball, possession, [mid], [], Vector3(-26, 1, 0), Vector3(26, 1, 0), slot)
	_check("A winger's attacking-support movement differs from a central midfielder's under identical conditions (role genuinely affects shape)", winger.move_input != mid.move_input)

	defender.queue_free()
	teammate.queue_free()
	winger.queue_free()
	mid.queue_free()


# ------------------------------------------------- E. goalkeeper no-teleport

func _test_goalkeeper_no_teleport(main: Node3D) -> void:
	var home_gk: FootballPlayer = null
	for p in main.home_players:
		if p.is_goalkeeper:
			home_gk = p
			break
	_check("A home goalkeeper exists", home_gk != null)
	if home_gk == null:
		return

	var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 0)
	# Suddenly move the ball right in front of the home goal, forcing the
	# keeper to react -- it must step out smoothly frame-by-frame (bounded
	# by its own move speed, ramped by acceleration) rather than
	# teleporting to make a save.
	main.ball.linear_velocity = Vector3.ZERO
	main.ball.global_position = own_goal + Vector3(4, 0, 1)

	var max_step := 0.0
	var previous_pos: Vector3 = home_gk.global_position
	var reasonable_step_bound: float = home_gk.sprint_speed * (1.0 / 60.0) * 3.0  # generous margin over one physics tick at full sprint
	for i in range(90):
		await get_tree().physics_frame
		var step: float = home_gk.global_position.distance_to(previous_pos)
		max_step = maxf(max_step, step)
		previous_pos = home_gk.global_position
	_check("Goalkeeper reacts to a sudden nearby ball by moving smoothly (max per-frame step %.2f, bound ~%.2f) rather than teleporting" % [max_step, reasonable_step_bound], max_step < reasonable_step_bound)


# --------------------------------------------------------- F. stamina fatigue

func _test_stamina_fatigue(main: Node3D) -> void:
	var p := _make_player("tokai_teio", Vector3(50, 1, 50), "ST")
	p.move_input = Vector2(0, 1)
	p.sprint_requested = true

	# Pin stamina at (effectively) full for every frame of this phase --
	# isolates the fatigue-scaling effect itself from stamina's own drain
	# dynamics (which would otherwise cross into "not sprinting anymore"
	# partway through a longer sprint and confound the comparison).
	p.velocity = Vector3.ZERO
	for i in range(20):
		p.current_stamina = p.max_stamina
		await get_tree().physics_frame
	var fresh_speed: float = Vector2(p.velocity.x, p.velocity.z).length()
	_check("A fresh (full-stamina) player reaches a meaningful sprint speed", fresh_speed > 2.5)

	p.velocity = Vector3.ZERO
	for i in range(20):
		p.current_stamina = p.max_stamina * 0.1
		await get_tree().physics_frame
	var fatigued_speed: float = Vector2(p.velocity.x, p.velocity.z).length()
	_check("Fatigue gradually reduces sprint speed rather than an instant on/off cliff", fatigued_speed < fresh_speed)
	_check("A heavily fatigued player is still able to move at all (not disabled)", fatigued_speed > 0.5)

	# Recovery: stop sprinting and let stamina drain-vs-regen play out
	# naturally (unpinned) -- it must climb back up over time.
	p.sprint_requested = false
	p.current_stamina = 20.0
	for i in range(5):
		await get_tree().physics_frame
	var stamina_before_rest: float = p.current_stamina
	for i in range(60):
		await get_tree().physics_frame
	_check("Stamina recovers while not sprinting", p.current_stamina > stamina_before_rest)


# ----------------------------------------------------------- G. AI shooting

func _test_ai_shot_scores(main: Node3D) -> void:
	# Hand a forward the ball near the opponent goal and let normal AI
	# decision-making (update_player's shoot-in-range branch) take it from
	# there -- proves shooting/goal detection still resolve correctly with
	# the new formation/role system driving a real 22-player match, not
	# just via a directly-teleported ball as in MainSceneTest. Away players
	# are moved well clear first so this specifically isolates shooting
	# mechanics (goalkeeper behavior is covered separately) rather than
	# depending on how a full contested passage of play happens to unfold
	# within a short, deterministic test window.
	var striker: FootballPlayer = null
	for p in main.home_players:
		if p.formation_role == "ST":
			striker = p
			break
	_check("Home striker found for the AI-shot test", striker != null)
	if striker == null:
		return

	# The ST slot is the default human-controlled player (see
	# MatchManager.DEFAULT_HUMAN_INDEX) -- switch away first so the
	# striker is genuinely AI-controlled for this check.
	if main.player_controller.controlled_player == striker:
		for p in main.home_players:
			if p != striker:
				main._set_human_player(p)
				break
		await get_tree().physics_frame

	for p in main.away_players:
		p.global_position = Vector3(200, 1, 200)

	main.ball.linear_velocity = Vector3.ZERO
	main.ball.global_position = striker.global_position + Vector3(0.5, 0, 0)
	var pre_score: int = main.home_score

	var scored := false
	for i in range(240):
		await get_tree().physics_frame
		if main.home_score > pre_score:
			scored = true
			break
	_check("An AI-controlled forward given the ball near goal eventually scores through normal decision-making", scored)


# ------------------------------------------------------- H. goal reset @ 22

func _test_goal_reset_22(main: Node3D) -> void:
	var controlled_before: FootballPlayer = main.player_controller.controlled_player

	var away_gold: FootballPlayer = null
	for p in main.away_players:
		if p.player_data.visual_id == "gold_ship":
			away_gold = p
			break
	if away_gold:
		main.force_personality_event(away_gold, "gold_ship_wander_off")

	# _test_ai_shot_scores already scored into this same GoalAreaRight
	# trigger once; its own reset moved the ball back to spawn but this
	# function runs immediately afterward with no physics step in between,
	# so the Area3D never actually got a processed frame with the ball
	# genuinely outside it. Godot's body_entered/exited pairing is a
	# delta between consecutive physics steps, so re-teleporting straight
	# back in without that intervening "outside" step can leave the area's
	# internal pair-tracking still considering the ball "already entered,"
	# and the signal silently never re-fires. A few settled frames with the
	# ball explicitly clear of the trigger first avoids that.
	main.ball.global_position = Vector3(0, 1, 0)
	main.ball.linear_velocity = Vector3.ZERO
	for i in range(5):
		await get_tree().physics_frame

	main.ball.linear_velocity = Vector3.ZERO
	main.ball.global_position = main.get_node("Field/GoalAreaRight").global_position
	var pre_score: int = main.home_score
	var scored := false
	for i in range(60):
		await get_tree().physics_frame
		if main.home_score > pre_score:
			scored = true
			break
	_check("A goal is detected during the 22-player reset test", scored)

	for i in range(5):
		await get_tree().physics_frame

	var all_home_reset := true
	for p in main.home_players:
		var expected: Vector3 = FormationManager.get_world_position(p.formation_slot, 0)
		if p.global_position.distance_to(expected) > 0.5:
			all_home_reset = false
	var all_away_reset := true
	for p in main.away_players:
		var expected: Vector3 = FormationManager.get_world_position(p.formation_slot, 1)
		if p.global_position.distance_to(expected) > 0.5:
			all_away_reset = false
	_check("All 11 home players return to their formation slots after a goal", all_home_reset)
	_check("All 11 away players return to their formation slots after a goal", all_away_reset)

	var gk_count_near_goal := 0
	for p in main.home_players + main.away_players:
		if p.is_goalkeeper:
			var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), p.team_id)
			if p.global_position.distance_to(own_goal) < 3.0:
				gk_count_near_goal += 1
	_check("Both goalkeepers are back near their own goal after the reset", gk_count_near_goal == 2)

	_check("Possession is in a valid state after the reset (loose or a real carrier)", main.possession_manager.is_loose or main.possession_manager.current_carrier != null)
	_check("The camera still tracks the same controlled player after the reset", main.camera_controller.target == controlled_before)

	var events_cleared := true
	for p in main.home_players + main.away_players:
		if p.active_personality_event != "":
			events_cleared = false
	_check("No personality event survives the post-goal reset anywhere on the pitch", events_cleared)


# --------------------------------------------------------- I. full restart

func _test_full_restart_22(main: Node3D, default_player: FootballPlayer) -> void:
	for p in main.home_players + main.away_players:
		p.global_position += Vector3(randf_range(-5, 5), 0, randf_range(-5, 5))
	await get_tree().physics_frame

	main.restart_match()
	await get_tree().physics_frame

	_check("Full restart resets the score", main.home_score == 0 and main.away_score == 0)

	var all_reset := true
	for p in main.home_players + main.away_players:
		var expected: Vector3 = FormationManager.get_world_position(p.formation_slot, p.team_id)
		if p.global_position.distance_to(expected) > 0.5:
			all_reset = false
	_check("Full restart returns all 22 players to their formation slots", all_reset)
	_check("Full restart re-selects the default controlled player", main.player_controller.controlled_player == default_player)


# ------------------------------------------------------ J. performance smoke

func _test_performance_smoke(main: Node3D) -> void:
	var start_ticks: int = Time.get_ticks_msec()
	for i in range(180):
		await get_tree().physics_frame
	var elapsed_ms: int = Time.get_ticks_msec() - start_ticks
	# Not a rigorous profile (headless, no rendering) -- a coarse smoke
	# check that 3 simulated seconds (180 physics frames) of full
	# 22-player AI/personality/possession processing doesn't blow up into
	# something pathologically slow (e.g. an accidental O(n^3) loop).
	_check("180 physics frames of the full 22-player match complete without a pathological slowdown (%dms)" % elapsed_ms, elapsed_ms < 20000)


# --------------------------------------------------------------- pass assist

func _test_pass_assist_unit() -> void:
	var field = FieldScene.instantiate()
	add_child(field)

	var passer := _make_player("oguri_cap", Vector3(0, 1, 0))
	var aligned_open := _make_player("tamamo_cross", Vector3(10, 1, 0))
	var aligned_blocked := _make_player("agnes_digital", Vector3(10, 1, 6))
	var blocker := _make_player("air_groove", Vector3(5, 1, 3))  # sits almost exactly on the passer->aligned_blocked line
	var off_to_the_side := _make_player("grass_wonder", Vector3(1, 1, 20))

	var base_dir := Vector3(1, 0, 0)

	passer.teammates = [passer, aligned_blocked, off_to_the_side]
	passer.opponents = []
	var target: FootballPlayer = passer._find_pass_target(base_dir)
	_check("Pass assist ignores a teammate far outside the aim cone (off_to_the_side never considered)", target != off_to_the_side)

	passer.teammates = [passer, aligned_open, aligned_blocked]
	passer.opponents = [blocker]
	var target2: FootballPlayer = passer._find_pass_target(base_dir)
	_check("Pass assist prefers an aligned, unobstructed teammate over an aligned-but-blocked one", target2 == aligned_open)

	passer.teammates = []
	passer.opponents = []
	var direction_no_teammates: Vector3 = passer._get_pass_direction()
	_check("With no teammates known, the pass direction is exactly the raw aim direction (no assist forced)", direction_no_teammates == passer._get_aim_direction())

	field.queue_free()


# ------------------------------------------------------------ hysteresis unit

func _test_possession_hysteresis_unit() -> void:
	var pm := PossessionManager.new()
	add_child(pm)

	var field = FieldScene.instantiate()
	add_child(field)
	var ball := BallScene.instantiate()
	add_child(ball)
	ball.global_position = Vector3(0, 1, 0)

	var p1 := _make_player("oguri_cap", Vector3(1.0, 1, 0))
	var p2 := _make_player("tamamo_cross", Vector3(1.05, 1, 0))
	p1.team_id = 0
	p2.team_id = 1
	p1.has_possession = true
	p2.has_possession = true

	pm.setup([p1, p2], ball)
	pm._physics_process(0.0)
	_check("Possession picks the strictly-closer player when there's no established carrier yet", pm.current_carrier == p1)

	# p2 becomes marginally closer (well within the hysteresis margin) --
	# the established carrier (p1) should NOT flip on this tiny jitter.
	p2.global_position = Vector3(0.98, 1, 0)
	pm._physics_process(0.0)
	_check("A marginally-closer player does not steal the carrier away (hysteresis prevents flicker)", pm.current_carrier == p1)

	# p2 becomes genuinely, decisively closer -- the carrier must still be
	# able to change for a real possession change.
	p2.global_position = Vector3(0.1, 1, 0)
	pm._physics_process(0.0)
	_check("A decisively closer player still legitimately takes over as carrier (hysteresis doesn't freeze possession forever)", pm.current_carrier == p2)

	field.queue_free()
	ball.queue_free()


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
