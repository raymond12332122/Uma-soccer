extends Node3D

# Headless regression test for Main.tscn: goal scoring and match restart.
# Run via: godot --headless --path . tests/MainSceneTest.tscn

const MainScene := preload("res://scenes/Main.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	var main = MainScene.instantiate()
	add_child(main)

	for i in range(5):
		await get_tree().physics_frame

	var ball: RigidBody3D = main.get_node("Ball")
	var player: CharacterBody3D = main.get_node("Player")
	var score_label: Label = main.get_node("UI/ScoreLabel")

	_check("Initial score label shows 0", score_label.text == "Goals: 0")

	# --- drive the ball into the right goal trigger directly ---
	ball.linear_velocity = Vector3.ZERO
	ball.global_position = main.get_node("Field/GoalAreaRight").global_position

	var scored := false
	for i in range(30):
		await get_tree().physics_frame
		if main.score == 1:
			scored = true
			break
	_check("Ball entering GoalAreaRight increments score", scored)
	_check("Score label updates after goal", score_label.text == "Goals: 1")
	_check("Ball auto-resets to spawn after goal", ball.global_position.distance_to(ball.spawn_position) < 0.5)

	# --- score again via the left goal ---
	ball.linear_velocity = Vector3.ZERO
	ball.global_position = main.get_node("Field/GoalAreaLeft").global_position
	var scored_again := false
	for i in range(30):
		await get_tree().physics_frame
		if main.score == 2:
			scored_again = true
			break
	_check("Ball entering GoalAreaLeft also increments score", scored_again)

	# --- displace player and ball, then restart ---
	player.global_position = Vector3(20, 1, 15)
	ball.global_position = Vector3(-15, 1, -10)
	ball.linear_velocity = Vector3(5, 0, 5)
	await get_tree().physics_frame

	main.restart_match()

	_check("Restart resets score to 0", main.score == 0)
	_check("Restart resets score label", score_label.text == "Goals: 0")
	_check("Restart resets ball position", ball.global_position.distance_to(ball.spawn_position) < 0.5)
	_check("Restart resets ball velocity", ball.linear_velocity.length() < 0.001)

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
