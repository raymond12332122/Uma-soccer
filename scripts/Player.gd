extends CharacterBody3D

# ---- Movement ----
@export var base_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var acceleration: float = 14.0
@export var deceleration: float = 20.0
@export var turn_lerp_speed: float = 12.0
@export var gravity: float = 20.0

# ---- Ball control / dribbling ----
@export var dribble_distance: float = 0.9
@export var dribble_accel: float = 24.0
@export var dribble_damping_accel: float = 9.0
@export var dribble_force_accel_clamp: float = 30.0
@export var control_loss_angle_threshold: float = 1.2
@export var control_loss_speed_threshold: float = 2.5
@export var control_loss_duration: float = 0.35
@export var possession_release_cooldown: float = 0.35

# ---- Pass / Shoot ----
@export var pass_power: float = 2.4
@export var shoot_min_power: float = 3.4
@export var shoot_max_power: float = 7.0
@export var shoot_charge_time: float = 1.1
@export var kick_lift: float = 0.35
@export var momentum_transfer: float = 0.25

@onready var action_area: Area3D = $ActionArea
@onready var control_area: Area3D = $ControlArea
@onready var model: Node3D = $Model

var ball_in_action_range: RigidBody3D = null
var ball_in_control_range: RigidBody3D = null

var has_possession: bool = false
var _facing_angle: float = 0.0

var _control_lost_timer: float = 0.0
var _possession_cooldown_timer: float = 0.0

var _shoot_charging: bool = false
var _shoot_charge_elapsed: float = 0.0

var _space_was_pressed: bool = false
var _f_was_pressed: bool = false


func _ready() -> void:
	action_area.body_entered.connect(_on_action_area_entered)
	action_area.body_exited.connect(_on_action_area_exited)
	control_area.body_entered.connect(_on_control_area_entered)
	control_area.body_exited.connect(_on_control_area_exited)


func _physics_process(delta: float) -> void:
	var input_vector: Vector2 = _get_move_input()
	var sprinting: bool = _is_sprint_held() and input_vector.length() > 0.1
	var target_speed: float = sprint_speed if sprinting else base_speed

	var direction := Vector3(input_vector.x, 0.0, input_vector.y)

	if direction.length() > 0.01:
		var target_angle := atan2(direction.x, direction.z)
		var angle_delta := absf(wrapf(target_angle - _facing_angle, -PI, PI))
		var angle_threshold := control_loss_angle_threshold * (0.7 if sprinting else 1.0)

		if has_possession and _control_lost_timer <= 0.0 and angle_delta > angle_threshold and velocity.length() > control_loss_speed_threshold:
			_control_lost_timer = control_loss_duration

		_facing_angle = target_angle
		model.rotation.y = lerp_angle(model.rotation.y, _facing_angle, turn_lerp_speed * delta)

		velocity.x = move_toward(velocity.x, direction.x * target_speed, acceleration * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, deceleration * delta)

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()

	_update_possession(sprinting)
	_process_pass_input()
	_process_shoot_input(delta)

	if _control_lost_timer > 0.0:
		_control_lost_timer = maxf(0.0, _control_lost_timer - delta)
	if _possession_cooldown_timer > 0.0:
		_possession_cooldown_timer = maxf(0.0, _possession_cooldown_timer - delta)


func _get_move_input() -> Vector2:
	var input_vector: Vector2 = InputState.move_vector
	if input_vector == Vector2.ZERO:
		input_vector = _keyboard_vector()
	return input_vector.limit_length(1.0)


func _keyboard_vector() -> Vector2:
	var kb := Vector2.ZERO
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		kb.x += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		kb.x -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		kb.y += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		kb.y -= 1.0
	return kb


func _is_sprint_held() -> bool:
	return InputState.sprint_held or Input.is_key_pressed(KEY_SHIFT)


func _get_aim_direction() -> Vector3:
	var input_vector: Vector2 = _get_move_input()
	if input_vector.length() > 0.15:
		return Vector3(input_vector.x, 0.0, input_vector.y).normalized()
	return Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))


# Soft-attach steering: nudges the ball toward a point just ahead of the
# player with a spring/damper force. The ball stays a fully simulated
# RigidBody3D at all times -- this only adds a force on top of normal
# physics, so collisions, bounces, and knock-aways still behave naturally.
func _update_possession(sprinting: bool) -> void:
	if ball_in_control_range == null or _possession_cooldown_timer > 0.0:
		has_possession = false
		return

	has_possession = true

	if _control_lost_timer > 0.0:
		return

	var accel_coeff := dribble_accel
	var damping_coeff := dribble_damping_accel
	if sprinting:
		accel_coeff *= 0.6
		damping_coeff *= 0.7

	var facing_dir := Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))
	var target_pos: Vector3 = global_position + facing_dir * dribble_distance

	var to_target: Vector3 = target_pos - ball_in_control_range.global_position
	to_target.y = 0.0

	var ball_vel: Vector3 = ball_in_control_range.linear_velocity
	var horizontal_vel := Vector3(ball_vel.x, 0.0, ball_vel.z)

	var accel_total: Vector3 = to_target * accel_coeff - horizontal_vel * damping_coeff
	accel_total = accel_total.limit_length(dribble_force_accel_clamp)

	ball_in_control_range.apply_central_force(accel_total * ball_in_control_range.mass)


func _process_pass_input() -> void:
	var f_now := Input.is_key_pressed(KEY_F)
	var f_just_pressed := f_now and not _f_was_pressed
	_f_was_pressed = f_now

	var pass_requested := InputState.pass_pressed or f_just_pressed
	InputState.pass_pressed = false

	if not pass_requested or ball_in_action_range == null:
		return

	_apply_kick_impulse(ball_in_action_range, pass_power, false)


func _process_shoot_input(delta: float) -> void:
	var shoot_held_now := InputState.shoot_held or Input.is_key_pressed(KEY_SPACE)

	if shoot_held_now:
		if not _shoot_charging:
			_shoot_charging = true
			_shoot_charge_elapsed = 0.0
		else:
			_shoot_charge_elapsed = minf(_shoot_charge_elapsed + delta, shoot_charge_time)
	elif _shoot_charging:
		_shoot_charging = false
		var charge_ratio: float = _shoot_charge_elapsed / shoot_charge_time if shoot_charge_time > 0.0 else 1.0
		var power: float = lerp(shoot_min_power, shoot_max_power, charge_ratio)
		_shoot_charge_elapsed = 0.0

		if ball_in_action_range != null:
			_apply_kick_impulse(ball_in_action_range, power, true)


func _apply_kick_impulse(ball: RigidBody3D, power: float, is_shot: bool) -> void:
	var aim_dir := _get_aim_direction()
	var impulse: Vector3 = aim_dir * power + velocity * momentum_transfer
	impulse.y = kick_lift * (1.0 if is_shot else 0.6)

	ball.apply_central_impulse(impulse)

	has_possession = false
	_control_lost_timer = 0.0
	_possession_cooldown_timer = possession_release_cooldown


func _on_action_area_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_action_range = body


func _on_action_area_exited(body: Node3D) -> void:
	if body == ball_in_action_range:
		ball_in_action_range = null


func _on_control_area_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_control_range = body


func _on_control_area_exited(body: Node3D) -> void:
	if body == ball_in_control_range:
		ball_in_control_range = null
		has_possession = false
