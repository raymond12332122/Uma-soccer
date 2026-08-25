extends RigidBody3D

@export var reset_height: float = -10.0

var spawn_position: Vector3


func _ready() -> void:
	spawn_position = global_position
	add_to_group("ball")


func _physics_process(_delta: float) -> void:
	if global_position.y < reset_height:
		reset_ball()


func reset_ball() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_position = spawn_position
