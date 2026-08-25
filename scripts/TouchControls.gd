extends CanvasLayer

@onready var joystick: Control = $JoystickBase
@onready var kick_button: Button = $KickButton


func _ready() -> void:
	joystick.vector_changed.connect(_on_joystick_vector_changed)
	kick_button.button_down.connect(_on_kick_pressed)


func _on_joystick_vector_changed(vector: Vector2) -> void:
	InputState.move_vector = vector


func _on_kick_pressed() -> void:
	InputState.kick_pressed = true
