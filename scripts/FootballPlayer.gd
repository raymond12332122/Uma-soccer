class_name FootballPlayer
extends CharacterBody3D

## Reusable entity for every player on the pitch -- human-controlled,
## AI-controlled, or goalkeeper. This script owns movement/dribbling/
## kicking simulation only. It never reads Input or InputState directly;
## exactly one driver (PlayerController for the human, or TeamController/
## AIController for everyone else) writes into the intent fields below
## each physics frame, and this script simulates the result.

# ---- Identity / team ----
@export var player_data: PlayerData
@export var team_id: int = 0
@export var is_goalkeeper: bool = false

## Normalized formation slot (see FormationManager), assigned by
## MatchManager at spawn time and used by TeamController/AIController and
## match-reset logic to know where this player belongs.
var formation_slot: Vector2 = Vector2.ZERO

# ---- Intent, written externally each physics frame ----
var move_input: Vector2 = Vector2.ZERO
var sprint_requested: bool = false
var pass_requested: bool = false
var shoot_held: bool = false

# ---- Movement tunables (defaults; overridden by player_data in apply_player_data) ----
var base_speed: float = 5.0
var sprint_speed: float = 8.5
@export var acceleration: float = 14.0
@export var deceleration: float = 20.0
@export var turn_lerp_speed: float = 12.0
@export var gravity: float = 20.0

@export var stamina_drain_rate: float = 18.0
@export var stamina_regen_rate: float = 10.0
var max_stamina: float = 100.0
var current_stamina: float = 100.0

# ---- Ball control / dribbling ----
@export var dribble_distance: float = 0.9
var dribble_accel: float = 24.0
@export var dribble_damping_accel: float = 9.0
@export var dribble_force_accel_clamp: float = 30.0
var control_loss_angle_threshold: float = 1.2
@export var control_loss_speed_threshold: float = 2.5
@export var control_loss_duration: float = 0.35
@export var possession_release_cooldown: float = 0.35

# ---- Pass / Shoot ----
var pass_power: float = 2.4
var shoot_min_power: float = 3.4
var shoot_max_power: float = 7.0
@export var shoot_charge_time: float = 1.1
@export var kick_lift: float = 0.35
@export var momentum_transfer: float = 0.25

@onready var action_area: Area3D = $ActionArea
@onready var control_area: Area3D = $ControlArea
@onready var model: Node3D = $Model
@onready var animation_controller: AnimationController = $Model/AnimationController
@onready var name_label: Label3D = $NameLabel
@onready var control_indicator: MeshInstance3D = $ControlIndicator

var ball_in_action_range: RigidBody3D = null
var ball_in_control_range: RigidBody3D = null

var has_possession: bool = false
var _facing_angle: float = 0.0

var _control_lost_timer: float = 0.0
var _possession_cooldown_timer: float = 0.0

var _shoot_charging: bool = false
var _shoot_charge_elapsed: float = 0.0


func _ready() -> void:
	action_area.body_entered.connect(_on_action_area_entered)
	action_area.body_exited.connect(_on_action_area_exited)
	control_area.body_entered.connect(_on_control_area_entered)
	control_area.body_exited.connect(_on_control_area_exited)

	if player_data:
		apply_player_data(player_data)

	if control_indicator:
		control_indicator.visible = false


func apply_player_data(data: PlayerData) -> void:
	player_data = data
	base_speed = data.movement_speed
	sprint_speed = data.sprint_speed
	acceleration = data.acceleration

	max_stamina = data.stamina
	current_stamina = max_stamina

	pass_power = lerp(1.6, 3.2, data.passing / 100.0)
	shoot_min_power = lerp(2.4, 4.2, data.shooting / 100.0)
	shoot_max_power = lerp(5.0, 8.5, data.shooting / 100.0)
	dribble_accel = lerp(16.0, 30.0, data.dribbling / 100.0)
	control_loss_angle_threshold = lerp(0.9, 1.5, data.dribbling / 100.0)

	if name_label:
		name_label.text = data.display_name

	if animation_controller:
		animation_controller.set_visual(data.visual_id)

	if control_area:
		var shape_node: CollisionShape3D = control_area.get_node("CollisionShape3D")
		if shape_node and shape_node.shape:
			var shape: SphereShape3D = shape_node.shape.duplicate()
			shape.radius = lerp(0.95, 1.35, data.defensive_ability / 100.0)
			shape_node.shape = shape


func set_team_color(color: Color) -> void:
	if animation_controller:
		animation_controller.set_team_color(color)


func set_controlled_visual(is_controlled: bool) -> void:
	if control_indicator:
		control_indicator.visible = is_controlled


## Called by PossessionManager when this player wins the ball away from an
## opponent (as opposed to picking up a loose ball) -- a reasonable, cheap
## proxy for "successfully tackled" without a dedicated tackle mechanic.
func notify_possession_won_from_opponent() -> void:
	if animation_controller:
		animation_controller.play_action("tackle")


## Called by MatchManager on every player of the scoring team after a goal.
func play_celebration() -> void:
	if animation_controller:
		animation_controller.play_action("celebration")


## Clears all input intent and cancels any in-progress shot charge. Called
## when a player stops being human-controlled so it doesn't keep coasting
## on stale input or fire a phantom shot mid-charge.
func reset_intent() -> void:
	move_input = Vector2.ZERO
	sprint_requested = false
	shoot_held = false
	pass_requested = false
	_shoot_charging = false
	_shoot_charge_elapsed = 0.0


func _physics_process(delta: float) -> void:
	var wants_sprint: bool = sprint_requested and move_input.length() > 0.1
	var sprinting: bool = wants_sprint and current_stamina > 0.0

	if sprinting:
		current_stamina = maxf(0.0, current_stamina - stamina_drain_rate * delta)
	else:
		current_stamina = minf(max_stamina, current_stamina + stamina_regen_rate * delta)

	var target_speed: float = sprint_speed if sprinting else base_speed
	var direction := Vector3(move_input.x, 0.0, move_input.y)

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
	_update_animation_state()

	if _control_lost_timer > 0.0:
		_control_lost_timer = maxf(0.0, _control_lost_timer - delta)
	if _possession_cooldown_timer > 0.0:
		_possession_cooldown_timer = maxf(0.0, _possession_cooldown_timer - delta)


func _update_animation_state() -> void:
	if animation_controller == null:
		return
	var speed: float = Vector2(velocity.x, velocity.z).length()
	var state: String
	if speed < 0.3:
		state = "idle"
	elif has_possession:
		state = "dribble"
	elif speed >= sprint_speed * 0.85:
		state = "sprint"
	elif speed >= base_speed * 0.6:
		state = "run"
	else:
		state = "walk"
	animation_controller.set_state(state)


func _get_aim_direction() -> Vector3:
	if move_input.length() > 0.15:
		return Vector3(move_input.x, 0.0, move_input.y).normalized()
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
	if not pass_requested:
		return
	pass_requested = false
	execute_pass()


func _process_shoot_input(delta: float) -> void:
	if shoot_held:
		if not _shoot_charging:
			_shoot_charging = true
			_shoot_charge_elapsed = 0.0
		else:
			_shoot_charge_elapsed = minf(_shoot_charge_elapsed + delta, shoot_charge_time)
	elif _shoot_charging:
		_shoot_charging = false
		var charge_ratio: float = _shoot_charge_elapsed / shoot_charge_time if shoot_charge_time > 0.0 else 1.0
		_shoot_charge_elapsed = 0.0
		execute_shot(charge_ratio)


## Public kick API -- used by the human charge-release flow above and
## called directly by AIController for AI-driven passes/shots.
func execute_pass() -> void:
	if ball_in_action_range == null:
		return
	_apply_kick_impulse(ball_in_action_range, pass_power, false)


func execute_shot(charge_ratio: float) -> void:
	if ball_in_action_range == null:
		return
	var power: float = lerp(shoot_min_power, shoot_max_power, clampf(charge_ratio, 0.0, 1.0))
	_apply_kick_impulse(ball_in_action_range, power, true)


func _apply_kick_impulse(ball: RigidBody3D, power: float, is_shot: bool) -> void:
	var aim_dir := _get_aim_direction()
	var impulse: Vector3 = aim_dir * power + velocity * momentum_transfer
	impulse.y = kick_lift * (1.0 if is_shot else 0.6)

	ball.apply_central_impulse(impulse)

	has_possession = false
	_control_lost_timer = 0.0
	_possession_cooldown_timer = possession_release_cooldown

	if animation_controller:
		animation_controller.play_action("shoot" if is_shot else "pass")


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
