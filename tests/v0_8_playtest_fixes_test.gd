extends Node3D

# Regression tests for the V0.8 manual-playtest fix pass: contested-ball
# freeze, multitouch finger independence, AI players staying alive/spaced
# even away from the ball, sprint stamina, and goal-post collision. Run via:
#   godot --headless --path . tests/V0_8PlaytestFixesTest.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")
const HUDScene := preload("res://scenes/UI/HUD.tscn")

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	await _test_contested_ball_does_not_freeze()
	await _test_sprint_stamina()
	await _test_goal_post_blocks_ball()
	await _test_multitouch_independent_fingers()
	await _test_ai_movement_and_support_spacing()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# --------------------------------------------------- contested ball freeze

func _test_contested_ball_does_not_freeze() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	ball.position = Vector3(0, 1, 0)
	add_child(ball)

	var pm := PossessionManager.new()
	add_child(pm)

	var a_pair := _make_player("contest_a", 0, Vector3(-0.4, 1, -0.05))
	var b_pair := _make_player("contest_b", 1, Vector3(0.4, 1, 0.05))
	var a: FootballPlayer = a_pair[0]
	var b: FootballPlayer = b_pair[0]
	add_child(a)
	add_child(b)
	a.apply_player_data(a_pair[1])
	b.apply_player_data(b_pair[1])
	a.set_match_context([a], [b])
	b.set_match_context([b], [a])
	pm.setup([a, b], ball)
	a.set_possession_manager(pm)
	b.set_possession_manager(pm)

	# Let control-area overlaps register before driving anything.
	for i in range(5):
		await get_tree().physics_frame

	# The classic contest: both players want the ball at the same instant,
	# pulling from opposite directions.
	a.move_input = Vector2(1, 0)
	b.move_input = Vector2(-1, 0)

	var start_pos: Vector3 = ball.global_position
	var max_disp := 0.0
	var carrier_was_elected := false
	for i in range(180):
		await get_tree().physics_frame
		max_disp = maxf(max_disp, ball.global_position.distance_to(start_pos))
		if pm.current_carrier == a or pm.current_carrier == b:
			carrier_was_elected = true

	_check("Contested ball moves meaningfully instead of freezing (max displacement %.2fm)" % max_disp, max_disp > 0.3)
	_check("PossessionManager resolves a single carrier out of the contest at some point", carrier_was_elected)

	a.move_input = Vector2.ZERO
	b.move_input = Vector2.ZERO
	a.queue_free()
	b.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------- sprint UI

func _test_sprint_stamina() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var pair := _make_player("sprint_test", 0, Vector3(0, 1, 0))
	var player: FootballPlayer = pair[0]
	add_child(player)
	player.apply_player_data(pair[1])
	for i in range(3):
		await get_tree().physics_frame

	player.move_input = Vector2(0, 1)
	player.sprint_requested = true
	var stamina_before: float = player.current_stamina
	var sprinted_flag_seen := false
	for i in range(30):
		await get_tree().physics_frame
		if player.is_currently_sprinting:
			sprinted_flag_seen = true
	_check("is_currently_sprinting reflects an active sprint (for the HUD)", sprinted_flag_seen)
	_check("Sprinting drains stamina smoothly, not instantly to zero", player.current_stamina < stamina_before and player.current_stamina > 0.0)

	player.sprint_requested = false
	var stamina_after_stop: float = player.current_stamina
	for i in range(30):
		await get_tree().physics_frame
	_check("is_currently_sprinting clears once sprint is released", not player.is_currently_sprinting)
	_check("Stamina regenerates smoothly once no longer sprinting", player.current_stamina > stamina_after_stop)

	player.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------- goal-post collision

func _test_goal_post_blocks_ball() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	# Fire directly at the left post -- must be physically blocked, not
	# pass through the goal frame like it isn't there.
	ball.global_position = Vector3(-27.0, 1.5, -4.0)
	ball.linear_velocity = Vector3(-8.0, 0.0, 0.0)
	for i in range(40):
		await get_tree().physics_frame

	_check("A ball shot straight at a goal post is physically blocked by it", ball.global_position.x > -29.2)

	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# --------------------------------------------------------- multitouch HUD

func _test_multitouch_independent_fingers() -> void:
	var hud = HUDScene.instantiate()
	add_child(hud)
	for i in range(2):
		await get_tree().process_frame

	InputState.move_vector = Vector2.ZERO
	InputState.shoot_held = false

	var joystick_touch := 0
	var shoot_touch := 1

	var joy_pos: Vector2 = hud.joystick.global_position + hud.joystick.size * 0.5
	var shoot_pos: Vector2 = hud.shoot_button.global_position + hud.shoot_button.size * 0.5

	hud._input(_touch_event(joystick_touch, joy_pos, true))
	hud._input(_touch_event(shoot_touch, shoot_pos, true))

	_check("Pressing SHOOT does not steal the joystick's touch ownership", hud._touch_owner.get(joystick_touch) == hud.joystick)
	_check("Holding the joystick does not steal SHOOT's touch ownership", hud._touch_owner.get(shoot_touch) == hud.shoot_button)
	_check("InputState.shoot_held is true while SHOOT is held", InputState.shoot_held)

	hud._input(_drag_event(joystick_touch, joy_pos + Vector2(60, 0)))
	_check("Dragging the joystick's own finger still moves it while SHOOT is held by a different finger", InputState.move_vector.x > 0.1)
	_check("SHOOT stays held through the joystick drag -- fully independent finger IDs", InputState.shoot_held)

	hud._input(_touch_event(shoot_touch, shoot_pos, false))
	_check("Releasing the SHOOT finger clears shoot_held", not InputState.shoot_held)
	_check("Releasing the SHOOT finger leaves the joystick's finger untouched", InputState.move_vector.x > 0.1)

	hud._input(_touch_event(joystick_touch, joy_pos + Vector2(60, 0), false))
	_check("Releasing the joystick's finger resets move_vector to zero", InputState.move_vector == Vector2.ZERO)

	InputState.move_vector = Vector2.ZERO
	InputState.shoot_held = false
	hud.queue_free()
	await get_tree().process_frame


func _touch_event(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e


func _drag_event(index: int, pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	return e


# ------------------------------------------- AI keeps moving / keeps space

func _test_ai_movement_and_support_spacing() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(5):
		await get_tree().physics_frame

	# Pin the ball deep in the away team's corner for a while, far from
	# home's own defenders -- a fully static formation target would leave
	# those defenders motionless indefinitely; the ball-reactive dynamic
	# target should not.
	var far_defender: FootballPlayer = null
	for p in main.home_players:
		if p.formation_role in ["CB", "LB", "RB"]:
			far_defender = p
			break
	var defender_spawn: Vector3 = far_defender.global_position

	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(28, 1, 15)))
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)

	for i in range(240):
		await get_tree().physics_frame

	_check("A defender away from the ball still moves (ball-reactive team shape, not a frozen static slot)", far_defender.global_position.distance_to(defender_spawn) > 0.4)

	# --- give the controlled player the ball and check teammates don't stack on top of them ---
	var controlled: FootballPlayer = main.player_controller.controlled_player
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), controlled.global_position + Vector3(0, 0.5, 0.6)))
	PhysicsServer3D.body_set_state(main.ball.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	InputState.move_vector = Vector2(1, 0)

	for i in range(120):
		await get_tree().physics_frame

	var stacked_count := 0
	for p in main.home_players:
		if p == controlled or p.is_goalkeeper:
			continue
		if p.global_position.distance_to(main.ball.global_position) < 1.6:
			stacked_count += 1
	_check("Supporting teammates keep a passing distance instead of stacking on the ball carrier (%d stacked)" % stacked_count, stacked_count == 0)

	InputState.move_vector = Vector2.ZERO
	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------- utils

## Caller is responsible for add_child()-ing the returned player, then
## calling apply_player_data(data) on it (needs @onready nodes ready --
## see the same two-step pattern in tests/character_pipeline_test.gd).
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
