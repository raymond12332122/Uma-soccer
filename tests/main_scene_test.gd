extends Node3D

# Headless regression test for Main.tscn (MatchManager): goal scoring and
# match restart, now with two real teams. Run via:
#   godot --headless --path . tests/MainSceneTest.tscn

const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	var main = MainScene.instantiate()
	add_child(main)

	for i in range(5):
		await get_tree().physics_frame

	var ball: BallController = main.get_node("Ball")
	var score_label: Label = main.get_node("UI/ScoreLabel")

	_check("Initial score label shows 0-0", score_label.text == "Home 0 - 0 Away")

	# --- drive the ball into the right goal trigger directly (home scores) ---
	ball.linear_velocity = Vector3.ZERO
	ball.global_position = main.get_node("Field/GoalAreaRight").global_position

	var scored := false
	for i in range(30):
		await get_tree().physics_frame
		if main.home_score == 1:
			scored = true
			break
	_check("Ball entering GoalAreaRight increments home_score", scored)
	_check("Score label updates after goal", score_label.text == "Home 1 - 0 Away")
	_check("Ball auto-resets to spawn after goal", ball.global_position.distance_to(ball.spawn_position) < 0.5)

	var scoring_team_celebrating := true
	for p in main.home_players:
		if p.animation_controller._pulse_kind != "celebration":
			scoring_team_celebrating = false
	_check("Scoring team's players trigger a celebration on goal", scoring_team_celebrating)

	var conceding_team_not_celebrating := true
	for p in main.away_players:
		if p.animation_controller._pulse_kind == "celebration":
			conceding_team_not_celebrating = false
	_check("Conceding team's players do not celebrate", conceding_team_not_celebrating)

	# --- score again via the left goal (away scores) ---
	ball.linear_velocity = Vector3.ZERO
	ball.global_position = main.get_node("Field/GoalAreaLeft").global_position
	var scored_again := false
	for i in range(30):
		await get_tree().physics_frame
		if main.away_score == 1:
			scored_again = true
			break
	_check("Ball entering GoalAreaLeft increments away_score", scored_again)
	_check("Score label shows both teams", score_label.text == "Home 1 - 1 Away")

	# --- displace players and ball, then restart ---
	for p in main.home_players + main.away_players:
		p.global_position = Vector3(randf_range(-20, 20), 1, randf_range(-15, 15))
	ball.global_position = Vector3(-15, 1, -10)
	ball.linear_velocity = Vector3(5, 0, 5)
	await get_tree().physics_frame

	main.restart_match()

	_check("Restart resets home_score to 0", main.home_score == 0)
	_check("Restart resets away_score to 0", main.away_score == 0)
	_check("Restart resets score label", score_label.text == "Home 0 - 0 Away")
	_check("Restart resets ball position", ball.global_position.distance_to(ball.spawn_position) < 0.5)
	_check("Restart resets ball velocity", ball.linear_velocity.length() < 0.001)

	var all_near_formation := true
	for p in main.home_players + main.away_players:
		var expected: Vector3 = FormationManager.get_world_position(p.formation_slot, p.team_id)
		if p.global_position.distance_to(expected) > 0.5:
			all_near_formation = false
	_check("Restart returns all players to their formation slots", all_near_formation)

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
