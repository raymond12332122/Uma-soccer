class_name PlayerController
extends Node

## Drives exactly one FootballPlayer from human input (touch via
## InputState, or keyboard). Reassigning the target is how "player
## switching" works -- the previously-controlled player is handed back to
## AI simply by no longer being this controller's target.

var controlled_player: FootballPlayer = null

var _f_was_pressed: bool = false


func set_controlled_player(player: FootballPlayer) -> void:
	if controlled_player:
		controlled_player.reset_intent()
	controlled_player = player


func _physics_process(_delta: float) -> void:
	if controlled_player == null:
		return

	var move_vector: Vector2 = InputState.move_vector
	if move_vector == Vector2.ZERO:
		move_vector = _keyboard_vector()
	move_vector = move_vector.limit_length(1.0)

	controlled_player.move_input = move_vector
	controlled_player.sprint_requested = InputState.sprint_held or Input.is_key_pressed(KEY_SHIFT)
	controlled_player.shoot_held = InputState.shoot_held or Input.is_key_pressed(KEY_SPACE)

	var f_now := Input.is_key_pressed(KEY_F)
	var f_just_pressed := f_now and not _f_was_pressed
	_f_was_pressed = f_now

	if InputState.pass_pressed or f_just_pressed:
		controlled_player.pass_requested = true
	InputState.pass_pressed = false


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
