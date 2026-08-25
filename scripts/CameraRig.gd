extends Node3D

@export var target_path: NodePath
@export var follow_speed: float = 4.0

var target: Node3D


func _ready() -> void:
	if target_path != NodePath():
		target = get_node(target_path)


func _process(delta: float) -> void:
	if target == null:
		return
	var target_pos: Vector3 = target.global_position
	global_position.x = lerp(global_position.x, target_pos.x, follow_speed * delta)
	global_position.z = lerp(global_position.z, target_pos.z, follow_speed * delta)
