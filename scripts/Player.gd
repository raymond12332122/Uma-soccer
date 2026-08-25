extends CharacterBody3D

@export var speed: float = 6.0
@export var acceleration: float = 12.0
@export var gravity: float = 20.0
@export var kick_force: float = 14.0

@onready var kick_area: Area3D = $KickArea
@onready var model: Node3D = $Model

var ball_in_range: RigidBody3D = null
var _space_was_pressed: bool = false


func _ready() -> void:
	kick_area.body_entered.connect(_on_kick_area_body_entered)
	kick_area.body_exited.connect(_on_kick_area_body_exited)


func _physics_process(delta: float) -> void:
	var input_vector: Vector2 = InputState.move_vector

	if input_vector == Vector2.ZERO:
		input_vector = _keyboard_vector()

	input_vector = input_vector.limit_length(1.0)
	var direction := Vector3(input_vector.x, 0.0, input_vector.y)

	if direction.length() > 0.01:
		velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * delta)
		velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * delta)
		model.rotation.y = atan2(direction.x, direction.z)
	else:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()

	var space_now := Input.is_key_pressed(KEY_SPACE)
	var kick_triggered := InputState.kick_pressed or (space_now and not _space_was_pressed)
	_space_was_pressed = space_now
	InputState.kick_pressed = false

	if kick_triggered and ball_in_range:
		_kick_ball()


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


func _kick_ball() -> void:
	var to_ball: Vector3 = ball_in_range.global_position - global_position
	to_ball.y = 0.3
	var impulse: Vector3 = to_ball.normalized() * kick_force
	ball_in_range.apply_central_impulse(impulse)


func _on_kick_area_body_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_range = body


func _on_kick_area_body_exited(body: Node3D) -> void:
	if body == ball_in_range:
		ball_in_range = null
