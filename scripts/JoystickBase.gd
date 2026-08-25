extends Control

signal vector_changed(vector: Vector2)

@export var max_radius: float = 60.0

var dragging: bool = false
var knob_offset: Vector2 = Vector2.ZERO


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				dragging = true
				_update_knob(event.position)
			else:
				dragging = false
				knob_offset = Vector2.ZERO
				vector_changed.emit(Vector2.ZERO)
				queue_redraw()
	elif event is InputEventMouseMotion and dragging:
		_update_knob(event.position)


func _update_knob(pos: Vector2) -> void:
	var center: Vector2 = size / 2.0
	var offset: Vector2 = pos - center
	if offset.length() > max_radius:
		offset = offset.normalized() * max_radius
	knob_offset = offset
	queue_redraw()
	vector_changed.emit(offset / max_radius)


func _draw() -> void:
	var center: Vector2 = size / 2.0
	draw_circle(center, max_radius, Color(1, 1, 1, 0.15))
	draw_circle(center + knob_offset, max_radius * 0.4, Color(1, 1, 1, 0.55))
