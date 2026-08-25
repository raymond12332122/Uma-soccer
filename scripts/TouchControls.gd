extends CanvasLayer

@onready var joystick: Control = $JoystickBase
@onready var pass_button: Button = $PassButton
@onready var shoot_button: Button = $ShootButton
@onready var sprint_button: Button = $SprintButton
@onready var switch_button: Button = $SwitchButton


func _ready() -> void:
	joystick.vector_changed.connect(_on_joystick_vector_changed)
	pass_button.button_down.connect(_on_pass_pressed)
	shoot_button.button_down.connect(_on_shoot_down)
	shoot_button.button_up.connect(_on_shoot_up)
	sprint_button.button_down.connect(_on_sprint_down)
	sprint_button.button_up.connect(_on_sprint_up)
	switch_button.button_down.connect(_on_switch_pressed)


func _on_joystick_vector_changed(vector: Vector2) -> void:
	InputState.move_vector = vector


func _on_pass_pressed() -> void:
	InputState.pass_pressed = true


func _on_shoot_down() -> void:
	InputState.shoot_held = true


func _on_shoot_up() -> void:
	InputState.shoot_held = false


func _on_sprint_down() -> void:
	InputState.sprint_held = true


func _on_sprint_up() -> void:
	InputState.sprint_held = false


func _on_switch_pressed() -> void:
	InputState.switch_pressed = true
