class_name TouchButton
extends Control

## Self-drawing on-screen action button built for real multitouch. It
## deliberately never uses Godot's Button/BaseButton -- those resolve
## touch input through the engine's single emulated-mouse pointer, which
## is exactly why the old TouchControls setup couldn't hold this button
## and drag the joystick at the same time. HUD.gd owns one central
## per-finger dispatcher and calls press()/release() directly on whichever
## button or joystick a given touch index actually landed on, so any
## number of independent fingers can each own a different control at once.

signal pressed_down
signal pressed_up

@export var label_text: String = ""
@export var base_color: Color = Color(1, 1, 1, 0.16)
@export var pressed_color: Color = Color(1, 1, 1, 0.36)
@export var ring_color: Color = Color(1, 1, 1, 0.45)
@export var accent_color: Color = Color(1, 0.82, 0.2, 1.0)

## 0 draws no charge ring; >0 fills an arc clockwise from the top -- used
## by the SHOOT button to show hold-to-charge progress.
var charge_ratio: float = 0.0
var is_pressed: bool = false


func press() -> void:
	if is_pressed:
		return
	is_pressed = true
	queue_redraw()
	pressed_down.emit()


func release() -> void:
	if not is_pressed:
		return
	is_pressed = false
	charge_ratio = 0.0
	queue_redraw()
	pressed_up.emit()


func set_charge_ratio(ratio: float) -> void:
	var clamped: float = clampf(ratio, 0.0, 1.0)
	if is_equal_approx(clamped, charge_ratio):
		return
	charge_ratio = clamped
	queue_redraw()


## Circular hit region centered on this control, sized to its box -- a
## generous, thumb-friendly tap target rather than pixel-perfect bounds.
func hit_test(screen_pos: Vector2) -> bool:
	var local: Vector2 = screen_pos - global_position
	var radius: float = minf(size.x, size.y) * 0.5
	return local.distance_to(size * 0.5) <= radius


func _draw() -> void:
	var center: Vector2 = size * 0.5
	var radius: float = minf(size.x, size.y) * 0.5

	draw_circle(center, radius, pressed_color if is_pressed else base_color)
	draw_arc(center, radius - 3.0, 0.0, TAU, 32, ring_color, 3.0)

	if charge_ratio > 0.0:
		draw_arc(center, radius - 8.0, -PI / 2.0, -PI / 2.0 + TAU * charge_ratio, 32, accent_color, 5.0)

	if label_text != "":
		var font: Font = ThemeDB.fallback_font
		var font_size: int = maxi(14, int(radius * 0.42))
		var text_size: Vector2 = font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var draw_pos := Vector2(center.x - text_size.x * 0.5, center.y + font_size * 0.32)
		draw_string(font, draw_pos, label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(1, 1, 1, 0.95))
