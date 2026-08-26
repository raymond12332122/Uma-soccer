class_name CameraController
extends Node3D

@export var target_path: NodePath
@export var ball_path: NodePath
@export var follow_speed: float = 5.5
@export var ball_bias: float = 0.28
## Closer/lower than the old distant-simulation framing (was Vector3(0, 9, 7))
## -- players read clearly on a phone screen while still keeping enough
## pitch in view for tactical awareness.
@export var base_camera_offset: Vector3 = Vector3(0, 6, 4.6)
@export var max_extra_back: float = 3.0
@export var zoom_distance_threshold: float = 7.0

@onready var camera: Camera3D = $Camera3D

var target: Node3D
var ball: Node3D


func _ready() -> void:
	if target_path != NodePath():
		target = get_node(target_path)
	if ball_path != NodePath():
		ball = get_node(ball_path)
	if camera:
		camera.position = base_camera_offset


## Runtime retargeting -- used by MatchManager on player switch, since the
## human-controlled player (and therefore the camera's follow target) can
## change at any time.
func set_target(node: Node3D) -> void:
	target = node


func set_ball(node: Node3D) -> void:
	ball = node


func _process(delta: float) -> void:
	if target == null:
		return

	var focus_pos: Vector3 = target.global_position
	if ball:
		focus_pos = focus_pos.lerp(ball.global_position, ball_bias)

	global_position.x = lerp(global_position.x, focus_pos.x, follow_speed * delta)
	global_position.z = lerp(global_position.z, focus_pos.z, follow_speed * delta)

	if ball and camera:
		var separation: float = target.global_position.distance_to(ball.global_position)
		var extra: float = clampf(separation - zoom_distance_threshold, 0.0, 10.0)
		var extra_back: float = minf(extra * 0.4, max_extra_back)
		var desired_offset: Vector3 = base_camera_offset + Vector3(0, extra_back * 0.5, extra_back)
		camera.position = camera.position.lerp(desired_offset, follow_speed * delta)
