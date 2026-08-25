extends Node3D

# Headless gameplay smoke test. Drives a real FootballPlayer through a
# PlayerController exactly as touch/keyboard input would (via InputState),
# and asserts on the resulting physics state. Validates that V0.2
# mechanics (dribble/pass/shoot/clamp/reset) still work correctly through
# the V0.3 FootballPlayer + PlayerController split. Not part of the
# shipped game -- run manually via:
#   godot --headless --path . tests/GameplayTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	var field = FieldScene.instantiate()
	add_child(field)

	var ball: BallController = BallScene.instantiate()
	ball.position = Vector3(0, 1, 0)
	add_child(ball)

	var player: FootballPlayer = PlayerScene.instantiate()
	player.position = Vector3(0, 1, -3)
	add_child(player)

	var controller := PlayerController.new()
	add_child(controller)
	controller.set_controlled_player(player)

	for i in range(5):
		await get_tree().physics_frame

	# --- approach + gain possession ---
	InputState.move_vector = Vector2(0, 1)
	var approached := false
	for i in range(180):
		await get_tree().physics_frame
		if player.global_position.distance_to(ball.global_position) < 2.5:
			approached = true
			break
	_check("Player approaches ball", approached)

	for i in range(30):
		await get_tree().physics_frame

	_check("Player gains possession while close", player.has_possession)
	var dribble_dist: float = player.global_position.distance_to(ball.global_position)
	_check("Ball stays within dribble range (<2.0m)", dribble_dist < 2.0)

	# --- dribble while moving sideways: ball should follow ---
	InputState.move_vector = Vector2(1, 0)
	var start_ball_x: float = ball.global_position.x
	for i in range(60):
		await get_tree().physics_frame
	var moved_with_player: bool = ball.global_position.x > start_ball_x + 1.0
	_check("Ball follows player while dribbling sideways", moved_with_player)
	var dribble_dist_2: float = player.global_position.distance_to(ball.global_position)
	_check("Ball still close after dribbling (<2.0m)", dribble_dist_2 < 2.0)

	InputState.move_vector = Vector2.ZERO
	for i in range(20):
		await get_tree().physics_frame

	# --- pass ---
	var pre_pass_speed: float = ball.linear_velocity.length()
	InputState.move_vector = Vector2(0, 1)
	await get_tree().physics_frame
	InputState.pass_pressed = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	var post_pass_speed: float = ball.linear_velocity.length()
	_check("Pass gives ball noticeable velocity", post_pass_speed > pre_pass_speed + 1.0)
	_check("Player releases possession on pass", not player.has_possession)
	var pass_peak_speed: float = post_pass_speed
	InputState.move_vector = Vector2.ZERO

	for i in range(90):
		await get_tree().physics_frame

	# --- re-approach the ball for the shoot test ---
	var reapproached := false
	for i in range(240):
		var to_ball: Vector2 = Vector2(ball.global_position.x, ball.global_position.z) - Vector2(player.global_position.x, player.global_position.z)
		InputState.move_vector = to_ball.normalized() if to_ball.length() > 0.05 else Vector2.ZERO
		await get_tree().physics_frame
		if player.global_position.distance_to(ball.global_position) < 1.3:
			reapproached = true
			break
	_check("Player re-approaches ball after pass", reapproached)

	InputState.move_vector = Vector2.ZERO
	for i in range(20):
		await get_tree().physics_frame

	# --- charged shot ---
	InputState.move_vector = Vector2(0, 1)
	InputState.shoot_held = true
	for i in range(50):
		await get_tree().physics_frame
	InputState.shoot_held = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	var shoot_speed: float = ball.linear_velocity.length()
	_check("Shot is stronger than pass", shoot_speed > pass_peak_speed)
	_check("Shot speed respects max_speed clamp", shoot_speed <= ball.max_speed + 0.01)

	# --- clamp holds over subsequent flight/bounces ---
	var exceeded := false
	for i in range(120):
		await get_tree().physics_frame
		if ball.linear_velocity.length() > ball.max_speed + 0.05:
			exceeded = true
	_check("Ball never exceeds max_speed during flight/bounce", not exceeded)

	# --- reset_ball() sanity (used by goal-scoring in MatchManager) ---
	ball.reset_ball()
	var reset_ok: bool = ball.global_position.distance_to(ball.spawn_position) < 0.05 and ball.linear_velocity.length() < 0.001
	_check("Ball reset_ball() restores spawn position and zero velocity", reset_ok)

	# --- switching mid-charge cancels the charge cleanly (no phantom shot) ---
	# Isolated from earlier state: rest the ball, place `player` right next
	# to it (in action range, not necessarily dribbling it), start a
	# charge, switch away mid-charge, then confirm the ball never gets an
	# impulse -- distinguishing a real fix from ambient dribble-force noise.
	ball.reset_ball()
	InputState.move_vector = Vector2.ZERO
	InputState.shoot_held = false
	for i in range(5):
		await get_tree().physics_frame

	player.global_position = ball.global_position + Vector3(0, 0, -0.8)
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	for i in range(15):
		await get_tree().physics_frame

	_check("Player is within action range of the ball for the switch test", player.ball_in_action_range == ball)

	var player2: FootballPlayer = PlayerScene.instantiate()
	player2.position = Vector3(20, 1, 20)
	add_child(player2)
	for i in range(3):
		await get_tree().physics_frame

	InputState.shoot_held = true
	for i in range(15):
		await get_tree().physics_frame
	_check("Charge is in progress before switching", player._shoot_charging)

	controller.set_controlled_player(player2)
	InputState.shoot_held = false

	var ball_speed_after_switch := 0.0
	for i in range(20):
		await get_tree().physics_frame
		ball_speed_after_switch = maxf(ball_speed_after_switch, ball.linear_velocity.length())

	_check("Switching away mid-charge does not fire a phantom shot", ball_speed_after_switch < 0.5)

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
