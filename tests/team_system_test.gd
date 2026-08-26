extends Node3D

# Headless regression test for the V0.3 team/AI architecture: spawning,
# team assignment, formation positioning, player switching, possession
# transfer, AI movement, and goalkeeper behavior. Run via:
#   godot --headless --path . tests/TeamSystemTest.tscn

const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	var main = MainScene.instantiate()
	add_child(main)

	for i in range(5):
		await get_tree().physics_frame

	# --- player spawning ---
	_check("11 home players spawned", main.home_players.size() == 11)
	_check("11 away players spawned", main.away_players.size() == 11)

	var home_gk_count := 0
	for p in main.home_players:
		if p.is_goalkeeper:
			home_gk_count += 1
	_check("Exactly 1 home goalkeeper", home_gk_count == 1)

	var away_gk_count := 0
	for p in main.away_players:
		if p.is_goalkeeper:
			away_gk_count += 1
	_check("Exactly 1 away goalkeeper", away_gk_count == 1)

	# --- team assignment ---
	var home_team_ok := true
	for p in main.home_players:
		if p.team_id != 0:
			home_team_ok = false
	_check("All home players have team_id 0", home_team_ok)

	var away_team_ok := true
	for p in main.away_players:
		if p.team_id != 1:
			away_team_ok = false
	_check("All away players have team_id 1", away_team_ok)

	# --- PlayerData actually applied ---
	var data_applied := true
	for p in main.home_players + main.away_players:
		if p.player_data == null or p.name_label.text != p.player_data.display_name:
			data_applied = false
	_check("PlayerData applied to every spawned player (name label set)", data_applied)

	# --- formation positioning ---
	var formation_ok := true
	for p in main.home_players + main.away_players:
		var expected: Vector3 = FormationManager.get_world_position(p.formation_slot, p.team_id)
		if p.global_position.distance_to(expected) > 0.1:
			formation_ok = false
	_check("Every player spawns at its formation slot", formation_ok)

	# --- player switching ---
	var initial_controlled = main.player_controller.controlled_player
	_check("A player is controlled by default", initial_controlled != null)
	_check("Default controlled player is on the home team", initial_controlled.team_id == 0)
	_check("Default controlled player's indicator is visible", initial_controlled.control_indicator.visible)

	main._switch_to_next_player()
	await get_tree().physics_frame
	var second_controlled = main.player_controller.controlled_player
	_check("Switching changes the controlled player", second_controlled != initial_controlled)
	_check("Previous player's indicator turns off", not initial_controlled.control_indicator.visible)
	_check("New player's indicator turns on", second_controlled.control_indicator.visible)
	_check("Home team no longer treats old player as human", main.home_team.human_player == second_controlled)

	# v0.7: switching is relevance-scored (distance to ball + attacking/
	# defensive positioning -- see MatchManager._select_switch_target), not
	# simple round-robin, so repeatedly switching is no longer guaranteed to
	# tour every player and return to the start (a football game's smart
	# switch is explicitly allowed to revisit the most relevant couple of
	# players rather than blindly cycling). What must still hold at every
	# step: the result is always a real member of the home roster, and a
	# switch always actually changes who's controlled (the previous player
	# is excluded from candidates by construction).
	var repeated_switch_ok := true
	var previous = second_controlled
	for i in range(main.home_players.size() + 3):
		main._switch_to_next_player()
		await get_tree().physics_frame
		var now = main.player_controller.controlled_player
		if not main.home_players.has(now) or now == previous:
			repeated_switch_ok = false
		previous = now
	_check("Repeated switching always lands on a distinct, valid home-roster player", repeated_switch_ok)

	# --- possession transfer ---
	var controlled = main.player_controller.controlled_player
	var to_ball: Vector2 = Vector2(main.ball.global_position.x, main.ball.global_position.z) - Vector2(controlled.global_position.x, controlled.global_position.z)
	InputState.move_vector = to_ball.normalized()
	var gained := false
	for i in range(300):
		await get_tree().physics_frame
		to_ball = Vector2(main.ball.global_position.x, main.ball.global_position.z) - Vector2(controlled.global_position.x, controlled.global_position.z)
		if to_ball.length() > 0.05:
			InputState.move_vector = to_ball.normalized()
		if main.possession_manager.current_carrier == controlled:
			gained = true
			break
	InputState.move_vector = Vector2.ZERO
	_check("Controlled player can gain possession (PossessionManager reflects it)", gained)
	_check("PossessionManager reports the correct possessing team", not gained or main.possession_manager.possessing_team == 0)
	_check("PossessionManager reports ball not loose while controlled", not gained or not main.possession_manager.is_loose)

	if gained:
		InputState.pass_pressed = true
		for i in range(10):
			await get_tree().physics_frame
		_check("Possession clears from PossessionManager after passing away", main.possession_manager.current_carrier != controlled)

	# --- AI movement ---
	for i in range(30):
		await get_tree().physics_frame
	var ai_player = null
	for p in main.home_players:
		if p != main.player_controller.controlled_player and not p.is_goalkeeper:
			ai_player = p
			break
	# By this point in the test, AI has already been running for hundreds
	# of frames (through the switching/possession phases above), so it may
	# have already converged on its current target and correctly stopped
	# (move_input == ZERO on arrival is right, not a bug). What actually
	# proves AI logic is live is that it left its static spawn/formation
	# point at all, rather than idling there the whole match.
	var spawn_pos: Vector3 = FormationManager.get_world_position(ai_player.formation_slot, ai_player.team_id)
	var ai_moved_from_spawn: bool = ai_player.global_position.distance_to(spawn_pos) > 0.5

	for i in range(60):
		await get_tree().physics_frame
	_check("A non-controlled AI player has moved away from its static spawn point", ai_moved_from_spawn)

	# --- goalkeeper stays near its own goal ---
	var home_gk = null
	for p in main.home_players:
		if p.is_goalkeeper:
			home_gk = p
			break
	var home_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 0)
	var gk_far := false
	for i in range(180):
		await get_tree().physics_frame
		if home_gk.global_position.distance_to(home_goal) > 12.0:
			gk_far = true
	_check("Goalkeeper stays reasonably close to its own goal", not gk_far)

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
