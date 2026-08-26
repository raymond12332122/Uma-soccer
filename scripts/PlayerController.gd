class_name PlayerController
extends Node

## Drives exactly one FootballPlayer from human input (touch via
## InputState, or keyboard). Reassigning the target is how "player
## switching" works -- the previously-controlled player is handed back to
## AI simply by no longer being this controller's target.

var controlled_player: FootballPlayer = null

var _f_was_pressed: bool = false
var _space_was_pressed: bool = false
var _space_pressed_at_ms: int = -1
var _touch_shoot_was_held: bool = false
## Which player a currently-in-progress touch-SHOOT press was observed to
## start on, or null if none is in progress -- lets the direct-InputState
## fallback below (see _physics_process) tell "this hold has belonged to
## the same controlled player the whole time" apart from "the player
## changed underneath a still-physically-held finger", without which a
## switch mid-charge could credit a phantom release to whoever is
## controlled by the time the finger finally lifts.
var _fallback_press_owner: FootballPlayer = null


func set_controlled_player(player: FootballPlayer) -> void:
	if controlled_player:
		controlled_player.reset_intent()
	controlled_player = player
	# A touch-SHOOT press still physically held across a switch must not
	# get to credit time that happened while a DIFFERENT player was
	# charging to this one -- that would be a phantom shot (see
	# InputState.gd's doc comment and FootballPlayer.notify_shoot_release()).
	# But a finger that's still physically down should keep working for
	# whoever is controlled now, same as any other still-held control
	# (sprint, movement) does -- so rather than dropping it outright,
	# restart its credited hold from this exact moment for the new player.
	if InputState.shoot_held and InputState.shoot_pressed_at_ms >= 0:
		InputState.shoot_pressed_at_ms = Time.get_ticks_msec()
		_fallback_press_owner = player
	else:
		InputState.shoot_pressed_at_ms = -1
		_fallback_press_owner = null
	InputState.shoot_release_pending = false


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

	# Keyboard mirrors the same real-timestamp release path touch uses
	# (see InputState.gd) -- keeps a single, exclusive firing point
	# (FootballPlayer.notify_shoot_release()) for both input methods
	# instead of two separate release-detection paths that could race.
	var space_now := Input.is_key_pressed(KEY_SPACE)
	if space_now and not _space_was_pressed:
		_space_pressed_at_ms = Time.get_ticks_msec()
	if not space_now and _space_was_pressed and _space_pressed_at_ms >= 0:
		var elapsed: float = (Time.get_ticks_msec() - _space_pressed_at_ms) / 1000.0
		controlled_player.notify_shoot_release(elapsed)
		_space_pressed_at_ms = -1
	_space_was_pressed = space_now

	var touch_shoot_now: bool = InputState.shoot_held
	if touch_shoot_now and not _touch_shoot_was_held:
		_fallback_press_owner = controlled_player
	if InputState.shoot_release_pending:
		controlled_player.notify_shoot_release(InputState.shoot_release_elapsed_seconds)
		InputState.shoot_release_pending = false
		_fallback_press_owner = null
	elif _touch_shoot_was_held and not touch_shoot_now and _fallback_press_owner == controlled_player:
		# Fallback for InputState.shoot_held being toggled directly rather
		# than through HUD's precise-timestamp press/release signals (e.g.
		# tests driving InputState by hand, or any other future direct
		# consumer) -- fires using whatever charge FootballPlayer already
		# accumulated this hold via _process_shoot_input(). HUD's own
		# releases always set shoot_release_pending in the same signal
		# handler that clears shoot_held, so this branch never double-fires
		# for a real touch release. Gated on _fallback_press_owner so a
		# press that started on a player who has since been switched away
		# from can't fire on whoever is controlled now.
		controlled_player.notify_shoot_release(0.0)
		_fallback_press_owner = null
	_touch_shoot_was_held = touch_shoot_now


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
