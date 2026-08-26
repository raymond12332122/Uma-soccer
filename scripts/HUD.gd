extends CanvasLayer

## Gameplay HUD: mobile-football-style layout (top score/timer, controlled-
## player info + stamina, left joystick, right action cluster) plus the
## single central multitouch dispatcher for every on-screen control.
##
## Multitouch design: each active finger (InputEventScreenTouch.index) or
## the mouse pointer (using the reserved index -1, for desktop/editor
## testing) is bound to at most one control at the moment it goes down --
## whichever of the joystick/buttons its hit_test() claims it first. That
## binding is exclusive and independent per finger until release, so e.g.
## a thumb held on SHOOT never sees input meant for the joystick-holding
## thumb, and vice versa. This relies on the project disabling
## "emulate_mouse_from_touch" (see project.godot) -- otherwise a real touch
## would additionally arrive here a second time as a synthesized mouse
## event tied to the same reserved index as genuine desktop mouse input.

## Set once by MatchManager right after instancing this scene.
var match_manager: Node = null

@onready var joystick: VirtualJoystick = $Joystick
@onready var shoot_button: TouchButton = $ShootButton
@onready var pass_button: TouchButton = $PassButton
@onready var sprint_button: TouchButton = $SprintButton
@onready var switch_button: TouchButton = $SwitchButton

@onready var player_name_label: Label = $PlayerInfoPanel/PlayerNameLabel
@onready var stamina_bar: ProgressBar = $PlayerInfoPanel/StaminaBar
@onready var timer_label: Label = $TimerLabel

## touch index (int; -1 reserved for the mouse pointer) -> the control
## instance that index currently owns exclusively.
var _touch_owner: Dictionary = {}
var _stamina_fill_style: StyleBoxFlat = null


func _ready() -> void:
	joystick.vector_changed.connect(_on_joystick_vector_changed)
	shoot_button.pressed_down.connect(_on_shoot_pressed_down)
	shoot_button.pressed_up.connect(_on_shoot_pressed_up)
	sprint_button.pressed_down.connect(func(): InputState.sprint_held = true)
	sprint_button.pressed_up.connect(func(): InputState.sprint_held = false)
	pass_button.pressed_down.connect(func(): InputState.pass_pressed = true)
	switch_button.pressed_down.connect(func(): InputState.switch_pressed = true)

	var base_fill: StyleBox = stamina_bar.get_theme_stylebox("fill")
	if base_fill is StyleBoxFlat:
		_stamina_fill_style = base_fill.duplicate()
		stamina_bar.add_theme_stylebox_override("fill", _stamina_fill_style)


func _on_joystick_vector_changed(vector: Vector2) -> void:
	InputState.move_vector = vector


## Real-timestamped press/release (see InputState.gd's doc comment) rather
## than a plain level-triggered bool -- guarantees a fast tap still fires,
## even if both edges land inside the same physics-tick gap.
func _on_shoot_pressed_down() -> void:
	InputState.shoot_held = true
	InputState.shoot_pressed_at_ms = Time.get_ticks_msec()


func _on_shoot_pressed_up() -> void:
	InputState.shoot_held = false
	if InputState.shoot_pressed_at_ms >= 0:
		InputState.shoot_release_elapsed_seconds = (Time.get_ticks_msec() - InputState.shoot_pressed_at_ms) / 1000.0
		InputState.shoot_release_pending = true
	InputState.shoot_pressed_at_ms = -1


func _process(_delta: float) -> void:
	if match_manager == null:
		return

	if match_manager.has_method("get_match_time_string"):
		timer_label.text = match_manager.get_match_time_string()

	var controlled: FootballPlayer = match_manager.player_controller.controlled_player if match_manager.player_controller else null
	if controlled == null:
		return

	player_name_label.text = controlled.player_data.display_name if controlled.player_data else "?"

	var stamina_ratio: float = (controlled.current_stamina / controlled.max_stamina) if controlled.max_stamina > 0.0 else 1.0
	stamina_bar.value = stamina_ratio * 100.0
	if _stamina_fill_style:
		_stamina_fill_style.bg_color = Color(1.0, 0.78, 0.15) if controlled.is_currently_sprinting else Color(0.29, 0.85, 0.4)

	shoot_button.set_charge_ratio(controlled.get_shoot_charge_ratio())


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_try_bind(event.index, event.position)
		else:
			_release(event.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_bind(-1, event.position)
		else:
			_release(-1)
	elif event is InputEventMouseMotion:
		if _touch_owner.has(-1):
			_drag(-1, event.position)


## Hit-test order: joystick first (spatially separate, left side), then
## the right-side action buttons. First match wins and owns this touch
## index exclusively until it's released.
func _try_bind(index: int, pos: Vector2) -> void:
	if _touch_owner.has(index):
		return
	if joystick.hit_test(pos):
		_touch_owner[index] = joystick
		joystick.begin(pos)
		return
	for button: TouchButton in [shoot_button, pass_button, sprint_button, switch_button]:
		if button.hit_test(pos):
			_touch_owner[index] = button
			button.press()
			return


func _drag(index: int, pos: Vector2) -> void:
	var owner_control = _touch_owner.get(index)
	if owner_control == joystick:
		joystick.drag(pos)


func _release(index: int) -> void:
	var owner_control = _touch_owner.get(index)
	if owner_control == null:
		return
	_touch_owner.erase(index)
	if owner_control == joystick:
		joystick.end()
	else:
		owner_control.release()
