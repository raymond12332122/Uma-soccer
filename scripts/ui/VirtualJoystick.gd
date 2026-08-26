class_name VirtualJoystick
extends Control

## Floating-base virtual joystick driven entirely by HUD.gd's central
## multitouch dispatcher (see TouchButton.gd for why): this control never
## reads input itself, it just exposes begin()/drag()/end() for whichever
## touch index the dispatcher assigned to it, and hit_test() so the
## dispatcher can decide whether a given touch-down landed on it in the
## first place.

signal vector_changed(vector: Vector2)

@export var max_radius: float = 72.0
## Hit-catch radius around the joystick's resting position, larger than
## the visual base so a thumb doesn't need to land pixel-perfectly on it
## ("easier to reach" -- HUD requirement).
@export var catch_radius: float = 120.0

var active: bool = false
var knob_offset: Vector2 = Vector2.ZERO
var _origin: Vector2 = Vector2.ZERO


func hit_test(screen_pos: Vector2) -> bool:
	var local: Vector2 = screen_pos - global_position
	return local.distance_to(size * 0.5) <= catch_radius


## The base visually recenters under wherever the thumb actually landed
## (clamped to stay fully on screen within this control's own box) --
## classic floating-joystick behavior, forgiving about exact placement.
func begin(screen_pos: Vector2) -> void:
	active = true
	var local: Vector2 = screen_pos - global_position
	_origin = Vector2(
		clampf(local.x, max_radius, size.x - max_radius),
		clampf(local.y, max_radius, size.y - max_radius)
	)
	knob_offset = Vector2.ZERO
	queue_redraw()
	vector_changed.emit(Vector2.ZERO)


func drag(screen_pos: Vector2) -> void:
	if not active:
		return
	var local: Vector2 = screen_pos - global_position
	var offset: Vector2 = local - _origin
	if offset.length() > max_radius:
		offset = offset.normalized() * max_radius
	knob_offset = offset
	queue_redraw()
	vector_changed.emit(offset / max_radius)


func end() -> void:
	active = false
	knob_offset = Vector2.ZERO
	queue_redraw()
	vector_changed.emit(Vector2.ZERO)


func _draw() -> void:
	var origin: Vector2 = _origin if active else size * 0.5
	draw_circle(origin, max_radius, Color(1, 1, 1, 0.14))
	draw_arc(origin, max_radius, 0.0, TAU, 40, Color(1, 1, 1, 0.35), 3.0)
	var knob_center: Vector2 = origin + knob_offset
	draw_circle(knob_center, max_radius * 0.42, Color(1, 1, 1, 0.62) if active else Color(1, 1, 1, 0.4))
